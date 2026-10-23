# Operator guide

[Polski](README.pl.md) | [Technical reference](REFERENCE.md) | [TSV format](../configuration/TSV-FORMAT.md)

## What do I run?

| I want to... | Run |
| --- | --- |
| Deploy for the first time | Complete setup below, then **A → B → C → D** |
| Change assignment scopes, parameters or enabled rows | Edit Excel, export TSV, then **B → D** |
| Change a custom policy or initiative | Edit `source/own/`, then **B → C → D** |
| Update Microsoft ALZ definitions | **A → B → C → D** |
| Preview assignment changes | **D** with `deployMode=whatif` |
| Remove managed policy resources | **E**, list-only first |
| Update scripts, modules and pipeline templates from GitHub | **F**, preview first |

**B builds; C and D deploy.** Editing Excel alone changes nothing in Azure.
If new definitions are needed, deploy them with C before running D.
Removing a TSV row is not a deletion request; review stale Azure assignments separately.

## One-time setup

Work in the **Azure DevOps deployment repository**. GitHub holds the shared framework;
your environment configuration, workbook and custom definitions belong in the deployment repo.

1. Copy [deployment-config.example.json](../configuration/deployment-config.example.json) to
   `configuration/deployment-config.json`. Set the main MG, locations, ownership marker
   (`managementTag`) and the subscription/RG for policy UAMIs.
2. Create that identity RG in advance.
3. Copy [ado-env.example.yml](../configuration/ado-env.example.yml) to `configuration/ado-env.yml`.
   Set `devopsManagedPool` and `serviceConnectionName`.
4. Configure an Azure Resource Manager service connection using the pipeline UAMI and
   workload identity federation. Authorize it for the pipelines and grant the roles below.
5. Copy the six [pipeline examples](../.pipelines/) from `*.example.yml` to `*.yml`
   and register pipelines A–F in ADO. See the [pipeline setup guide](../.pipelines/README.md).
   Upstream `source:` names must match the registered names exactly:
   `A-fetch-policies` and `B-rebuild-configuration` by default.
   If you add an environment suffix, use it consistently.
6. Keep environment-specific values out of public GitHub. Check what is tracked before pushing:
   `.gitignore` does not untrack existing files.

Agents need the tools used by the scripts, including Bash, Azure CLI, Python 3 and jq.

### Pipeline UAMI permissions

Grant roles to its **principal/object ID**, not client ID.
This identity runs the pipeline; **policy UAMIs** are separate identities used for remediation.

| Scope | Role | Why |
| --- | --- | --- |
| **Root MG** (recommended), or the main MG covering all managed scopes | **Resource Policy Contributor** | Manage policies, initiatives, assignments, remediation and policy deployments |
| **Exactly the same MG scope** | **Role Based Access Control Administrator**, with a delegation condition | Create/delete policy UAMI role assignments; exclude **Owner**, **Role Based Access Control Administrator** and **User Access Administrator** for both operations |
| **Policy UAMI RG** | **Managed Identity Contributor** | Create, update and delete UAMIs |
| **The same UAMI RG** | **Managed Identity Operator** | Attach UAMIs to policy assignments |

Do not grant the pipeline Owner or User Access Administrator. MG permissions are inherited;
separate grants on every child MG/subscription are unnecessary. A main MG does not cover
resources outside its hierarchy. Root MG scope is not tenant scope `/`.
Creating the identity RG needs separate permissions; an administrator should create it first.
Policy UAMIs receive the roles needed by their policies, not the pipeline's RBAC admin role.

