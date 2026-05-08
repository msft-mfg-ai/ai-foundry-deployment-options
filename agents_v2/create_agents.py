"""
Create initial agents for an AI Foundry project after azd provisioning.

Reads environment variables set by azd from Bicep outputs:
  PROJECT_CONNECTION_STRINGS          JSON array of project connection strings
  FOUNDRY_PROJECTS_CONNECTION_STRINGS Fallback for older ai-gateway variants
  AZURE_OPENAI_CHAT_DEPLOYMENT_NAME   Model deployment to use (e.g. gpt-4.1-mini)
  OPENAPI_SPEC_FILE                   Path to an OpenAPI JSON spec; skipped if absent
  OPENAPI_SERVICE_URL                 Overrides servers[0].url in the spec (use APIM URL for private backends)

Agents created per project:
  agent-basic            No tools; model routed via discovered APIM gateway connection
  agent-mcp-{label}      One per RemoteTool (MCP) Foundry connection discovered
  agent-openapi          Only when OPENAPI_SPEC_FILE is set
"""

import asyncio
import json
import os
import sys

from azure.ai.projects.aio import AIProjectClient
from azure.ai.projects.models import MCPTool, OpenApiFunctionDefinition, OpenApiTool, OpenApiAnonymousAuthDetails
from azure.identity.aio import DefaultAzureCredential

# Allow running from any working directory
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "src"))
from agents_utils import agents_utils  # noqa: E402
from foundry_utils import get_gateway_connections  # noqa: E402


def _get_connection_strings() -> list[str]:
    # azd exports Bicep outputs with the exact output name (preserving case).
    # ai-gateway-internal uses lowercase: project_connection_strings
    # older variants use uppercase: FOUNDRY_PROJECTS_CONNECTION_STRINGS
    raw = (
        os.environ.get("project_connection_strings")
        or os.environ.get("PROJECT_CONNECTION_STRINGS")
        or os.environ.get("FOUNDRY_PROJECTS_CONNECTION_STRINGS")
    )
    if not raw:
        raise EnvironmentError(
            "Could not find project connection strings. "
            "Expected env var 'project_connection_strings' (or 'FOUNDRY_PROJECTS_CONNECTION_STRINGS')."
        )
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        # Single plain connection string
        parsed = [raw]
    return parsed if isinstance(parsed, list) else [parsed]


async def _get_mcp_connections(client: AIProjectClient) -> list[dict]:
    """Return list of {name, target} for RemoteTool connections (MCP)."""
    mcp_connections = []
    async for conn in client.connections.list():
        if conn.type == "RemoteTool":
            # Fetch full details to get target URL
            full = await client.connections.get(conn.name)
            target = getattr(full, "target", None)
            if target:
                mcp_connections.append({"name": conn.name, "target": target})
    return mcp_connections


async def _create_agents_for_project(conn_string: str, spec_file: str | None):
    credential = DefaultAzureCredential()
    async with credential:
        async with AIProjectClient(
            endpoint=conn_string, credential=credential
        ) as client:
            utils = agents_utils(client)

            # Discover gateway connections for model routing
            gateway_connections = await get_gateway_connections(client)
            model_connection = (
                gateway_connections.get("ai_gateway_connection_static")
                or gateway_connections.get("ai_gateway_connection_dynamic")
                or gateway_connections.get("model_gateway_connection_static")
                or gateway_connections.get("model_gateway_connection_dynamic")
            )

            if not model_connection:
                print(
                    "⚠️  No APIM/ModelGateway connection found — creating agents directly against "
                    f"the model deployment ({os.environ.get('AZURE_OPENAI_CHAT_DEPLOYMENT_NAME')})."
                )
            else:
                print(f"\n🔗 Using gateway connection: {model_connection}")

            # --- agent-basic ---
            print("\n📝 Creating agent-basic...")
            await utils.create_agent(
                name="agent-basic",
                model_gateway_connection=model_connection,
                instructions="You are a helpful assistant.",
            )

            # --- agent-mcp-{label} ---
            mcp_connections = await _get_mcp_connections(client)
            if mcp_connections:
                for mcp in mcp_connections:
                    # Derive a short label from the connection name (strip "MCP-" prefix)
                    label = mcp["name"].removeprefix("MCP-").lower()
                    agent_name = f"agent-mcp-{label}"
                    print(f"\n📝 Creating {agent_name} (server: {mcp['target']})...")
                    mcp_tool = MCPTool(
                        server_label=label,
                        server_url=mcp["target"],
                        require_approval="never",
                    )
                    await utils.create_agent(
                        name=agent_name,
                        model_gateway_connection=model_connection,
                        instructions=f"You are a helpful assistant with access to the {label} MCP tool.",
                        tools=[mcp_tool],
                    )
            else:
                print("ℹ️  No RemoteTool (MCP) connections found — skipping MCP agents.")

            # --- agent-openapi ---
            if spec_file:
                abs_spec = os.path.abspath(spec_file)
                if not os.path.exists(abs_spec):
                    print(f"⚠️  OPENAPI_SPEC_FILE '{abs_spec}' not found — skipping agent-openapi.")
                else:
                    with open(abs_spec) as f:
                        spec_dict = json.load(f)
                    # Allow caller to override the servers URL (e.g. route through APIM
                    # instead of calling the backend service directly).
                    service_url = os.environ.get("OPENAPI_SERVICE_URL")
                    if service_url:
                        spec_dict.setdefault("servers", [{}])
                        spec_dict["servers"][0]["url"] = service_url
                        print(f"ℹ️  Overriding OpenAPI server URL → {service_url}")
                    spec_name = os.path.splitext(os.path.basename(abs_spec))[0]
                    print(f"\n📝 Creating agent-openapi (spec: {abs_spec})...")
                    openapi_tool = OpenApiTool(
                        openapi=OpenApiFunctionDefinition(
                            name=spec_name,
                            spec=spec_dict,
                            auth=OpenApiAnonymousAuthDetails(),
                        )
                    )
                    await utils.create_agent(
                        name="agent-openapi",
                        model_gateway_connection=model_connection,
                        instructions="You are a helpful assistant with access to an OpenAPI tool.",
                        tools=[openapi_tool],
                    )
            else:
                print("ℹ️  OPENAPI_SPEC_FILE not set — skipping agent-openapi.")


async def main():
    conn_strings = _get_connection_strings()
    spec_file = os.environ.get("OPENAPI_SPEC_FILE")

    print(f"\n🚀 Creating agents for {len(conn_strings)} project(s)...")
    for i, conn in enumerate(conn_strings, 1):
        print(f"\n{'='*60}")
        print(f"Project {i}/{len(conn_strings)}: {conn[:80]}...")
        print("=" * 60)
        try:
            await _create_agents_for_project(conn, spec_file)
        except Exception as e:
            print(f"❌ Failed for project {i}: {e}")

    print("\n✅ Agent creation complete.")


if __name__ == "__main__":
    asyncio.run(main())
