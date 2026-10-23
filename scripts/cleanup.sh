#!/usr/bin/env bash
# List managed policy resources by default; --delete enables deletion.
# Usage: scripts/cleanup.sh [--delete] [--with-definitions] [-a <assignment>]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
delete=false
with_definitions=false
assignment=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete) delete=true; shift ;;
    --with-definitions) with_definitions=true; shift ;;
    -a|--assignment)
      [[ $# -gt 1 && -n "$2" ]] || { echo "ERROR: assignment name required" >&2; exit 1; }
      assignment="$2"; shift 2 ;;
    -h|--help) head -n 3 "$0"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
  esac
done
if [[ -n "$assignment" && "$with_definitions" == true ]]; then
  echo "ERROR: selective cleanup cannot delete shared definitions; omit --with-definitions" >&2
  exit 1
fi
for tool in az jq; do
  command -v "$tool" >/dev/null || { echo "ERROR: required command missing: $tool" >&2; exit 1; }
done
config="$ROOT_DIR/configuration/deployment-config.json"
mg="$(jq -er '.deployment.definitionManagementGroupId | select(length > 0)' "$config")"
tag="$(jq -er '.managementTag | select(length > 0)' "$config")"
sub="$(jq -er '.identityDefaults.subscriptionId | select(length > 0)' "$config")"
rg="$(jq -er '.identityDefaults.resourceGroup | select(length > 0)' "$config")"
[[ "$mg$tag$sub$rg" != *"<"* ]] || { echo "ERROR: configure deployment-config.json first" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
issue() {
  echo "ERROR: $*" >&2
  if [[ "${TF_BUILD:-}" == True || "${TF_BUILD:-}" == true ]]; then
    echo "##vso[task.logissue type=error]Cleanup failed; review task log."
  fi
}
trap 'issue "Cleanup stopped; changes may be partial if deletion started."' ERR

# Same paginated ARM Resource Graph pattern as AMBA cleanup.
graph() {
  local query="$1" output="$2" token="" body next
  echo '[]' > "$output"
  while :; do
    body="$(jq -nc --arg q "$query" --arg mg "$mg" --arg token "$token" \
      '{query:$q,managementGroups:[$mg],options:({"$top":1000,resultFormat:"objectArray"} +
      (if $token == "" then {} else {"$skipToken":$token} end))}')"
    az rest --method post --url \
      "https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01" \
      --body "$body" -o json > "$tmp/response.json"
    jq -e '.data | type == "array"' "$tmp/response.json" >/dev/null
    jq -s '.[0] + .[1].data' "$output" "$tmp/response.json" > "$tmp/page.json"
    mv "$tmp/page.json" "$output"
    next="$(jq -r '.["$skipToken"] // empty' "$tmp/response.json")"
    if [[ -z "$next" ]]; then
      [[ "$(jq -r '.resultTruncated // false' "$tmp/response.json")" != true ]] ||
        { issue "Truncated inventory without continuation token"; return 1; }
      break
    fi
    [[ "$next" != "$token" ]] || { issue "Repeated inventory continuation token"; return 1; }
    token="$next"
  done
}

echo "Cleanup: MG=$mg; marker=$tag; delete=$delete; definitions=$with_definitions"
echo "Only marked resources are eligible. Older unmarked ALZ copies require separate review."
echo "Run without --delete first. Resource Graph visibility is limited to the current account."
# Complete inventory before the first delete; failures must never become empty lists.
graph "PolicyResources | where type =~ 'microsoft.authorization/policyassignments' | project id, name, properties, identity" "$tmp/all-assignments.json"
jq --arg tag "$tag" --arg name "$assignment" \
  '[.[] | select(.properties.metadata.assignedBy == $tag) |
  select($name == "" or .name == $name)]' "$tmp/all-assignments.json" > "$tmp/assignments.json"
if [[ -n "$assignment" && "$(jq length "$tmp/assignments.json")" == 0 ]]; then
  issue "No managed assignment named '$assignment'; nothing deleted"
  exit 1
