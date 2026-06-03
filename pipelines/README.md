# pipelines/

Azure DevOps pipeline definitions. All pipelines are triggered manually (`trigger: none`).

| File | Stage | Consumes | Produces |
| --- | --- | --- | --- |
| `fetch-policies.yml` | A | GitHub Azure/Enterprise-Scale | artifact: `policy-source` |
| `rebuild-configuration.yml` | B | artifact: `policy-source` | artifact: `policy-generated` |
| `update-definitions.yml` | C | artifact: `policy-generated` | deploys policy definitions + initiatives to MG |
| `update-assignments.yml` | D | artifact: `policy-generated` | what-if or deploys policy assignments to tenant |
| `cleanup.yml` | E | (none) | lists or deletes managed policy resources in Azure |

Pipelines C and D are independent — both consume `policy-generated` from Pipeline B
and can be run separately without re-running each other.

Artifact flow (key behavior):

- Stage A (`fetch-policies.yml`) publishes artifact `policy-source` (snapshot from `source/`).
- Stage B (`rebuild-configuration.yml`) downloads `policy-source`, generates files, and publishes artifact `policy-generated` (selected files from `bicep/` and `generated/`).
- Stage C (`update-definitions.yml`) downloads `policy-generated` and deploys; it does not publish a new artifact.
- Stage D (`update-assignments.yml`) downloads `policy-generated` and deploys/what-if; it does not publish a new artifact.

Each pipeline includes a final cleanup step (`condition: always()`) that removes restored/generated temporary files from the job workspace after execution.

Required Azure DevOps Library values (Variable Group):

- `serviceConnectionName` - service connection used by AzureCLI tasks (pipelines C and D).
- `devopsManagedPool` - managed agent pool name used by all pipelines.

In each pipeline YAML, replace `REPLACE_WITH_LIBRARY_VARIABLE_GROUP` with your Variable Group name.

Key manual-run parameters:

- `update-definitions.yml`: `targetInitiative` (default `*`), `targetDefinition` (default `*`), `deployPolicyDefinitions`, `deployInitiatives`
- `update-assignments.yml`: `deployPolicies`, `targetAssignment` (default `*`)
- `cleanup.yml`: `targetAssignment` (default `*`), `withDefinitions`, `delete` (default `false` = dry-run)
