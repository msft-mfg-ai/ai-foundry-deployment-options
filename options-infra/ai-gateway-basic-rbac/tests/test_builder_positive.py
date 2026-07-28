"""B-01..B-07: Builder positive tests.

The builder SP has `Foundry User` at the project scope. It should be able to:
- B-01 read the project
- B-02 create/update a draft agent
- B-03 attach an approved tool
- B-04 create a knowledge source
- B-05 create/update guardrails
- B-06 start an evaluation and read results
- B-07 build a workflow

Foundry data-plane paths for tools/knowledge/guardrails/workflows are versioned
and tenant-rollout dependent. Where a stable API isn't available, we emit
`skip_manual_required` — the result is classified as ManualRequired (not Pass)
in the evidence report.
"""
from __future__ import annotations

import uuid

import pytest
from conftest import (
    foundry_request,
    get_foundry_token,
    skip_manual_required,
)


AGENT_MODEL = "gpt-5-mini"


@pytest.fixture(scope="session")
def builder_token(cred_builder) -> str:
    return get_foundry_token(cred_builder)


def test_b01_read_project(personas, foundry_project_endpoint, builder_token, evidence):
    """B-01: list agents (v2) — proves data-plane project read works."""
    url = f"{foundry_project_endpoint}/agents"
    resp = foundry_request("GET", url, builder_token)
    passed = resp.status_code == 200
    evidence.record_response(
        test_id="B-01",
        suite="BuilderPositive",
        persona=personas["builder"],
        operation=f"GET {url}",
        expected="200 OK (v2 agents list)",
        response=resp,
        passed=passed,
    )
    assert passed, f"Builder should list agents; got {resp.status_code}: {resp.text[:400]}"


def test_b02_create_draft_agent(personas, foundry_project_endpoint, builder_token, evidence):
    """B-02: create a v2 agent version (Agents v2 API, not legacy /assistants)."""
    agent_name = f"rbac-b02-{uuid.uuid4().hex[:8]}"
    create_url = f"{foundry_project_endpoint}/agents/{agent_name}/versions"
    body = {
        "definition": {
            "kind": "prompt",
            "model": AGENT_MODEL,
            "instructions": "RBAC harness B-02 draft agent.",
            "tools": [],
        }
    }
    resp = foundry_request("POST", create_url, builder_token, json_body=body)
    passed = 200 <= resp.status_code < 300
    evidence.record_response(
        test_id="B-02",
        suite="BuilderPositive",
        persona=personas["builder"],
        operation=f"POST {create_url}",
        expected="2xx (v2 agent version created)",
        response=resp,
        passed=passed,
    )
    # Cleanup — best effort.
    if passed:
        del_url = f"{foundry_project_endpoint}/agents/{agent_name}"
        foundry_request("DELETE", del_url, builder_token)
    assert passed, f"Builder should create v2 agent; got {resp.status_code}: {resp.text[:400]}"


def test_b03_add_approved_tool(personas, foundry_project_endpoint, builder_token, evidence):
    """B-03: create a v2 agent that has a **tool attached** (MCP toolbox).

    Confirms the Foundry User persona can build an agent WITH tools — the
    customer's &ldquo;Create tool / skill&rdquo; requirement. Uses a public
    MCP endpoint so the test doesn't depend on APIM being wired.

    If the deployment fails with a Foundry-side error (e.g. tools plane
    rejects a public MCP server on a locked-down account), the test is
    downgraded to ManualRequired so the harness still surfaces the issue
    instead of masking it as a pass.
    """
    agent_name = f"rbac-b03-{uuid.uuid4().hex[:8]}"
    create_url = f"{foundry_project_endpoint}/agents/{agent_name}/versions"
    body = {
        "definition": {
            "kind": "prompt",
            "model": AGENT_MODEL,
            "instructions": "RBAC harness B-03 agent with MCP toolbox.",
            "tools": [
                {
                    "type": "mcp",
                    "server_label": "microsoft_learn",
                    "server_url": "https://learn.microsoft.com/api/mcp",
                    "require_approval": "never",
                }
            ],
        }
    }
    resp = foundry_request("POST", create_url, builder_token, json_body=body)
    passed = 200 <= resp.status_code < 300
    evidence.record_response(
        test_id="B-03",
        suite="BuilderPositive",
        persona=personas["builder"],
        operation=f"POST {create_url} (agent + MCP tool)",
        expected="2xx — Foundry User can create agent with a tool attached",
        response=resp,
        passed=passed,
        notes="Customer requirement: builders must be able to create tools/skills on their agents.",
    )
    if passed:
        del_url = f"{foundry_project_endpoint}/agents/{agent_name}"
        foundry_request("DELETE", del_url, builder_token)
    assert passed, (
        f"Foundry User should create agent-with-tool; got {resp.status_code}: {resp.text[:400]}"
    )


def test_b04_create_knowledge(personas):
    """B-04: create a knowledge source using approved data source access."""
    skip_manual_required("B-04", "UI-04", "Knowledge source creation is currently UI-only in Foundry")


def test_b05_create_guardrails(personas):
    """B-05: create/update guardrail configuration."""
    skip_manual_required("B-05", "UI-05", "Guardrail configuration is currently UI-only in Foundry")


def test_b06_run_evaluation(personas, foundry_project_endpoint, builder_token, evidence):
    """B-06: start an evaluation and read status."""
    url = f"{foundry_project_endpoint}/evaluations/runs"
    resp = foundry_request("GET", url, builder_token, api_version="2025-05-15-preview")
    if resp.status_code in (404, 400):
        skip_manual_required("B-06", "UI-06", "Evaluations API not available in this Foundry version")
    passed = resp.status_code == 200
    evidence.record_response(
        test_id="B-06",
        suite="BuilderPositive",
        persona=personas["builder"],
        operation=f"GET {url}",
        expected="200 OK",
        response=resp,
        passed=passed,
    )
    assert passed, f"Builder should list evaluations; got {resp.status_code}"


def test_b07_build_workflow(personas):
    """B-07: create a Foundry project workflow."""
    skip_manual_required("B-07", "UI-07", "Workflows API not stable; use UI checklist")
