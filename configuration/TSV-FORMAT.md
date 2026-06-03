# TSV File Format Reference

The TSV format is the primary interface between your data source and the deployment scripts.
Any tool that produces a UTF-8 tab-separated file with the correct column headers will work —
Excel, Google Sheets, VS Code, a script, or a hand-edited text file.

**General rules:**

- Delimiter: tab (`\t`). CSV (`,` or `;`) is also accepted — the script auto-detects.
- Encoding: UTF-8 (with or without BOM).
- First row: column headers (order does not matter).
- Unknown columns are silently ignored — add as many helper columns as needed.
- Files are excluded from git (`.gitignore`) — they contain environment-specific data.

---

## policy-assignments.tsv

One row per policy assignment. Rows with `Deploy=FALSE` are skipped by default.

| Column | Required | Description |
| --- | --- | --- |
| `InternalID` | ✓ | Unique tracking identifier (e.g. `AP2026-04-28_0001`) — used as the ARM resource name and UAMI name suffix |
| `Deploy` | ✓ | `TRUE` / `FALSE` — rows with `FALSE` are skipped |
| `Assignment Scope` | ✓ | Management Group name or subscription UUID |
| `Assignment Name` | ✓ | Human-readable display name for the assignment |
| `DefinitionType` or `Type` | ✓ | `Initiative` or `Policy` |
| `Definition Name` | ✓ | Initiative or policy display name |
| `ID` | ✓ | Definition file stem (without `.json`), built-in policy GUID, or full ARM path |
| `Parameter Set` | — | Key into `policy-parameters.tsv` (must match exactly) |
| `Enforcement Mode` | — | `Default` or `DoNotEnforce` (default: `Default`) |
| `DeployIfNotExists` | — | `DeployIfNotExists` or `Modify` — triggers UAMI creation for the assignment |
| `Identity RBAC Roles` | — | Comma-separated role names or IDs to assign to the UAMI |
| `Identity RBAC Scope` | — | Comma-separated ARM scopes for the role assignments (default: assignment scope) |

Any other columns (e.g. `AzAdvertizer Link`, `Version`, `Comment`) are treated as helper columns and ignored.

### Minimal example

```tsv
InternalID	Deploy	Assignment Scope	Assignment Name	DefinitionType	Definition Name	ID
AP2026-01-01_0001	TRUE	mg-contoso-root	contoso-deny-public-paas	Initiative	Deny Public PaaS Endpoints	Deny-PublicPaaSEndpoints
AP2026-01-01_0002	TRUE	mg-contoso-root	contoso-allowed-locations	Policy	Allowed locations	e56962a6-4747-49cd-b67b-bf8b01975c4c
AP2026-01-01_0003	FALSE	mg-contoso-root	contoso-not-deployed-yet	Initiative	Enforce ALZ Decomm	Enforce-ALZ-Decomm
```

---

## policy-parameters.tsv

One row per parameter key within a parameter set. Multiple sets can coexist in the same file.

| Column | Required | Description |
| --- | --- | --- |
| `Parameter Set` | ✓ | Set key — must match the `Parameter Set` value in `policy-assignments.tsv` |
| `Key` | ✓ | Parameter name as defined in the initiative or policy |
| `Value` | ✓ | Value — plain string, boolean string, or array (see below) |
| `Type` | — | `array` to force list parsing; omit for strings |
| `Applies To` | — | `initiative`, `policy`, or `both` (default: `both`) — splits the set when mixed assignment types share the same key name |

Any other columns (e.g. `Default Value`, `Allowed Values`, `Description`) are ignored.

### Array values

Three accepted formats:

```
# 1. JSON array in a single cell
["germanywestcentral","northeurope"]

# 2. Comma-separated values across multiple lines (common in spreadsheet exports)
germanywestcentral,
northeurope

# 3. Single-column list (one value per row, same Parameter Set + Key)
germanywestcentral
northeurope
```

### Minimal example

```tsv
Parameter Set	Key	Value	Type
param-allowed-locations	allowedLocations	["germanywestcentral","northeurope"]	array
param-allowed-locations	effect	Audit
param-diagnostics	effect	DeployIfNotExists
param-diagnostics	logAnalytics	/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-logs/providers/Microsoft.OperationalInsights/workspaces/law-contoso
```
