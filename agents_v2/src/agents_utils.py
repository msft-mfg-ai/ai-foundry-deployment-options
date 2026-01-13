import os
from azure.ai.projects.models import (
    PromptAgentDefinition,
    Tool,
)
from openai import AsyncStream
from openai.types.responses import ResponseStreamEvent, Response
from openai.types.responses.response_input_param import (
    McpApprovalResponse,
)
import logging


class agents_utils:
    def __init__(self, client):
        self.client = client
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
    ):
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


async def process_stream(stream: AsyncStream[ResponseStreamEvent]):
    """Process streaming events and handle MCP approval requests."""
    events_received = []
    input_list = []
    response_id = None
    full_response = ""

    async for event in stream:
        previous_event = events_received[-1] if len(events_received) > 0 else None
        if previous_event and previous_event["type"] == event.type:
            previous_event["count"] += 1
        else:
            events_received.append({"type": event.type, "count": 1})

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
                input_list.append(
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
            response_id = event.response.id
            print("\n🎉 Response completed!")
            print(f"💰 Usage: {event.response.to_dict()['usage']}")
            full_response = event.response.output_text

    return events_received, input_list, response_id, full_response

async def process_response(response: Response):
    """Process response and handle MCP approval requests."""
    events_received = []
    input_list = []
    response_id = None
    full_response = ""

    for event in response.output:
        previous_event = events_received[-1] if len(events_received) > 0 else None
        if previous_event and previous_event["type"] == event.type:
            previous_event["count"] += 1
        else:
            events_received.append({"type": event.type, "count": 1})

        if event.type == "response.created":
            print(f"🆕 Stream started (ID: {event.response.id})\n")
        elif event.type == "response.output_text.delta":
            print(event.delta, end="", flush=True)
        elif event.type == "response.text.done":
            print("\n\n✅ Text complete")
        elif event.type == "response.output_item.added":
            if event.item.type == "mcp_approval_request":
                process_approval(event.item, input_list)
            else:
                print(f"\n\n📦 Output item added: {event.item.type}")
        elif event.type == "mcp_approval_request":
            process_approval(event, input_list)
        elif event.type == "response.output_item.done":
            print(f"   ✅ Item complete: {event.item.type}")
        elif event.type == "response.completed":
            response_id = event.response.id
            print("\n🎉 Response completed!")
            print(f"💰 Usage: {event.response.to_dict()['usage']}")
            full_response = event.response.output_text
        elif event.type == "mcp_list_tools":
            print(f"🔧 Listing tools...")

    return events_received, input_list, response_id, full_response

def process_approval(item, input_list = []):
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