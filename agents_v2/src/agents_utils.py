import os
from dataclasses import dataclass, field
from azure.ai.projects.models import PromptAgentDefinition, Tool, AgentObject
from azure.ai.projects.aio import AIProjectClient
from openai import AsyncStream, AsyncOpenAI
from openai.types.conversations import Conversation
from openai.types.responses import (
    ResponseStreamEvent,
    Response,
    ResponseReasoningItem,
    ResponseOutputText,
)
from openai.types.responses.response_input_param import (
    McpApprovalResponse,
)
import logging


@dataclass
class ProcessedResponse:
    """Result from processing a streaming or non-streaming response."""

    events_received: list = field(default_factory=list)
    input_list: list = field(default_factory=list)
    response_id: str | None = None
    full_response: str = ""
    served_by_cluster: str = "unknown"
    openai_processing_ms: str = "unknown"
    request_id: str = "unknown"


class agents_utils:
    def __init__(self, client):
        self.client: AIProjectClient = client
        pass

    async def get_agents(self):
        logging.info("Getting list of agents")
        all_agents = []
        async for agent in self.client.agents.list():
            all_agents.append(agent)
        return all_agents

    async def create_agent(
        self,
        name: str,
        model_gateway_connection: str = None,
        instructions="You are a helpful assistant that answers general questions",
        deployment_name: str = None,
        delete_before_create: bool = True,
        tools: list[Tool] = [],
    ) -> AgentObject:
        # default deployment name
        deployment_name = (
            deployment_name
            if deployment_name
            else os.environ.get("AZURE_OPENAI_CHAT_DEPLOYMENT_NAME")
        )

        if not deployment_name:
            raise ValueError(
                "❌ deployment_name must be provided either as argument or environment variable AZURE_OPENAI_CHAT_DEPLOYMENT_NAME"
            )

        model = (
            f"{model_gateway_connection}/{deployment_name}"
            if model_gateway_connection
            else deployment_name
        )

        # check if agent "MyV2Agent" exists
        all_agents = await self.get_agents()
        agent_names = [agent.name for agent in all_agents]
        agent = None

        # this is temporary?
        if name in agent_names and delete_before_create:
            # delete the agent because of a bug?
            print(f"Deleting existing agent {name} before creating a new one")
            await self.client.agents.delete(agent_name=name)
            agent_names.remove(name)

        if name not in agent_names:
            agent = await self.client.agents.create(
                name=name,
                definition=PromptAgentDefinition(
                    model=model, instructions=instructions, tools=tools
                ),
            )
            print(
                f"Agent created (id: {agent.id}, name: {agent.name}, version: {agent.versions.latest.version} using model {agent.versions.latest.definition.model})"
            )
        else:
            agent = await self.client.agents.update(
                agent_name=name,
                definition=PromptAgentDefinition(
                    model=model, instructions=instructions, tools=tools
                ),
            )
            print(
                f"Agent updated (id: {agent.id}, name: {agent.name}, version: {agent.versions.latest.version} using model {agent.versions.latest.definition.model})"
            )
        return agent


async def process_stream(stream: AsyncStream[ResponseStreamEvent]) -> ProcessedResponse:
    """Process streaming events and handle MCP approval requests."""
    result = ProcessedResponse(
        served_by_cluster=stream.response.headers.get(
            "azureml-served-by-cluster", "unknown"
        ),
        openai_processing_ms=stream.response.headers.get(
            "openai-processing-ms", "unknown"
        ),
        request_id=stream.response.headers.get("x-request-id", "unknown"),
    )

    async for event in stream:
        previous_event = (
            result.events_received[-1] if len(result.events_received) > 0 else None
        )
        if previous_event and previous_event["type"] == event.type:
            previous_event["count"] += 1
        else:
            result.events_received.append({"type": event.type, "count": 1})

        if event.type == "response.created":
            print(f"🆕 Stream started (ID: {event.response.id})\n")
        elif event.type == "response.output_text.delta":
            print(event.delta, end="", flush=True)
        elif event.type == "response.text.done":
            print("\n\n✅ Text complete")
        elif event.type == "response.output_item.added":
            if event.item.type == "mcp_approval_request":
                print(
                    f"\n\n🔐 MCP approval requested: {event.item.name if hasattr(event.item, 'name') else 'tool'}"
                )
                result.input_list.append(
                    McpApprovalResponse(
                        type="mcp_approval_response",
                        approve=True,
                        approval_request_id=event.item.id,
                    )
                )
            else:
                print(f"\n\n📦 Output item added: {event.item.type}")
        elif event.type == "response.output_item.done":
            print(f"   ✅ Item complete: {event.item.type}")
        elif event.type == "response.completed":
            result.response_id = event.response.id
            print("\n🎉 Response completed!")
            print(f"💰 Usage: {event.response.to_dict()['usage']}")
            result.full_response = event.response.output_text

    return result


