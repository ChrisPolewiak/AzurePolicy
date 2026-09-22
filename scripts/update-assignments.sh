#!/usr/bin/env bash
# update-assignments.sh
# Validates config JSON, then runs what-if and optionally deploys
# policy assignments to Azure tenant scope.
# Requires active Azure CLI login (az login) or service principal context.
#
# Config JSON (generated/assignments.json etc.) must already be generated
# by rebuild-configuration.sh or generate_config_from_table.py before running this script.
#
# Usage:
#   scripts/update-assignments.sh [-l <loc>] [-m <mg-id>] [-a <AP...>] [--deploy] [-h]
#
# Options:
#   -l, --location        <loc>    Azure region for deployment metadata.
#                                  Default: deployment.location from deployment-config.json
#   -m, --management-group <mg-id> Lookup Management Group ID used to build definition IDs
#                                  from policyDefinitionName/initiativeName when policyDefinitionId is not provided.
#                                  Does not control assignment scope (scope comes from generated/assignments.json).
#                                  Default: deployment.definitionManagementGroupId from deployment-config.json
#   -a, --assignment      <name>   Process only a single assignment name (e.g. AP2026-04-28_0015)
#       --deploy                   Actually deploy after what-if. Without this flag only what-if runs.
#   -h, --help                     Show this help and exit.
#
# Examples:
#   scripts/update-assignments.sh
#   scripts/update-assignments.sh --deploy
#   scripts/update-assignments.sh -l germanywestcentral -m mg-platform --deploy
#   scripts/update-assignments.sh -a AP2026-04-28_0015 --deploy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '1,/^set -euo/{ /^#[^!]/!d; s/^# \?//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

LOCATION=""
MANAGEMENT_GROUP=""
TARGET_ASSIGNMENT=""
DEPLOY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--location)         LOCATION="$2"; shift 2 ;;
    -m|--management-group) MANAGEMENT_GROUP="$2"; shift 2 ;;
    -a|--assignment)       TARGET_ASSIGNMENT="$2"; shift 2 ;;
    --deploy)              DEPLOY=true; shift ;;
    -h|--help)             usage ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

cd "$ROOT_DIR"

# Read defaults from deployment-config.json
CONFIG_FILE="$ROOT_DIR/configuration/deployment-config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: deployment-config.json not found at $CONFIG_FILE"
  exit 1
fi
if [[ -z "$LOCATION" ]]; then
  LOCATION="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['deployment']['location'])")"
fi
if [[ -z "$MANAGEMENT_GROUP" ]]; then
  MANAGEMENT_GROUP="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['deployment']['definitionManagementGroupId'])")"
fi

DEFAULT_IDENTITY_TYPE="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('identityDefaults', {}).get('type', 'UserAssigned'))")"
DEFAULT_IDENTITY_SUBSCRIPTION="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('identityDefaults', {}).get('subscriptionId', ''))")"
DEFAULT_IDENTITY_RESOURCE_GROUP="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('identityDefaults', {}).get('resourceGroup', ''))")"
DEFAULT_IDENTITY_LOCATION="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('identityDefaults', {}).get('location', c.get('deployment', {}).get('location', 'germanywestcentral')))" )"

echo "Location:         $LOCATION"
echo "Management Group: $MANAGEMENT_GROUP"
if [[ -n "$TARGET_ASSIGNMENT" ]]; then
  ASSIGNMENT_DISPLAY_NAME="$(python3 -c "
import json
a = json.load(open('generated/assignments.json'))
found = [x for x in a if x.get('name') == '$TARGET_ASSIGNMENT']
print(found[0].get('displayName', '') if found else '')
")"
  ASSIGNMENT_DESCRIPTION="$(python3 -c "
import json
a = json.load(open('generated/assignments.json'))
found = [x for x in a if x.get('name') == '$TARGET_ASSIGNMENT']
print(found[0].get('description', '') if found else '')
")"
  echo "Assignment:       $TARGET_ASSIGNMENT"
  [[ -n "$ASSIGNMENT_DISPLAY_NAME" ]] && echo "DisplayName:      $ASSIGNMENT_DISPLAY_NAME"
  [[ -n "$ASSIGNMENT_DESCRIPTION"  ]] && echo "Description:      $ASSIGNMENT_DESCRIPTION"
else
  echo "Assignment:       (all)"
fi
echo "Deploy:           $DEPLOY"

# --- Step 1: Validate ---
echo ""
echo "==> Validating config..."
chmod +x "$SCRIPT_DIR/validate-config.sh"
FILTER_ASSIGNMENT="$TARGET_ASSIGNMENT" "$SCRIPT_DIR/validate-config.sh"
echo "✓ Validation passed"

