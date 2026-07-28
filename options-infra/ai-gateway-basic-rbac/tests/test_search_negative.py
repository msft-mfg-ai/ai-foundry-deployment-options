"""
N-09/N-10: builders MUST NOT be able to manage the underlying Azure AI Search
resource used by the Foundry project.

Two attack paths tested:
- N-09: builder SP calls the Search dataplane with a valid Entra ID token.
  Fails because Foundry User does NOT grant any Search dataAction and no
  Search RBAC role is assigned to the builder SP.
- N-10: builder SP tries to obtain and use an admin key. Fails because the
  Search resource has `disableLocalAuth: true` — no admin/query keys can be
  issued or used, so even if the builder had listAdminKeys it wouldn't help.
  (We also assert the underlying listAdminKeys ARM call is denied.)

The project's managed identity gets `Search Index Data Reader` (query-only)
so agents can still ground answers.  Index authoring is CI/Bicep only.
"""
from __future__ import annotations

import os
import uuid

import httpx
import pytest
from conftest import arm_request  # type: ignore
from azure.identity import ClientSecretCredential


SEARCH_ENDPOINT = os.environ.get("AI_SEARCH_ENDPOINT", "").rstrip("/")
SEARCH_NAME = os.environ.get("AI_SEARCH_NAME", "")
SEARCH_SCOPE = "https://search.azure.com/.default"
ARM_SCOPE = "https://management.azure.com/.default"


pytestmark = pytest.mark.skipif(
    not SEARCH_ENDPOINT or not SEARCH_NAME,
    reason="AI_SEARCH_ENDPOINT / AI_SEARCH_NAME not set — deploy hasn't wired AI Search yet.",
)


@pytest.fixture(scope="session")
def builder_arm_token_local(cred_builder) -> str:
    return cred_builder.get_token(ARM_SCOPE).token


def _search_token(cred: ClientSecretCredential) -> str:
    return cred.get_token(SEARCH_SCOPE).token


def test_n09_builder_cannot_create_index_via_entra(personas, cred_builder, evidence):
    """N-09: builder SP with Foundry User cannot PUT an index on Search via Entra ID."""
    index_name = f"rbac-deny-idx-{uuid.uuid4().hex[:8]}"
    url = f"{SEARCH_ENDPOINT}/indexes/{index_name}?api-version=2024-07-01"
    body = {
        "name": index_name,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "searchable": False},
            {"name": "content", "type": "Edm.String", "searchable": True},
        ],
    }
    token = _search_token(cred_builder)
    resp = httpx.put(
        url,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=body,
        timeout=30.0,
    )
    passed = resp.status_code in (401, 403)
    evidence.record_response(
        test_id="N-09",
        suite="BuilderNegative",
        persona=personas["builder"],
        operation=f"PUT {url}",
        expected="401/403 — Foundry User grants no Search dataActions",
        response=resp,
        passed=passed,
        notes="Foundry User (or any Foundry-* role) does NOT include Search dataplane rights.",
    )
    assert passed, (
        f"Builder must not create Search indexes; got {resp.status_code}: {resp.text[:400]}"
    )


def test_n10_builder_cannot_list_admin_keys(
    personas, subscription_id, resource_group, builder_arm_token_local, evidence
):
    """N-10: builder cannot listAdminKeys on the Search resource.

    Even if key auth were on, Foundry User doesn't grant listAdminKeys; and
    with `disableLocalAuth: true` the keys don't work anyway. This test proves
    the ARM path is denied — defence in depth.
    """
    url = (
        f"https://management.azure.com/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}/providers/Microsoft.Search/searchServices/"
        f"{SEARCH_NAME}/listAdminKeys?api-version=2024-06-01-preview"
    )
    resp = arm_request("POST", url, builder_arm_token_local, api_version="2024-06-01-preview")
    passed = resp.status_code in (401, 403)
    evidence.record_response(
        test_id="N-10",
        suite="BuilderNegative",
        persona=personas["builder"],
        operation=f"POST {url}",
        expected="401/403 — listAdminKeys denied AND disableLocalAuth=true makes keys unusable",
        response=resp,
        passed=passed,
        notes="disableLocalAuth=true on the Search resource means no admin keys exist to leak.",
    )
    assert passed, f"Builder must not listAdminKeys; got {resp.status_code}: {resp.text[:400]}"
