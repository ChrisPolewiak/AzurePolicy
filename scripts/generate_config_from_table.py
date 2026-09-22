#!/usr/bin/env python3
"""Generate policy config JSON files from TSV/CSV source.

Outputs:
  - initiatives{suffix}.json
  - assignments{suffix}.json
  - parameters{suffix}.json
    - assignment-identities{suffix}.json

Run this script whenever policy assignments change.
For ARM JSON generation after a policy snapshot update, use generate_arm_from_source.py.
"""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
import re
from typing import Any, Dict, Iterable, List, Optional


def normalize_key(value: str) -> str:
    """Collapse extra whitespace in a column header so lookups are whitespace-insensitive."""
    return " ".join((value or "").strip().split())


def normalize_value(value: Optional[str]) -> str:
    """Strip leading/trailing whitespace from a cell value; treat None as empty string."""
    return (value or "").strip()


def to_bool(value: str) -> bool:
    """Return True for common truthy string representations (case-insensitive)."""
    return normalize_value(value).lower() in {"true", "1", "yes", "y"}


def detect_delimiter(path: Path) -> str:
    """Infer the column delimiter from file extension and header content.

    TSV files always use tab.  CSV files exported from Excel with a Polish locale
    often use semicolons instead of commas; we detect that by comparing counts in
    the first line.  Unknown extensions fall back to the same heuristic.
    """
    if path.suffix.lower() == ".tsv":
        return "\t"
    sample = path.read_text(encoding="utf-8-sig", errors="replace").splitlines()
    header = sample[0] if sample else ""

    if path.suffix.lower() == ".csv":
        # Prefer semicolon when it appears more often than comma (Polish Excel locale).
        if header.count(";") > header.count(","):
            return ";"
        return ","

    # Generic heuristic for files without a recognised extension.
    if "\t" in header:
        return "\t"
    if header.count(";") > header.count(","):
        return ";"
    return ","


def is_subscription_scope(scope_id: str) -> bool:
    """Return True when the scope ID looks like an Azure subscription.

    Accepts both full ARM paths (/subscriptions/<guid>) and bare GUID strings
    so the TSV can contain either form.
    """
    scope = normalize_value(scope_id)
    if scope.lower().startswith("/subscriptions/"):
        return True

    # Bare GUID has the shape xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx (8-4-4-4-12 hex chars).
    parts = scope.split("-")
    expected = [8, 4, 4, 4, 12]
    if len(parts) != 5:
        return False
    return all(len(part) == exp for part, exp in zip(parts, expected))


def normalize_scope_type(scope_type: str) -> str:
    """Map supported scope-type aliases to the generated configuration value."""
    normalized = re.sub(r"[\s_-]+", "", normalize_value(scope_type).lower())
    if normalized in {"mg", "managementgroup"}:
        return "managementGroup"
    if normalized in {"sub", "sb", "subscription"}:
        return "subscription"
    raise ValueError(
        "Scope Type must be one of: MG, managementgroup, SUB, SB, subscription."
    )


