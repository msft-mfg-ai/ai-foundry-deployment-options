"""Create one prompt agent with all shared MCP connections in each project."""

import asyncio
import json
import os

from azure.ai.projects.aio import AIProjectClient
from azure.ai.projects.models import MCPTool, PromptAgentDefinition
from azure.identity.aio import DefaultAzureCredential


def _json_array(name: str) -> list[str]:
    raw = os.environ.get(name)
    if not raw:
        raise EnvironmentError(f"{name} is required.")
    value = json.loads(raw)
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise ValueError(f"{name} must be a JSON array of strings.")
    return value


async def _mcp_tools(client: AIProjectClient) -> list[MCPTool]:
    tools = []
    async for connection in client.connections.list():
        if connection.type != "RemoteTool":
            continue
        full_connection = await client.connections.get(connection.name)
        target = getattr(full_connection, "target", None)
        if not target:
            continue
        label = connection.name.removeprefix("MCP-").lower()
        tools.append(
            MCPTool(
                server_label=label,
                server_url=target,
                require_approval="never",
                project_connection_id=connection.name,
            )
        )
    if not tools:
        raise RuntimeError("No shared RemoteTool (MCP) connections were found.")
    return tools


async def _create_agent(
    credential: DefaultAzureCredential,
    endpoint: str,
    project_name: str,
    deployment_name: str,
) -> None:
    suffix = "with-cap" if "-with-cap-" in project_name else "no-cap"
    agent_name = f"prompt-mcp-{suffix}"

    async with AIProjectClient(endpoint=endpoint, credential=credential) as client:
        tools = await _mcp_tools(client)
        agent = await client.agents.create_version(
            agent_name=agent_name,
            definition=PromptAgentDefinition(
                model=deployment_name,
                instructions=(
                    "You are a helpful assistant. Use the available MCP servers "
                    "when they can answer the user's request."
                ),
                tools=tools,
            ),
        )
        print(
            f"Created {agent.name} version {agent.version} in {project_name} "
            f"with {len(tools)} MCP server(s)."
        )


async def main() -> None:
    endpoints = _json_array("PROJECT_CONNECTION_STRINGS")
    project_names = _json_array("PROJECT_NAMES")
    deployment_name = os.environ.get("AZURE_OPENAI_CHAT_DEPLOYMENT_NAME")
    if not deployment_name:
        raise EnvironmentError("AZURE_OPENAI_CHAT_DEPLOYMENT_NAME is required.")
    if len(endpoints) != len(project_names):
        raise ValueError("Project connection strings and project names must have equal lengths.")

    credential = DefaultAzureCredential()
    async with credential:
        for endpoint, project_name in zip(endpoints, project_names, strict=True):
            await _create_agent(
                credential,
                endpoint,
                project_name,
                deployment_name,
            )


if __name__ == "__main__":
    asyncio.run(main())
