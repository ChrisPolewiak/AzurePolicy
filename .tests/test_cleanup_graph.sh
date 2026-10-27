#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mg=test
issue() { echo "ERROR: $*" >&2; }
source <(sed -n '/^graph() {$/,/^}$/p' "${1:-$SCRIPT_DIR/../scripts/cleanup.sh}")

# One ARG page can exceed Linux's per-argument limit even with few resources.
jq -n '{data:[range(0;1000) | {id:("resource-" + tostring),properties:{text:("x" * 1024)}}],
  "$skipToken":"next-page",resultTruncated:true}' > "$tmp/first.json"
jq -n '{data:[{id:"last"}],resultTruncated:false}' > "$tmp/last.json"
echo 0 > "$tmp/calls"
az() {
  local body="" calls
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --body ]]; then body="$2"; shift 2; else shift; fi
  done
  calls="$(cat "$tmp/calls")"
  echo "$((calls + 1))" > "$tmp/calls"
  if [[ "$calls" == 0 ]]; then
    jq -e '.options["$skipToken"] == null' <<< "$body" >/dev/null
    cat "$tmp/first.json"
  else
    jq -e '.options["$skipToken"] == "next-page"' <<< "$body" >/dev/null
    cat "$tmp/last.json"
  fi
}
graph "PolicyResources | project id, properties" "$tmp/inventory.json"
jq -e 'length == 1001 and .[0].id == "resource-0" and .[-1].id == "last"
  and .[0].properties.text == ("x" * 1024)' "$tmp/inventory.json" >/dev/null
echo "PASS: multi-megabyte inventory preserves all rows across pages"

az() { echo '{"data":null}'; }
export tmp mg
export -f graph issue az
if bash -e -c 'graph test "$tmp/invalid.json"'; then
  echo "FAIL: malformed response accepted" >&2
  exit 1
fi
az() { echo "Query denied" >&2; return 1; }
export -f az
if bash -e -c 'graph test "$tmp/denied.json"'; then
  echo "FAIL: failed query accepted" >&2
  exit 1
fi
echo "PASS: malformed responses and query failures fail inventory"