def is_guid(value: str) -> bool:
    """Return True when *value* is a canonical GUID string."""
    return bool(re.fullmatch(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", normalize_value(value)))


def collect_source_definition_names(source_dir: Path, subdir: str) -> set[str]:
    """Return file stems from source/<subdir>/*.json, or empty set if missing."""
    target = source_dir / subdir
    if not target.exists():
        return set()
    return {p.stem for p in target.glob("*.json")}


def parse_list_values(value: str) -> List[str]:
    """Parse comma/semicolon/newline separated values into a cleaned list."""
    raw = normalize_value(value)
    if not raw:
        return []
    parts: List[str] = []
    for line in raw.replace(";", ",").splitlines():
        for item in line.split(","):
            cleaned = normalize_value(item).strip('"')
            if cleaned:
                parts.append(cleaned)
    return parts


def slugify_name(value: str) -> str:
    """Return lowercase alphanumeric-and-dash slug suitable for Azure resource names."""
    slug = re.sub(r"[^a-z0-9-]+", "-", normalize_value(value).lower())
    slug = re.sub(r"-+", "-", slug).strip("-")
    return slug


def default_identity_name(assignment_name: str, scope_type: str, scope_id: str) -> str:
    """Build deterministic user-assigned identity name for a policy assignment.

    Preserves hyphens and underscores from the InternalID (e.g. AP2026-04-28_0001)
    so the identity name is human-readable and searchable as id-policy-AP2026-04-28_0001.
    UAMI naming rules: 3-128 chars, alphanumeric + hyphens + underscores,
    must start and end with letter or number.
    """
    # Keep hyphens and underscores — both are valid in UAMI names
    token = re.sub(r"[^A-Za-z0-9\-_]+", "", normalize_value(assignment_name)) or "assignment"
    # Strip leading/trailing separators to satisfy Azure naming rule
    token = token.strip("-_")
    name = f"id-policy-{token}"
    # Truncate to 128 chars; ensure last char is alphanumeric after truncation
    name = name[:128].rstrip("-_")
    return name


def assignment_scope_path(scope_type: str, scope_id: str) -> str:
    """Return canonical ARM scope path for a management group or subscription assignment."""
    if scope_type == "subscription":
        return f"/subscriptions/{scope_id}"
    return f"/providers/Microsoft.Management/managementGroups/{scope_id}"


def normalize_assignment_scope(scope_id: str, deployment_config: Dict[str, Any]) -> str:
    """Resolve supported assignment-scope aliases to their Azure resource ID.

    ROOT is an explicit alias for the configured root management group. It is
    intentionally resolved before subscription detection because Azure
    management-group IDs can also look like GUIDs.
    """
    normalized = normalize_value(scope_id)
    if normalized.lower().startswith("/subscriptions/"):
        subscription_id = normalized.rstrip("/").rsplit("/", 1)[-1]
        if is_guid(subscription_id):
            return subscription_id

    if normalized.upper() != "ROOT":
        return normalized

    deployment = deployment_config.get("deployment", {})
    root_management_group = normalize_value(
        deployment.get("definitionManagementGroupId", "")
    ) if isinstance(deployment, dict) else ""
    if not root_management_group or root_management_group.startswith("<"):
        raise ValueError(
            "Assignment Scope ROOT requires a configured "
            "deployment.definitionManagementGroupId in configuration/deployment-config.json."
        )
    return root_management_group


def normalize_tags(value: Any) -> Dict[str, str]:
    """Return a stringified tag dictionary from arbitrary JSON-like input."""
    if not isinstance(value, dict):
        return {}
    return {
        str(k): str(v)
        for k, v in value.items()
        if normalize_value(str(k))
    }


def normalize_row(raw_row: Dict[str, str]) -> Dict[str, str]:
    """Return a copy of the CSV row with keys and values normalised.

    Removes None keys that csv.DictReader can produce for trailing delimiters,
    and collapses whitespace in column headers so lookups are robust to
    formatting differences in the source file.
    """
    return {
        normalize_key(k): normalize_value(v)
        for k, v in raw_row.items()
        if k is not None
    }


def read_rows(path: Path, only_deploy_true: bool) -> List[Dict[str, str]]:
    """Read the assignments source file and return a list of normalised row dicts.

    When *only_deploy_true* is set (the default), rows whose Deploy column is not
    a truthy value are silently dropped so they never reach the output JSON.
    utf-8-sig handles the optional BOM that Excel adds when saving as UTF-8 CSV.
    """
    delimiter = detect_delimiter(path)
    rows: List[Dict[str, str]] = []

    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter)
        for raw_row in reader:
            row = normalize_row(raw_row)
            # Filter out rows that are not marked for deployment.
            if only_deploy_true and not to_bool(row.get("Deploy", "")):
                continue
            rows.append(row)

    return rows


def build_json_payloads(
    rows: Iterable[Dict[str, str]],
    location: str,
    source_dir: Path,
    deployment_config: Dict[str, Any],
    custom_dir: Optional[Path] = None,
) -> tuple[list[dict], list[dict], dict, list[dict]]:
    """Convert normalised TSV rows into three JSON payloads.

    Returns a tuple of (initiatives, assignments, parameters, assignment_identities)
    that map directly to deployment-time JSON files.

    - initiatives  – deduplicated list of initiative (policy set) definitions to deploy.
    - assignments  – one entry per assignment row; each entry carries the 'managed' marker
                     so deployments can be identified as policy-by-code managed.
    - parameters   – empty skeleton dict keyed by Parameter Set name; actual values are
                     overlaid later from the dedicated parameters source file.
    """
    initiatives: List[dict] = []
    assignments: List[dict] = []
    parameters: Dict[str, dict] = {}
    assignment_identities: List[dict] = []
    management_tag = deployment_config.get("managementTag", "policy-by-code") if isinstance(deployment_config, dict) else "policy-by-code"
    identity_defaults = deployment_config.get("identityDefaults", {}) if isinstance(deployment_config, dict) else {}
    default_identity_tags = normalize_tags(identity_defaults.get("tags", {}))
    source_policy_set_names = collect_source_definition_names(source_dir, "policySetDefinitions")
    source_policy_def_names = collect_source_definition_names(source_dir, "policyDefinitions")
    # Track initiative names already added to avoid duplicate entries.
    seen_initiative_names: set[str] = set()

    for row in rows:
        internal_id = normalize_value(row.get("InternalID", ""))
        raw_assignment_scope = normalize_value(row.get("Assignment Scope", ""))
        is_root_management_group_scope = raw_assignment_scope.upper() == "ROOT"
        scope_type = normalize_scope_type(row.get("Scope Type", ""))
        if is_root_management_group_scope and scope_type != "managementGroup":
            raise ValueError("Assignment Scope ROOT requires Scope Type MG or managementgroup.")
        assignment_scope = normalize_assignment_scope(
            raw_assignment_scope, deployment_config
        )
        parameter_set = normalize_value(row.get("Parameter Set", ""))
        effect_value = normalize_value(row.get("DeployIfNotExists", ""))
        enforcement_mode = normalize_value(row.get("Enforcement Mode", "")) or "Default"
        # Accept both 'DefinitionType' and the legacy 'Type' column header.
        definition_type = normalize_value(
            row.get("DefinitionType", "") or row.get("Type", "")
        ).lower()
        # Type2 column distinguishes Built-in from Custom (used to build correct policyDefinitionId).
        definition_type2 = normalize_value(row.get("Type2", "")).lower()
        definition_id = normalize_value(row.get("ID", ""))
        definition_name = normalize_value(row.get("Definition Name", ""))[:128]
        assignment_name = normalize_value(row.get("Assignment Name", ""))
        comment_text = normalize_value(
            row.get("Comment", "") or row.get("Description", "")
        )

        # Rows missing mandatory fields are silently skipped.
        if not assignment_name or not assignment_scope:
            continue

        print(f"Processing assignment: {internal_id} {assignment_name} (Scope: {assignment_scope}) (Deploy: {row.get('Deploy')})")
        # Guard against rows that passed read_rows filtering but still have Deploy=FALSE
        # (can happen when --all flag is used together with explicit Deploy column).
        if not to_bool(row.get("Deploy", "true")):
            continue

        # Build the common part of the assignment entry shared by both types.
        assignment_entry = {
            # ARM resource name must be ≤24 chars; use InternalID (e.g. ap001) as a
            # stable short resource name and keep the human-readable label as displayName.
            "name": internal_id,
            "displayName": f"{assignment_name} ({internal_id})"[:128],
            "scope": {
                # Distinguish subscription-scope from management-group-scope assignments.
                "type": scope_type,
                "id": assignment_scope,
            },
            "enforcementMode": enforcement_mode,
            "location": location,
            # Marker used by deployment scripts to identify policy-as-code managed assignments.
            "managed": management_tag,
            # Used by parameters binding to split initiative vs policy parameter sets.
            "definitionType": "initiative" if definition_type == "initiative" else "policy",
        }

        # metadata is always written so assignedBy reaches Azure and appears in the portal.
        assignment_entry["metadata"] = {"assignedBy": management_tag}
        # Always append the ARM resource name (internal_id) to description so it is
        # visible and searchable in the Azure portal (portal shows displayName, not name).
        description_parts = [comment_text] if comment_text else []
        description_parts.append(f"({internal_id})")
        assignment_entry["description"] = " ".join(description_parts)
        if comment_text:
            assignment_entry["metadata"]["comment"] = comment_text

        if definition_type == "initiative":
            # Initiative assignment:
            # - custom (from GH/source): reference MG-scoped policy set by name
            # - built-in: reference global policySetDefinitions path directly
            if not definition_name or not definition_id:
                continue

            if definition_id.startswith("/providers/"):
                assignment_entry["policyDefinitionId"] = definition_id
            elif definition_id in source_policy_set_names:
                assignment_entry["initiativeName"] = definition_id
            elif is_guid(definition_id):
                assignment_entry["policyDefinitionId"] = f"/providers/Microsoft.Authorization/policySetDefinitions/{definition_id}"
            elif definition_type2 == "built-in":
                # Built-in initiatives referenced by friendly name (not GUID) must use the
                # global (non-MG-scoped) path; using initiativeName would cause Bicep to
                # prepend the management group path, resulting in PolicySetDefinitionNotFound.
                assignment_entry["policyDefinitionId"] = f"/providers/Microsoft.Authorization/policySetDefinitions/{definition_id}"
            else:
                assignment_entry["initiativeName"] = definition_id

            # Add the initiative definition only once even if it appears in multiple rows.
            if definition_id in source_policy_set_names and definition_id not in seen_initiative_names:
                initiatives.append(
                    {
                        "name": definition_id,
                        "definitionFile": f"source/policySetDefinitions/{definition_id}.json",
                        "enabled": True,
                    }
                )
                seen_initiative_names.add(definition_id)

            # Auto-detect targetManagementGroup from custom initiative source file.
            if custom_dir is not None and "initiativeName" in assignment_entry:
                _custom_init_path = (
                    custom_dir / "policySetDefinitions" / f"{assignment_entry['initiativeName']}.json"
                )
                if _custom_init_path.exists():
                    try:
                        with _custom_init_path.open() as _f:
                            _init_def = json.load(_f)
                        _target_mg = (
                            _init_def.get("properties", {})
                            .get("metadata", {})
                            .get("targetManagementGroup")
                        )
                        if _target_mg:
                            assignment_entry["definitionManagementGroupId"] = _target_mg
                    except Exception:
                        pass
        else:
            # Individual policy assignment:
            # - custom (from GH/source): reference MG-scoped policy definition by name
            # - built-in: reference global policyDefinitions path directly
            policy_name = definition_id or definition_name
            if not policy_name:
                continue
            if policy_name.startswith("/providers/"):
                assignment_entry["policyDefinitionId"] = policy_name
            elif policy_name in source_policy_def_names:
                assignment_entry["policyDefinitionName"] = policy_name
            elif is_guid(policy_name):
                assignment_entry["policyDefinitionId"] = f"/providers/Microsoft.Authorization/policyDefinitions/{policy_name}"
            else:
                assignment_entry["policyDefinitionName"] = policy_name

            # Auto-detect targetManagementGroup from custom policy definition source file.
            # If the source JSON has metadata.targetManagementGroup, the definition lives in
            # a specific child MG rather than the global root — propagate it to the assignment
            # so the Bicep template builds the correct policyDefinitionId automatically.
            if custom_dir is not None and "policyDefinitionName" in assignment_entry:
                _custom_def_path = (
                    custom_dir / "policyDefinitions" / f"{assignment_entry['policyDefinitionName']}.json"
                )
                if _custom_def_path.exists():
                    try:
                        with _custom_def_path.open() as _f:
                            _def = json.load(_f)
                        _target_mg = (
                            _def.get("properties", {})
                            .get("metadata", {})
                            .get("targetManagementGroup")
                        )
                        if _target_mg:
                            assignment_entry["definitionManagementGroupId"] = _target_mg
                    except Exception:
                        pass

        if parameter_set:
            # Link the assignment to a parameter set; values come from policy-parameters.tsv.
            assignment_entry["parametersKey"] = parameter_set

        assignments.append(assignment_entry)

        rbac_roles_raw = normalize_value(
            row.get("Identity RBAC Roles", "") or row.get("RBAC Roles", "")
        )
        rbac_scopes_raw = normalize_value(
            row.get("Identity RBAC Scope", "") or row.get("RBAC Scope", "")
        )
        identity_type = normalize_value(
            row.get("Identity Type", "") or str(identity_defaults.get("type", ""))
        )
        identity_name = normalize_value(row.get("Identity Name", ""))
        identity_subscription = normalize_value(
            row.get("Identity Subscription", "") or str(identity_defaults.get("subscriptionId", ""))
        )
        identity_resource_group = normalize_value(
            row.get("Identity Resource Group", "") or str(identity_defaults.get("resourceGroup", ""))
        )
        identity_location = normalize_value(
            row.get("Identity Location", "") or str(identity_defaults.get("location", "") or location)
        )

        requires_identity = effect_value.lower() in {"deployifnotexists", "modify"}
        # identity_type comes from defaults for every row — don't treat it as user-provided data
        has_explicit_identity = bool(identity_name or rbac_roles_raw)
        if not (requires_identity or has_explicit_identity):
            continue

        normalized_identity_type = identity_type or "UserAssigned"
        identity_entry: Dict[str, Any] = {
            "assignmentName": assignment_entry["name"],
            "identity": {
                "type": normalized_identity_type,
            },
            "roleAssignments": [],
        }

        if "UserAssigned" in normalized_identity_type:
            identity_entry["identity"]["userAssignedIdentityName"] = (
                identity_name or default_identity_name(assignment_entry["name"], scope_type, assignment_scope)
            )
            identity_entry["identity"]["subscriptionId"] = (
                identity_subscription or (assignment_scope if scope_type == "subscription" else "")
            )
            identity_entry["identity"]["resourceGroup"] = identity_resource_group
            identity_entry["identity"]["location"] = identity_location
            identity_entry["identity"]["tags"] = {
                **default_identity_tags,
                "hidden-title": assignment_name,
                "assignmentName": assignment_entry["name"],
                "assignmentDisplayName": assignment_entry["displayName"],
                "assignmentScopeType": scope_type,
                "assignmentScopeId": assignment_scope,
            }

        explicit_rbac_scopes = [s for s in parse_list_values(rbac_scopes_raw) if s]
        effective_rbac_scopes = explicit_rbac_scopes or [assignment_scope_path(scope_type, assignment_scope)]

        for role in parse_list_values(rbac_roles_raw):
            for rbac_scope in effective_rbac_scopes:
                identity_entry["roleAssignments"].append(
                    {
                        "roleDefinitionIdOrName": role,
                        "scope": rbac_scope,
                    }
                )

        assignment_identities.append(identity_entry)

    return initiatives, assignments, parameters, assignment_identities


def parse_parameter_value(value: str, type_hint: str) -> object:
    """Return a Python object for the given raw value string.

    - If type_hint is 'array', or the trimmed value starts with '[', parse as list.
      Multi-line comma-separated strings (Excel/TSV export) are split accordingly.
    - Otherwise return as plain string.
    """
    v = value.strip()

    th = type_hint.strip().lower()

    is_array = th == "array"

    if th == "integer":
        try:
            return int(v)
        except (ValueError, TypeError):
            return v

    if not is_array and v.startswith("["):
        try:
            return json.loads(v)
        except json.JSONDecodeError:
            is_array = True  # fallback: treat as multi-value string

    if is_array:
        # Handle multi-line or comma-separated values produced by Excel TSV/CSV exports.
        # Each line may end with a trailing comma; strip and skip blanks.
        items: List[str] = []
        for line in v.splitlines():
            for part in line.split(","):
                part = part.strip().strip('"')
                if part:
                    items.append(part)
        return items

    # Excel often exports boolean-like strings in all caps; Azure Policy string
    # parameters typically expect 'True'/'False' casing.
    lowered = v.lower()
    if lowered == "true":
        return "True"
    if lowered == "false":
        return "False"

    return v


def parse_parameter_target(row: Dict[str, str]) -> str:
    """Return normalized parameter target: initiative, policy, or both.

    Accepted column names: Applies To, Target, Scope.
    Accepted values (case-insensitive): initiative, policy, both/all/any.
    Empty values default to both for backward compatibility.
    """
    raw_target = normalize_value(
        row.get("Applies To", "") or row.get("Target", "") or row.get("Scope", "")
    ).lower()
    if not raw_target:
        return "both"
    if raw_target in {"initiative", "policy"}:
        return raw_target
    if raw_target in {"both", "all", "any", "*"}:
        return "both"
    return "both"


def read_params_source(path: Path) -> Dict[str, Dict[str, Dict[str, dict]]]:
    """Read parameters TSV/CSV grouped by parameter set and target.

    Expected columns: Parameter Set, Key, Value, Type and optional Applies To.
    Returned shape:
    {
      "<parameterSet>": {
        "both": {...},
        "initiative": {...},
        "policy": {...}
      }
    }
    """
    delimiter = detect_delimiter(path)
    result: Dict[str, Dict[str, Dict[str, dict]]] = {}

    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle, delimiter=delimiter)
        for raw_row in reader:
            row = normalize_row(raw_row)
            param_set = row.get("Parameter Set", "").strip()
            key = row.get("Key", "").strip()
            raw_value = row.get("Value", "")
            type_hint = row.get("Type", "")
            target = parse_parameter_target(row)

            if not param_set or not key:
                continue

            parsed = parse_parameter_value(raw_value, type_hint)

            if param_set not in result:
                result[param_set] = {
                    "both": {},
                    "initiative": {},
                    "policy": {},
                }
            result[param_set][target][key] = {"value": parsed}

    return result


