#!/usr/bin/env bash
# update-definitions.sh
# Deploys policy set definitions (initiatives) to an Azure Management Group.
# Requires active Azure CLI login (az login) or service principal context.
#
# Usage:
#   scripts/update-definitions.sh [-l <loc>] [-m <mg-id>] [-i <name>] [-d <name>] [--skip-definitions] [--skip-initiatives] [-h]
#
# Options:
#   -l, --location        <loc>    Azure region for deployment metadata.
#                                  Default: deployment.location from deployment-config.json
#   -m, --management-group <mg-id> Management Group ID for policySetDefinitions scope.
#                                  Default: deployment.definitionManagementGroupId from deployment-config.json
#   -i, --initiative      <name>   Process only a single initiative (e.g. Enforce-Guardrails-VirtualDesktop)
#   -d, --definition      <name>   Process only a single policy definition (e.g. Deploy-ANMVnetPeering)
#       --skip-definitions         Skip policy definitions deployment phase.
#       --skip-initiatives         Skip initiative definitions deployment phase.
#   -h, --help                     Show this help and exit.
#
# Examples:
#   scripts/update-definitions.sh
#   scripts/update-definitions.sh -l germanywestcentral -m mg-platform
#   scripts/update-definitions.sh -i Enforce-Guardrails-VirtualDesktop
#   scripts/update-definitions.sh -d Deploy-ANMVnetPeering
#   scripts/update-definitions.sh --skip-definitions
#   scripts/update-definitions.sh --skip-initiatives -d Deploy-ANMVnetPeering

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '1,/^set -euo/{ /^#[^!]/!d; s/^# \?//; p; }' "${BASH_SOURCE[0]}"
  exit 0
}

LOCATION=""
MANAGEMENT_GROUP=""
TARGET_INITIATIVE=""
TARGET_DEFINITION=""
SKIP_DEFINITIONS=false
SKIP_INITIATIVES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--location)         LOCATION="$2"; shift 2 ;;
    -m|--management-group) MANAGEMENT_GROUP="$2"; shift 2 ;;
    -i|--initiative)       TARGET_INITIATIVE="$2"; shift 2 ;;
    -d|--definition)       TARGET_DEFINITION="$2"; shift 2 ;;
    --skip-definitions)    SKIP_DEFINITIONS=true; shift ;;
    --skip-initiatives)    SKIP_INITIATIVES=true; shift ;;
    -h|--help)             usage ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [[ "$SKIP_DEFINITIONS" == "true" && "$SKIP_INITIATIVES" == "true" ]]; then
  echo "Both --skip-definitions and --skip-initiatives are set. Nothing to deploy."
  exit 1
fi

if [[ "$SKIP_DEFINITIONS" == "true" && -n "$TARGET_DEFINITION" ]]; then
  echo "Cannot combine --definition with --skip-definitions."
  exit 1
fi

if [[ "$SKIP_INITIATIVES" == "true" && -n "$TARGET_INITIATIVE" && -z "$TARGET_DEFINITION" ]]; then
  echo "Cannot combine --initiative with --skip-initiatives when no --definition is provided."
  exit 1
fi

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

echo "Location:         $LOCATION"
echo "Management Group: $MANAGEMENT_GROUP"
echo "Skip definitions: $SKIP_DEFINITIONS"
echo "Skip initiatives: $SKIP_INITIATIVES"
if [[ -n "$TARGET_DEFINITION" ]]; then
  echo "Definition:       $TARGET_DEFINITION"
elif [[ -n "$TARGET_INITIATIVE" ]]; then
  echo "Initiative:       $TARGET_INITIATIVE"
else
  echo "Initiative:       (all - TSV Deploy=TRUE pool)"
fi

# --- Step 1: Validate config ---
echo ""
echo "==> Validating config..."
chmod +x "$SCRIPT_DIR/validate-config.sh"
FILTER_INITIATIVE="$TARGET_INITIATIVE" FILTER_DEFINITION="$TARGET_DEFINITION" "$SCRIPT_DIR/validate-config.sh"
echo "✓ Validation passed"

