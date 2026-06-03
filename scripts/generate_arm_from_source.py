#!/usr/bin/env python3
"""Generate deployment templates from source policy snapshots and custom definitions.

Reads all JSON files from source/EnterpriseALZ/policyDefinitions/ and
source/EnterpriseALZ/policySetDefinitions/ (populated by fetch-policies.sh)
and from source/own/policyDefinitions/ and source/own/policySetDefinitions/
(maintained manually in the repository) and generates:
  - bicep/policyDefinitions/<name>.json  — one ARM JSON per policy definition
  - bicep/policySetDefinitions/<name>.json — one ARM JSON per policy set definition

Files from source/own/ are merged into the same bicep/ output directories as ALZ files.
Own files override ALZ files when both share the same policy name.

Individual ARM JSON files are self-contained (no loadJsonContent) so they can be
deployed in Pipeline C without requiring source/ to be present.

Run this script after fetch-policies.sh in the rebuild-initiatives pipeline.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict, List, Optional


GENERATOR_LABEL = "scripts/generate_arm_from_source.py"


def load_deployment_config(repo_root: Path) -> Dict[str, Any]:
    """Load deployment configuration from configuration/deployment-config.json."""
    config_path = repo_root / "configuration" / "deployment-config.json"
    if config_path.exists():
        with config_path.open("r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def generate_policy_definitions_bicep(policy_defs_dir: Path, bicep_dir: Path, management_tag: str = "") -> Path:
    """Generate individual ARM JSON deployment templates for each policy definition.

    Scans *policy_defs_dir* for JSON files (each one is an Azure policy definition
    snapshot fetched by fetch-policies.sh) and emits one ARM JSON file per policy to
    bicep/policyDefinitions/<name>.json.

    Using ARM JSON instead of a single Bicep with loadJsonContent means:
    - No source/ directory is required at deployment time (Pipeline C).
    - Each policy is deployed in a separate 'az deployment mg create' call so errors
      are granular and the 'aggregated deployment error too large' limit is not hit.

    Raises FileNotFoundError if the source directory or its JSON files are missing.
    """
    if not policy_defs_dir.exists():
        raise FileNotFoundError(f"policyDefinitions source dir not found: {policy_defs_dir}")

    files = sorted(policy_defs_dir.glob("*.json"))
    if not files:
        raise FileNotFoundError(f"No JSON files found in {policy_defs_dir}")

    # Exclude cloud-specific variants (AzureChinaCloud, AzureUSGovernment) — they carry
    # the same `name` as the base file and would produce duplicate resource definitions.
    CLOUD_SUFFIXES = (".AzureChinaCloud.json", ".AzureUSGovernment.json")
    files = [f for f in files if not any(f.name.endswith(s) for s in CLOUD_SUFFIXES)]

    out_dir = bicep_dir / "policyDefinitions"
    out_dir.mkdir(parents=True, exist_ok=True)

    generated: List[Path] = []
    for f in files:
        with f.open("r", encoding="utf-8") as fh:
            source = json.load(fh)

        policy_name = source.get("name", f.stem)
        properties = source.get("properties", {})

        # Extract targetManagementGroup from policy metadata — it is a deployment routing
        # hint, not a policy property, so it must not be published to Azure.  We move it
        # to the ARM template's top-level metadata section where update-definitions.sh can
        # read it to override the default management group for this definition.
        target_mg: Optional[str] = None
        if "metadata" in properties:
            target_mg = properties["metadata"].pop("targetManagementGroup", None)

        # Inject managedBy marker so the definition can be identified as policy-by-code
        # managed both locally (for cleanup filtering) and in Azure after deployment.
        if management_tag:
            if "metadata" not in properties:
                properties["metadata"] = {}
            properties["metadata"].setdefault("managedBy", management_tag)

        arm_template: Dict[str, Any] = {
            "$schema": "https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#",
            "contentVersion": "1.0.0.0",
            "resources": [
                {
                    "type": "Microsoft.Authorization/policyDefinitions",
                    "apiVersion": "2023-04-01",
                    "name": policy_name,
                    "properties": properties,
                }
            ],
        }
        if target_mg:
            arm_template["metadata"] = {"targetManagementGroup": target_mg}

        out_path = out_dir / f"{policy_name}.json"
        out_path.write_text(json.dumps(arm_template, ensure_ascii=False, indent=2), encoding="utf-8")
        generated.append(out_path)

    print(f"Generated {len(generated)} ARM JSON templates in {out_dir}")
    return out_dir


def generate_policy_set_definitions_bicep(
    policy_set_defs_dir: Path,
    bicep_dir: Path,
    management_group_id: str = "",
    management_tag: str = "",
) -> Path:
    """Generate individual ARM JSON deployment templates for each policy set definition.

    Scans *policy_set_defs_dir* for JSON files and emits one ARM JSON file per
    initiative to bicep/policySetDefinitions/<name>.json.

    Using ARM JSON instead of a single Bicep with loadJsonContent means:
    - No source/ directory is required at deployment time (Pipeline C).
    - Each initiative is deployed in a separate 'az deployment mg create' call so errors
      are granular and the 'aggregated deployment error too large' limit is not hit.

    When *management_group_id* is given the ALZ source placeholder 'contoso' is
    replaced with the real management group ID in all policyDefinitionId references
    inside the policy set (custom policy references are scoped to the root MG).

    Raises FileNotFoundError if the source directory or its JSON files are missing.
    """
    if not policy_set_defs_dir.exists():
        raise FileNotFoundError(f"policySetDefinitions source dir not found: {policy_set_defs_dir}")

    files = sorted(policy_set_defs_dir.glob("*.json"))
    if not files:
        raise FileNotFoundError(f"No JSON files found in {policy_set_defs_dir}")

    out_dir = bicep_dir / "policySetDefinitions"
    out_dir.mkdir(parents=True, exist_ok=True)

    generated: List[Path] = []
    for f in files:
        with f.open("r", encoding="utf-8") as fh:
            source_text = fh.read()

        # Replace the ALZ placeholder management group name with the real one so that
        # custom policyDefinitionId references inside the set resolve correctly.
        if management_group_id:
            source_text = source_text.replace(
                "/managementGroups/contoso/",
                f"/managementGroups/{management_group_id}/",
            )

        source = json.loads(source_text)
        policy_set_name = source.get("name", f.stem)
        properties = source.get("properties", {})

        # Inject managedBy marker into custom initiative definitions.
        if management_tag:
            if "metadata" not in properties:
                properties["metadata"] = {}
            properties["metadata"].setdefault("managedBy", management_tag)

        arm_template = {
            "$schema": "https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#",
            "contentVersion": "1.0.0.0",
            "resources": [
                {
                    "type": "Microsoft.Authorization/policySetDefinitions",
                    "apiVersion": "2023-04-01",
                    "name": policy_set_name,
                    "properties": properties,
                }
            ],
        }

        out_path = out_dir / f"{policy_set_name}.json"
        out_path.write_text(json.dumps(arm_template, ensure_ascii=False, indent=2), encoding="utf-8")
        generated.append(out_path)

    print(f"Generated {len(generated)} ARM JSON templates in {out_dir}")
    return out_dir


def parse_args() -> argparse.Namespace:
    """Parse CLI arguments, resolving defaults from deployment-config.json where available."""
    repo_root = Path(__file__).resolve().parents[1]
    config = load_deployment_config(repo_root)
    paths = config.get("paths", {})

    # Fall back to convention if paths are not declared.
    default_source = str(repo_root / paths.get("sourceDir", "source/EnterpriseALZ"))
    default_bicep = str(repo_root / paths.get("bicepDir", "bicep"))
    default_custom = str(repo_root / paths.get("customDir", "source/own"))

    parser = argparse.ArgumentParser(
        description="Generate ARM JSON files from source policy snapshots (after fetch-policies.sh)."
    )
    parser.add_argument(
        "--source-dir",
        default=default_source,
        help=f"Root of source snapshots directory (default: {default_source})",
    )
    parser.add_argument(
        "--bicep-dir",
        default=default_bicep,
        help=f"Output directory for generated ARM JSON files (default: {default_bicep})",
    )
    parser.add_argument(
        "--custom-dir",
        default=default_custom,
        help=f"Root of custom policy definitions directory (default: {default_custom})",
    )
    return parser.parse_args()


def generate_custom_policy_definitions(custom_pd_dir: Path, bicep_dir: Path, management_tag: str = "") -> None:
    """Generate ARM JSON templates from own/policyDefinitions/ if the directory is non-empty.

    Silently skips when the directory does not exist or contains no JSON files.
    Files are written to the same bicep/policyDefinitions/ output directory as ALZ definitions,
    so a custom file with the same policy name as an ALZ file will replace it.
    """
    if not custom_pd_dir.exists():
        print(f"Custom policyDefinitions dir not found ({custom_pd_dir}) — skipping.")
        return
    files = [f for f in sorted(custom_pd_dir.glob("*.json"))]
    if not files:
        print(f"No custom policy definitions in {custom_pd_dir} — skipping.")
        return
    generate_policy_definitions_bicep(custom_pd_dir, bicep_dir, management_tag=management_tag)


def generate_custom_policy_set_definitions(custom_psd_dir: Path, bicep_dir: Path, management_group_id: str = "", management_tag: str = "") -> None:
    """Generate ARM JSON templates from own/policySetDefinitions/ if the directory is non-empty.

    Silently skips when the directory does not exist or contains no JSON files.
    Files are written to the same bicep/policySetDefinitions/ output directory as ALZ initiatives.
    """
    if not custom_psd_dir.exists():
        print(f"Custom policySetDefinitions dir not found ({custom_psd_dir}) — skipping.")
        return
    files = [f for f in sorted(custom_psd_dir.glob("*.json"))]
    if not files:
        print(f"No custom policy set definitions in {custom_psd_dir} — skipping.")
        return
    generate_policy_set_definitions_bicep(custom_psd_dir, bicep_dir, management_group_id=management_group_id, management_tag=management_tag)


def main() -> int:
    """Entry point: generate ARM JSON per-policy and per-initiative."""
    args = parse_args()
    source_dir = Path(args.source_dir).resolve()
    bicep_dir = Path(args.bicep_dir).resolve()
    custom_dir = Path(args.custom_dir).resolve()

    # Read management group ID and managementTag from deployment config.
    repo_root = Path(__file__).resolve().parents[1]
    config = load_deployment_config(repo_root)
    mg_id = config.get("deployment", {}).get("definitionManagementGroupId", "")
    management_tag = config.get("managementTag", "")
    if mg_id:
        print(f"Using management group ID '{mg_id}' to replace ALZ 'contoso' placeholder.")
    else:
        print("WARNING: definitionManagementGroupId not found in deployment-config.json — 'contoso' placeholders will NOT be replaced.")

    source_root = source_dir
    custom_root = custom_dir

    print(f"Using source root: {source_root}")
    print(f"Using custom root: {custom_root}")

    # Generate individual ARM JSON templates for ALZ policy definitions.
    pd_dir = generate_policy_definitions_bicep(source_root / "policyDefinitions", bicep_dir)
    print(f"Policy definition templates: {pd_dir}")

    # Generate individual ARM JSON templates for ALZ policy set definitions.
    psd_dir = generate_policy_set_definitions_bicep(source_root / "policySetDefinitions", bicep_dir, management_group_id=mg_id)
    print(f"Policy set definition templates: {psd_dir}")

    # Merge custom policy definitions (overrides ALZ files with the same name).
    print("")
    print("==> Processing custom policy definitions...")
    generate_custom_policy_definitions(custom_root / "policyDefinitions", bicep_dir, management_tag=management_tag)

    # Merge custom policy set definitions (overrides ALZ files with the same name).
    print("==> Processing custom policy set definitions...")
    generate_custom_policy_set_definitions(custom_root / "policySetDefinitions", bicep_dir, management_group_id=mg_id, management_tag=management_tag)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
