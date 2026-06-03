# Azure Policy by Code

This repository deploys Azure Policy definitions and assignments using a Policy as Code model aligned with the Azure Landing Zone (ALZ / Enterprise Scale) approach.

Technical details (file formats, script descriptions, Bicep structure): [REFERENCE.md](REFERENCE.md)

---

## Table of Contents

1. [Repository structure](#repository-structure)
2. [Initial ADO setup](#initial-ado-setup-one-time)
3. [Process A — fetch-policies](#process-a--fetch-policies)
4. [Process B — rebuild-configuration](#process-b--rebuild-configuration)
5. [Process C — update-definitions](#process-c--update-definitions)
6. [Process D — update-assignments](#process-d--update-assignments)
7. [Process E — cleanup](#process-e--cleanup)
8. [Process F — sync-framework](#process-f--sync-framework)

---

## Repository structure

```text
.
├── bicep/
│   ├── policyDefinitions/                # AUTO-GENERATED ARM JSON — in .gitignore, passed via artifact
│   ├── policySetDefinitions/             # AUTO-GENERATED ARM JSON — in .gitignore, passed via artifact
│   ├── assignments.bicep                 # Iterates over assignments.json and calls MG/Sub modules
│   ├── policyAssignmentManagementGroup.bicep  # Assignment module for Management Group scope
│   └── policyAssignmentSubscription.bicep     # Assignment module for Subscription scope
├── generated/
│   ├── initiatives.json                  # AUTO-GENERATED — in .gitignore, passed via artifact
│   ├── assignments.json                  # AUTO-GENERATED — in .gitignore, passed via artifact
│   └── parameters.json                   # AUTO-GENERATED — in .gitignore, passed via artifact
├── source/
│   ├── EnterpriseALZ/
│   │   ├── policyDefinitions/            # Snapshot JSON from GitHub Azure/Enterprise-Scale
│   │   ├── policySetDefinitions/         # Snapshot JSON from GitHub Azure/Enterprise-Scale
│   │   └── .snapshot-version             # Current version/tag of the GH snapshot
│   ├── own/
│   │   ├── policyDefinitions/            # Custom policy definitions
│   │   └── policySetDefinitions/         # Custom policy sets
├── configuration/
│   ├── deployment-config.json            # Local runtime config (ignored by git)
│   ├── deployment-config.example.json    # Template for deployment-config.json
│   ├── Azure-Policy.xlsx                 # Source of truth — assignments (edit here)
│   ├── policy-assignments.tsv            # Export from Excel — input for scripts
│   ├── policy-parameters.tsv             # Export from Excel — input for scripts
│   └── README.md                         # Migration notes for config location
├── docs/
├── pipelines/
│   ├── fetch-policies.yml                # Pipeline A: fetch GH snapshot → artifact policy-source
│   ├── rebuild-configuration.yml         # Pipeline B: fetch policy-source → generate → artifact policy-generated
│   ├── update-definitions.yml            # Pipeline C: fetch policy-generated → deploy to MG
│   └── update-assignments.yml            # Pipeline D: fetch policy-generated → what-if → deploy to tenant
├── scripts/
│   ├── fetch-policies.sh                 # Fetches snapshot from GitHub Azure/Enterprise-Scale
│   ├── rebuild-configuration.sh          # Generates ARM JSON + config JSON + validation
│   ├── update-definitions.sh             # Deploys policyDefinitions and policySetDefinitions to Management Group
│   ├── update-assignments.sh             # What-if + optional deploy of assignments to tenant
│   ├── generate_arm_from_source.py       # Generates ARM JSON templates for policies and initiatives
│   ├── generate_config_from_table.py     # Generates generated/*.json from TSV/CSV files
│   └── validate-config.sh               # Validates generated/*.json correctness before deployment
└── REFERENCE.md                          # Technical documentation
```

---

## Initial ADO setup (one-time)

Before running any pipeline, create local configuration files in your ADO repository:

1. Copy `configuration/ado-env.example.yml` to `configuration/ado-env.yml`.
2. Fill in your values:
   - `devopsManagedPool` — name of your ADO agent pool (e.g. `Default` or a self-hosted pool).
   - `serviceConnectionName` — name of the Azure DevOps service connection for Azure CLI tasks.
3. Copy `pipelines/sync-framework.example.yml` to `pipelines/sync-framework.yml`.
4. In `sync-framework.yml`, set `endpoint:` to the name of your GitHub service connection in ADO.
5. Both files are in `.gitignore` — they stay in your ADO repo only and are never committed to GitHub.

> Service connection setup: ADO **Project Settings** → **Service connections** → **New service connection** → **Azure Resource Manager** → Service principal (automatic).
> Assign it **Contributor** + **User Access Administrator** at Management Group scope.

---

## Process A — fetch-policies

Use when Microsoft releases a new version of definitions in the
[Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) repository and you want to update the snapshots.

The pipeline runs `fetch-policies.sh` and **publishes the `policy-source` artifact** (the `source/` directory), which is the input for Process B.

> `source/` is in `.gitignore` — it does not go into the repository; it lives only as a pipeline artifact.

### Step A1 — Check the current snapshot version

Check the list of tags/commits on GitHub: <https://github.com/Azure/Enterprise-Scale/releases>

### Step A2 — Run the fetch-policies pipeline

Run the **`fetch-policies`** pipeline (manually, trigger: none):

| Parameter | Default | Description |
| --- | --- | --- |
| `policyVersion` | `main` | Tag or commit SHA from Azure/Enterprise-Scale |

The pipeline:

1. Runs `fetch-policies.sh <policyVersion>` — clones Enterprise-Scale and copies JSON to `source/`
2. Publishes the **`policy-source`** artifact (`source/`)

### Step A2 (alternative — run locally)

```bash
./scripts/fetch-policies.sh
```

---

## Process B — rebuild-configuration

Use when you are changing **which initiatives are active** (adding/removing initiatives from `configuration/Azure-Policy.xlsx`) or updating definitions from a new snapshot.

The pipeline fetches the `policy-source` artifact from Process A, generates all files, and **publishes the `policy-generated` artifact** (ARM JSON + config JSON), which is the input for Processes C and D.

> `bicep/policyDefinitions/*.json`, `bicep/policySetDefinitions/*.json` and `generated/*.json`
> are in `.gitignore` — they do not go into the repository; they live only as pipeline artifacts.

### Step B1 — Update the initiatives and assignments list in Excel

Open `configuration/Azure-Policy.xlsx` and modify the relevant tabs (assignments and/or parameters).

### Step B2 — Export changes to TSV

In Excel, for each modified tab:

1. Select the entire table (including headers) → copy (`Ctrl+C`)
2. Open the corresponding TSV file in VS Code:
   - assignments → `configuration/policy-assignments.tsv`
   - parameters → `configuration/policy-parameters.tsv`
3. Select all content (`Ctrl+A`), paste (`Ctrl+V`), save

### Step B3 — Commit changes and run the pipeline

```bash
git add configuration/policy-assignments.tsv configuration/policy-parameters.tsv
git commit -m "feat: update initiatives — <description of changes>"
git push
```

Run the **`rebuild-configuration`** pipeline (manually, trigger: none):

| Parameter | Default | Description |
| --- | --- | --- |
| `policyVersion` | `main` | Tag or commit SHA from Azure/Enterprise-Scale (source of artifact A) |

When you trigger the run, ADO will ask you to select a Pipeline A run — choose the one with the correct version or leave the default (last successful).

The pipeline:

1. Fetches the **`policy-source`** artifact from Pipeline A
2. Runs `rebuild-configuration.sh` — generates ARM JSON + config JSON + validation
3. Publishes the **`policy-generated`** artifact (`bicep/` + `generated/`)

### Step B3 (alternative — run locally)

```bash
# Assuming source/ is already populated by fetch-policies.sh
./scripts/rebuild-configuration.sh
```

> **Next step:** Run **Process C** (`update-definitions`) and/or **Process D** (`update-assignments`).

---

## Process C — update-definitions

Use after **Process B** — deploys updated policy definitions and initiatives (`bicep/policyDefinitions/*.json`, `bicep/policySetDefinitions/*.json`) to the Management Group.

The pipeline fetches the `policy-generated` artifact from Process B (containing ARM JSON + config JSON) and runs `update-definitions.sh`.

### Step C1 — Run the update-definitions pipeline

Run the **`update-definitions`** pipeline (manually, trigger: none):

| Parameter | Default | Description |
| --- | --- | --- |
| `location` | `germanywestcentral` | Deployment metadata location |
| `targetInitiative` | `''` | Optional: deploy only one initiative name |
| `targetDefinition` | `''` | Optional: deploy only one policy definition name |
| `deployPolicyDefinitions` | `true` | Deploy policy definitions phase |
| `deployInitiatives` | `true` | Deploy initiative definitions phase |

Required variables (`configuration/ado-env.yml`):

- `serviceConnectionName` — Azure DevOps service connection used by `AzureCLI@2` (`azureSubscription`).
- `devopsManagedPool` — agent pool name used by the pipeline (`pool.name`).

When you trigger the run, ADO will ask you to select a Pipeline B run — choose the correct one or leave the default (last successful).

The pipeline:

1. Fetches the **`policy-generated`** artifact from Pipeline B
2. Runs `update-definitions.sh` — validation + loop `az deployment mg create` for each file in `bicep/policyDefinitions/*.json` (definitions use `metadata.targetManagementGroup` when present; otherwise `definitionManagementGroupId` is used as fallback)
3. Runs `update-definitions.sh` — loop `az deployment mg create` for each file in `bicep/policySetDefinitions/*.json`

Examples for selective execution from the pipeline UI:

- set `targetInitiative=Enforce-Guardrails-VirtualDesktop` to deploy one initiative only
- set `targetDefinition=Deploy-ANMVnetPeering` to deploy one policy definition only
- set `deployPolicyDefinitions=false` to skip policy definitions phase
- set `deployInitiatives=false` to skip initiative definitions phase

### Step C1 (alternative — run locally)

```bash
# Assuming bicep/ and generated/ are populated by rebuild-configuration.sh
./scripts/update-definitions.sh

# With location override only:
./scripts/update-definitions.sh --location germanywestcentral

# Optional: override management group for initiatives (and fallback for definitions without metadata.targetManagementGroup):
./scripts/update-definitions.sh --location germanywestcentral --management-group your-management-group-id
```

---

## Process D — update-assignments

Use when you want to update **assignments and parameters** — without changing initiative definitions.
Can be run independently of Processes A–C provided that the `policy-generated` artifact from Process B is available (or files are locally generated).

### Step D1 — Edit the Excel file with assignments

Open `configuration/Azure-Policy.xlsx`.

The table includes helper columns (not processed by the script):

- **AzAdvertizer Link** — link to the policy preview on azadvertizer.net
- **Version** — definition version from GH on which the assignment is based

Columns processed by the script — described in [REFERENCE.md → TSV format](REFERENCE.md#tsv-format).

### Step D2 — Edit parameters (if needed)

Open `configuration/Azure-Policy.xlsx` → **Parameters** tab and update parameter values for the relevant sets (Parameter Set).

### Step D3 — Export changes to TSV

In Excel, for each modified tab:

1. Select the entire data table (including headers)
2. Copy (`Ctrl+C`)
3. Open the corresponding TSV file in VS Code:
   - assignments → `configuration/policy-assignments.tsv`
   - parameters → `configuration/policy-parameters.tsv`
4. Select all content (`Ctrl+A`) and paste (`Ctrl+V`)
5. Save

### Step D4 — Commit changes and run the pipeline

```bash
git add configuration/policy-assignments.tsv configuration/policy-parameters.tsv
git commit -m "feat: update policy assignments — <description of changes>"
git push
```

Run the **`update-assignments`** pipeline (manually, trigger: none):

| Parameter | Default | Description |
| --- | --- | --- |
| `location` | `germanywestcentral` | Deployment metadata location |
| `deployPolicies` | `false` | Whether to deploy assignments to Azure (`false` = what-if only) |
| `targetAssignment` | `''` | Optional: process only one assignment name |

Required variables (`configuration/ado-env.yml`):

- `serviceConnectionName` — Azure DevOps service connection used by `AzureCLI@2` (`azureSubscription`).
- `devopsManagedPool` — agent pool name used by the pipeline (`pool.name`).

Note: Assignment destination scope is always taken from each item in `generated/assignments.json` (`scope.type` + `scope.id`).
Definition IDs are resolved from assignment data (`policyDefinitionId` when present, otherwise names).
`definitionManagementGroupId` is read from `configuration/deployment-config.json`, not from Library.
For UAMI RBAC, effective role assignment scopes come from `generated/assignment-identities.json` (`roleAssignments[].scope`), not from `definitionManagementGroupId`.

When you trigger the run, ADO will ask you to select a Pipeline B run — choose the correct one or leave the default (last successful).

The pipeline:

1. Fetches the **`policy-generated`** artifact from Pipeline B
2. Runs `update-assignments.sh` — generates `generated/*.json` + validation + `az deployment tenant what-if`
3. *(optionally when `deployPolicies=true`)* `az deployment tenant create`

> **Tip:** By default (`deployPolicies=false`) the pipeline runs what-if only, without deployment.
> Set `deployPolicies=true` only after reviewing the what-if output.

### Step D4 (alternative — run locally)

```bash
# What-if only (preview changes)
./scripts/update-assignments.sh

# Actual deployment
./scripts/update-assignments.sh --deploy

# With parameter overrides:
./scripts/update-assignments.sh --deploy --location germanywestcentral --management-group your-management-group-id

# Single assignment only (what-if):
./scripts/update-assignments.sh --assignment AP2026-04-28_0015

# Single assignment only (deploy) — useful for testing or rolling out one by one:
./scripts/update-assignments.sh --assignment AP2026-04-28_0015 --deploy
```

---

## Process E — cleanup

Use to list or delete policy resources managed by this repo (assignments, UAMIs, definitions, initiatives).

> **Safe by default** — without `delete=true` the pipeline only lists resources, no changes are made.

### Step E1 — Run the cleanup pipeline

Run the **`cleanup`** pipeline (manually, trigger: none):

| Parameter | Default | Description |
| --- | --- | --- |
| `targetAssignment` | `*` | Assignment name to process (`*` = all) |
| `withDefinitions` | `false` | Also remove policy definitions and initiatives |
| `delete` | `false` | `false` = list only (dry-run), `true` = delete resources |

Required variables (`configuration/ado-env.yml`): `serviceConnectionName`, `devopsManagedPool` (same as Pipeline C/D).

### Step E1 (alternative — run locally)

```bash
# List all managed resources (no changes)
./scripts/cleanup.sh

# List including definitions and initiatives
./scripts/cleanup.sh --with-definitions

# Delete assignments and UAMIs (dry-run first!)
./scripts/cleanup.sh --delete

# Delete everything including definitions
./scripts/cleanup.sh --delete --with-definitions

# Scope to single assignment
./scripts/cleanup.sh -a AP202604290022 --delete
```

---

## Process F — sync-framework

Use when a new version of the framework (pipelines, scripts, Bicep modules) is released on GitHub and you want to pull it into the ADO repository, without overwriting your local configuration.

> This pipeline syncs **framework files only** — it never touches `source/own/`, `configurations/`, `scripts/deployment-config.json`, nor local data exports in `docs/`.

### Prerequisite — GitHub service connection

Before the pipeline can be run for the first time, create a **GitHub service connection** in Azure DevOps with the exact name expected by the pipeline:

```
sc-chrispolewiak-github-azurepolicy
```

Steps:

1. In ADO, go to **Project Settings → Service connections → New service connection**.
2. Select **GitHub**.
3. Choose authentication method — recommended: **GitHub App** or **Personal Access Token (PAT)**.
   - PAT requires at least `repo` (read) scope.
4. Set the **Service connection name** — can be any name (your naming convention).
5. Check **Grant access permission to all pipelines** (or limit to the `sync-framework` pipeline).
6. Save.

Then update `endpoint:` in your local `pipelines/sync-framework.yml` to match the name you chose.

### Step F1 — Run the sync-framework pipeline

Run the **`sync-framework`** pipeline (manually, trigger: none):

| Parameter | Default | Description |
| --- | --- | --- |
| `frameworkVersion` | `main` | Tag or branch from GitHub `ChrisPolewiak/AzurePolicy` |
| `dryRun` | `true` | `true` = preview only (no commit), `false` = commit and push to ADO |

The pipeline:

1. Checks out the ADO repository (`self`) with `persistCredentials: true`.
2. Checks out the GitHub repository (`framework`) to `_framework_tmp`.
3. Runs `rsync` — copies files from GitHub to ADO, **excluding** local-only paths:
   - `source/own/` — własne definicje polityk
   - `configurations/` — lokalna konfiguracja wdrożeń
   - `scripts/deployment-config.json`
   - `docs/*.tsv`, `docs/*.csv`, `docs/*.xlsx`, `docs/*.xls`
4. If `dryRun=false`: commits and pushes changes with message `chore: sync framework <version> from GitHub [skip ci]`.
5. If `dryRun=true` (default): displays `git status` and `git diff --stat HEAD` without committing.

> **Tip:** Always run with `dryRun=true` first to review what would change before committing.

---

## Further development

Recommended next step:

- Add exemption support via `generated/exemptions.json` and `bicep/exemptions.bicep`.

---

## License and acknowledgements

This project is licensed under the [MIT License](LICENSE).

Policy definitions and initiatives are sourced from
[Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) by Microsoft,
also released under the MIT License.

Developed with [Visual Studio Code](https://code.visualstudio.com/) and
[Claude AI](https://www.anthropic.com/claude) by Anthropic.