fi
graph "Resources | where type =~ 'microsoft.managedidentity/userassignedidentities' | project id, name, subscriptionId, resourceGroup, tags, properties" "$tmp/all-identities.json"
graph "Resources | where isnotempty(identity.userAssignedIdentities) | project id, identity" "$tmp/references.json"
jq -n --slurpfile selected "$tmp/assignments.json" --slurpfile all "$tmp/all-assignments.json" \
  --slurpfile resources "$tmp/references.json" '
  ($selected[0] | map(.id | ascii_downcase)) as $ids |
  [($all[0][] | select((.id | ascii_downcase) as $id | $ids | index($id) | not)),
   $resources[0][]] |
  [ .[] | (.identity.userAssignedIdentities // {} | keys[]) | ascii_downcase] | unique' > "$tmp/protected.json"
jq --arg tag "$tag" --arg sub "$sub" --arg rg "$rg" --arg name "$assignment" \
  --slurpfile selected "$tmp/assignments.json" --slurpfile protected "$tmp/protected.json" '
  ([$selected[0][] | (.identity.userAssignedIdentities // {} | keys[]) | ascii_downcase]) as $refs |
  [.[] | select(.tags.managedBy == $tag) |
   (.id | ascii_downcase) as $id |
   select(($refs | index($id)) != null or
     ($name == "" and (.subscriptionId | ascii_downcase) == ($sub | ascii_downcase) and
       (.resourceGroup | ascii_downcase) == ($rg | ascii_downcase))) |
   select(($protected[0] | index($id)) == null)]' "$tmp/all-identities.json" > "$tmp/identities.json"
jq -e 'all(.[]; (.properties.principalId // "") != "")' "$tmp/identities.json" >/dev/null
jq -n --slurpfile identities "$tmp/identities.json" --slurpfile assignments "$tmp/assignments.json" \
  '[$identities[0][].properties.principalId, $assignments[0][].identity.principalId |
  select(. != null and . != "") | ascii_downcase] | unique' > "$tmp/principals.json"
graph "AuthorizationResources | where type =~ 'microsoft.authorization/roleassignments' | project id, properties" "$tmp/all-roles.json"
jq --slurpfile principals "$tmp/principals.json" \
  '[.[] | (.properties.principalId // "" | ascii_downcase) as $id |
  select(($principals[0] | index($id)) != null)]' "$tmp/all-roles.json" > "$tmp/roles.json"
echo '[]' > "$tmp/initiatives.json"
echo '[]' > "$tmp/definitions.json"
if $with_definitions; then
  graph "PolicyResources | where type =~ 'microsoft.authorization/policysetdefinitions' | project id, properties" "$tmp/sets.json"
  graph "PolicyResources | where type =~ 'microsoft.authorization/policydefinitions' | project id, properties" "$tmp/defs.json"
  jq --arg tag "$tag" '[.[] | select(.properties.metadata.managedBy == $tag)]' "$tmp/sets.json" > "$tmp/initiatives.json"
  jq --arg tag "$tag" '[.[] | select(.properties.metadata.managedBy == $tag)]' "$tmp/defs.json" > "$tmp/definitions.json"
fi

remove() {
  local collection="$1" api="$2" id current expected actual
  echo "==> $collection: $(jq length "$tmp/$collection.json")"
  while IFS= read -r id; do
    echo "  $id"
    $delete || continue
    current="$(az rest --method get --url "https://management.azure.com${id}?api-version=$api" -o json)"
    case "$collection" in
      assignments) actual="$(jq -r '.properties.metadata.assignedBy // ""' <<< "$current")"; expected="$tag" ;;
      definitions|initiatives) actual="$(jq -r '.properties.metadata.managedBy // ""' <<< "$current")"; expected="$tag" ;;
      identities)
        [[ "$(jq -r '.tags.managedBy // ""' <<< "$current")" == "$tag" ]] ||
          { issue "Identity marker changed: $id"; return 1; }
        actual="$(jq -r '.properties.principalId | ascii_downcase' <<< "$current")"
        expected="$(jq -r --arg id "$id" '.[] | select(.id == $id) | .properties.principalId | ascii_downcase' "$tmp/$collection.json")" ;;
      roles)
        actual="$(jq -r '.properties.principalId | ascii_downcase' <<< "$current")"
        expected="$(jq -r --arg id "$id" '.[] | select(.id == $id) | .properties.principalId | ascii_downcase' "$tmp/$collection.json")" ;;
    esac
    [[ -n "$expected" && "$actual" == "$expected" ]] ||
      { issue "Ownership changed: $id"; return 1; }
    az rest --method delete --url "https://management.azure.com${id}?api-version=$api" -o none
    echo "  DELETED"
  done < <(jq -r '.[].id' "$tmp/$collection.json")
}

remove assignments 2024-04-01
remove roles 2022-04-01
remove identities 2023-01-31
remove initiatives 2023-04-01
remove definitions 2023-04-01
echo "Done. Unmarked resources are retained. Shared UAMIs are retained."
echo "Resource Graph is eventually consistent; repeat list-only after propagation to verify."