# --- Build TSV pool (bulk mode only) ---
POOL_FILE=""
POOL_DEF_COUNT=0
POOL_INIT_COUNT=0
if [[ -z "$TARGET_INITIATIVE" && -z "$TARGET_DEFINITION" ]]; then
  POOL_FILE="$(mktemp /tmp/update-definitions-XXXXXX.txt)"
  trap "rm -f $POOL_FILE" EXIT
  echo ""
  echo "==> Building deployment pool from TSV (Deploy=TRUE custom items)..."
  python3 - "$CONFIG_FILE" "$MANAGEMENT_GROUP" <<'PYEOF' > "$POOL_FILE"
import csv, json, sys
from pathlib import Path

config = json.load(open(sys.argv[1]))
mg_id  = sys.argv[2]
root   = Path(sys.argv[1]).parent.parent

assignments_path = root / config['sourceFiles']['assignments']
if not assignments_path.exists():
    fallback = config.get('sourceFiles', {}).get('assignmentsFallback', '')
    if fallback:
        assignments_path = root / fallback

if not assignments_path.exists():
    print('ERROR: assignments file not found', file=sys.stderr)
    sys.exit(1)

bicep_set_dir = root / config['bicepTemplates']['policySetDefinitions']

delimiter = '\t' if assignments_path.suffix.lower() == '.tsv' else ','
if assignments_path.suffix.lower() == '.csv':
    header = assignments_path.read_text(encoding='utf-8-sig').splitlines()[0]
    if header.count(';') > header.count(','):
        delimiter = ';'

initiative_ids: set[str] = set()
definition_ids: set[str] = set()

def norm_key(k: str) -> str:
    return ' '.join((k or '').strip().split())

with open(assignments_path, 'r', encoding='utf-8-sig', newline='') as f:
    reader = csv.DictReader(f, delimiter=delimiter)
    for raw_row in reader:
        row = {norm_key(k): (v or '').strip() for k, v in raw_row.items() if k}
        if row.get('Deploy', '').lower() not in ('true', '1', 'yes'):
            continue
        if row.get('Type2', row.get('Type', '')).lower() not in ('custom', 'own'):
            continue
        def_type = row.get('DefinitionType', row.get('Type', '')).lower()
        id_ = row.get('ID', '').strip()
        if not id_:
            continue
        if 'initiative' in def_type:
            initiative_ids.add(id_)
        else:
            definition_ids.add(id_)

mg_prefix = (
    f'/providers/Microsoft.Management/managementGroups/{mg_id}'
    f'/providers/Microsoft.Authorization/policyDefinitions/'
)

def scan_for_defs(obj: object) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == 'policyDefinitionId' and isinstance(v, str) and v.startswith(mg_prefix):
                definition_ids.add(v[len(mg_prefix):])
            else:
                scan_for_defs(v)
    elif isinstance(obj, list):
        for item in obj:
            scan_for_defs(item)

for init_id in initiative_ids:
    tmpl = bicep_set_dir / f'{init_id}.json'
    if tmpl.exists():
        scan_for_defs(json.load(open(tmpl)))

for d in sorted(definition_ids):
    print(f'DEF:{d}')
for i in sorted(initiative_ids):
    print(f'INIT:{i}')
PYEOF
  POOL_DEF_COUNT=$(grep -c '^DEF:' "$POOL_FILE" || true)
  POOL_INIT_COUNT=$(grep -c '^INIT:' "$POOL_FILE" || true)
  echo "  Pool: $POOL_DEF_COUNT policy definition(s), $POOL_INIT_COUNT initiative(s)"
fi

