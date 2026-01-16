#!/usr/bin/env python3
"""
Create 3 agents using Azure AI Projects SDK v2 (azure-ai-projects).
Each agent uses a different AI Search connection for file search.

Run with: uv run --directory ../../agents_v2 python ../../options-infra/option_foundry-search/scripts/create_agents_v2.py
"""

import asyncio
import os
import sys
from azure.identity.aio import DefaultAzureCredential
from azure.ai.projects.aio import AIProjectClient
from azure.ai.projects.models import (
    PromptAgentDefinition,
    AzureAISearchAgentTool,
    AzureAISearchToolResource,
    AISearchIndexResource,
    AzureAISearchQueryType,
    AzureAISearchIndex,
)

# Configuration - can be overridden by environment variables
FOUNDRY_ENDPOINT = os.environ.get("AI_PROJECT_CONNECTION_STRING")
DEPLOYMENT_NAME = os.environ.get("FOUNDRY_DEPLOYMENT_NAME", "gpt-4.1")

# AI Search connection names (created by Bicep at Foundry level)
SEARCH_CONNECTIONS = [
    os.environ.get("AI_SEARCH_SERVICE_PUBLIC_NO_PE_CONNECTION_NAME"),
    os.environ.get("AI_SEARCH_SERVICE_PUBLIC_PE_CONNECTION_NAME"),
    os.environ.get("AI_SEARCH_SERVICE_PE_CONNECTION_NAME"),
]

AGENT_CONFIGS = [
    {
        "name": "v2-search-agent-public-no-pe",
        "instructions": "You are a helpful book recommendation assistant using Azure AI Search. Search the books index to help users find great reads. When responding, be sure to cite the sources from the search results. If there's no relevant information, respond that you couldn't find any information.",
        "search_connection_index": 0,
    },
    {
        "name": "v2-search-agent-public-pe",
        "instructions": "You are a helpful book recommendation assistant using Azure AI Search. Search the books index to help users find great reads. When responding, be sure to cite the sources from the search results. If there's no relevant information, respond that you couldn't find any information.",
        "search_connection_index": 1,
    },
    {
        "name": "v2-search-agent-pe-only",
        "instructions": "You are a helpful book recommendation assistant using Azure AI Search. Search the books index to help users find great reads. When responding, be sure to cite the sources from the search results. If there's no relevant information, respond that you couldn't find any information.",
        "search_connection_index": 2,
    },
]


async def get_existing_agent(client: AIProjectClient, name: str):
    """Check if an agent with the given name already exists."""
    async for agent in client.agents.list():
        if agent.name == name:
            return agent
    return None


async def create_agent_with_search(
    client: AIProjectClient,
    name: str,
    instructions: str,
    search_connection_id: str,
    search_connection_name: str,
    index_name: str = "good-books-azd",
):
    """Create or update an agent with Azure AI Search tool."""

    index_for_agent = f"{index_name}-{search_connection_name}"

    await client.indexes.create_or_update(
        name=index_for_agent,
        version="1.0",
        index=AzureAISearchIndex(
            connection_name=search_connection_name,
            index_name=index_name,
            description=f"Index of good books for recommendation agent using {search_connection_name}",
        ),
    )
    print(f"  ➕ Created/Updated index: {index_for_agent}")

    # Check if agent exists
    existing_agent = await get_existing_agent(client, name)

    # Create Azure AI Search tool (SDK 2.0 structure)
    search_tool = AzureAISearchAgentTool(
        azure_ai_search=AzureAISearchToolResource(
            indexes=[
                AISearchIndexResource(
                    project_connection_id=search_connection_id,
                    index_name=index_name,
                    query_type=AzureAISearchQueryType.SIMPLE,
                ),
            ]
        )
    )

    definition = PromptAgentDefinition(
        model=DEPLOYMENT_NAME,
        instructions=instructions,
        tools=[search_tool],
    )

    if existing_agent:
        print(f"  📝 Updating existing agent: {name} with index {index_for_agent}")
        # Delete and recreate (v2 SDK pattern)
        delete_response = await client.agents.delete(agent_name=name)
        print(f"    🗑️  Deleted existing agent: {name}, response: {delete_response.deleted}")
        agent = await client.agents.create(
            name=name,
            definition=definition,
        )
    else:
        print(f"  ➕ Creating new agent: {name} with index {index_for_agent}")
        agent = await client.agents.create(
            name=name,
            definition=definition,
        )

    return agent


async def main():
    print("=" * 60)
    print("🤖 Creating V2 Agents with Azure AI Search")
    print("=" * 60)

    if not FOUNDRY_ENDPOINT:
        print("❌ Error: AI_PROJECT_CONNECTION_STRING environment variable not set")
        print("   Set it to the AI Foundry project endpoint URL")
        sys.exit(1)

    print(f"\n📍 Project endpoint: {FOUNDRY_ENDPOINT[:50]}...")
    print(f"🧠 Model: {DEPLOYMENT_NAME}")
    print(f"🔍 Search connections: {SEARCH_CONNECTIONS}")

    credential = DefaultAzureCredential()

    async with AIProjectClient(
        endpoint=FOUNDRY_ENDPOINT,
        credential=credential,
    ) as client:
        print("\n" + "-" * 60)
        print("Creating agents...")
        print("-" * 60)

        created_agents = []
        for config in AGENT_CONFIGS:
            search_connection = SEARCH_CONNECTIONS[config["search_connection_index"]]
            search_connection_id = (await client.connections.get(search_connection)).id
            print(f"\n🔧 Agent: {config['name']}")
            print(f"   🔗 Search connection: {search_connection}")

            try:
                agent = await create_agent_with_search(
                    client=client,
                    name=config["name"],
                    instructions=config["instructions"],
                    search_connection_id=search_connection_id,
                    search_connection_name=search_connection,
                )
                created_agents.append(agent)
                print(f"   ✅ Success! Agent ID: {agent.id}")
            except Exception as e:
                print(f"   ❌ Failed: {e}")

        print("\n" + "=" * 60)
        print("📊 SUMMARY")
        print("=" * 60)
        print(f"   Created/Updated: {len(created_agents)} agents")
        for agent in created_agents:
            print(f"   • {agent.name} (ID: {agent.id})")
        print()


if __name__ == "__main__":
    asyncio.run(main())
