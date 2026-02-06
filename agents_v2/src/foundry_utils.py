# List all AI Foundry projects using direct REST API call
import httpx
from azure.identity.aio import DefaultAzureCredential
from azure.ai.projects.aio import AIProjectClient


async def get_ai_foundry_projects(
    subscription_id: str,
    resource_group: str,
    account_name: str,
    api_version="2025-04-01-preview",
):
    url = f"https://management.azure.com/subscriptions/{subscription_id}/resourceGroups/{resource_group}/providers/Microsoft.CognitiveServices/accounts/{account_name}/projects?api-version={api_version}"

    creds = DefaultAzureCredential()
    # Get token for Azure Resource Manager
    token = await creds.get_token("https://management.azure.com/.default")

    async with httpx.AsyncClient() as http_client:
        response = await http_client.get(
            url, headers={"Authorization": f"Bearer {token.token}"}
        )

    print(f"Status: {response.status_code}")
    # print(f"Response: {response.text}")
    projects_data = response.json()

    print("\n--- AI Foundry Projects ---")
    project_names = []
    project_api_endpoints = []
    for project in projects_data.get("value", []):
        name = project.get("name")
        location = project.get("location")
        props = project.get("properties", {})
        endpoints = props.get("endpoints", {})
        api = endpoints.get("AI Foundry API", None)
        print(f"  Name: {name}, Location: {location}")
        print(f"    Endpoint: {api}")
        project_names.append(name)
        project_api_endpoints.append(api)

    print(f"\nTotal projects found: {len(project_names)}")
    print(f"Project names: {project_names}")
    return project_api_endpoints


async def get_gateway_connections(client: AIProjectClient):
    model_gateway_connection_static = None
    model_gateway_connection_dynamic = None
    ai_gateway_connection_static = None
    ai_gateway_connection_dynamic = None

    async for connection in client.connections.list():
        print(
            f"Connection ID: {connection.id}, Name: {connection.name}, Type: {connection.type} Default: {connection.is_default}"
        )
        if connection.type == "ModelGateway" and "static" in connection.name.lower():
            model_gateway_connection_static = connection.name
            print(
                f"  - Static Model gateway connection found: {model_gateway_connection_static}"
            )
        if (
            connection.type == "ModelGateway"
            and "static" not in connection.name.lower()
        ):
            model_gateway_connection_dynamic = connection.name
            print(
                f"  - Dynamic Model gateway connection found: {model_gateway_connection_dynamic}"
            )
        if connection.type == "ApiManagement" and "static" in connection.name.lower():
            ai_gateway_connection_static = connection.name
            print(
                f"  - Static API Management gateway connection found: {ai_gateway_connection_static}"
            )
        if (
            connection.type == "ApiManagement"
            and "static" not in connection.name.lower()
        ):
            ai_gateway_connection_dynamic = connection.name
            print(
                f"  - Dynamic API Management gateway connection found: {ai_gateway_connection_dynamic}"
            )
    return {
        "model_gateway_connection_static": model_gateway_connection_static,
        "model_gateway_connection_dynamic": model_gateway_connection_dynamic,
        "ai_gateway_connection_static": ai_gateway_connection_static,
        "ai_gateway_connection_dynamic": ai_gateway_connection_dynamic,
    }

# Helper function to classify connection type
def classify_connection(conn_name: str, gateway_connections: dict) -> tuple[str, str]:
    """Returns (gateway_type, mode) based on connection name and gateway_connections dict."""
    conn_lower = conn_name.lower()
    
    # Determine gateway type (APIM vs ModelGateway)
    if conn_name in [gateway_connections.get("ai_gateway_connection_static"), 
                     gateway_connections.get("ai_gateway_connection_dynamic")]:
        gateway_type = "APIM"
    elif conn_name in [gateway_connections.get("model_gateway_connection_static"),
                       gateway_connections.get("model_gateway_connection_dynamic")]:
        gateway_type = "ModelGateway"
    else:
        gateway_type = "Unknown"
    
    # Determine mode (static vs dynamic)
    mode = "static" if "static" in conn_lower else "dynamic"
    
    return gateway_type, mode

async def get_bing_grounding_connection(client: AIProjectClient):

    async for connection in client.connections.list():
        print(
            f"Connection ID: {connection.id}, Name: {connection.name}, Type: {connection.type} Default: {connection.is_default}"
        )
        if connection.type == "GroundingWithBingSearch":
            print(
                f"  Bing Grounding connection found: {connection.name}"
            )
            return connection.id
    return None