# --- Step 2: Deploy individual policy definitions to Management Group ---
if [[ "$SKIP_DEFINITIONS" != "true" && ( -n "$TARGET_DEFINITION" || -z "$TARGET_INITIATIVE" ) ]]; then
  echo ""
  echo "==> Deploying policy definitions to Management Group '$MANAGEMENT_GROUP'..."
  POLICY_DEF_DEPLOYED=0

  if [[ -n "$TARGET_DEFINITION" ]]; then
    echo "    Processing single definition: $TARGET_DEFINITION"
    template="bicep/policyDefinitions/${TARGET_DEFINITION}.json"
    if [[ ! -f "$template" ]]; then
      echo ""
      echo "✗ Definition not found in bicep/policyDefinitions: $TARGET_DEFINITION"
      exit 1
    fi
    deploy_mg=$(python3 -c "import json; d=json.load(open('$template')); print(d.get('metadata', {}).get('targetManagementGroup', ''))" 2>/dev/null || true)
    deploy_mg="${deploy_mg:-$MANAGEMENT_GROUP}"
    echo ""
    echo "  [1/1] Definition: $TARGET_DEFINITION (MG: $deploy_mg)"
    az deployment mg create \
      --management-group-id "$deploy_mg" \
      --location "$LOCATION" \
      --template-file "$template" \
      --name "policyDef-$(echo "$TARGET_DEFINITION" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-47)-$(date +%H%M%S)" \
      --output none
    POLICY_DEF_DEPLOYED=1
  else
    echo "    Processing $POOL_DEF_COUNT definition(s) from TSV Deploy=TRUE pool"
    POLICY_DEF_INDEX=0
    while IFS= read -r line; do
      [[ "$line" != DEF:* ]] && continue
      policy_name="${line#DEF:}"
      template="bicep/policyDefinitions/${policy_name}.json"
      if [[ ! -f "$template" ]]; then
        echo "  ✗ Template not found, skipping: $template"
        continue
      fi
      POLICY_DEF_INDEX=$((POLICY_DEF_INDEX + 1))
      deploy_mg=$(python3 -c "import json; d=json.load(open('$template')); print(d.get('metadata', {}).get('targetManagementGroup', ''))" 2>/dev/null || true)
      deploy_mg="${deploy_mg:-$MANAGEMENT_GROUP}"
      echo ""
      echo "  [$POLICY_DEF_INDEX/$POOL_DEF_COUNT] Definition: $policy_name (MG: $deploy_mg)"
      az deployment mg create \
        --management-group-id "$deploy_mg" \
        --location "$LOCATION" \
        --template-file "$template" \
        --name "policyDef-$(echo "$policy_name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-47)-$(date +%H%M%S)" \
        --output none
      POLICY_DEF_DEPLOYED=$((POLICY_DEF_DEPLOYED + 1))
    done < "$POOL_FILE"
  fi

  echo ""
  echo "✓ $POLICY_DEF_DEPLOYED policy definition(s) deployed."
fi

# --- Step 3: Deploy initiative (policy set) definitions to Management Group ---
if [[ "$SKIP_INITIATIVES" != "true" && -z "$TARGET_DEFINITION" ]]; then
  echo ""
  echo "==> Deploying initiative definitions to Management Group '$MANAGEMENT_GROUP'..."
  POLICY_SET_DEPLOYED=0

  if [[ -n "$TARGET_INITIATIVE" ]]; then
    echo "    Processing single initiative: $TARGET_INITIATIVE"
    template="bicep/policySetDefinitions/${TARGET_INITIATIVE}.json"
    if [[ ! -f "$template" ]]; then
      echo ""
      echo "✗ Initiative not found in bicep/policySetDefinitions: $TARGET_INITIATIVE"
      exit 1
    fi
    echo ""
    echo "  [1/1] Initiative: $TARGET_INITIATIVE"
    az deployment mg create \
      --management-group-id "$MANAGEMENT_GROUP" \
      --location "$LOCATION" \
      --template-file "$template" \
      --name "policySet-$(echo "$TARGET_INITIATIVE" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-47)-$(date +%H%M%S)" \
      --output none
    POLICY_SET_DEPLOYED=1
  else
    echo "    Processing $POOL_INIT_COUNT initiative(s) from TSV Deploy=TRUE pool"
    POLICY_SET_INDEX=0
    while IFS= read -r line; do
      [[ "$line" != INIT:* ]] && continue
      initiative_name="${line#INIT:}"
      template="bicep/policySetDefinitions/${initiative_name}.json"
      if [[ ! -f "$template" ]]; then
        echo "  ✗ Template not found, skipping: $template"
        continue
      fi
      POLICY_SET_INDEX=$((POLICY_SET_INDEX + 1))
      echo ""
      echo "  [$POLICY_SET_INDEX/$POOL_INIT_COUNT] Initiative: $initiative_name"
      az deployment mg create \
        --management-group-id "$MANAGEMENT_GROUP" \
        --location "$LOCATION" \
        --template-file "$template" \
        --name "policySet-$(echo "$initiative_name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | cut -c1-47)-$(date +%H%M%S)" \
        --output none
      POLICY_SET_DEPLOYED=$((POLICY_SET_DEPLOYED + 1))
    done < "$POOL_FILE"
  fi
  echo ""
  echo "✓ $POLICY_SET_DEPLOYED initiative definition(s) deployed."
fi
