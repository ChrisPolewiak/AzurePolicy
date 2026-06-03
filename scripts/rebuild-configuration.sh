#!/usr/bin/env bash
# rebuild-configuration.sh
# Generates ARM JSON templates and config JSON from existing source/ snapshot.
# Requires source/ to be already populated by fetch-policies.sh.
#
# Usage:
#   scripts/rebuild-configuration.sh
#
# Examples:
#   scripts/rebuild-configuration.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR"

SNAPSHOT_VERSION_FILE="source/EnterpriseALZ/.snapshot-version"
if [[ ! -f "$SNAPSHOT_VERSION_FILE" ]]; then
  echo "ERROR: $SNAPSHOT_VERSION_FILE not found. Run fetch-policies.sh first."
  exit 1
fi
echo "Snapshot version: $(cat "$SNAPSHOT_VERSION_FILE")"

# --- Step 1: Generate Bicep ---
python3 "$SCRIPT_DIR/generate_arm_from_source.py"

for d in bicep/policyDefinitions bicep/policySetDefinitions; do
  [[ -d "$d" ]] || { echo "ERROR: Missing generated directory: $d"; exit 1; }
  count=$(ls "$d"/*.json 2>/dev/null | wc -l)
  [[ $count -gt 0 ]] || { echo "ERROR: No ARM JSON files in $d"; exit 1; }
  echo "  $d: $count templates"
done
echo "✓ ARM JSON templates generated"

# --- Step 2: Generate config JSON ---
echo ""
echo "==> Generating config JSON..."
python3 "$SCRIPT_DIR/generate_config_from_table.py"
echo "✓ Config files generated"
ls -lh generated/initiatives.json generated/assignments.json generated/parameters.json generated/assignment-identities.json

# --- Step 3: Validate ---
echo ""
echo "==> Validating config..."
chmod +x "$SCRIPT_DIR/validate-config.sh"
"$SCRIPT_DIR/validate-config.sh"
echo "✓ Validation passed"

# --- Done ---
echo ""
echo "Done. Review changes, then run update-definitions.sh / update-assignments.sh."
