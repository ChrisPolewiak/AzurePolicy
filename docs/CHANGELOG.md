# Changelog

All notable changes to this project will be documented in this file.

---

## [Unreleased]

### Changed

- **ADO environment variables renamed** in `configuration/ado-env.yml` and all pipelines:
  `devopsManagedPool` → `devops_runner_pool_name`,
  `serviceConnectionName` → `devops_service_connection_name`.
  Update your local `configuration/ado-env.yml` accordingly.
- **Assignment display name** — generated `displayName` now follows the pattern
  `<InternalID> - <Assignment Name>` (e.g. `AP202610160001 - polewiak-guardrails_avm-DINE`).
  The assignment resource `name` and user-assigned identity names are unchanged.

### Removed

- **Assignment timing logs** (`TIME ...` lines) from `scripts/update-assignments.sh`.

## [0.6.0] — 2026-10-23

### Added

- **Rebuild validation** (`scripts/validate_rebuild.py`) checks deployable TSV rows,
  policy/initiative types, required source files and generated templates, and
  parameters where a schema is available. Pipeline B reports actionable errors
  with TSV line references and an Azure DevOps summary. Failed validation blocks
  publication of the `policy-generated` artifact.
- **Assignment error summary** collects scope, identity, what-if, deployment and
  RBAC failures into a final report with Azure DevOps issues and a Markdown summary.
  What-if failures now return a nonzero exit code.
- **Assignment timing logs** show UAMI preparation, deployment/what-if, principal
  lookup, individual RBAC operations and total assignment-loop duration.

### Changed

- **Pipeline D run modes** use an explicit mode selector: `deployMode=whatif`
  (default) runs preview only; `deployMode=deploy` runs preview followed by
  deployment. `skipValidation=true` skips preview only in deploy mode, not
  configuration checks. A failed preview blocks deployment; no manual pause is
  introduced between preview and deployment.
- **Shared assignment task** moved to
  `.pipelines/.templates/update-assignments-step.yml`, reused for preview and
  deployment. Pipeline C and cleanup retain their existing run-mode controls.
- **Pipeline examples** no longer require a literal `<SUFFIX>` placeholder in
  pipeline names. An explicit environment suffix remains optional.
- **AzAdvertizer validation** generates canonical URLs from the definition type
  and ID for Custom and Built-in rows. The TSV link column is optional and ignored;
  Own definitions do not require an online lookup. Permanent lookup failures
  block validation; transient failures are reported as warnings after retries.
- **Cleanup** uses Bash, Azure CLI and jq to inventory resources before deletion,
  with paginated Resource Graph queries and live ownership checks. Only resources
  with the exact configured ownership marker are eligible. Shared identities are
  protected where visible, and marked orphan UAMIs in the configured identity
  resource group are included. Deletion proceeds through assignments, RBAC, UAMIs,
  initiatives and definitions; query or deletion errors stop the operation.
- **Operator documentation** simplified in Polish and English, with workflow and
  artifact-selection guidance, validation troubleshooting, cleanup boundaries,
  and pipeline UAMI roles: Resource Policy Contributor and conditioned Role Based
  Access Control Administrator at Root/main MG, plus Managed Identity Contributor
  and Managed Identity Operator at the policy UAMI resource group.

### Fixed

- **Policy parameter strings preserve their exact case** instead of normalizing
  boolean-like strings to `True`/`False`. This prevents allowed-value failures
  such as `includeArcMachines=false` becoming the invalid string `False`.
  Surrounding whitespace trimming and existing array/integer parsing are retained.
- **Generated ALZ definitions and initiatives receive the configured ownership
  marker**, allowing cleanup to identify framework-managed copies.
- **Large cleanup inventories** are merged from files rather than passed as
  JSON command-line arguments, avoiding jq's `Argument list too long` failure.
- **Cleanup function failures** propagate to the error trap instead of allowing
  the script to continue after a failed operation.
- **UAMI principal lookup** reads the specified identity directly rather than
  polling the policy assignment. A missing UAMI is reported as an error, without
  falling back to another identity; system-assigned identity retries are retained.

### Upgrade notes

- Update environment-specific Pipeline D YAML from
  `.pipelines/update-assignments.example.yml` and include the new shared task.
  Replace saved `deployPolicies` inputs with `deployMode`; explicitly select
  `deploy` to apply changes. `whatif` remains the safe default, even when the
  skip checkbox is selected.
- Run Pipeline B again to regenerate artifacts after updating the framework,
  especially for the parameter casing fix. Pipeline D consumes B's artifact
  and does not regenerate assignments from edited TSV files.
- Cleanup is list-only unless deletion is explicitly enabled. Older unmarked
  resources require separate review; Resource Graph visibility limits discovery.