async def process_response(response: Response) -> ProcessedResponse:
    """Process response and handle MCP approval requests."""
    result = ProcessedResponse()

    if response.status == "incomplete":
        print(f"⚠️ Response incomplete! Reason: {response.incomplete_details}")
    else:
        print(f"✅ Response complete with status: {response.status}.")

    for event in response.output:
        previous_event = (
            result.events_received[-1] if len(result.events_received) > 0 else None
        )
        if previous_event and previous_event["type"] == event.type:
            previous_event["count"] += 1
        else:
            result.events_received.append({"type": event.type, "count": 1})

        if event.type == "response.created":
            print(f"🆕 Stream started (ID: {event.response.id})\n")
        elif event.type == "response.output_text.delta":
            print(event.delta, end="", flush=True)
        elif event.type == "reasoning":
            reasoning_item: ResponseReasoningItem = event
            print(
                f"🧠 Reasoning update ({reasoning_item.status}): {reasoning_item.content} Summary: {reasoning_item.summary}"
            )
        elif event.type == "bing_grounding_call":
            print(f"🔎 Bing grounding call: {event.arguments}")
        elif event.type == "bing_grounding_call_output":
            print("📥 Bing grounding call completed")
        elif event.type == "response.text.done":
            print("\n\n✅ Text complete")
        elif event.type == "response.output_item.added":
            if event.item.type == "mcp_approval_request":
                process_approval(event.item, result.input_list)
            else:
                print(f"\n\n📦 Output item added: {event.item.type}")
        elif event.type == "mcp_approval_request":
            process_approval(event, result.input_list)
        elif event.type == "response.output_item.done":
            print(f"   ✅ Item complete: {event.item.type}")
        elif event.type == "response.completed":
            result.response_id = event.response.id
            print("\n🎉 Response completed!")
            print(f"💰 Usage: {event.response.to_dict()['usage']}")
            result.full_response = event.response.output_text
        elif event.type == "mcp_list_tools":
            print("🔧 Listing tools...")
        elif event.type == "mcp_call":
            print(
                f"🔧 Making MCP call to {event.name} on server {event.server_label} with arguments {event.arguments[:50]}. Result: '{event.output[:50]}'"
            )
        elif event.type == "message":
            for message in event.content:
                if isinstance(message, ResponseOutputText):
                    result.full_response += message.text
                for annotation in message.annotations:
                    print(f"💬 Message annotation: {annotation}")

    return result


def process_approval(item, input_list=[]):
    if item.type == "mcp_approval_request":
        print(
            f"\n\n🔐 MCP approval requested: {item.name if hasattr(item, 'name') else 'tool'}"
        )
        input_list.append(
            McpApprovalResponse(
                type="mcp_approval_response",
                approve=True,
                approval_request_id=item.id,
            )
        )


async def create_response_with_retry(
    openai_client: AsyncOpenAI,
    conversation: Conversation,
    agent: AgentObject = None,
    max_retries: int = 10,
    use_retry: bool = True,
) -> Response:
    last_exception = None
    for attempt in range(1, max_retries + 1):
        try:
            response = await openai_client.responses.create(
                conversation=conversation.id,
                extra_body=(
                    {"agent": {"name": agent.name, "type": "agent_reference"}}
                    if agent
                    else None
                ),
                input="",
            )
            return response
        except Exception as e:
            if not use_retry:
                raise e

            last_exception = e
            logging.warning(f"Attempt {attempt}/{max_retries} failed: {e}")
            if attempt < max_retries:
                import asyncio

                await asyncio.sleep(1)  # Wait 1 second before retrying

    raise Exception(
        f"Failed to get response after {max_retries} attempts. Last error: {last_exception}"
    )


async def stream_response_with_retry(
    openai_client: AsyncOpenAI,
    conversation: Conversation,
    agent: AgentObject = None,
    max_retries: int = 10,
    use_retry: bool = True,
) -> ProcessedResponse:
    last_exception = None
    for attempt in range(1, max_retries + 1):
        try:
            stream = await openai_client.responses.create(
                conversation=conversation.id,
                extra_body=(
                    {"agent": {"name": agent.name, "type": "agent_reference"}}
                    if agent
                    else None
                ),
                input="",
                stream=True,
            )
            return await process_stream(stream)
        except Exception as e:
            if not use_retry:
                raise e

            last_exception = e
            logging.warning(f"Attempt {attempt}/{max_retries} failed: {e}")
            if attempt < max_retries:
                import asyncio

                await asyncio.sleep(1)  # Wait 1 second before retrying

    raise Exception(
        f"Failed to stream response after {max_retries} attempts. Last error: {last_exception}"
    )
