# Azure Policy by Code

This repository deploys Azure Policy definitions and assignments using a Policy as Code model aligned with the Azure Landing Zone (ALZ / Enterprise Scale) approach.

Technical details (file formats, script descriptions, Bicep structure): [REFERENCE.md](REFERENCE.md)

---

## Table of Contents

1. [Repository structure](#repository-structure)
2. [Process A — fetch-policies](#process-a--fetch-policies)
3. [Process B — rebuild-configuration](#process-b--rebuild-configuration)
4. [Process C — update-definitions](#process-c--update-definitions)
5. [Process D — update-assignments](#process-d--update-assignments)

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

Required Library variables (Variable Group `AzureDevOps`):

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

Required Library variables (Variable Group `AzureDevOps`):

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
