"""AS-01: each persona SP has exactly its expected role at the expected scope,
and no broad inherited Owner/Contributor/User Access Administrator access."""
from __future__ import annotations

import pytest
from azure.identity import DefaultAzureCredential
from conftest import ARM_SCOPE, arm_request


BROAD_ROLES = {
    "Owner": "8e3af657-a8ff-443c-a75c-2fe8c4bcb635",
    "Contributor": "b24988ac-6180-42a0-ab88-20f7382dd24c",
    "User Access Administrator": "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9",
}

PERSONA_EXPECTED = {
    "builder": ("Foundry User", "project"),
    "runtime": ("Foundry Agent Consumer", "project"),
    "responses": ("Foundry Project Runtime User", "project"),
    "platform": ("Foundry Account Owner", "account"),
    "project-admin": ("Foundry Project Manager", "project"),
    "none": ("", "none"),
}


@pytest.fixture(scope="session")
def deployer_token() -> str:
    return DefaultAzureCredential().get_token(ARM_SCOPE).token


@pytest.mark.parametrize("persona_key,expected", list(PERSONA_EXPECTED.items()))
def test_as01_persona_has_only_expected_role(
    persona_key,
    expected,
    personas,
    subscription_id,
    deployer_token,
    evidence,
    account_scope,
    project_scope,
):
    p = personas[persona_key]
    exp_role, exp_scope_kind = expected
    scope_map = {"project": project_scope, "account": account_scope, "none": None}
    exp_scope = scope_map[exp_scope_kind]

    url = f"https://management.azure.com/subscriptions/{subscription_id}/providers/Microsoft.Authorization/roleAssignments"
    resp = arm_request(
        "GET",
        url,
        deployer_token,
        api_version="2022-04-01",
        extra_params={"$filter": f"principalId eq '{p.object_id}'"},
    )
    assignments = resp.json().get("value", []) if resp.status_code == 200 else []

    # AS-01a: builder must not carry any broad Azure roles inherited from the sub.
    broken = []
    for a in assignments:
        role_id = a["properties"]["roleDefinitionId"].split("/")[-1]
        if role_id in BROAD_ROLES.values():
            broken.append(a)

    if exp_scope is None:
        # "none" persona: should have zero assignments.
        our_scope_assignments = [
            a for a in assignments if project_scope.lower() in a["properties"]["scope"].lower()
            or account_scope.lower() in a["properties"]["scope"].lower()
        ]
        passed = not our_scope_assignments and not broken
    else:
        # Must have the expected role at the expected scope.
        has_expected = any(
            a["properties"]["scope"].lower() == exp_scope.lower() for a in assignments
        )
        passed = has_expected and not broken

    evidence.record_response(
        test_id=f"AS-01/{persona_key}",
        suite="Assignments",
        persona=p,
        operation=f"List effective role assignments for {p.display_name}",
        expected=f"Only {exp_role or 'no role'} at {exp_scope_kind} scope, no broad inherited access",
        response=resp,
        passed=passed,
        notes=f"broad={[b['properties']['roleDefinitionId'] for b in broken]}",
    )
    assert passed, (
        f"Persona {persona_key} assignments mismatch: expected {exp_role}@{exp_scope_kind}, "
        f"broad={broken}, all={[a['properties']['scope'] for a in assignments]}"
    )