ASSIGNMENT_COUNT=$(python3 -c "import json,sys; a=json.load(open('generated/assignments.json')); t='''$TARGET_ASSIGNMENT'''.strip(); print(sum(1 for x in a if not t or x.get('name')==t))")
IDENTITY_CONFIG_FILE="generated/assignment-identities.json"

if [[ "$ASSIGNMENT_COUNT" -eq 0 ]]; then
  if [[ -n "$TARGET_ASSIGNMENT" ]]; then
    echo "✗ Assignment not found in generated/assignments.json: $TARGET_ASSIGNMENT"
  else
    echo "✗ No assignments found in generated/assignments.json"
  fi
  exit 1
fi

if [[ ! -f "$IDENTITY_CONFIG_FILE" ]]; then
  echo "[]" > "$IDENTITY_CONFIG_FILE"
fi

# Temporary files for passing JSON objects to az --parameters
TMP_ASSIGNMENT=$(mktemp /tmp/az-assignment-XXXXXX.json)
TMP_PARAMETERSET=$(mktemp /tmp/az-parameterset-XXXXXX.json)
trap 'rm -f "$TMP_ASSIGNMENT" "$TMP_PARAMETERSET"' EXIT

get_identity_config_entry() {
  local assignment_name="$1"
  python3 - "$assignment_name" "$IDENTITY_CONFIG_FILE" <<'PY'
import json
import sys

assignment_name = sys.argv[1]
config_path = sys.argv[2]

try:
  data = json.load(open(config_path, "r", encoding="utf-8"))
except FileNotFoundError:
  print("null")
  raise SystemExit(0)

if not isinstance(data, list):
  print("null")
  raise SystemExit(0)

for item in data:
  if isinstance(item, dict) and item.get("assignmentName") == assignment_name:
    print(json.dumps(item))
    break
else:
  print("null")
PY
}

inject_identity_into_assignment() {
  local assignment_json="$1"
  local identity_entry_json="$2"
  python3 - "$assignment_json" "$identity_entry_json" <<'PY'
import json
import sys

assignment = json.loads(sys.argv[1])
entry = json.loads(sys.argv[2])
identity_cfg = entry.get("identity") or {}

identity_type = (identity_cfg.get("type") or "SystemAssigned").strip()
identity = {"type": identity_type}

if "UserAssigned" in identity_type:
  user_assigned_ids = identity_cfg.get("userAssignedIdentityResourceIds") or []
  if user_assigned_ids:
    identity["userAssignedIdentities"] = {
      rid: {} for rid in user_assigned_ids if isinstance(rid, str) and rid.strip()
    }

assignment["identity"] = identity
print(json.dumps(assignment))
PY
}

get_role_assignments_json() {
  local identity_entry_json="$1"
  python3 - "$identity_entry_json" <<'PY'
import json
import sys

entry = json.loads(sys.argv[1])
role_assignments = entry.get("roleAssignments")
if isinstance(role_assignments, list):
  print(json.dumps(role_assignments))
else:
  print("[]")
PY
}

# Emit normalized role bindings as: <role>\t<scope>
# This keeps all RBAC loops simple and consistent in one place.
iter_role_bindings() {
  local role_assignments_json="$1"
  local default_scope="$2"
  python3 - "$role_assignments_json" "$default_scope" <<'PY'
import json
import sys

raw = sys.argv[1]
default_scope = sys.argv[2]

data = json.loads(raw)
if not isinstance(data, list):
  raise SystemExit(0)

for item in data:
  if not isinstance(item, dict):
    continue
  role = (item.get("roleDefinitionIdOrName") or item.get("roleDefinitionId") or item.get("roleName") or "").strip()
  if not role:
    continue
  scope = (item.get("scope") or default_scope or "").strip()
  print(f"{role}\t{scope}")
PY
}

# Render argv as a shell-safe command string for copy/paste troubleshooting.
print_shell_command() {
  printf '%q ' "$@"
  echo
}

