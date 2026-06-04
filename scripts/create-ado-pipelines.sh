#!/usr/bin/env bash
# create-ado-pipelines.sh
# Creates Azure DevOps pipelines from YAML files in pipelines/ using the Azure CLI.
#
# Requires:
#   - Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli
#   - Azure DevOps CLI extension: az extension add --name azure-devops
#   - Active login: az login (or service principal context)
#
# Usage:
#   scripts/create-ado-pipelines.sh --org <org-url> --project <project> [--repo <repo>] [--branch <branch>] [--folder <ado-folder>] [--dry-run]
#
# Options:
#   --org <url>        Full Azure DevOps organization URL (must include https://), e.g. https://dev.azure.com/MyOrg
#   --project <name>   ADO project name, e.g. AzurePolicy
#   --repo <name>      ADO repository name (default: same as --project)
#   --branch <name>    Branch to use as default (default: main)
#   --folder <path>    ADO pipeline folder path (default: \AzurePolicy)
#   --name-suffix <s>  Suffix appended to every pipeline name, e.g. -DEV or -PRD (default: none)
#   --dry-run          Show what would be created without making changes
#   -h, --help         Show this help and exit
#
# Example:
#   scripts/create-ado-pipelines.sh \
#     --org https://dev.azure.com/ChrisPolewiak \
#     --project AzurePolicy \
#     --name-suffix -DEV \
#     --dry-run

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
ORG=""
PROJECT=""
REPO=""
BRANCH="main"
FOLDER='\AzurePolicy'
SUFFIX=""
DRY_RUN=false

# Pipeline definitions: "display-name|yaml-path"
PIPELINES=(
  "A-fetch-policies|pipelines/fetch-policies.yml"
  "B-rebuild-configuration|pipelines/rebuild-configuration.yml"
  "C-update-definitions|pipelines/update-definitions.yml"
  "D-update-assignments|pipelines/update-assignments.yml"
  "E-cleanup|pipelines/cleanup.yml"
  "F-sync-framework|pipelines/sync-framework.yml"
)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)       ORG="$2";     shift 2 ;;
    --project)   PROJECT="$2"; shift 2 ;;
    --repo)      REPO="$2";    shift 2 ;;
    --branch)    BRANCH="$2";  shift 2 ;;
    --folder)    FOLDER="$2";  shift 2 ;;
    --name-suffix) SUFFIX="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift   ;;
    -h|--help)
      sed -n '/^# Usage/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ -z "$ORG" || -z "$PROJECT" ]]; then
  echo "Error: --org and --project are required." >&2
  echo "Run with -h for usage." >&2
  exit 1
fi

if [[ ! "$ORG" =~ ^https:// ]]; then
  echo "Error: --org must be a full URL including https://, e.g. https://dev.azure.com/MyOrg" >&2
  echo "Got: $ORG" >&2
  exit 1
fi

REPO="${REPO:-$PROJECT}"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if ! command -v az &>/dev/null; then
  echo "Error: Azure CLI not found. Install from https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
  exit 1
fi

if ! az extension show --name azure-devops &>/dev/null; then
  echo "Azure DevOps CLI extension not found. Installing..."
  az extension add --name azure-devops
fi

# Configure defaults so we don't have to pass --org/--project to every az call
export AZURE_DEVOPS_EXT_PAT="${AZURE_DEVOPS_EXT_PAT:-}"
az devops configure --defaults organization="$ORG" project="$PROJECT"

# ---------------------------------------------------------------------------
# Helper: check if pipeline already exists
# ---------------------------------------------------------------------------
pipeline_exists() {
  local name="$1"
  az pipelines show --name "$name" &>/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "Organization : $ORG"
echo "Project      : $PROJECT"
echo "Repository   : $REPO"
echo "Branch       : $BRANCH"
echo "ADO folder   : $FOLDER"
echo "Name suffix  : ${SUFFIX:-(none)}"
echo "Dry run      : $DRY_RUN"
echo ""

CREATED=0
SKIPPED=0
FAILED=0

for entry in "${PIPELINES[@]}"; do
  NAME="${entry%%|*}"
  YAML="${entry##*|}"

  # Warn if YAML file is missing locally (gitignored files must be set up from .example.yml)
  if [[ ! -f "$(dirname "${BASH_SOURCE[0]}")/../${YAML}" ]]; then
    echo "  [WARN] $YAML not found locally (gitignored) — pipeline will be created but ADO needs the file in the repo."
    echo "         Copy from the .example.yml template and set the correct pipeline name in source: field."
  fi

  if pipeline_exists "${NAME}${SUFFIX}"; then
    echo "  [SKIP] ${NAME}${SUFFIX} — already exists"
    ((SKIPPED++)) || true
    continue
  fi

  echo -n "  [CREATE] ${NAME}${SUFFIX} ($YAML) ... "

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "(dry run)"
    ((CREATED++)) || true
    continue
  fi

  if az pipelines create \
      --name "${NAME}${SUFFIX}" \
      --yaml-path "$YAML" \
      --repository "$REPO" \
      --repository-type tfsgit \
      --branch "$BRANCH" \
      --folder-path "$FOLDER" \
      --skip-first-run \
      --output none; then
    echo "OK"
    ((CREATED++)) || true
  else
    echo "FAILED"
    ((FAILED++)) || true
  fi
done

echo ""
echo "Done. Created: $CREATED  Skipped: $SKIPPED  Failed: $FAILED"
[[ $FAILED -eq 0 ]]
