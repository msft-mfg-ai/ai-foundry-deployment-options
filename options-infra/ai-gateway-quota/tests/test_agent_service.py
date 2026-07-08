"""Foundry v2 Agent Service tests routed through the APIM gateway.

WHAT: Create a v2 agent backed by an APIM-type project connection (so all
      model inference flows through the gateway), run it against one prompt,
      and assert the response succeeded.

WHY:  The unit tests in test_gateway.py prove the *HTTP surface* of the
      gateway works (chat/embeddings/anthropic). These tests prove that the
      Foundry Agent Service can use the gateway as its inference backend
      end-to-end — which is the production usage shape.

SKIP CONDITIONS:
  - No Foundry project endpoint reachable
  - No connection of type=ApiManagement on the project
  - No OpenAI / Anthropic model returned by /inference/deployments

A random model is picked per test from the pool of deployed models so the
suite naturally exercises whatever the gateway can serve.
"""
from __future__ import annotations

import pytest

from azure.ai.projects.models import PromptAgentDefinition


async def _create_and_run(project_client, apim_connection: str, deployment: str, prompt: str):
    """Create (or update) an agent that uses {apim_connection}/{deployment} as
    its model, then invoke it once via the Responses API and return the
    response object. Wraps the notebook pattern in agents_v2/.
    """
    # `model = "<connection-name>/<deployment-name>"` is the contract the
    # Agent Service uses to route through the APIM connection.
    model = f'{apim_connection}/{deployment}'

    # Deterministic agent name per (connection, deployment) so reruns reuse
    # the same agent version.
    agent_name = f'gw-test-{deployment}'.replace('.', '-').replace('_', '-').lower()[:63]

    agent = await project_client.agents.create_version(
        agent_name=agent_name,
        definition=PromptAgentDefinition(
            model=model,
            instructions='You are a terse assistant. Answer in <= 8 words.',
            tools=[],
        ),
    )

    openai_client = project_client.get_openai_client()

    conversation = await openai_client.conversations.create(
        items=[{'type': 'message', 'role': 'user', 'content': prompt}],
    )

    response = await openai_client.responses.create(
        conversation=conversation.id,
        extra_body={
            'agent_reference': {'name': agent.name, 'type': 'agent_reference'}
        },
        input='',
    )
    return agent, response


@pytest.mark.asyncio
async def test_agent_run_openai_via_gateway(
    project_client,
    openai_apim_connection,
    random_openai_chat_model,
):
    """WHAT: Run a v2 Foundry agent whose model is `{openai-apim-conn}/{openai-model}`
           and assert the Responses API returns text.
    HOW:   Picks a random OpenAI chat-capable deployment from
           /inference/deployments and creates/updates an agent using the
           OpenAI-flavored APIM connection (metadata.deploymentInPath=true).
           POST a one-shot prompt via the Responses API, then assert
           non-empty output_text.
    WHY:   Verifies the *agent service path* through the gateway — distinct
           from the direct HTTP path tested in test_gateway.py. Catches
           regressions in: project connection wiring, gateway JWT acceptance
           of agent-service-issued tokens, model name passthrough.
    """
    agent, response = await _create_and_run(
        project_client,
        openai_apim_connection,
        random_openai_chat_model,
        prompt='What is 2+2? Reply with just the number.',
    )
    request_id = getattr(response, '_request_id', 'n/a')
    output = (response.output_text or '').strip()
    print(f'│  → agent={agent.name!r} model={random_openai_chat_model!r} via {openai_apim_connection!r}')
    print(f'│  ← request-id={request_id} output={output[:80]!r}')
    assert output, f'Empty output_text from agent run (request-id={request_id})'


@pytest.mark.asyncio
async def test_agent_run_anthropic_via_gateway(
    project_client,
    anthropic_apim_connection,
    random_anthropic_model,
):
    """WHAT: Run a v2 Foundry agent backed by a random Anthropic deployment
           through the Anthropic-flavored APIM gateway connection.
    HOW:   Same flow as test_agent_run_openai_via_gateway but selects a
           model with format=Anthropic and the APIM connection where
           metadata.deploymentInPath=false (Anthropic /v1/messages shape).
    WHY:   Anthropic models reach Foundry only via /v1/messages — this proves
           the agent service can drive that path through the gateway end-to-end,
           not just via curl in test_chat_anthropic_model.
    """
    agent, response = await _create_and_run(
        project_client,
        anthropic_apim_connection,
        random_anthropic_model,
        prompt='Say hi in 3 words.',
    )
    request_id = getattr(response, '_request_id', 'n/a')
    output = (response.output_text or '').strip()
    print(f'│  → agent={agent.name!r} model={random_anthropic_model!r} via {anthropic_apim_connection!r}')
    print(f'│  ← request-id={request_id} output={output[:80]!r}')
    assert output, f'Empty output_text from anthropic agent run (request-id={request_id})'
