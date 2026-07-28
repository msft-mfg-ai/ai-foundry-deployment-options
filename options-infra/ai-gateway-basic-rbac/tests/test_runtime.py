"""R-01..R-03: runtime persona tests using the real Foundry Python SDK.

R-01/R-02 exercise the `runtime` SP (Foundry Agent Consumer). That role only
grants `endpoints/interact/action` and must NOT list or create agents.

R-03 exercises the Agents v2 → Responses API invocation path (the modern
execution surface — the legacy `/assistants` API is out of scope). It also
documents an important RBAC observation: `Foundry Project Runtime User` on
its own currently cannot invoke `/openai/v1/responses` because that endpoint
requires `Microsoft.CognitiveServices/accounts/AIServices/agents/write`,
which the role does not grant. The practical "runtime app" persona therefore
uses `Foundry User` — proven here by invoking with the builder SP.
"""
from __future__ import annotations

import asyncio
import uuid

import pytest
from azure.ai.projects.aio import AIProjectClient
from azure.ai.projects.models import PromptAgentDefinition
from azure.identity.aio import ClientSecretCredential as AsyncClientSecretCredential

from conftest import (
    foundry_request,
    get_foundry_token,
    skip_manual_required,
)


AGENT_MODEL = "gpt-5-mini"


@pytest.fixture(scope="session")
def runtime_token(cred_runtime) -> str:
    return get_foundry_token(cred_runtime)


def _async_cred(persona) -> AsyncClientSecretCredential:
    return AsyncClientSecretCredential(
        tenant_id=persona.tenant_id,
        client_id=persona.app_id,
        client_secret=persona.client_secret,
    )


def test_r01_runtime_cannot_list_agents(
    personas, foundry_project_endpoint, runtime_token, evidence
):
    """R-01: Foundry Agent Consumer MUST NOT list agents (no agents/read)."""
    url = f"{foundry_project_endpoint}/agents"
    resp = foundry_request("GET", url, runtime_token)
    body_lower = resp.text.lower()
    is_permission_denied = resp.status_code in (401, 403) and (
        "permissiondenied" in body_lower
        or "does not have permissions" in body_lower
        or "data action" in body_lower
        or "authorization" in body_lower
        or "usererror" in body_lower
    )
    passed = is_permission_denied
    evidence.record_response(
        test_id="R-01",
        suite="Runtime",
        persona=personas["runtime"],
        operation=f"GET {url}",
        expected="401/403 PermissionDenied (Agent Consumer has no agents/read)",
        response=resp,
        passed=passed,
    )
    assert passed, (
        f"Runtime SP (Agent Consumer) should NOT list agents; "
        f"got {resp.status_code}: {resp.text[:400]}"
    )


def test_r02_runtime_cannot_create_agent(
    personas, foundry_project_endpoint, runtime_token, evidence
):
    """R-02: Foundry Agent Consumer MUST NOT create/modify agents."""
    agent_name = f"rbac-r02-{uuid.uuid4().hex[:8]}"
    url = f"{foundry_project_endpoint}/agents/{agent_name}/versions"
    body = {
        "definition": {
            "kind": "prompt",
            "model": AGENT_MODEL,
            "instructions": "should be denied",
            "tools": [],
        }
    }
    resp = foundry_request("POST", url, runtime_token, json_body=body)
    passed = resp.status_code in (401, 403)
    evidence.record_response(
        test_id="R-02",
        suite="Runtime",
        persona=personas["runtime"],
        operation=f"POST {url}",
        expected="401/403",
        response=resp,
        passed=passed,
    )
    assert passed, f"Runtime persona must not create agents; got {resp.status_code}: {resp.text[:400]}"


async def _create_probe_agent_as_builder(personas, foundry_project_endpoint):
    b = personas["builder"]
    name = f"rbac-r03-{uuid.uuid4().hex[:8]}"
    async with _async_cred(b) as cred:
        async with AIProjectClient(endpoint=foundry_project_endpoint, credential=cred) as client:
            await client.agents.create_version(
                agent_name=name,
                definition=PromptAgentDefinition(
                    model=AGENT_MODEL,
                    instructions="Reply with one short greeting.",
                    tools=[],
                ),
            )
    return name


async def _delete_agent_as_builder(personas, foundry_project_endpoint, name):
    b = personas["builder"]
    async with _async_cred(b) as cred:
        async with AIProjectClient(endpoint=foundry_project_endpoint, credential=cred) as client:
            try:
                await client.agents.delete(agent_name=name)
            except Exception:
                pass


async def _invoke_response(persona, foundry_project_endpoint, agent_name):
    async with _async_cred(persona) as cred:
        async with AIProjectClient(endpoint=foundry_project_endpoint, credential=cred) as client:
            oai = client.get_openai_client()
            resp = await oai.responses.create(
                input="say hi",
                extra_body={"agent_reference": {"name": agent_name, "type": "agent_reference"}},
            )
            return resp


def test_r03_responses_api_via_project_runtime(
    personas, foundry_project_endpoint, evidence
):
    """R-03: Agents v2 → Responses API invocation.

    This test does TWO things:

    1. Documents that `Foundry Project Runtime User` alone (persona
       `responses`) currently CANNOT invoke `/openai/v1/responses` —
       Foundry today requires `agents/write` on this path, which is not
       granted by the role. Expected result: PermissionDenied 403.
    2. Proves that `Foundry User` (persona `builder`) CAN invoke a v2
       agent via the Responses API — this is the practical persona for
       runtime applications until Foundry closes the RBAC gap.

    The test PASSES when observation 1 shows a permission denial AND
    observation 2 completes a successful Responses call.
    """
    agent_name = asyncio.run(_create_probe_agent_as_builder(personas, foundry_project_endpoint))

    try:
        # Observation 1: responses persona should be denied.
        responses_denied = False
        responses_err = ""
        try:
            asyncio.run(_invoke_response(personas["responses"], foundry_project_endpoint, agent_name))
        except Exception as e:
            responses_err = str(e)
            msg_lower = responses_err.lower()
            responses_denied = ("403" in responses_err) or ("permissiondenied" in msg_lower) or (
                "does not have permissions" in msg_lower
            )
        evidence.record_raw(
            test_id="R-03a",
            suite="Runtime",
            persona=personas["responses"],
            operation="AsyncOpenAI.responses.create (Agents v2)",
            expected="403 PermissionDenied — role has no agents/write",
            status_code=403 if responses_denied else 0,
            response_body=responses_err[:1000],
            passed=responses_denied,
        )

        # Observation 2: Foundry User (builder) should succeed.
        builder_ok = False
        builder_err = ""
        output_text = ""
        try:
            resp = asyncio.run(_invoke_response(personas["builder"], foundry_project_endpoint, agent_name))
            output_text = getattr(resp, "output_text", "") or ""
            builder_ok = bool(output_text)
        except Exception as e:
            builder_err = str(e)
        evidence.record_raw(
            test_id="R-03b",
            suite="Runtime",
            persona=personas["builder"],
            operation="AsyncOpenAI.responses.create (Agents v2)",
            expected="2xx — Foundry User can invoke",
            status_code=200 if builder_ok else 0,
            response_body=(output_text or builder_err)[:1000],
            passed=builder_ok,
        )

        assert responses_denied, (
            "Expected Foundry Project Runtime User to be denied on /openai/v1/responses; "
            f"got: {responses_err[:400]}"
        )
        assert builder_ok, (
            f"Expected Foundry User (builder) to invoke Responses API; got: {builder_err[:400]}"
        )
    finally:
        asyncio.run(_delete_agent_as_builder(personas, foundry_project_endpoint, agent_name))
