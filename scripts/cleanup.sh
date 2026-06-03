#!/usr/bin/env bash
# cleanup.sh
# Lists or deletes Azure Policy assignments, UAMIs, and optionally policy definitions /
# initiatives managed by this repo.  Queries Azure directly — does not depend on local
# config/*.json files.
#
# Default behaviour (no --delete): list only — no changes are made.
# Pass --delete to actually remove the listed resources.
# Requires active Azure CLI login (az login) or service principal context.
#
# Usage:
#   scripts/cleanup.sh [--delete] [--with-definitions] [-a <name>] [-h]
#
# Options:
#   (no flags)                   List all managed resources found in Azure — no changes made
#       --delete                 Delete the listed resources
#       --with-definitions       Also include custom policy definitions and initiatives
#   -a, --assignment <name>      Scope to a single assignment (ARM resource name / InternalID)
#   -h, --help                   Show this help and exit.
#
# Examples:
#   scripts/cleanup.sh
#   scripts/cleanup.sh --with-definitions
#   scripts/cleanup.sh --delete
#   scripts/cleanup.sh --delete --with-definitions
#   scripts/cleanup.sh -a AP202604290022
#   scripts/cleanup.sh -a AP202604290022 --delete

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '1,/^set -euo/{ /^#[^!]/!d; s/^# \?//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

TARGET_ASSIGNMENT=""
WITH_DEFINITIONS=false
DELETE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--assignment)    TARGET_ASSIGNMENT="$2"; shift 2 ;;
    --with-definitions) WITH_DEFINITIONS=true; shift ;;
    --delete)           DELETE=true; shift ;;
    -h|--help)          usage ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

cd "$ROOT_DIR"

CONFIG_FILE="$ROOT_DIR/configuration/deployment-config.json"
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: deployment-config.json not found at $CONFIG_FILE"
  exit 1
fi
MANAGEMENT_GROUP="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c['deployment']['definitionManagementGroupId'])")"
MANAGEMENT_TAG="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('managementTag', 'policy-by-code'))")"
DEFAULT_IDENTITY_SUBSCRIPTION="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('identityDefaults', {}).get('subscriptionId', ''))")"
DEFAULT_IDENTITY_RESOURCE_GROUP="$(python3 -c "import json; c=json.load(open('$CONFIG_FILE')); print(c.get('identityDefaults', {}).get('resourceGroup', ''))")"

if ! $DELETE; then
  echo "*** LIST MODE — pass --delete to remove resources ***"
  echo ""
fi

echo "Mode:             $([ -n "$TARGET_ASSIGNMENT" ] && echo "selective (assignment: $TARGET_ASSIGNMENT)" || echo "full")"
echo "With definitions: $WITH_DEFINITIONS"
echo "Management Group: $MANAGEMENT_GROUP"
echo "Management Tag:   $MANAGEMENT_TAG"
echo ""

# Temp file for JSON exchange between az CLI and Python; cleaned up on exit.
TMPFILE=$(mktemp /tmp/cleanup-XXXXXX.json)
trap "rm -f $TMPFILE" EXIT

# ---------------------------------------------------------------------------
# Step 1: Policy Assignments — queried via Azure Resource Graph
# ---------------------------------------------------------------------------
echo "==> Policy assignments (assignedBy='$MANAGEMENT_TAG')..."

KQL="PolicyResources
  | where type == 'microsoft.authorization/policyassignments'
  | where properties.metadata.assignedBy == '${MANAGEMENT_TAG}'"

if [[ -n "$TARGET_ASSIGNMENT" ]]; then
  KQL="${KQL} | where name == '${TARGET_ASSIGNMENT}'"
fi

KQL="${KQL} | project name, id, displayName=properties.displayName, uamis=identity.userAssignedIdentities"

az graph query -q "$KQL" --management-groups "$MANAGEMENT_GROUP" --query "data" -o json 2>/dev/null > "$TMPFILE" || echo "[]" > "$TMPFILE"

