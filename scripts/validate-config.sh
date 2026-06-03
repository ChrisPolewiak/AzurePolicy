#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR

python3 - <<'PY'
import json
import os
import sys

root = os.environ.get('ROOT_DIR')

if not root:
    print('ROOT_DIR environment variable is not set.')
    sys.exit(1)

initiatives_path = os.path.join(root, 'generated', 'initiatives.json')
assignments_path = os.path.join(root, 'generated', 'assignments.json')
parameters_path = os.path.join(root, 'generated', 'parameters.json')
assignment_identities_path = os.path.join(root, 'generated', 'assignment-identities.json')

errors = []

def load_json(path):
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as ex:
        errors.append(f'Invalid JSON in {path}: {ex}')
        return None

initiatives = load_json(initiatives_path)
assignments = load_json(assignments_path)
parameters = load_json(parameters_path)

filter_assignment = os.environ.get('FILTER_ASSIGNMENT', '').strip()
if filter_assignment and assignments is not None and isinstance(assignments, list):
    assignments = [x for x in assignments if x.get('name') == filter_assignment]
    if not assignments:
        errors.append(f'Assignment not found in generated/assignments.json: {filter_assignment}')

filter_initiative = os.environ.get('FILTER_INITIATIVE', '').strip()
if filter_initiative and initiatives is not None and isinstance(initiatives, list):
    initiatives = [x for x in initiatives if x.get('name') == filter_initiative]
    if not initiatives:
        errors.append(f'Initiative not found in generated/initiatives.json: {filter_initiative}')

filter_definition = os.environ.get('FILTER_DEFINITION', '').strip()

# When targeting a single definition, skip assignment/initiative validation entirely
if filter_definition:
    assignments = []
    initiatives = []
assignment_identities = load_json(assignment_identities_path) if os.path.exists(assignment_identities_path) else []

if initiatives is not None:
    if not isinstance(initiatives, list):
        errors.append('generated/initiatives.json must be an array.')
    else:
        for i, item in enumerate(initiatives):
            if not isinstance(item, dict):
                errors.append(f'initiatives[{i}] must be an object.')
                continue
            for key in ['name', 'definitionFile']:
                if key not in item:
                    errors.append(f'initiatives[{i}] missing required field: {key}')

if assignments is not None:
    if not isinstance(assignments, list):
        errors.append('generated/assignments.json must be an array.')
    else:
        for i, item in enumerate(assignments):
            if not isinstance(item, dict):
                errors.append(f'assignments[{i}] must be an object.')
                continue
            for key in ['name', 'scope']:
                if key not in item:
                    errors.append(f'assignments[{i}] missing required field: {key}')

            has_initiative = bool(item.get('initiativeName'))
            has_policy_definition = bool(item.get('policyDefinitionName'))
            has_policy_definition_id = bool(item.get('policyDefinitionId'))

            targets = sum([has_initiative, has_policy_definition, has_policy_definition_id])
            if targets == 0:
                errors.append(f'assignments[{i}] must define one of: initiativeName, policyDefinitionName, policyDefinitionId.')
            if targets > 1:
                errors.append(f'assignments[{i}] must define only one of: initiativeName, policyDefinitionName, policyDefinitionId.')

            scope = item.get('scope', {})
            if not isinstance(scope, dict):
                errors.append(f'assignments[{i}].scope must be an object.')
            else:
                if scope.get('type') not in ['managementGroup', 'subscription']:
                    errors.append(f'assignments[{i}].scope.type must be managementGroup or subscription.')
                if not scope.get('id'):
                    errors.append(f'assignments[{i}].scope.id is required.')

if parameters is not None and not isinstance(parameters, dict):
    errors.append('generated/parameters.json must be an object.')

if assignment_identities is not None:
    if not isinstance(assignment_identities, list):
        errors.append('generated/assignment-identities.json must be an array when present.')
    else:
        seen_assignment_names = set()
        for i, item in enumerate(assignment_identities):
            if not isinstance(item, dict):
                errors.append(f'assignment-identities[{i}] must be an object.')
                continue
            assignment_name = item.get('assignmentName')
            if not assignment_name:
                errors.append(f'assignment-identities[{i}] missing required field: assignmentName')
            elif assignment_name in seen_assignment_names:
                errors.append(f'assignment-identities[{i}] duplicate assignmentName: {assignment_name}')
            else:
                seen_assignment_names.add(assignment_name)

            identity = item.get('identity')
            if identity is not None:
                if not isinstance(identity, dict):
                    errors.append(f'assignment-identities[{i}].identity must be an object when provided.')
                else:
                    identity_type = identity.get('type')
                    if identity_type and identity_type not in ['SystemAssigned', 'UserAssigned', 'SystemAssigned,UserAssigned']:
                        errors.append(f'assignment-identities[{i}].identity.type must be SystemAssigned, UserAssigned, or SystemAssigned,UserAssigned.')
                    user_ids = identity.get('userAssignedIdentityResourceIds')
                    if user_ids is not None and not isinstance(user_ids, list):
                        errors.append(f'assignment-identities[{i}].identity.userAssignedIdentityResourceIds must be an array when provided.')

            role_assignments = item.get('roleAssignments')
            if role_assignments is not None:
                if not isinstance(role_assignments, list):
                    errors.append(f'assignment-identities[{i}].roleAssignments must be an array when provided.')
                else:
                    for j, role_assignment in enumerate(role_assignments):
                        if not isinstance(role_assignment, dict):
                            errors.append(f'assignment-identities[{i}].roleAssignments[{j}] must be an object.')
                            continue
                        has_role_key = any(role_assignment.get(k) for k in ['roleDefinitionIdOrName', 'roleDefinitionId', 'roleName'])
                        if not has_role_key:
                            errors.append(f'assignment-identities[{i}].roleAssignments[{j}] must define one of: roleDefinitionIdOrName, roleDefinitionId, roleName.')

initiative_names = set()
if initiatives is not None and isinstance(initiatives, list):
    for item in initiatives:
        if isinstance(item, dict) and 'name' in item:
            initiative_names.add(item['name'])

if assignments is not None and isinstance(assignments, list) and parameters is not None and isinstance(parameters, dict):
    for i, assignment in enumerate(assignments):
        key = assignment.get('parametersKey')
        if key and key not in parameters:
            errors.append(f'assignments[{i}] references missing parametersKey: {key}')
        # Cross-reference check only makes sense when full initiatives list is available
        if not filter_initiative:
            initiative_name = assignment.get('initiativeName')
            if initiative_name and initiative_name not in initiative_names:
                errors.append(f'assignments[{i}] references missing initiativeName: {initiative_name}')

if errors:
    print('Configuration validation failed:')
    for err in errors:
        print(f'- {err}')
    sys.exit(1)

print('Configuration validation passed.')
PY
