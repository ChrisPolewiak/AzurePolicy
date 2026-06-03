#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
TARGET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_REPO_URL="https://github.com/Azure/Enterprise-Scale.git"

if [[ -z "$VERSION" ]]; then
  echo "Usage: ./scripts/fetch-policies.sh <tag-or-commit>"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

REQUESTED_VERSION="$VERSION"
CHECKOUT_VERSION="$VERSION"
if [[ "$CHECKOUT_VERSION" == "master" ]]; then
  echo "Requested version 'master' is not available in Azure/Enterprise-Scale. Using 'main' instead."
  CHECKOUT_VERSION="main"
fi

echo "Cloning Azure Policy repo..."
git clone --depth 1 "$POLICY_REPO_URL" "$TMP_DIR/azure-policy"
cd "$TMP_DIR/azure-policy"

echo "Checking out version: $CHECKOUT_VERSION"
git fetch --tags --force origin
git fetch --depth 1 origin "$CHECKOUT_VERSION" || true

if git show-ref --verify --quiet "refs/remotes/origin/$CHECKOUT_VERSION"; then
  git checkout -B "$CHECKOUT_VERSION" "origin/$CHECKOUT_VERSION"
elif git rev-parse --verify --quiet "$CHECKOUT_VERSION^{commit}" >/dev/null; then
  git checkout "$CHECKOUT_VERSION"
else
  echo "Failed to resolve version '$REQUESTED_VERSION' (resolved as '$CHECKOUT_VERSION')."
  echo "Use a valid branch name, tag, or commit SHA from Azure/Enterprise-Scale."
  exit 1
fi

SRC_POLICY_DEFINITIONS="$TMP_DIR/azure-policy/src/resources/Microsoft.Authorization/policyDefinitions"
SRC_POLICY_SET_DEFINITIONS="$TMP_DIR/azure-policy/src/resources/Microsoft.Authorization/policySetDefinitions"
SOURCE_ROOT="$TARGET_ROOT/source/EnterpriseALZ"

DST_POLICY_DEFINITIONS="$SOURCE_ROOT/policyDefinitions"
DST_POLICY_SET_DEFINITIONS="$SOURCE_ROOT/policySetDefinitions"

# show $TMP_DIR Resource tree for debugging
echo "Source policy definitions path: $SRC_POLICY_DEFINITIONS"
echo "Source policy set definitions path: $SRC_POLICY_SET_DEFINITIONS"
ls -la "$TMP_DIR/azure-policy"

if [[ ! -d "$SRC_POLICY_DEFINITIONS" || ! -d "$SRC_POLICY_SET_DEFINITIONS" ]]; then
  echo "Expected source folders not found in Azure Policy repo structure."
  exit 1
fi

mkdir -p "$DST_POLICY_DEFINITIONS" "$DST_POLICY_SET_DEFINITIONS"

# Keep a local versioned snapshot in repo as source of truth.
rsync -a --delete "$SRC_POLICY_DEFINITIONS/" "$DST_POLICY_DEFINITIONS/"
rsync -a --delete "$SRC_POLICY_SET_DEFINITIONS/" "$DST_POLICY_SET_DEFINITIONS/"

echo "$CHECKOUT_VERSION" > "$SOURCE_ROOT/.snapshot-version"

echo "Definitions updated successfully."
echo "Snapshot version (requested): $REQUESTED_VERSION"
echo "Snapshot version (resolved):  $CHECKOUT_VERSION"
