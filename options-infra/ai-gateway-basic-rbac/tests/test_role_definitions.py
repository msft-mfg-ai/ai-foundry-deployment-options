"""RD-01: fetch all six Foundry role definitions and assert mandatory permissions."""
from __future__ import annotations

import json
from pathlib import Path

import pytest
from azure.identity import DefaultAzureCredential

from conftest import ARM_SCOPE, arm_request


EXPECTED_ROLES: dict[str, str] = {
    "Foundry User": "53ca6127-db72-4b80-b1b0-d745d6d5456d",
    "Foundry Agent Consumer": "eed3b665-ab3a-47b6-8f48-c9382fb1dad6",
    "Foundry Project Runtime User": "142bfaed-a13f-4c2d-bed2-6db62c4a1009",
    "Foundry Project Manager": "eadc314b-1a2d-4efa-be10-5d325db5065e",
    "Foundry Account Owner": "e47c6f54-e4a2-4754-9501-8e0985b135e1",
    "Foundry Owner": "c883944f-8b7b-4483-af10-35834be79c4a",
}

EXPECTED_JSON_PATH = Path(__file__).resolve().parents[1] / "config" / "role-definitions.expected.json"


@pytest.fixture(scope="session")
def deployer_token() -> str:
    """Token for the identity that ran `azd up` — used to read role definitions."""
    cred = DefaultAzureCredential()
    return cred.get_token(ARM_SCOPE).token


@pytest.mark.parametrize("role_name,role_id", list(EXPECTED_ROLES.items()))
def test_rd01_role_definition_exists(role_name, role_id, subscription_id, deployer_token, evidence):
    """RD-01: role definition is visible in the tenant and matches expected GUID."""
    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/providers/Microsoft.Authorization/roleDefinitions/{role_id}"
    )
    resp = arm_request("GET", url, deployer_token, api_version="2022-04-01")
    passed = resp.status_code == 200 and resp.json().get("properties", {}).get("roleName") == role_name
    evidence.record_response(
        test_id=f"RD-01/{role_name}",
        suite="RoleDefinitions",
        persona=None,
        operation=f"GET role definition {role_name}",
        expected="200 OK, roleName matches",
        response=resp,
        passed=passed,
    )
    assert passed, f"Role {role_name} ({role_id}) not found or name mismatch: {resp.text[:300]}"


def test_rd01_expected_permissions_snapshot(subscription_id, deployer_token, tmp_path):
    """Compare live role definitions with config/role-definitions.expected.json.

    Not a strict assertion — writes an `.actual.json` alongside for diffing when
    Microsoft updates role definitions.
    """
    actual: dict = {}
    for role_name, role_id in EXPECTED_ROLES.items():
        url = (
            f"https://management.azure.com/subscriptions/{subscription_id}"
            f"/providers/Microsoft.Authorization/roleDefinitions/{role_id}"
        )
        resp = arm_request("GET", url, deployer_token, api_version="2022-04-01")
        assert resp.status_code == 200, f"Failed to fetch {role_name}: {resp.status_code}"
        props = resp.json().get("properties", {})
        perms = (props.get("permissions") or [{}])[0]
        actual[role_name] = {
            "roleDefinitionId": role_id,
            "actions": perms.get("actions", []),
            "notActions": perms.get("notActions", []),
            "dataActions": perms.get("dataActions", []),
            "notDataActions": perms.get("notDataActions", []),
        }

    out_dir = Path(__file__).resolve().parent / "output"
    out_dir.mkdir(exist_ok=True)
    (out_dir / "foundry-role-definitions.actual.json").write_text(json.dumps(actual, indent=2))

    if not EXPECTED_JSON_PATH.exists():
        pytest.skip(f"{EXPECTED_JSON_PATH} not present; first run captures baseline.")

    expected = json.loads(EXPECTED_JSON_PATH.read_text())

    # Mandatory assertions from the spec (foundry-rbac-ghcp-implementation-spec.html):
    fu = actual["Foundry User"]
    assert "Microsoft.CognitiveServices/*" in fu["dataActions"], "Foundry User missing CS data wildcard"
    assert not any(
        a in fu["actions"] for a in ("Microsoft.Authorization/roleAssignments/write",)
    ), "Foundry User must not have role-assignment write"
    assert "Microsoft.CognitiveServices/*" not in fu["actions"], "Foundry User must not have CS mgmt wildcard"

    fac = actual["Foundry Agent Consumer"]
    assert fac["dataActions"] == [
        "Microsoft.CognitiveServices/accounts/AIServices/endpoints/interact/action"
    ], "Foundry Agent Consumer has unexpected data actions"
    assert not fac["actions"], "Foundry Agent Consumer must have no management actions"

    fpru = actual["Foundry Project Runtime User"]
    assert fpru["dataActions"] == [
        "Microsoft.CognitiveServices/accounts/AIServices/responses/*"
    ], "Foundry Project Runtime User has unexpected data actions"
    assert not fpru["actions"], "Foundry Project Runtime User must have no management actions"

    fpm = actual["Foundry Project Manager"]
    assert "Microsoft.Authorization/roleAssignments/write" in fpm["actions"], (
        "Foundry Project Manager should have role-assignment write"
    )

    fao = actual["Foundry Account Owner"]
    assert "Microsoft.CognitiveServices/*" in fao["actions"], "Foundry Account Owner needs CS mgmt wildcard"

    fo = actual["Foundry Owner"]
    assert "Microsoft.CognitiveServices/*" in fo["actions"], "Foundry Owner needs CS mgmt wildcard"
