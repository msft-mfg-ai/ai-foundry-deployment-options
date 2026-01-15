#!/usr/bin/env python3
"""
Create 3 agents using Azure AI Agents SDK v1 (azure-ai-agents).
Each agent uses a different AI Search connection for file search.

Run with: uv run --directory ../../agents python ../../options-infra/option_foundry-search/scripts/create_agents_v1.py
"""

import asyncio
from json import tool
import os
import sys
from azure.identity import DefaultAzureCredential
from azure.ai.agents.aio import AgentsClient
from azure.ai.projects.aio import AIProjectClient
from azure.ai.agents.models import AzureAISearchTool, ToolDefinition, ToolResources
# Configuration - can be overridden by environment variables
FOUNDRY_CONNECTION_STRING = os.environ.get("AI_PROJECT_CONNECTION_STRING")
DEPLOYMENT_NAME = os.environ.get("FOUNDRY_DEPLOYMENT_NAME", "gpt-4.1")

# AI Search connection names (created by Bicep)
SEARCH_CONNECTIONS = [
    os.environ.get("AI_SEARCH_SERVICE_PUBLIC_NO_PE_CONNECTION_NAME"),
    os.environ.get("AI_SEARCH_SERVICE_PUBLIC_PE_CONNECTION_NAME"),
    os.environ.get("AI_SEARCH_SERVICE_PE_CONNECTION_NAME"),
]

AGENT_CONFIGS = [
    {
        "name": "v1-search-agent-public-no-pe",
        "instructions": "You are a helpful book recommendation assistant using Azure AI Search. Search the books index to help users find great reads. When responding, be sure to cite the sources from the search results. If there's no relevant information, respond that you couldn't find any information.",
        "search_connection_index": 0,
    },
    {
        "name": "v1-search-agent-public-pe",
        "instructions": "You are a helpful book recommendation assistant using Azure AI Search. Search the books index to help users find great reads. When responding, be sure to cite the sources from the search results. If there's no relevant information, respond that you couldn't find any information.",
        "search_connection_index": 1,
    },
    {
        "name": "v1-search-agent-pe-only",
        "instructions": "You are a helpful book recommendation assistant using Azure AI Search. Search the books index to help users find great reads. When responding, be sure to cite the sources from the search results. If there's no relevant information, respond that you couldn't find any information.",
        "search_connection_index": 2,
    },
]


async def create_agent_with_search(
    client: AgentsClient,
    name: str,
    instructions: str,
    search_connection_id: str,
    index_name: str = "good-books-azd",
):
    """Create or update an agent with Azure AI Search tool."""
    
    # Check if agent exists
    existing_agent = None
    async for agent in client.list_agents():
        if agent.name == name:
            existing_agent = agent
            break
    
    # Create Azure AI Search tool
    search_tool = AzureAISearchTool(
        index_connection_id=search_connection_id,
        index_name=index_name,
    )
            
    if existing_agent:
        print(f"  📝 Updating existing agent: {name} with search tool: {search_connection_id}")
        agent = await client.update_agent(
            agent_id=existing_agent.id,
            name=name,
            model=DEPLOYMENT_NAME,
            instructions=instructions,
            tools=search_tool.definitions,
            tool_resources=search_tool.resources,
        )
    else:
        print(f"  ➕ Creating new agent: {name} with search tool: {search_connection_id}")
        agent = await client.create_agent(
            name=name,
            model=DEPLOYMENT_NAME,
            instructions=instructions,
            tools=search_tool.definitions,
            tool_resources=search_tool.resources,
        )
    
    return agent


async def main():
    print("=" * 60)
    print("🤖 Creating V1 Agents with Azure AI Search")
    print("=" * 60)
    
    if not FOUNDRY_CONNECTION_STRING:
        print("❌ Error: AI_PROJECT_CONNECTION_STRING environment variable not set")
        sys.exit(1)
    
    print(f"\n📍 Foundry endpoint: {FOUNDRY_CONNECTION_STRING[:50]}...")
    print(f"🧠 Model: {DEPLOYMENT_NAME}")
    print(f"🔍 Search connections: {SEARCH_CONNECTIONS}")
    
    credential = DefaultAzureCredential()

    search_connection_ids = []

    async with AIProjectClient(
        endpoint=FOUNDRY_CONNECTION_STRING,
        credential=credential,
    ) as project_client:
        for conn_name in SEARCH_CONNECTIONS:
            connection = await project_client.connections.get(conn_name)
            search_connection_ids.append(connection.id)
        
    
    async with AgentsClient(
        endpoint=FOUNDRY_CONNECTION_STRING,
        credential=credential,
    ) as client:
        print("\n" + "-" * 60)
        print("Creating agents...")
        print("-" * 60)
        
        created_agents = []
        for config in AGENT_CONFIGS:
            search_connection = SEARCH_CONNECTIONS[config["search_connection_index"]]
            print(f"\n🔧 Agent: {config['name']}")
            print(f"   🔗 Search connection: {search_connection}")
            search_connection_id = search_connection_ids[config["search_connection_index"]]

            try:
                agent = await create_agent_with_search(
                    client=client,
                    name=config["name"],
                    instructions=config["instructions"],
                    search_connection_id=search_connection_id
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
