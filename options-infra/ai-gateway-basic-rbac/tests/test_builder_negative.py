"""N-01..N-08: Builder negative tests. All must return 403 / AuthorizationFailed.

A negative test PASSES when authorization denies the operation before any
resource is created. A 400/BadRequest that never reaches authorization is
classified as Investigate (assertion still fails).
"""
from __future__ import annotations

import uuid

import pytest
from conftest import arm_request, foundry_request, get_arm_token, get_foundry_token, skip_manual_required


AUTH_FAIL_CODES = {"AuthorizationFailed", "InsufficientPermissions", "Forbidden"}


def _is_denied(resp):
    if resp.status_code in (401, 403):
        return True
    if resp.status_code == 409:
        # Some ARM paths return 409 for policy denials — check the body.
        try:
            body = resp.json()
            code = (body.get("error") or {}).get("code", "")
            return code in AUTH_FAIL_CODES
        except Exception:
            return False
    return False


@pytest.fixture(scope="session")
def builder_arm_token(cred_builder) -> str:
    return get_arm_token(cred_builder)


@pytest.fixture(scope="session")
def builder_foundry_token(cred_builder) -> str:
    return get_foundry_token(cred_builder)


def test_n01_create_new_foundry_account(
    personas, subscription_id, resource_group, location, builder_arm_token, evidence
):
    """N-01: builder attempts to create a new Foundry / AI Services account."""
    name = f"rbac-deny-{uuid.uuid4().hex[:8]}"
    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.CognitiveServices/accounts/{name}"
    )
    body = {
        "location": location,
        "kind": "AIServices",
        "sku": {"name": "S0"},
        "identity": {"type": "SystemAssigned"},
        "properties": {"customSubDomainName": name},
    }
    resp = arm_request("PUT", url, builder_arm_token, api_version="2025-07-01-preview", json_body=body)
    passed = _is_denied(resp)
    evidence.record_response(
        test_id="N-01",
        suite="BuilderNegative",
        persona=personas["builder"],
        operation=f"PUT Foundry account {name}",
        expected="403 AuthorizationFailed",
        response=resp,
        passed=passed,
    )
    assert passed, f"Builder must not create Foundry account; got {resp.status_code}: {resp.text[:400]}"


def test_n02_create_new_project(
    personas, subscription_id, resource_group, foundry_name, location, builder_arm_token, evidence
):
    """N-02: builder attempts to create a new Foundry project on the deployed account."""
    name = f"rbac-deny-proj-{uuid.uuid4().hex[:8]}"
    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.CognitiveServices/accounts/{foundry_name}"
        f"/projects/{name}"
    )
    body = {"location": location, "identity": {"type": "SystemAssigned"}, "properties": {"displayName": name}}
    resp = arm_request("PUT", url, builder_arm_token, api_version="2025-07-01-preview", json_body=body)
    passed = _is_denied(resp)
    evidence.record_response(
        test_id="N-02",
        suite="BuilderNegative",
        persona=personas["builder"],
        operation=f"PUT project {name}",
        expected="403",
        response=resp,
        passed=passed,
    )
    assert passed, f"Builder must not create project; got {resp.status_code}: {resp.text[:400]}"


def test_n03_deploy_new_model(
    personas, subscription_id, resource_group, foundry_name, builder_arm_token, evidence
):
    """N-03: builder attempts to create a model deployment on the deployed account."""
    name = f"rbac-deny-model-{uuid.uuid4().hex[:8]}"
    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.CognitiveServices/accounts/{foundry_name}"
        f"/deployments/{name}"
    )
    body = {
        "sku": {"name": "Standard", "capacity": 1},
        "properties": {
            "model": {"format": "OpenAI", "name": "gpt-4o-mini", "version": "2024-07-18"}
        },
    }
    resp = arm_request("PUT", url, builder_arm_token, api_version="2025-07-01-preview", json_body=body)
    passed = _is_denied(resp)
    evidence.record_response(
        test_id="N-03",
        suite="BuilderNegative",
        persona=personas["builder"],
        operation=f"PUT model deployment {name}",
        expected="403",
        response=resp,
        passed=passed,
    )
    assert passed, f"Builder must not deploy models; got {resp.status_code}: {resp.text[:400]}"


