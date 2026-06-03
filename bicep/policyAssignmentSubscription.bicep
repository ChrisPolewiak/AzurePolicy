targetScope = 'subscription'

param assignment object
param parameterSet object
param definitionManagementGroupId string

var targetsPolicyDefinition = contains(assignment, 'policyDefinitionName')
var policyDefinitionId = contains(assignment, 'policyDefinitionId')
  ? string(assignment.policyDefinitionId)
  : (targetsPolicyDefinition
    ? '/providers/Microsoft.Management/managementGroups/${definitionManagementGroupId}/providers/Microsoft.Authorization/policyDefinitions/${assignment.policyDefinitionName}'
    : '/providers/Microsoft.Management/managementGroups/${definitionManagementGroupId}/providers/Microsoft.Authorization/policySetDefinitions/${assignment.initiativeName}')

resource policyAssignmentWithIdentity 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (contains(assignment, 'identity')) {
  name: string(assignment.name)
  location: string(assignment.?location ?? 'germanywestcentral')
  identity: {
    type: assignment.?identity.?type ?? 'UserAssigned'
    userAssignedIdentities: assignment.?identity.?userAssignedIdentities ?? {}
  }
  properties: {
    displayName: string(assignment.?displayName ?? assignment.name)
    description: string(assignment.?description ?? '')
    metadata: assignment.?metadata ?? {}
    policyDefinitionId: policyDefinitionId
    enforcementMode: string(assignment.?enforcementMode ?? 'Default')
    parameters: parameterSet
  }
}

resource policyAssignmentWithoutIdentity 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (!contains(assignment, 'identity')) {
  name: string(assignment.name)
  properties: {
    displayName: string(assignment.?displayName ?? assignment.name)
    description: string(assignment.?description ?? '')
    metadata: assignment.?metadata ?? {}
    policyDefinitionId: policyDefinitionId
    enforcementMode: string(assignment.?enforcementMode ?? 'Default')
    parameters: parameterSet
  }
}
