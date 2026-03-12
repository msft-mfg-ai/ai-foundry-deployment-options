#!/usr/bin/env python3
"""
Create 3 agents using Azure AI Agents SDK v1 (azure-ai-agents).
Each agent uses a different AI Search connection for file search.

Run with: uv run --directory ../../agents python ../../options-infra/option_foundry-search/scripts/create_agents_v1.py
"""

import asyncio
import os
import sys
from azure.identity import DefaultAzureCredential
from azure.ai.agents.aio import AgentsClient
from azure.ai.projects.aio import AIProjectClient
from azure.ai.agents.models import AzureAISearchTool, AzureAISearchQueryType
from azure.ai.projects.models import AzureAISearchIndex, FieldMapping

# Configuration - can be overridden by environment variables
FOUNDRY_CONNECTION_STRING = os.environ.get("AI_PROJECT_CONNECTION_STRING")
# gpt-5-mini: Best balance of cost/performance for RAG, no registration required
# Alternatives: gpt-5 (requires registration), gpt-4.1 (good but older), gpt-4o (legacy)
DEPLOYMENT_NAME = os.environ.get("FOUNDRY_CHAT_DEPLOYMENT_NAME", "gpt-5-mini")

# AI Search connection name (created by Bicep)
SEARCH_CONNECTION = os.environ.get("AI_SEARCH_SERVICE_PUBLIC_PE_CONNECTION_NAME")

HR_AGENT_INSTRUCTIONS = """You are an HR Assistant. Answer HR questions using ONLY information from search results.

WORKFLOW FOR EVERY QUESTION:
1. IMMEDIATELY call the azure_ai_search tool - do this NOW before responding
2. Read the search results carefully
3. Answer using ONLY facts from the search results
4. Cite sources using the file_name field: [Source: filename.pdf]

If the question is not HR-related, say: "I can only help with HR questions."
If search returns nothing relevant, say: "I searched our HR documents but found no information on this topic."

NEVER say "I will look this up" - just DO the search immediately.
NEVER answer from general knowledge - ONLY from search results.
NEVER make up information.

Topics you handle: benefits, PTO, leave policies, onboarding, performance reviews, compensation, workplace policies, training.
"""

AGENT_CONFIGS = [
    {
        "name": "v1-hr-agent",
        "instructions": HR_AGENT_INSTRUCTIONS,
        "index_name": "documents",
        "query_type": AzureAISearchQueryType.VECTOR_SIMPLE_HYBRID,
    },
    {
        "name": "v1-hr-agent-semantic",
        "instructions": HR_AGENT_INSTRUCTIONS,
        "index_name": "documents",
        "query_type": AzureAISearchQueryType.VECTOR_SEMANTIC_HYBRID,
    },
    {
        "name": "v1-hr-agent-indexer",
        "instructions": HR_AGENT_INSTRUCTIONS,
        "index_name": "documents-indexer",
        "query_type": AzureAISearchQueryType.VECTOR_SIMPLE_HYBRID,
    },
    {
        "name": "v1-hr-agent-indexer-semantic",
        "instructions": HR_AGENT_INSTRUCTIONS,
        "index_name": "documents-indexer",
        "query_type": AzureAISearchQueryType.VECTOR_SEMANTIC_HYBRID,
    },
]


async def create_agent_with_search(
    client: AgentsClient,
    project_client: AIProjectClient,
    name: str,
    instructions: str,
    search_connection_id: str,
    search_connection_name: str,
    index_name: str = "documents",
    query_type: AzureAISearchQueryType = AzureAISearchQueryType.SIMPLE,
):
    """Create or update an agent with Azure AI Search tool."""

    # Create an index in the AI Foundry project that wraps the Azure AI Search index
    # This enables proper content retrieval and grounding
    project_index_name = f"{index_name}-{search_connection_name}"

    # Define field mappings to tell the agent which fields contain the content
    # This maps our custom index schema to what the agent expects
    # The 'citation' field contains: "[file_name](blob_url) - Page N"
    field_mapping = FieldMapping(
        content_fields=[
            "content",
            "content_markdown",
            "table_markdown",
            "image_description",
        ],
        title_field="file_name",
        url_field="citation",  # Combined citation with file name, URL, and page number
        filepath_field="file_path",
        metadata_fields=["chunk_type", "page_number"],
        vector_fields=["content_vector"],
    )

    await project_client.indexes.create_or_update(
        name=project_index_name,
        version="1.0",
        index=AzureAISearchIndex(
            connection_name=search_connection_name,
            index_name=index_name,
            description=f"HR documents index using {search_connection_name}",
            field_mapping=field_mapping,
        ),
    )
    print(
        f"  ➕ Created/Updated project index: {project_index_name} with field mappings"
    )

    # Check if agent exists
    existing_agent = None
    async for agent in client.list_agents():
        if agent.name == name:
            existing_agent = agent
            break

    # Create Azure AI Search tool with hybrid search (vector + keyword + semantic)
    search_tool = AzureAISearchTool(
        index_connection_id=search_connection_id,
        index_name=index_name,
        query_type=query_type,
        top_k=30 if query_type == AzureAISearchQueryType.VECTOR_SEMANTIC_HYBRID else 10,
    )

    if existing_agent:
        print(
            f"  📝 Updating existing 🤖 agent: {name} with search tool: {search_connection_id}"
        )
        agent = await client.update_agent(
            agent_id=existing_agent.id,
            name=name,
            model=DEPLOYMENT_NAME,
            instructions=instructions,
            tools=search_tool.definitions,
            tool_resources=search_tool.resources,
        )
    else:
        print(
            f"  ➕ Creating new 🤖 agent: {name} with search tool: {search_connection_id}"
        )
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

    print(f"\n📍 Foundry endpoint: {FOUNDRY_CONNECTION_STRING}...")
    print(f"🧠 Model: {DEPLOYMENT_NAME}")
    print(f"🔍 Search connection: {SEARCH_CONNECTION}")

    credential = DefaultAzureCredential()

    async with AIProjectClient(
        endpoint=FOUNDRY_CONNECTION_STRING,
        credential=credential,
    ) as project_client:
        search_connection = await project_client.connections.get(SEARCH_CONNECTION)
        search_connection_id = search_connection.id

        async with AgentsClient(
            endpoint=FOUNDRY_CONNECTION_STRING,
            credential=credential,
        ) as client:
            print("\n" + "-" * 60)
            print("Creating agents...")
            print("-" * 60)

            created_agents = []
            for config in AGENT_CONFIGS:
                print(f"\n🔧 Agent: {config['name']}")
                print(f"   🔗 Search connection: {SEARCH_CONNECTION}")

                try:
                    agent = await create_agent_with_search(
                        client=client,
                        project_client=project_client,
                        name=config["name"],
                        instructions=config["instructions"],
                        search_connection_id=search_connection_id,
                        search_connection_name=SEARCH_CONNECTION,
                        index_name=config["index_name"],
                        query_type=config["query_type"],
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