**Only for Virtual Network Manager `addToNetworkGroup` policies:** the deploying UAMI also
needs **Network Contributor** on each referenced network group, or a custom role containing
`Microsoft.Network/networkManagers/networkGroups/join/action`.
A `LinkedAuthorizationFailed` mentioning this action refers to that linked group or an
invalid group ID. Verify the ID/access and retry after propagation; changing remediation
`roleDefinitionIds` will not fix deployment authorization.
See [Microsoft's required permissions](https://learn.microsoft.com/en-us/azure/virtual-network-manager/concept-azure-policy-integration#required-permissions).

## Everyday workflow

1. Edit your workbook in [configuration/](../configuration/) (for example `ALZPolicyAssignments.xlsx`).
2. Copy each changed table **including headers** into `configuration/policy-assignments.tsv`
   or `configuration/policy-parameters.tsv` in the deployment repo.
   Save, commit and push the workbook/exports according to your repository practice.
3. Run **B — rebuild-configuration**. It builds deployment files and validates configuration.
   Review the summary in the pipeline results: it identifies the TSV line, definition and issue.
   **A failed rebuild publishes no new `policy-generated` artifact.**
4. If definitions changed, run **C — update-definitions**.
5. Run **D — update-assignments** with `deployMode=whatif`. Review the what-if output,
   then rerun with `deployMode=deploy` when ready.
   By default, deploy repeats the preview and deploys only after it succeeds.
   `skipValidation=true` skips that preview only in `deploy` mode;
   configuration validation remains enabled. There is no manual pause between preview and deployment.

   D ends with an assignment error table (scope, stage and message), also uploaded
   to the ADO summary. Deployment, what-if, UAMI or RBAC errors fail the run;
   earlier changes are not rolled back.

   `TIME` lines measure UAMI preparation, deployment/what-if, principalId lookup,
   individual RBAC grants and total assignment processing. UAMI principal IDs are read
   directly from the identity without polling the assignment's principalId field.

**Choose the results from the right pipeline run.** A publishes `policy-source`; B consumes it and publishes
`policy-generated`; C and D consume B's artifact. D uses generated configuration, not your
newly edited TSV directly. C also reads TSV from its checkout, so use the same source revision
as B. Do not accidentally deploy an older successful B artifact after a failed rebuild.
The selected A artifact determines the snapshot; setting B's `policyVersion` alone does not replace it.

### When validation reports an issue

| Issue | How to fix it |
| --- | --- |
| Invalid definition name/ID or type | Correct the Excel row; check whether the definition is a policy (`Policy`) or initiative (`Initiative`) |
| Missing source or generated template | Check the definition name, custom sources and selected A snapshot; fix the source rather than manually creating an output file |
| Missing parameter set, required parameter or table header | Complete the parameter table and match the `Parameter Set` name; include headers in the export |
| AzAdvertizer HTTP 404/410 | The URL is generated from type and ID; check these fields and `Type2` (`Own` for your own definitions). TSV links are ignored |
| Timeout, HTTP 429 or 5xx warning | The service may be temporarily unavailable; check the link and retry later. A warning alone does not block publication |

After correcting data, export TSV again, save the changes in the repository and rerun B.
Errors block the new artifact; do not bypass them by deploying an older one.

### Useful Run pipeline settings

| Pipeline | Settings |
| --- | --- |
| **A — fetch-policies** | `policyVersion`: ALZ tag/commit; default `main` |
| **C — update-definitions** | `deployPolicyDefinitions=true`, `targetDefinition=*`, `deployInitiatives=true`, `targetInitiative=*`; `location` is for deployment metadata |
| **D — update-assignments** | `deployMode=whatif` (default) or `deploy`; `skipValidation=false`; `targetAssignment=*` for all, or one exact name |
| **E — cleanup** | `targetAssignment=*`, `withDefinitions=false`, `delete=false` by default |
| **F — sync-framework** | `frameworkVersion=main`, `dryRun=true` previews; `false` commits and pushes to ADO |

For one definition, also turn off the unrelated phase in C; the two selectors are independent.
The D parameter `deployPolicies` is replaced by `deployMode` and `skipValidation`.
Update saved pipeline invocations and environment YAMLs together with the new
`.pipelines/.templates/update-assignments-step.yml` template.
Assignment scopes come from TSV; `MG` + `ROOT` resolves to `deployment.definitionManagementGroupId`.
UAMI role scopes come from generated `roleAssignments[].scope`, not one global MG setting.

## Cleanup: preview, review, delete

For a complete cleanup, run E with `targetAssignment=*`, `withDefinitions=true`, **`delete=false`**.
Review the list, then rerun with **`delete=true`**. Inventory is recalculated on each run.

- Ownership comes from `managementTag`: assignments use `metadata.assignedBy`,
  definitions/initiatives use `metadata.managedBy`, UAMIs use `tags.managedBy`.
  Cleanup selects only resources with the configured ownership marker.
  Use a unique `managementTag` to avoid selecting resources managed by another deployment.
- Order: **assignments → identity RBAC → UAMIs → initiatives → definitions**.
  RBAC is found by identity `principalId`, not by a tag.
- Marked orphan UAMIs in the configured RG are included. Marked UAMIs referenced by
  selected assignments can also be outside that RG.
- UAMIs used by remaining visible assignments/resources and their RBAC are retained.
  Check cross-hierarchy sharing separately: inventory sees only the configured MG and current account's access.
- One assignment can be selected, but not together with `withDefinitions=true`.
- Query/delete errors fail the run. Earlier deletions are not rolled back.
- Unmarked resources, remediation-created workload resources, RGs and deployment history remain.
  Older unmarked ALZ definitions need rebuild + C redeployment to receive the marker before cleanup.

Resource Graph can lag. Repeat list-only after propagation to check what remains.
Cleanup RBAC deletions are also subject to the pipeline's delegation condition.

## Updating the framework

Run F with `dryRun=true` and inspect the diff before allowing commit/push.
It preserves `source/own/` and environment-specific pipeline YAMLs.
**Do not assume all of `configuration/` is excluded:** the current exclusion is the legacy
`configurations/` path. Inspect configuration/example changes and keep a clean, backed-up
deployment repo before applying. F does not update existing environment-specific YAMLs;
compare those with updated examples manually.

For file schemas, CLI options and modules, use the [technical reference](REFERENCE.md).