resolve_assignment_principal_id() {
  local assignment_name="$1"
  local assignment_scope_path="$2"
  local max_attempts="${3:-3}"
  local wait_seconds="${4:-2}"
  local attempt=1
  local principal_id=""

  while [[ "$attempt" -le "$max_attempts" ]]; do
    principal_id=$(az policy assignment show --name "$assignment_name" --scope "$assignment_scope_path" --query "identity.principalId" -o tsv 2>/dev/null || true)
    if [[ -n "$principal_id" && "$principal_id" != "None" ]]; then
      echo "$principal_id"
      return 0
    fi

    if [[ "$attempt" -lt "$max_attempts" ]]; then
      sleep "$wait_seconds"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

ensure_user_assigned_identity_entry() {
  local identity_entry_json="$1"
  local assignment_name="$2"
  local scope_type="$3"
  local scope_id="$4"
  local deploy_mode="$5"
  python3 - "$identity_entry_json" "$assignment_name" "$scope_type" "$scope_id" "$DEFAULT_IDENTITY_TYPE" "$DEFAULT_IDENTITY_SUBSCRIPTION" "$DEFAULT_IDENTITY_RESOURCE_GROUP" "$DEFAULT_IDENTITY_LOCATION" "$deploy_mode" <<'PY'
import json
import subprocess
import sys

entry = json.loads(sys.argv[1])
assignment_name = sys.argv[2]
scope_type = sys.argv[3]
scope_id = sys.argv[4]
default_identity_type = sys.argv[5] or "UserAssigned"
default_subscription = sys.argv[6]
default_rg = sys.argv[7]
default_location = sys.argv[8]
deploy_mode = sys.argv[9].lower() == "true"

identity = entry.get("identity") or {}
identity_type = (identity.get("type") or default_identity_type).strip() or "UserAssigned"
entry["identity"] = identity
entry["identity"]["type"] = identity_type
tags = identity.get("tags") or {}

if "UserAssigned" not in identity_type:
  print(json.dumps(entry))
  raise SystemExit(0)

uami_ids = identity.get("userAssignedIdentityResourceIds") or []
if uami_ids and isinstance(uami_ids, list) and uami_ids[0]:
  print(json.dumps(entry))
  raise SystemExit(0)

uami_name = (identity.get("userAssignedIdentityName") or "").strip()
if not uami_name:
  token = "".join(ch for ch in assignment_name if ch.isalnum())
  if not token:
    token = "assignment"
  uami_name = f"id-policy-{token}"[:128]

subscription_id = (identity.get("subscriptionId") or default_subscription or (scope_id if scope_type == "subscription" else "")).strip()
resource_group = (identity.get("resourceGroup") or default_rg).strip()
location = (identity.get("location") or default_location).strip()

if not subscription_id or not resource_group:
  print("ERROR: Missing identity subscriptionId/resourceGroup for user-assigned identity.", file=sys.stderr)
  raise SystemExit(2)

def run_az(args):
  return subprocess.run(["az", *args], capture_output=True, text=True)

rg_show = run_az(["group", "show", "--name", resource_group, "--subscription", subscription_id, "--query", "name", "-o", "tsv"])
if rg_show.returncode != 0:
    if not deploy_mode:
      identity_id = (
          f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
          f"/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{uami_name}"
      )
      entry["identity"]["userAssignedIdentityName"] = uami_name
      entry["identity"]["subscriptionId"] = subscription_id
      entry["identity"]["resourceGroup"] = resource_group
      entry["identity"]["location"] = location
      entry["identity"]["userAssignedIdentityResourceIds"] = [identity_id]
      entry["identity"]["tags"] = tags
      print(json.dumps(entry))
      raise SystemExit(0)
    rg_create = run_az(["group", "create", "--name", resource_group, "--subscription", subscription_id, "--location", location, "--query", "name", "-o", "tsv"])
    if rg_create.returncode != 0:
      print(rg_create.stderr.strip() or rg_create.stdout.strip(), file=sys.stderr)
      raise SystemExit(6)

show = run_az(["identity", "show", "--name", uami_name, "--resource-group", resource_group, "--subscription", subscription_id, "--query", "id", "-o", "tsv"])
identity_id = show.stdout.strip() if show.returncode == 0 else ""

if not identity_id:
  if not deploy_mode:
    identity_id = (
        f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{uami_name}"
    )
    entry["identity"]["userAssignedIdentityName"] = uami_name
    entry["identity"]["subscriptionId"] = subscription_id
    entry["identity"]["resourceGroup"] = resource_group
    entry["identity"]["location"] = location
    entry["identity"]["userAssignedIdentityResourceIds"] = [identity_id]
    entry["identity"]["tags"] = tags
    print(json.dumps(entry))
    raise SystemExit(0)
  create_args = ["identity", "create", "--name", uami_name, "--resource-group", resource_group, "--subscription", subscription_id, "--location", location, "--query", "id", "-o", "tsv"]
  if isinstance(tags, dict):
    # az rejects blank tag values ("key="), so drop incomplete pairs instead of failing the whole create.
    tag_args = [f"{key}={value}" for key, value in tags.items() if str(key).strip() and str(value).strip()]
    if tag_args:
      create_args.extend(["--tags", *tag_args])
  create = run_az(create_args)
  if create.returncode != 0:
    print(create.stderr.strip() or create.stdout.strip(), file=sys.stderr)
    raise SystemExit(8)
  identity_id = create.stdout.strip()

entry["identity"]["userAssignedIdentityName"] = uami_name
entry["identity"]["subscriptionId"] = subscription_id
entry["identity"]["resourceGroup"] = resource_group
entry["identity"]["location"] = location
entry["identity"]["userAssignedIdentityResourceIds"] = [identity_id]
entry["identity"]["tags"] = tags

print(json.dumps(entry))
PY
}

# --- Step 2: Deploy each assignment individually ---
echo ""
echo "==> Processing $ASSIGNMENT_COUNT assignments one by one..."

ASSIGNMENT_INDEX=0
SUCCESS_COUNT=0
FAIL_COUNT=0

while IFS= read -r assignment_json; do
  ASSIGNMENT_INDEX=$((ASSIGNMENT_INDEX + 1))

  assignment_name=$(echo "$assignment_json" | python3 -c "import json,sys; a=json.load(sys.stdin); print(a['name'])")
  assignment_display_name=$(echo "$assignment_json" | python3 -c "import json,sys; a=json.load(sys.stdin); print(a.get('displayName', a['name']))")
  scope_type=$(echo "$assignment_json" | python3 -c "import json,sys; a=json.load(sys.stdin); print(a['scope']['type'].lower())")
  scope_id=$(echo "$assignment_json" | python3 -c "import json,sys; a=json.load(sys.stdin); print(a['scope']['id'])")
  parameters_key=$(echo "$assignment_json" | python3 -c "import json,sys; a=json.load(sys.stdin); print(a.get('parametersKey',''))")
  parameters_inline=$(echo "$assignment_json" | python3 -c "import json,sys; a=json.load(sys.stdin); print(json.dumps(a.get('parametersInline', {})))")
  identity_config_entry=$(get_identity_config_entry "$assignment_name")
  role_assignments_json='[]'

  # Write assignment and parameterSet to temp files (az CLI requires @file for object params)
  echo "$assignment_json" > "$TMP_ASSIGNMENT"
  if [[ -n "$parameters_key" ]]; then
    python3 -c "import json; p=json.load(open('generated/parameters.json')); print(json.dumps(p.get('${parameters_key}', {})))" > "$TMP_PARAMETERSET"
  elif [[ "$parameters_inline" != "{}" ]]; then
    echo "$parameters_inline" > "$TMP_PARAMETERSET"
  else
    echo '{}' > "$TMP_PARAMETERSET"
  fi

  deploy_name="assign-$(echo "$assignment_name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-47)-$(date +%H%M%S)"

  echo ""
  echo "  [$ASSIGNMENT_INDEX/$ASSIGNMENT_COUNT] $assignment_name: $assignment_display_name (scope: $scope_type/$scope_id)"

  if [[ "$scope_type" == "managementgroup" ]]; then
    AZ_SCOPE_CMD=(az deployment mg)
    SCOPE_ARGS=(--management-group-id "$scope_id")
    BICEP_TEMPLATE="bicep/policyAssignmentManagementGroup.bicep"
    ASSIGNMENT_SCOPE_PATH="/providers/Microsoft.Management/managementGroups/$scope_id"
  elif [[ "$scope_type" == "subscription" ]]; then
    AZ_SCOPE_CMD=(az deployment sub)
    SCOPE_ARGS=(--subscription "$scope_id")
    BICEP_TEMPLATE="bicep/policyAssignmentSubscription.bicep"
    ASSIGNMENT_SCOPE_PATH="/subscriptions/$scope_id"
  else
    echo "    ⚠  Unknown scope type '$scope_type' — skipping."
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  if [[ "$identity_config_entry" != "null" ]]; then
    if ! identity_config_entry=$(ensure_user_assigned_identity_entry "$identity_config_entry" "$assignment_name" "$scope_type" "$scope_id" "$DEPLOY"); then
      echo "    ✗ Failed to resolve/create user-assigned identity configuration"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      continue
    fi
    assignment_json=$(inject_identity_into_assignment "$assignment_json" "$identity_config_entry")
    echo "$assignment_json" > "$TMP_ASSIGNMENT"
    role_assignments_json=$(get_role_assignments_json "$identity_config_entry")

    if [[ "$role_assignments_json" != "[]" ]]; then
      echo "    ℹ RBAC plan:"
      while IFS=$'\t' read -r role_value role_scope; do
        echo "      - $role_value @ $role_scope"
      done < <(iter_role_bindings "$role_assignments_json" "$ASSIGNMENT_SCOPE_PATH")
    fi
  fi

  COMMON_ARGS=(
    "${SCOPE_ARGS[@]}"
    --location "$LOCATION"
    --template-file "$BICEP_TEMPLATE"
    --name "$deploy_name"
    --parameters
      "assignment=@${TMP_ASSIGNMENT}"
      "parameterSet=@${TMP_PARAMETERSET}"
      "definitionManagementGroupId=${MANAGEMENT_GROUP}"
  )

  if [[ "$DEPLOY" == "true" ]]; then
    if "${AZ_SCOPE_CMD[@]}" create "${COMMON_ARGS[@]}" --output none; then
      echo "    ✓ Deployed"

      if [[ "$role_assignments_json" != "[]" ]]; then
        principal_id=""
        if ! principal_id=$(resolve_assignment_principal_id "$assignment_name" "$ASSIGNMENT_SCOPE_PATH" 3 2); then
          # For user-assigned identity assignments, policy assignment principalId may stay empty.
          # Fallback: resolve principalId directly from the configured UAMI resource.
          uami_resource_id=$(echo "$identity_config_entry" | python3 -c "import json,sys; e=json.load(sys.stdin); ids=((e.get('identity') or {}).get('userAssignedIdentityResourceIds') or []); print(ids[0] if ids else '')")
          if [[ -n "$uami_resource_id" ]]; then
            echo "    ℹ PrincipalId fallback to UAMI"
            principal_id=$(az identity show --ids "$uami_resource_id" --query "principalId" -o tsv 2>/dev/null || true)
          fi
        fi

        if [[ -z "$principal_id" || "$principal_id" == "None" ]]; then
          echo "    ✗ Missing managed identity principalId for RBAC setup"
          echo "    ℹ Skipped RBAC commands:"
          while IFS=$'\t' read -r role_value role_scope; do
            echo "      az role assignment create --assignee-object-id <principalId> --assignee-principal-type ServicePrincipal --role \"$role_value\" --scope \"$role_scope\" --output json"
          done < <(iter_role_bindings "$role_assignments_json" "$ASSIGNMENT_SCOPE_PATH")
          FAIL_COUNT=$((FAIL_COUNT + 1))
          continue
        fi

        while IFS=$'\t' read -r role_value role_scope; do
          role_cmd=(
            az role assignment create
            --assignee-object-id "$principal_id"
            --assignee-principal-type ServicePrincipal
            --role "$role_value"
            --scope "$role_scope"
            --output json
          )

          set +e
          role_output=$("${role_cmd[@]}" 2>&1)
          role_rc=$?
          set -e

          if [[ "$role_rc" -eq 0 ]]; then
            echo "    ✓ RBAC ensured: $role_value"
          elif echo "$role_output" | grep -qi "RoleAssignmentExists"; then
            echo "    ✓ RBAC exists: $role_value"
          else
            echo "    ✗ RBAC failed: $role_value @ $role_scope"
            echo "      $role_output"
            FAIL_COUNT=$((FAIL_COUNT + 1))
          fi
        done < <(iter_role_bindings "$role_assignments_json" "$ASSIGNMENT_SCOPE_PATH")
      fi

      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      echo "    ✗ FAILED"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  else
    if "${AZ_SCOPE_CMD[@]}" what-if "${COMMON_ARGS[@]}"; then
      if [[ "$role_assignments_json" != "[]" ]]; then
        echo "    ℹ Role assignments to ensure after deploy:"
        while IFS=$'\t' read -r role_value role_scope; do
          echo "      - $role_value @ $role_scope"
        done < <(iter_role_bindings "$role_assignments_json" "$ASSIGNMENT_SCOPE_PATH")
      fi
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      echo "    ✗ What-if FAILED"
      FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
  fi

done < <(python3 -c "import json,sys; a=json.load(open('generated/assignments.json')); t='''$TARGET_ASSIGNMENT'''.strip(); [print(json.dumps(x)) for x in a if not t or x.get('name')==t]")

echo ""
if [[ "$DEPLOY" == "true" ]]; then
  echo "==> Done: $SUCCESS_COUNT deployed, $FAIL_COUNT failed (of $ASSIGNMENT_COUNT total)."
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "⚠  Some assignments failed. Review output above."
    exit 1
  else
    echo "✓ All policy assignments deployed successfully."
  fi
else
  echo "==> What-if complete: $SUCCESS_COUNT OK, $FAIL_COUNT failed (of $ASSIGNMENT_COUNT total)."
  echo "ℹ  Run with --deploy to apply changes."
fi
