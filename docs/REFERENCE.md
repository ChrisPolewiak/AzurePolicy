# Technical Reference — Azure Policy as Code

This document covers the technical details of the repository: file formats, script descriptions,
ARM JSON / Bicep template structure, and central configuration.

Operator guide (processes and workflows): [README.md](README.md)

---

## Table of Contents

1. [Central configuration — `deployment-config.json`](#central-configuration--deployment-configjson)
2. [Scripts](#scripts)
   - [fetch-policies.sh](#fetch-policiessh)
   - [generate\_arm\_from\_source.py](#generate_arm_from_sourcepy)
   - [generate\_config\_from\_table.py](#generate_config_from_tablepy)
   - [validate-config.sh](#validate-configsh)
   - [create-ado-pipelines.sh](#create-ado-pipelinessh)
   - [cleanup.sh](#cleanupsh)
3. [TSV file formats](#tsv-file-formats)
4. [JSON file formats (generated/)](#json-file-formats-generated)
   - [initiatives.json](#initiativesjson)
   - [assignments.json](#assignmentsjson)
   - [parameters.json](#parametersjson)
5. [Templates and Bicep structure](#templates-and-bicep-structure)
6. [Snapshot version tracking](#snapshot-version-tracking)
7. [Extension — exemptions](#extension--exemptions)

---

## Central configuration — `deployment-config.json`

`configuration/deployment-config.json` holds all paths and deployment parameters.
Python scripts read default values from it so they do not need to be passed via CLI.

```json
{
  "managementTag": "policy-by-code",
  "deployment": {
    "location": "germanywestcentral",
    "definitionManagementGroupId": "<GUID or MG name>"
  },
  "paths": {
    "configDir": "generated",
    "sourceDir": "source/EnterpriseALZ",
    "bicepDir": "bicep",
    "docsDir": "docs",
    "customDir": "source/own"
  },
  "sourceFiles": {
    "assignments": "configuration/policy-assignments.tsv",
    "assignmentsFallback": "configuration/policy-assignments.csv",
    "parameters": "configuration/policy-parameters.tsv",
    "parametersFallback": "configuration/policy-parameters.csv"
  },
  "outputFiles": {
    "initiatives": "generated/initiatives.json",
    "assignments": "generated/assignments.json",
    "parameters": "generated/parameters.json"
  },
  "bicepTemplates": {
    "policyDefinitions": "bicep/policyDefinitions",
    "policySetDefinitions": "bicep/policySetDefinitions",
    "assignments": "bicep/assignments.bicep",
    "policyAssignmentManagementGroup": "bicep/policyAssignmentManagementGroup.bicep",
    "policyAssignmentSubscription": "bicep/policyAssignmentSubscription.bicep"
  }
}
```

---

## Scripts

### fetch-policies.sh

**Purpose:** Downloads a policy definition snapshot from the
[Azure/Enterprise-Scale](https://github.com/Azure/Enterprise-Scale) repository and saves it locally.

**Usage:**

```bash
scripts/fetch-policies.sh <tag-or-commit-SHA>
```

**Steps:**

1. Clones `Azure/Enterprise-Scale` into a temporary directory (`--depth 1`).
2. Checks out the specified tag or commit.
3. Copies `src/resources/Microsoft.Authorization/policyDefinitions/` to `source/policyDefinitions/`
   and `policySetDefinitions/` to `source/policySetDefinitions/` using `rsync --delete`.
4. Writes the used version to `source/.snapshot-version`.

**Output files:**

- `source/policyDefinitions/*.json` — individual policy definitions
- `source/policySetDefinitions/*.json` — initiatives (policy sets)
- `source/.snapshot-version` — current snapshot tag or commit SHA

---

### generate_arm_from_source.py

**Purpose:** Generates individual ARM JSON deployment templates for policy definitions and initiatives
from the JSON files in `source/`. Run after `fetch-policies.sh` in the `rebuild-configuration` pipeline.

**Usage:**

```bash
python3 scripts/generate_arm_from_source.py [--source-dir SOURCE] [--bicep-dir BICEP]
```

| Argument | Default (from deployment-config.json) | Description |
| --- | --- | --- |
| `--source-dir` | `source/` | Directory containing the ALZ JSON snapshots |
| `--bicep-dir` | `bicep/` | Output directory for generated ARM JSON templates |

**Steps:**

1. Scans `source/policyDefinitions/*.json` → generates `bicep/policyDefinitions/<name>.json`
2. Scans `source/policySetDefinitions/*.json` → generates `bicep/policySetDefinitions/<name>.json`
3. Skips cloud-specific variants (`*.AzureChinaCloud.json`, `*.AzureUSGovernment.json`) for policy
   definitions to avoid duplicate resource names.
4. For **own** definitions only (`own/policyDefinitions/`, `own/policySetDefinitions/`):
   injects `properties.metadata.managedBy` with the value of `managementTag` from
   `deployment-config.json` (using `setdefault` — existing values are not overwritten).
   ALZ source definitions are not modified.

Generated files **must not be edited manually** — every script run overwrites them.

---

### generate_config_from_table.py

**Purpose:** Converts tabular data from TSV/CSV (Excel export) into JSON files used by assignment deployments.
Run locally or in the `update-assignments` pipeline.

**Usage:**

```bash
python3 scripts/generate_config_from_table.py [options]
```

| Argument | Default | Description |
| --- | --- | --- |
| `--input` | `configuration/policy-assignments.tsv` | Input TSV/CSV file with assignments |
| `--output-dir` | `generated/` | Output directory for generated JSON files |
| `--params-input` | `configuration/policy-parameters.tsv` | Input TSV/CSV file with parameters |
| `--suffix` | *(empty)* | Filename suffix for test runs (e.g. `test` → `assignments-test.json`) |
| `--limit` | *(none)* | Process only the first N rows after filtering |
| `--location` | from `deployment-config.json` | `location` value written to each assignment |
| `--all` | *(not set)* | Process all rows, including `Deploy=FALSE` |

**Examples:**

```bash
# Test preview — 3 rows, files with -test suffix
python3 scripts/generate_config_from_table.py --limit 3 --suffix test

# Generate production files
python3 scripts/generate_config_from_table.py

# Windows (PowerShell)
py .\scripts\generate_config_from_table.py --limit 3 --suffix test
```

**Delimiter detection:**

The script automatically detects the column separator:

- `.tsv` → `\t` (tab)
- `.csv` → `,` or `;` (Polish Excel locale — heuristic based on the first line)

**Input file resolution order** (when `--input` is not provided):

1. `sourceFiles.assignments` from `deployment-config.json`
2. `sourceFiles.assignmentsFallback` from `deployment-config.json`
3. Hardcoded: `configuration/policy-assignments.tsv`, `.csv`
4. Legacy fallback: `config/policy.tsv`

---

### validate-config.sh

**Purpose:** Validates the structure of `generated/*.json` files before deployment.

**Usage:**

```bash
scripts/validate-config.sh
```

Checks:
- valid JSON in `generated/initiatives.json`, `generated/assignments.json`, `generated/parameters.json`
- required fields in each object (e.g. `name`, `definitionFile` in initiatives; `name`, `scope` in assignments)
- referential integrity (every `parametersKey` in assignments exists in `parameters.json`)

---

### create-ado-pipelines.sh

**Purpose:** Creates all Azure DevOps pipeline definitions from YAML files in `pipelines/` using the Azure CLI (`az pipelines create`). Idempotent — skips pipelines that already exist.

**Requirements:**

- Azure CLI with the `azure-devops` extension (`az extension add --name azure-devops`)
- Active login: `az login` or service principal context
- `pipelines/sync-framework.yml` must exist in the ADO repo before this pipeline can be created (it is gitignored; copy from `sync-framework.example.yml` first)

**Usage:**

```bash
scripts/create-ado-pipelines.sh --org <org-url> --project <project> [options]
```

| Option | Default | Description |
| --- | --- | --- |
| `--org <url>` | *(required)* | Full ADO organization URL **including `https://`**, e.g. `https://dev.azure.com/MyOrg` |
| `--project <name>` | *(required)* | ADO project name |
| `--repo <name>` | same as `--project` | ADO repository name |
| `--branch <name>` | `main` | Default branch for all pipelines |
| `--folder <path>` | `\AzurePolicy` | ADO UI folder path |
| `--dry-run` | | Show what would be created without making changes |

> **Note:** `--org` requires a complete URL with the `https://` scheme, not just the organization name.
> The script validates this and exits with an error if only a bare name is provided.

**Pipelines created:**

| Name | YAML path |
| --- | --- |
| `fetch-policies` | `pipelines/fetch-policies.yml` |
| `rebuild-configuration` | `pipelines/rebuild-configuration.yml` |
| `update-definitions` | `pipelines/update-definitions.yml` |
| `update-assignments` | `pipelines/update-assignments.yml` |
| `cleanup` | `pipelines/cleanup.yml` |
| `sync-framework` | `pipelines/sync-framework.yml` |

**Example:**

```bash
# Preview what would be created
scripts/create-ado-pipelines.sh \
  --org https://dev.azure.com/MyOrg \
  --project AzurePolicy \
  --dry-run

# Create pipelines
scripts/create-ado-pipelines.sh \
  --org https://dev.azure.com/MyOrg \
  --project AzurePolicy
```

---

### cleanup.sh

**Purpose:** Lists or deletes Azure Policy assignments, UAMIs, and optionally policy definitions
and initiatives managed by this repository. Queries Azure directly — does not depend on local
`generated/*.json` files.

Default behaviour (no `--delete`): **list only** — no changes are made.

**Usage:**

```bash
scripts/cleanup.sh [--delete] [--with-definitions] [--assignment <name>]
```

| Flag | Description |
| --- | --- |
| *(no flags)* | List mode: show all managed resources found in Azure — no changes made |
| `--delete` | Delete the listed resources |
| `--with-definitions` | Also include custom policy definitions and initiatives |
| `--assignment <name>` | Scope to a single assignment (ARM resource name / InternalID) |

**How resources are discovered:**

| Resource | Discovery method |
| --- | --- |
| Policy assignments | `az graph query` on `PolicyResources` filtered by `properties.metadata.assignedBy` |
| UAMIs (selective) | Extracted from `identity.userAssignedIdentities` of the matched assignment |
| UAMIs (full) | `az identity list` filtered by tag `managedBy` in configured resource group |
| Policy definitions | `az policy definition list` filtered by `properties.metadata.managedBy` |
| Initiatives | `az policy set-definition list` filtered by `properties.metadata.managedBy` |

All values are compared against `managementTag` in `configuration/deployment-config.json`.

**Examples:**

```bash
# List all managed resources (no changes)
scripts/cleanup.sh

# List managed resources including definitions
scripts/cleanup.sh --with-definitions

# Delete all managed assignments + UAMIs
scripts/cleanup.sh --delete

# Delete a single assignment and its UAMI
scripts/cleanup.sh --assignment AP202604290022 --delete
```

---

## TSV file formats

Full column reference with examples: [docs/TSV-FORMAT.md](docs/TSV-FORMAT.md)

---

## JSON file formats (generated/)

Files generated by `generate_config_from_table.py` and consumed by Bicep at deployment time.

### initiatives.json

Array of objects; each initiative appears at most once (deduplicated by name).

```json
[
  {
    "name": "Enforce-ALZ-Decomm",
    "definitionFile": "source/policySetDefinitions/Enforce-ALZ-Decomm.json",
    "enabled": true
  }
]
```

| Field | Description |
| --- | --- |
| `name` | Initiative name — used as the key for assignment references |
| `definitionFile` | Repo-relative path to the ALZ snapshot JSON file |
| `enabled` | Always `true` for rows with `Deploy=TRUE` |

### assignments.json

Array of objects; one entry per `Deploy=TRUE` row in the TSV.

```json
[
  {
    "name": "AP202604280001",
    "displayName": "contoso-guardrails_avm-DINE",
    "scope": {
      "type": "managementGroup",
      "id": "mg-contoso-root"
    },
    "enforcementMode": "Default",
    "location": "germanywestcentral",
    "managed": "policy-by-code",
    "metadata": {
      "assignedBy": "policy-by-code"
    },
    "initiativeName": "Enforce-ALZ-Decomm",
    "parametersKey": "Enforce-ALZ-Decomm-Default"
  }
]
```

| Field | Description |
| --- | --- |
| `name` | Assignment ARM resource name — taken from `InternalID` in the TSV |
| `displayName` | Human-readable name shown in the portal |
| `scope` | Target scope: `managementGroup` or `subscription` |
| `enforcementMode` | `Default` or `DoNotEnforce` |
| `location` | Azure region for the assignment (required for DINE/Modify) |
| `managed` | Ownership marker — value from `managementTag` in `deployment-config.json`; used by scripts to identify managed assignments |
| `metadata.assignedBy` | Same value as `managed`; flows to Azure via Bicep and is displayed in the portal as **Assigned by** |
| `metadata.comment` | Optional — populated from the TSV description column when not empty |
| `initiativeName` / `policyName` | Reference to the initiative or policy being assigned |
| `parametersKey` | Key into `parameters.json`; omitted when no parameters are set |

**`managed` field:** Every generated assignment carries this field set to the value of `managementTag`
from `deployment-config.json`. Use it for lifecycle management via code:

```bash
# List all managed assignments (replace value with your managementTag)
jq '.[] | select(.managed=="policy-by-code") | .name' generated/assignments.json

# Remove managed assignments from the file
jq 'map(select(.managed != "policy-by-code"))' generated/assignments.json > generated/assignments-clean.json
```

### parameters.json

Dictionary object; keys are the `Parameter Set` values from the assignments table.

```json
{
  "Enforce-ALZ-Decomm-Default": {
    "allowedLocations": {
      "value": ["germanywestcentral", "northeurope"]
    },
    "effect": {
      "value": "Audit"
    }
  }
}
```

---

## Templates and Bicep structure

### bicep/policyDefinitions/ (AUTO-GENERATED)

- One ARM JSON deployment template per policy definition.
- Each file contains a single `Microsoft.Authorization/policyDefinitions@2023-04-01` resource.
- Deployed in a loop by `scripts/update-definitions.sh`.
- **Do not edit manually** — regenerated by `generate_arm_from_source.py` on every Pipeline B run.

### bicep/policySetDefinitions/ (AUTO-GENERATED)

- One ARM JSON deployment template per initiative (policy set).
- Each file contains a single `Microsoft.Authorization/policySetDefinitions@2023-04-01` resource.
- Deployed in a loop by `scripts/update-definitions.sh`.
- **Do not edit manually** — regenerated by `generate_arm_from_source.py` on every Pipeline B run.
- The ALZ placeholder `contoso` in `policyDefinitionId` references is replaced with the real
  Management Group ID from `deployment-config.json` during generation.

### bicep/assignments.bicep

Iterates over the `assignments` array and calls:
- `policyAssignmentManagementGroup.bicep` for `managementGroup` scope
- `policyAssignmentSubscription.bicep` for `subscription` scope

---

## Snapshot version tracking

`source/.snapshot-version` stores the tag or commit SHA used during the last
`fetch-policies.sh` run.

```bash
# Check the current version
cat source/.snapshot-version

# Compare with available tags on GitHub
# https://github.com/Azure/Enterprise-Scale/releases
```

The file is updated automatically by the script and should be committed to the repository.

---

## Extension — exemptions

To add support for Policy Exemptions:

1. Create `generated/exemptions.json` with an array of exemption objects (analogous to `assignments.json`).
2. Create `bicep/exemptions.bicep` with a loop over `Microsoft.Authorization/policyExemptions@2022-07-01-preview`.
3. Add an `exemptions` module to `bicep/assignments.bicep`.
4. Optionally extend `generate_config_from_table.py` to process an additional Excel worksheet.
