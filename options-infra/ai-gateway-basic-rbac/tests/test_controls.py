"""Platform / project-admin control tests.

These are CONTROL tests: they prove elevated personas *can* do the things
builders can't, confirming that RBAC — not policy — is what stops builders.
Anything they create must be self-cleaned in the same test.
"""
from __future__ import annotations

import os
import time
import uuid

import pytest
from conftest import arm_request, get_arm_token


@pytest.fixture(scope="session")
def platform_arm_token(cred_platform) -> str:
    return get_arm_token(cred_platform)


@pytest.fixture(scope="session")
def project_admin_arm_token(cred_project_admin) -> str:
    return get_arm_token(cred_project_admin)


def test_platform_can_manage_existing_foundry_account(
    personas, subscription_id, resource_group, foundry_name, platform_arm_token, evidence
):
    """Platform SP (Foundry Account Owner scoped to the deployed account) must
    be able to READ + PATCH the existing Foundry account (proves account-scope
    admin power) — but must NOT be able to CREATE a new account at RG scope
    (proves the role is not effectively subscription-Contributor)."""
    # 1. GET the existing account — should succeed with account-scope role.
    account_url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.CognitiveServices/accounts/{foundry_name}"
    )
    read_resp = arm_request("GET", account_url, platform_arm_token, api_version="2025-07-01-preview")
    read_ok = read_resp.status_code == 200
    evidence.record_response(
        test_id="CTRL-PLAT-01a",
        suite="PlatformControl",
        persona=personas["platform"],
        operation=f"GET existing Foundry account {foundry_name}",
        expected="200 (account-scope read allowed)",
        response=read_resp,
        passed=read_ok,
    )
    assert read_ok, f"Platform SP should GET the existing account; got {read_resp.status_code}: {read_resp.text[:400]}"

    # 2. PATCH a tag on the existing account — should succeed.
    patch_body = {"tags": {"rbac-control-test": f"ctrl-{uuid.uuid4().hex[:6]}"}}
    patch_resp = arm_request(
        "PATCH", account_url, platform_arm_token,
        api_version="2025-07-01-preview", json_body=patch_body,
    )
    patch_ok = patch_resp.status_code in (200, 202)
    evidence.record_response(
        test_id="CTRL-PLAT-01b",
        suite="PlatformControl",
        persona=personas["platform"],
        operation=f"PATCH tag on existing Foundry account {foundry_name}",
        expected="2xx (account-scope write allowed)",
        response=patch_resp,
        passed=patch_ok,
    )
    assert patch_ok, f"Platform SP should PATCH the existing account; got {patch_resp.status_code}: {patch_resp.text[:400]}"

    # 3. Try to CREATE a new Foundry account at RG scope — MUST be denied.
    #    Foundry Account Owner is scoped to a specific account, so RG-scope
    #    PUT should return 403 AuthorizationFailed. Anything 2xx would mean the
    #    persona has too much power and violates the customer requirement
    #    "we don't want users to create new foundry instances".
    new_name = f"rbac-plat-{uuid.uuid4().hex[:8]}"
    new_url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.CognitiveServices/accounts/{new_name}"
    )
    body = {
        "location": os.environ["AZURE_LOCATION"],
        "kind": "AIServices",
        "sku": {"name": "S0"},
        "identity": {"type": "SystemAssigned"},
        "properties": {"customSubDomainName": new_name},
    }
    create_resp = arm_request(
        "PUT", new_url, platform_arm_token,
        api_version="2025-07-01-preview", json_body=body,
    )
    denied = create_resp.status_code in (401, 403)
    evidence.record_response(
        test_id="CTRL-PLAT-01c",
        suite="PlatformControl",
        persona=personas["platform"],
        operation=f"PUT NEW Foundry account {new_name} (should be denied)",
        expected="401/403 (account-scope role cannot create new accounts at RG scope)",
        response=create_resp,
        passed=denied,
    )
    # Best-effort cleanup in case the PUT unexpectedly succeeded.
    if not denied:
        time.sleep(2)
        arm_request("DELETE", new_url, platform_arm_token, api_version="2025-07-01-preview")
    assert denied, (
        "SECURITY: Foundry Account Owner scoped to one account should NOT "
        f"create new accounts at RG scope; got {create_resp.status_code}: {create_resp.text[:400]}"
    )


def test_project_admin_can_assign_foundry_user(
    personas, project_scope, project_admin_arm_token, subscription_id, evidence
):
    """Project admin (Foundry Project Manager) can assign Foundry User to a
    principal — proves the role's conditional roleAssignments/write works."""
    target_object_id = personas["none"].object_id
    ra_name = str(uuid.uuid4())
    role_id = f"/subscriptions/{subscription_id}/providers/Microsoft.Authorization/roleDefinitions/53ca6127-db72-4b80-b1b0-d745d6d5456d"
    url = f"https://management.azure.com{project_scope}/providers/Microsoft.Authorization/roleAssignments/{ra_name}"
    body = {"properties": {"roleDefinitionId": role_id, "principalId": target_object_id, "principalType": "ServicePrincipal"}}
    resp = arm_request("PUT", url, project_admin_arm_token, api_version="2022-04-01", json_body=body)
    ok = resp.status_code in (200, 201)
    evidence.record_response(
        test_id="CTRL-ADMIN-01",
        suite="ProjectAdminControl",
        persona=personas["project-admin"],
        operation=f"PUT roleAssignment (Foundry User → {target_object_id}) on {project_scope}",
        expected="2xx (conditional roleAssignments write allowed for Foundry User)",
        response=resp,
        passed=ok,
    )
    # Cleanup.
    if ok:
        arm_request("DELETE", url, project_admin_arm_token, api_version="2022-04-01")
    assert ok, f"Project admin should assign Foundry User; got {resp.status_code}: {resp.text[:400]}"