def test_n04_create_logic_app(
    personas, subscription_id, resource_group, location, builder_arm_token, evidence
):
    """N-04: builder attempts to create a Logic App (arbitrary MCP path)."""
    name = f"rbac-deny-la-{uuid.uuid4().hex[:8]}"
    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.Logic/workflows/{name}"
    )
    body = {"location": location, "properties": {"definition": {
        "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
        "contentVersion": "1.0.0.0",
        "triggers": {}, "actions": {}, "outputs": {},
    }}}
    resp = arm_request("PUT", url, builder_arm_token, api_version="2019-05-01", json_body=body)
    passed = _is_denied(resp)
    evidence.record_response(
        test_id="N-04",
        suite="BuilderNegative",
        persona=personas["builder"],
        operation=f"PUT Logic App {name}",
        expected="403",
        response=resp,
        passed=passed,
    )
    assert passed, f"Builder must not create Logic Apps; got {resp.status_code}: {resp.text[:400]}"


def test_n05_create_storage_account(
    personas, subscription_id, resource_group, location, builder_arm_token, evidence
):
    """N-05: builder attempts to create a generic Azure resource (storage account)."""
    name = f"rbacdeny{uuid.uuid4().hex[:16]}"[:24]
    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.Storage/storageAccounts/{name}"
    )
    body = {"location": location, "sku": {"name": "Standard_LRS"}, "kind": "StorageV2", "properties": {}}
    resp = arm_request("PUT", url, builder_arm_token, api_version="2023-05-01", json_body=body)
    passed = _is_denied(resp)
    evidence.record_response(
        test_id="N-05",
        suite="BuilderNegative",
        persona=personas["builder"],
        operation=f"PUT storage account {name}",
        expected="403",
        response=resp,
        passed=passed,
    )
    assert passed, f"Builder must not create arbitrary Azure resources; got {resp.status_code}: {resp.text[:400]}"


def test_n06_create_role_assignment(
    personas, subscription_id, project_scope, builder_arm_token, evidence
):
    """N-06: builder attempts to assign Foundry User to the "none" persona SP."""
    target_object_id = personas["none"].object_id
    ra_name = str(uuid.uuid4())
    role_id = f"/subscriptions/{subscription_id}/providers/Microsoft.Authorization/roleDefinitions/53ca6127-db72-4b80-b1b0-d745d6d5456d"
    url = f"https://management.azure.com{project_scope}/providers/Microsoft.Authorization/roleAssignments/{ra_name}"
    body = {"properties": {"roleDefinitionId": role_id, "principalId": target_object_id, "principalType": "ServicePrincipal"}}
    resp = arm_request("PUT", url, builder_arm_token, api_version="2022-04-01", json_body=body)
    passed = _is_denied(resp)
    evidence.record_response(
        test_id="N-06",
        suite="BuilderNegative",
        persona=personas["builder"],
        operation=f"PUT roleAssignment on {project_scope}",
        expected="403",
        response=resp,
        passed=passed,
    )
    assert passed, f"Builder must not delegate roles; got {resp.status_code}: {resp.text[:400]}"


def test_n07_publish_to_teams(personas):
    """N-07: builder attempts to publish an agent to Teams.

    Publishing is UI-only in current Foundry — see docs/manual-ui-test-plan.md UI-11.
    """
    skip_manual_required("N-07", "UI-11", "Teams publish is UI-only; validate via Foundry portal")


def test_n08_list_account_keys(
    personas, subscription_id, resource_group, foundry_name, builder_arm_token, evidence
):
    """N-08: builder attempts to retrieve account keys (would bypass RBAC).

    The Foundry account is deployed with `disableLocalAuth=true`, so keys are
    inactive. But we still validate that `listKeys` is not authorized for the
    builder principal — belt and suspenders.
    """
    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.CognitiveServices/accounts/{foundry_name}"
        f"/listKeys"
    )
    resp = arm_request("POST", url, builder_arm_token, api_version="2025-07-01-preview")
    passed = _is_denied(resp)
    evidence.record_response(
        test_id="N-08",
        suite="BuilderNegative",
        persona=personas["builder"],
        operation=f"POST {url}",
        expected="403 (disableLocalAuth=true & builder lacks listkeys/action)",
        response=resp,
        passed=passed,
    )
    assert passed, f"Builder must not listKeys; got {resp.status_code}: {resp.text[:400]}"