def write_json(path: Path, data: object) -> None:
    """Serialise *data* to a pretty-printed JSON file, creating parent dirs as needed.

    A trailing newline is appended so text editors and git diffs treat the file
    as properly terminated.  Non-ASCII characters are kept as-is (ensure_ascii=False)
    so policy display names are preserved without escape sequences.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def load_deployment_config(repo_root: Path) -> Dict[str, Any]:
    """Load deployment configuration from configuration/deployment-config.json."""
    config_path = repo_root / "configuration" / "deployment-config.json"
    if config_path.exists():
        with config_path.open("r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def resolve_default_params_input(repo_root: Path, config: Dict[str, Any]) -> Optional[Path]:
    """Return the first existing parameters source file path, or None if none is found.

    Resolution order:
    1. 'parameters' key in deployment-config.json sourceFiles section.
    2. 'parametersFallback' key in deployment-config.json sourceFiles section.
    3. Hardcoded configuration/policy-parameters.tsv / .csv for backward compatibility.
    """
    candidates = []

    # Prefer paths declared in deployment-config.json.
    source_files = config.get("sourceFiles", {})
    if "parameters" in source_files:
        candidates.append(repo_root / source_files["parameters"])
    if "parametersFallback" in source_files:
        candidates.append(repo_root / source_files["parametersFallback"])

    # Hardcoded fallbacks for repos that have not yet added sourceFiles config.
    if not candidates:
        candidates = [
            repo_root / "configuration" / "policy-parameters.tsv",
            repo_root / "configuration" / "policy-parameters.csv",
        ]

    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def resolve_default_input(repo_root: Path, config: Dict[str, Any]) -> Path:
    """Return the assignments source file path to use as CLI default.

    Resolution order:
    1. 'assignments' key in deployment-config.json sourceFiles section.
    2. 'assignmentsFallback' key in deployment-config.json sourceFiles section.
    3. Hardcoded configuration/policy-assignments.tsv / .csv paths.
    4. Legacy config/policy.tsv (returned even if it doesn't exist, so argparse
       can show a meaningful default rather than crashing at startup).
    """
    candidates = []

    # Prefer paths declared in deployment-config.json.
    source_files = config.get("sourceFiles", {})
    if "assignments" in source_files:
        candidates.append(repo_root / source_files["assignments"])
    if "assignmentsFallback" in source_files:
        candidates.append(repo_root / source_files["assignmentsFallback"])

    # Hardcoded fallbacks for repos without sourceFiles config.
    if not candidates:
        candidates = [
            repo_root / "configuration" / "policy-assignments.tsv",
            repo_root / "configuration" / "policy-assignments.csv",
            repo_root / "docs" / "ALZPolicyAssignments.tsv",
            repo_root / "docs" / "ALZPolicyAssignments.csv",
        ]

    for candidate in candidates:
        if candidate.exists():
            return candidate

    # Last-resort fallback: return path even if file is missing so argparse default is printable.
    return repo_root / "config" / "policy.tsv"


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments, resolving defaults from deployment-config.json where possible."""
    repo_root = Path(__file__).resolve().parents[1]
    config = load_deployment_config(repo_root)

    default_input = resolve_default_input(repo_root, config)
    default_output = str(repo_root / config.get("paths", {}).get("configDir", "generated"))
    default_source = str(repo_root / config.get("paths", {}).get("sourceDir", "source/EnterpriseALZ"))
    default_custom = str(repo_root / config.get("paths", {}).get("customDir", "source/own"))
    default_location = config.get("deployment", {}).get("location", "germanywestcentral")
    
    parser = argparse.ArgumentParser(
        description="Generate initiatives/assignments/parameters JSON from TSV/CSV source table."
    )
    parser.add_argument(
        "--input",
        default=str(default_input),
        help=(
            "Path to input TSV/CSV file "
            "(default: from deployment-config.json or configuration/policy-assignments.tsv)"
        ),
    )
    parser.add_argument(
        "--output-dir",
        default=default_output,
        help=f"Output directory for generated JSON files (default: {default_output})",
    )
    parser.add_argument(
        "--source-dir",
        default=default_source,
        help=f"Source snapshot directory used to detect custom definitions (default: {default_source})",
    )
    parser.add_argument(
        "--custom-dir",
        default=default_custom,
        help=f"Custom policy definitions directory for targetManagementGroup auto-detection (default: {default_custom})",
    )
    parser.add_argument(
        "--suffix",
        default="",
        help="Suffix appended before .json (example: test -> initiatives-test.json)",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Process only first N rows after filtering",
    )
    parser.add_argument(
        "--location",
        default=default_location,
        help=f"Location value set on assignments (default: {default_location})",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Process all rows (by default only Deploy=TRUE rows are processed)",
    )
    default_params = resolve_default_params_input(repo_root, config)
    parser.add_argument(
        "--params-input",
        default=str(default_params) if default_params else "",
        help=(
            "Path to parameters source TSV/CSV file "
            "(default: from deployment-config.json or configuration/policy-parameters.tsv). "
            "Pass empty string to skip parameters loading."
        ),
    )
    return parser.parse_args()