# List / delete assignments; print UAMI resource IDs (for step 2 selective mode) to stdout.
UAMI_IDS=$(python3 - "$DELETE" "$TMPFILE" <<'PY'
import json, sys, subprocess

do_delete = sys.argv[1] == "true"
assignments = json.load(open(sys.argv[2]))

if not assignments:
    print("  (none found in Azure)", file=sys.stderr)
    sys.exit(0)

uami_ids = set()

for a in assignments:
    rid   = a["id"]
    scope = rid[:rid.lower().index("/providers/microsoft.authorization/policyassignments/")]
    print(f"  {a['name']}  ({a.get('displayName', '') or ''})  scope: {scope}", file=sys.stderr)
    if do_delete:
        r = subprocess.run(
            ["az", "policy", "assignment", "delete", "--name", a["name"], "--scope", scope],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            print(f"    DELETED", file=sys.stderr)
        else:
            print(f"    WARNING: {r.stderr.strip() or 'delete failed'}", file=sys.stderr)
    else:
        print(f"    (list only)", file=sys.stderr)
    for uami_id in (a.get("uamis") or {}).keys():
        uami_ids.add(uami_id)

for uid in sorted(uami_ids):
    print(uid)
PY
)
echo ""

# ---------------------------------------------------------------------------
# Step 2: UAMIs
# ---------------------------------------------------------------------------
echo "==> UAMIs (managedBy='$MANAGEMENT_TAG')..."

if [[ -n "$DEFAULT_IDENTITY_RESOURCE_GROUP" ]]; then

  if [[ -n "$UAMI_IDS" ]]; then
    # Selective mode: use UAMIs referenced by the assignment(s) found above.
    while IFS= read -r uami_id; do
      [[ -z "$uami_id" ]] && continue
      actual_tag=$(az identity show --ids "$uami_id" --query "tags.managedBy" -o tsv 2>/dev/null || true)
      uami_name=$(az identity show --ids "$uami_id" --query "name" -o tsv 2>/dev/null || echo "$uami_id")
      if [[ "$actual_tag" != "$MANAGEMENT_TAG" ]]; then
        echo "  SKIP — $uami_name  (managedBy='${actual_tag:-<unset>}', expected '$MANAGEMENT_TAG')"
        continue
      fi
      echo "  $uami_name"
      if $DELETE; then
        az identity delete --ids "$uami_id" \
          || echo "    (not found or already deleted, skipping)"
      fi
    done <<< "$UAMI_IDS"

  elif [[ -n "$TARGET_ASSIGNMENT" ]]; then
    # Selective mode but the assignment has no UAMI — do not fall through to full scan.
    echo "  (no UAMI referenced by assignment '$TARGET_ASSIGNMENT')"

  else
    # Full mode: list all UAMIs tagged managedBy == MANAGEMENT_TAG in the configured RG.
    az identity list \
      --subscription "$DEFAULT_IDENTITY_SUBSCRIPTION" \
      --resource-group "$DEFAULT_IDENTITY_RESOURCE_GROUP" \
      --query "[?tags.managedBy=='${MANAGEMENT_TAG}']" \
      -o json 2>/dev/null > "$TMPFILE" || echo "[]" > "$TMPFILE"

    python3 - "$DELETE" "$DEFAULT_IDENTITY_SUBSCRIPTION" "$DEFAULT_IDENTITY_RESOURCE_GROUP" "$TMPFILE" <<'PY'
import json, sys, subprocess

do_delete = sys.argv[1] == "true"
sub       = sys.argv[2]
rg        = sys.argv[3]
uamis     = json.load(open(sys.argv[4]))

if not uamis:
    print("  (none found)")
    sys.exit(0)

for u in uamis:
    print(f"  {u['name']}  (rg: {rg})")
    if do_delete:
        r = subprocess.run(
            ["az", "identity", "delete",
             "--name", u["name"], "--resource-group", rg, "--subscription", sub],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            print(f"    DELETED")
        else:
            print(f"    WARNING: {r.stderr.strip() or 'delete failed'}")
    else:
        print(f"    (list only)")
PY
  fi

else
  echo "  (identityDefaults.resourceGroup not configured — skipping)"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3: Policy definitions and initiatives (only with --with-definitions)
# ---------------------------------------------------------------------------
if $WITH_DEFINITIONS; then

  echo "==> Policy definitions (managedBy='$MANAGEMENT_TAG') across MG hierarchy '$MANAGEMENT_GROUP'..."
  KQL_DEF="PolicyResources
    | where type == 'microsoft.authorization/policydefinitions'
    | where properties.metadata.managedBy == '${MANAGEMENT_TAG}'
    | project name, id, displayName=properties.displayName"
  az graph query -q "$KQL_DEF" --management-groups "$MANAGEMENT_GROUP" --query "data" -o json 2>/dev/null > "$TMPFILE" || echo "[]" > "$TMPFILE"

  python3 - "$DELETE" "$TMPFILE" <<'PY'
import json, sys, subprocess

do_delete = sys.argv[1] == "true"
defs      = json.load(open(sys.argv[2]))

if not defs:
    print("  (none found)")
    sys.exit(0)

for d in defs:
    name = d["name"]
    disp = d.get("displayName") or ""
    # Extract MG name from resource ID:
    # /providers/Microsoft.Management/managementGroups/{mg}/providers/...
    rid  = d.get("id", "")
    parts = rid.split("/")
    mg = parts[4] if len(parts) > 4 else ""
    print(f"  {name}  ({disp})  [MG: {mg}]")
    if do_delete:
        r = subprocess.run(
            ["az", "policy", "definition", "delete", "--name", name, "--management-group", mg],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            print(f"    DELETED")
        else:
            print(f"    WARNING: {r.stderr.strip() or 'delete failed'}")
    else:
        print(f"    (list only)")
PY
  echo ""

  # Initiatives — only in full mode (an initiative is shared across assignments).
  if [[ -z "$TARGET_ASSIGNMENT" ]]; then
    echo "==> Initiatives (managedBy='$MANAGEMENT_TAG') across MG hierarchy '$MANAGEMENT_GROUP'..."
    KQL_INIT="PolicyResources
      | where type == 'microsoft.authorization/policysetdefinitions'
      | where properties.metadata.managedBy == '${MANAGEMENT_TAG}'
      | project name, id, displayName=properties.displayName"
    az graph query -q "$KQL_INIT" --management-groups "$MANAGEMENT_GROUP" --query "data" -o json 2>/dev/null > "$TMPFILE" || echo "[]" > "$TMPFILE"

    python3 - "$DELETE" "$TMPFILE" <<'PY'
import json, sys, subprocess

do_delete = sys.argv[1] == "true"
inits     = json.load(open(sys.argv[2]))

if not inits:
    print("  (none found)")
    sys.exit(0)

for i in inits:
    name = i["name"]
    disp = i.get("displayName") or ""
    rid  = i.get("id", "")
    parts = rid.split("/")
    mg = parts[4] if len(parts) > 4 else ""
    print(f"  {name}  ({disp})  [MG: {mg}]")
    if do_delete:
        r = subprocess.run(
            ["az", "policy", "set-definition", "delete", "--name", name, "--management-group", mg],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            print(f"    DELETED")
        else:
            print(f"    WARNING: {r.stderr.strip() or 'delete failed'}")
    else:
        print(f"    (list only)")
PY
    echo ""
  fi
fi

echo "Done."
