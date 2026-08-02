# bicep/

Bicep modules and auto-generated ARM JSON deployment templates.

| Path | Description |
| --- | --- |
| `assignments.bicep` | Iterates over `generated/assignments.json` and calls MG or subscription assignment modules |
| `policyAssignmentManagementGroup.bicep` | Module: creates a policy assignment at Management Group scope |
| `policyAssignmentSubscription.bicep` | Module: creates a policy assignment at Subscription scope |
| `policyDefinitions/` | **Auto-generated** ARM JSON — one template per policy definition (Pipeline B) |
| `policySetDefinitions/` | **Auto-generated** ARM JSON — one template per initiative/policy set (Pipeline B) |

The `policyDefinitions/` and `policySetDefinitions/` subdirectories are excluded from git (`.gitignore`)
and passed between pipelines as the `policy-generated` artifact.
