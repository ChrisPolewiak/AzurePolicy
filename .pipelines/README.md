# Azure DevOps pipelines

For everyday operation, read the [operator guide](../docs/README.md)
([Polski](../docs/README.pl.md)). All six pipelines are started manually.

## Set up in the deployment repository

1. Copy each `*.example.yml` here to the corresponding `*.yml`.
   Examples are shared framework files; environment-specific copies are gitignored.
2. Copy [ado-env.example.yml](../configuration/ado-env.example.yml) to
   `configuration/ado-env.yml`. Set the agent pool and Azure service connection.
3. Register the pipelines in ADO using the names below. Alternatively, use
   [create-ado-pipelines.sh](../scripts/create-ado-pipelines.sh); inspect its `--help`
   and run `--dry-run` before creating anything.
4. Match B's `source:` to A's registered name, and C/D's `source:` to B's.
   Defaults have no environment suffix. If using `--name-suffix`, update those references too.

| ADO name | Template | Input → result |
| --- | --- | --- |
| `A-fetch-policies` | [fetch-policies.example.yml](fetch-policies.example.yml) | Microsoft ALZ → `policy-source` |
| `B-rebuild-configuration` | [rebuild-configuration.example.yml](rebuild-configuration.example.yml) | `policy-source` + local sources/TSV → validated `policy-generated` |
| `C-update-definitions` | [update-definitions.example.yml](update-definitions.example.yml) | `policy-generated` + checkout TSV → definitions/initiatives in Azure |
| `D-update-assignments` | [update-assignments.example.yml](update-assignments.example.yml) | `policy-generated` → `deployMode=whatif` (default) or `deploy`; `skipValidation` skips preview only in deploy mode |
| `E-cleanup` | [cleanup.example.yml](cleanup.example.yml) | Live inventory → list; deletion only with `delete=true` |
| `F-sync-framework` | [sync-framework.example.yml](sync-framework.example.yml) | Public GitHub → diff; commit/push only with `dryRun=false` |

## Before starting a run

- Select the intended upstream artifact run, not simply the latest successful one.
  A failed B produces no new artifact. Keep C's checkout revision aligned with B.
- C and D can run independently, but C must run first when D needs new definitions.
- Authorize the Azure service connection for the relevant pipelines. Azure RBAC is separate;
  required UAMI roles are in the operator guide.
- F clones public GitHub anonymously: no GitHub service connection, PAT or `endpoint` is needed.
  Its agent needs Git and rsync. Review the actual exclusion list before applying changes;
  the legacy `configurations/` exclusion is not all of `configuration/`.
- F preserves existing environment-specific YAMLs. Compare them with changed examples manually.