- Framework sync still excludes the legacy `configurations/` path, not the whole
  current `configuration/` directory. Review sync changes before applying them.

---

## [0.5.0] — 2026-06-03

### Added

- **`scripts/generate_config_from_table.py`** — `Assignment Scope=ROOT` is now supported as a
  case-insensitive alias for the root Management Group configured by
  `deployment.definitionManagementGroupId` in `configuration/deployment-config.json`.

- **`pipelines/rebuild-configuration.example.yml`**, **`pipelines/update-definitions.example.yml`**,
  **`pipelines/update-assignments.example.yml`** — environment-specific pipeline templates with
  `source: <stage-letter>-<name><SUFFIX>` placeholder in `resources: pipelines:`.
  Same gitignored pattern as `sync-framework.yml` — copy from template and replace `<SUFFIX>` at deployment time.
  Prevents conflicts when multiple environment instances (DEV, PRD) share one ADO project.

### Changed

- **`pipelines/sync-framework.example.yml`** — the public framework repository is downloaded
  anonymously over HTTPS; the GitHub service connection, PAT, and `endpoint` configuration
  are no longer required. The sync target is the root of the single `self` checkout.

- **`scripts/create-ado-pipelines.sh`** — pipeline names now include stage letters
  (`A-fetch-policies`, `B-rebuild-configuration`, `C-update-definitions`, `D-update-assignments`,
  `E-cleanup`, `F-sync-framework`) for consistent sorting in ADO UI.
  New `--name-suffix` option for multi-environment setups (e.g. `--name-suffix -DEV`).

- **`pipelines/sync-framework.example.yml`** — rsync excludes extended with
  `pipelines/rebuild-configuration.yml`, `pipelines/update-definitions.yml`,
  `pipelines/update-assignments.yml` to prevent overwriting environment-specific local files.

---

## [0.4.0] — 2026-06-03

### Added

- **`scripts/create-ado-pipelines.sh`** — CLI script to register all ADO pipeline definitions
  from YAML files using `az pipelines create`. Idempotent (skips existing pipelines).
  Supports `--dry-run`, custom `--folder`, `--branch`, `--repo`.
  `--org` requires a full URL with `https://` scheme (validated at runtime).
  Requires Azure CLI with the `azure-devops` extension.

### Documentation

- **`README.md`** simplified to a project overview with links to `docs/`;
  full operator guide and technical reference moved to `docs/README.md` and `docs/REFERENCE.md`.

- **Process E (cleanup)** added to `docs/README.md` and `docs/README.pl.md`
  (was missing from docs/ despite existing in root README.md).

- **`docs/REFERENCE.md`**, **`docs/REFERENCE.pl.md`** — added `create-ado-pipelines.sh` section
  with full option reference, pipeline table, and examples.

---

## [0.3.0] — 2026-06-03

### Added

- **`pipelines/sync-framework.yml`** — new Pipeline F: syncs framework files (pipelines, scripts, Bicep modules)
  from GitHub `ChrisPolewiak/AzurePolicy` to the ADO repository via `rsync`.
  Preserves local-only paths: `source/own/`, `configurations/`, `scripts/deployment-config.json`,
  `docs/*.tsv / *.csv / *.xlsx / *.xls`.
  Supports `dryRun=true` (default, preview only) and `dryRun=false` (commit + push to ADO).

### Fixed

- **`pipelines/sync-framework.yml`** — multi-repo checkout places `self` under
  `$(Build.SourcesDirectory)/$(Build.Repository.Name)`, not directly at `$(Build.SourcesDirectory)`;
  corrected `rsync` destination and all `git` command paths accordingly.

- **`pipelines/sync-framework.example.yml`** — `sync-framework.yml` converted to gitignored local file
  (same pattern as `ado-env.yml`). ADO `resources:` evaluates before any variables or parameters,
  making the `endpoint:` field a literal-only value. Users copy the example, set their own service connection name,
  and the file is never overwritten by framework syncs.
  `pipelines/sync-framework.yml` added to `.gitignore` and untracked from git.
- **`configuration/ado-env.example.yml`** — committed template for the gitignored `configuration/ado-env.yml`.
  Contains `devops_runner_pool_name` and `devops_service_connection_name`.
  Replaces the former ADO Library Variable Group `AzureDevOps` pattern.
  `ado-env.yml` is loaded by all pipelines via `variables: - template: ../configuration/ado-env.yml`
  and is excluded from `sync-framework.yml` rsync (lives only in the ADO repo).

### Documentation

- **`README.md`**, **`docs/README.md`**, **`docs/README.pl.md`** — added Process F section with
  full usage instructions and GitHub service connection setup steps.
  Added "Initial ADO setup" section with `ado-env.yml` creation instructions.
- **`pipelines/README.md`** — added `sync-framework.yml` to pipeline table and added a dedicated section
  with description, excluded paths, and requirements.
  Updated required variables section to reference `configuration/ado-env.yml`.