def main() -> int:
    """Entry point: orchestrate reading, transforming and writing all output files."""
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    config = load_deployment_config(repo_root)
    output_dir = Path(args.output_dir).resolve()
    source_dir = Path(args.source_dir).resolve()
    custom_dir = Path(args.custom_dir).resolve()

    input_path = Path(args.input).resolve()
    if not input_path.exists():
        raise FileNotFoundError(f"Input file not found: {input_path}")

    if args.limit is not None and args.limit <= 0:
        raise ValueError("--limit must be a positive integer")

    # Read and optionally filter rows from the assignments source file.
    rows = read_rows(input_path, only_deploy_true=not args.all)
    if args.limit is not None:
        rows = rows[: args.limit]

    initiatives, assignments, parameters, assignment_identities = build_json_payloads(
        rows,
        location=args.location,
        source_dir=source_dir,
        deployment_config=config,
        custom_dir=custom_dir,
    )

    # Overlay parameters loaded from the dedicated parameters source file.
    # Supports target-specific rows via optional Applies To column (initiative/policy/both).
    # If a parameter set contains target-specific rows, assignments are rebound to a
    # generated key: <ParameterSet>__initiative or <ParameterSet>__policy.
    params_input_str = normalize_value(args.params_input)
    if params_input_str:
        params_path = Path(params_input_str).resolve()
        if params_path.exists():
            loaded_params = read_params_source(params_path)
            for param_set, target_values in loaded_params.items():
                common_values = target_values.get("both", {})
                initiative_values = target_values.get("initiative", {})
                policy_values = target_values.get("policy", {})
                has_target_specific = bool(initiative_values or policy_values)
                requires_initiative = any(
                    assignment.get("parametersKey") == param_set and assignment.get("definitionType") == "initiative"
                    for assignment in assignments
                )
                requires_policy = any(
                    assignment.get("parametersKey") == param_set and assignment.get("definitionType") == "policy"
                    for assignment in assignments
                )

                if not has_target_specific:
                    parameters[param_set] = common_values
                    continue

                if requires_initiative and not (common_values or initiative_values):
                    raise ValueError(
                        f"Parameter set '{param_set}' is used by initiative assignments but has no rows with Scope=initiative (or empty/both)."
                    )
                if requires_policy and not (common_values or policy_values):
                    raise ValueError(
                        f"Parameter set '{param_set}' is used by policy assignments but has no rows with Scope=policy (or empty/both)."
                    )

                # Build split parameter sets and rebind assignments to the matching one.
                initiative_key = f"{param_set}__initiative"
                policy_key = f"{param_set}__policy"
                parameters[initiative_key] = {**common_values, **initiative_values}
                parameters[policy_key] = {**common_values, **policy_values}

                for assignment in assignments:
                    if assignment.get("parametersKey") != param_set:
                        continue
                    assignment_type = normalize_value(str(assignment.get("definitionType", "policy"))).lower()
                    if assignment_type == "initiative":
                        assignment["parametersKey"] = initiative_key
                    else:
                        assignment["parametersKey"] = policy_key

            print(f"Loaded parameters from: {params_path}")
        else:
            print(f"Warning: --params-input file not found: {params_path}")

    # Apply suffix to output filenames for test/preview runs (e.g. initiatives-test.json).
    suffix = normalize_value(args.suffix)
    if suffix and not suffix.startswith("-"):
        suffix = f"-{suffix}"
    initiatives_out = output_dir / f"initiatives{suffix}.json"
    assignments_out = output_dir / f"assignments{suffix}.json"
    parameters_out = output_dir / f"parameters{suffix}.json"
    assignment_identities_out = output_dir / f"assignment-identities{suffix}.json"

    write_json(initiatives_out, initiatives)
    write_json(assignments_out, assignments)
    write_json(parameters_out, parameters)
    write_json(assignment_identities_out, assignment_identities)

    print(f"Processed rows: {len(rows)}")
    print(f"Generated: {initiatives_out}")
    print(f"Generated: {assignments_out}")
    print(f"Generated: {parameters_out}")
    print(f"Generated: {assignment_identities_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
