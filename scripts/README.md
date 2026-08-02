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

See [REFERENCE.md](../docs/REFERENCE.md) for detailed documentation of each script.
