"""Create or update a Foundry prompt agent connected to Databricks Genie One."""

import asyncio
import os

from azure.ai.projects.aio import AIProjectClient
from azure.ai.projects.models import MCPTool, PromptAgentDefinition
from azure.identity.aio import DefaultAzureCredential


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise EnvironmentError(f"Missing required environment variable: {name}")
    return value


async def main() -> None:
    project_endpoint = required_env("FOUNDRY_PROJECT_CONNECTION_STRING")
    model = required_env("AZURE_OPENAI_CHAT_DEPLOYMENT_NAME")
    server_url = required_env("DATABRICKS_GENIE_ONE_MCP_URL")
    agent_name = os.environ.get("GENIE_AGENT_NAME", "agent-databricks-genie-one")
    connection_name = "databricks-genie-one"

    credential = DefaultAzureCredential()
    async with credential:
        async with AIProjectClient(endpoint=project_endpoint, credential=credential) as client:
            agent = await client.agents.create_version(
                agent_name=agent_name,
                definition=PromptAgentDefinition(
                    model=model,
                    instructions=(
                        "You are a data assistant. Use Databricks Genie One for questions "
                        "that require enterprise data, SQL analysis, or governed business insights. "
                        "Preserve the user's Databricks permissions and cite the returned source links."
                    ),
                    tools=[
                        MCPTool(
                            server_label="databricks-genie-one",
                            server_url=server_url,
                            require_approval="never",
                            project_connection_id=connection_name,
                        )
                    ],
                ),
            )
            print(
                f"Created agent version: name={agent.name}, "
                f"version={agent.version}, id={agent.id}"
            )


if __name__ == "__main__":
    asyncio.run(main())