---

## [0.2.0] — 2026-06-02

### Added

- **`pipelines/cleanup.yml`** — new Pipeline E: lists or deletes managed policy resources in Azure
  (assignments, UAMIs, policy definitions, initiatives) via `scripts/cleanup.sh`.
  Safe by default — `delete=false` performs list-only dry-run.

### Fixed

- **`pipelines/rebuild-configuration.yml`** — staging and cleanup steps used `config/` instead of `generated/`;
  corrected directory names in `mkdir`, `cp` and `rm` operations.
- **`pipelines/update-assignments.yml`** — artifact restore and cleanup steps used `config/` instead of `generated/`.
- **`configuration/deployment-config.json`** — `sourceFiles` paths pointed to `docs/` after Excel/TSV source files
  were moved to `configuration/`; updated to `configuration/policy-assignments.tsv` etc.
- **`scripts/cleanup.sh`** — policy definitions and initiatives search used `az policy definition list`
  which only returns definitions at the root MG level; replaced with Azure Resource Graph query
  to correctly find definitions across the full MG hierarchy.
  Each result now shows the MG it belongs to (`[MG: ...]`).

### Changed

- **`pipelines/update-definitions.yml`** — optional parameters `targetInitiative` and `targetDefinition`
  now default to `'*'` (deploy all) instead of `''`, fixing the ADO UI "Required" flag.
  Bash conditions updated from `[[ -n '...' ]]` to `[[ '...' != '*' ]]`.
- **`pipelines/update-assignments.yml`** — optional parameter `targetAssignment`
  now defaults to `'*'` (process all) instead of `''`, fixing the ADO UI "Required" flag.

---

## [0.1.0] — 2026-05-XX

### Added

- **`configuration/`** directory as the canonical location for runtime configuration and source files.
- **`configuration/deployment-config.example.json`** — template showing all supported keys
  including `sourceFiles.assignments`, `sourceFiles.parameters`, `paths.*`, `identityDefaults.*`.
- **`generated/`** directory for all auto-generated config JSON files (`initiatives.json`,
  `assignments.json`, `parameters.json`, `assignment-identities.json`);
  replaces the former `config/` directory.

### Changed

- Excel and TSV source files moved from `docs/` to `configuration/`:
  `ALZPolicyAssignments.xlsx`, `policy-assignments.tsv`, `policy-parameters.tsv`.
- **`scripts/generate_config_from_table.py`** — hardcoded fallback paths updated from
  `docs/ALZPolicyAssignments.tsv` to `configuration/policy-assignments.tsv`.
- All pipeline artifacts updated to reference `generated/` instead of `config/`.
- `.gitignore` updated: `configuration/` no longer blanket-ignored; tracked files
  (`deployment-config.example.json`, xlsx, tsv) are explicitly included.

---

## [0.0.2] — 2026-05-XX

### Added

- **`source/own/`** directory (renamed from `custom/`) for custom policy definitions
  and policy set definitions managed outside the ALZ snapshot.
- `Type2=Own` support in TSV filter logic (`generate_config_from_table.py`).
- Bulk-mode TSV pool filtering in `update-definitions.sh` — only deploys rows where
  `Deploy=TRUE` and `Type2` is `Custom` or `Own`; auto-includes definitions referenced
  by custom initiatives.

### Changed

- `custom/policyDefinitions/` → `source/own/policyDefinitions/` (physical rename).
- `deployment-config.json` `paths.customDir` updated to `source/own`.

---

## [0.0.1] — 2026-04-XX

### Added

- Initial Policy as Code structure with four ADO pipelines:
  - **A** `fetch-policies` — fetches ALZ snapshot from GitHub.
  - **B** `rebuild-configuration` — generates ARM JSON + config JSON, publishes artifact.
  - **C** `update-definitions` — deploys policy definitions and initiatives to Management Group.
  - **D** `update-assignments` — what-if and optional deployment of assignments to tenant.
- `scripts/generate_arm_from_source.py` — generates ARM JSON deployment templates from ALZ and own sources.
- `scripts/generate_config_from_table.py` — generates config JSON from TSV/CSV source table.
- `scripts/update-definitions.sh` — deploys ARM JSON to Management Group via `az deployment mg create`.
- `scripts/update-assignments.sh` — deploys assignments via `az deployment tenant create`.
- `scripts/cleanup.sh` — lists or removes managed policy assignments, UAMIs, definitions and initiatives.
- `scripts/validate-config.sh` — validates generated config JSON before deployment.
- Bicep modules: `assignments.bicep`, `policyAssignmentManagementGroup.bicep`, `policyAssignmentSubscription.bicep`.
- UAMI-based identity management with `assignment-identities.json` RBAC plan.
