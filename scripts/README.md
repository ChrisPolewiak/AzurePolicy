# scripts/

Shell and Python scripts that implement the four pipeline stages.

| File | Pipeline | Description |
| --- | --- | --- |
| `fetch-policies.sh` | A | Clones Azure/Enterprise-Scale and copies policy snapshots to `source/EnterpriseALZ/` |
| `rebuild-configuration.sh` | B | Runs ARM JSON generation + config generation + validation |
| `update-definitions.sh` | C | Deploys policy definitions and initiatives to a Management Group |
| `update-assignments.sh` | D | Runs what-if and optionally deploys policy assignments to the tenant |
| `cleanup.sh` | — | Deletes assignments, UAMIs, and optionally definitions/initiatives managed by this repo; verifies Azure ownership markers before deleting |
| `create-ado-pipelines.sh` | — | Creates all ADO pipeline definitions from YAML files using `az pipelines create`; idempotent (skips existing pipelines) |
| `generate_arm_from_source.py` | B | Converts `source/EnterpriseALZ/` snapshots to per-file ARM JSON deployment templates |
| `generate_config_from_table.py` | B/D | Converts TSV exports to `config/*.json` used by Bicep |
| `validate-config.sh` | B/D | Validates structure and cross-references in `config/*.json` |
| `configuration/deployment-config.json` | all | Central configuration: locations, Management Group IDs, paths |

Cleanup uses Bash, Azure CLI and jq to inventory
all pages before deleting: assignments, their identities' RBAC assignments, owned
UAMIs (including orphans in the configured RG), initiatives, then definitions.
Shared UAMIs referenced by remaining policies or resources are retained.
`--assignment` cannot be combined with `--with-definitions`; definitions may be shared.
Query and deletion failures fail the pipeline instead of reporting an empty inventory.
Resource Graph pages are merged from files, not command-line JSON arguments, so
large inventories do not exceed the operating system's argument-size limit.
Always run list-only first and repeat after Azure Resource Graph propagation to verify.
Only resources with this repository's ownership marker are removed: older ALZ
definitions deployed without `metadata.managedBy` are deliberately retained.
Rebuild and redeploy definitions to add the marker before including them in cleanup.
Cleanup does not revert resources created or modified by policy remediation, delete
resource groups, or delete ARM deployment history. RBAC removal remains subject to
the pipeline's delegation conditions. Review identities shared outside the configured
MG hierarchy separately; they cannot be discovered by this scoped inventory.

See [REFERENCE.md](../docs/REFERENCE.md) for detailed documentation of each script.

Rebuild validation does not require local source or ARM template files for TSV rows
with `Type2=Built-in`. It still checks IDs, definition types, parameter set references
and automatically generated AzAdvertizer URLs (type + ID, excluding Own definitions).
The TSV link column is ignored. Required parameters are checked when a local schema
is available; its absence for built-ins does not produce a warning.
