targetScope = 'tenant'

@description('Array from config/assignments.json')
param assignments array

@description('Object from config/parameters.json')
param parameterSets object

@description('Management Group ID where initiatives are published')
param definitionManagementGroupId string

module managementGroupAssignments './policyAssignmentManagementGroup.bicep' = [
  for assignment in assignments: if (toLower(string(assignment.scope.type)) == 'managementgroup') {
    name: 'mg-${uniqueString(string(assignment.name), string(assignment.scope.id))}'
    scope: managementGroup(string(assignment.scope.id))
    params: {
      assignment: assignment
      parameterSet: contains(assignment, 'parametersKey') ? parameterSets[string(assignment.parametersKey)] : {}
      definitionManagementGroupId: definitionManagementGroupId
    }
  }
]

module subscriptionAssignments './policyAssignmentSubscription.bicep' = [
  for assignment in assignments: if (toLower(string(assignment.scope.type)) == 'subscription') {
    name: 'sub-${uniqueString(string(assignment.name), string(assignment.scope.id))}'
    scope: subscription(string(assignment.scope.id))
    params: {
      assignment: assignment
      parameterSet: contains(assignment, 'parametersKey') ? parameterSets[string(assignment.parametersKey)] : {}
      definitionManagementGroupId: definitionManagementGroupId
    }
  }
]

// Optional AVM alternatives for assignment layer:
// - br/public:avm/ptn/authorization/policy-assignment:<version>
// - br/public:avm/res/authorization/policy-assignment/mg-scope:<version>
