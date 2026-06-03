# Changelog

All notable changes to this project will be documented in this file.

---

## [Unreleased]

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
  Contains `devopsManagedPool` and `serviceConnectionName`.
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
