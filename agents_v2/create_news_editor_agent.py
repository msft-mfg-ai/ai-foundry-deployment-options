"""Create a Foundry news editor prompt agent backed by a versioned toolbox."""

import json
import os
import uuid
from dataclasses import dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

from azure.ai.projects import AIProjectClient
from azure.ai.projects.models import (
    CodeInterpreterToolboxTool,
    MCPTool,
    PromptAgentDefinition,
    SkillInlineContent,
    ToolboxSkillReference,
    ToolSearchToolboxTool,
    WebSearchToolboxTool,
)
from azure.identity import DefaultAzureCredential
from dotenv import load_dotenv


SKILLS_DIR = Path(__file__).parent / "skills"
SKILL_PATHS = (
    SKILLS_DIR / "weather-reporting" / "SKILL.md",
    SKILLS_DIR / "sports-reporting" / "SKILL.md",
    SKILLS_DIR / "ai-reporting" / "SKILL.md",
)
FOUNDRY_USER_ROLE_ID = "53ca6127-db72-4b80-b1b0-d745d6d5456d"

AGENT_INSTRUCTIONS = """
You are a rigorous news editor.

Before answering a weather, sports, or AI request, you must load and follow the
matching skill from the newsroom toolbox: `weather-reporting`,
`sports-reporting`, or `ai-reporting`. Do not answer without using the skill.

Use the toolbox's Web Search and Code Interpreter as directed by the selected
skill. Never invent facts, sources, quotations, statistics, or chart data.
""".strip()


@dataclass(frozen=True)
class SkillDocument:
    name: str
    description: str
    instructions: str


def required_env(*names: str) -> str:
    for name in names:
        value = os.environ.get(name)
        if value:
            if value.startswith("<") and value.endswith(">"):
                raise EnvironmentError(
                    f"{name} still contains the example placeholder {value}. "
                    "Set it to the real Azure resource value."
                )
            return value.rstrip("/")
    joined = ", ".join(names)
    raise EnvironmentError(f"Set one of these environment variables: {joined}")


def project_name_from_endpoint(endpoint: str) -> str:
    path_parts = urlparse(endpoint).path.strip("/").split("/")
    try:
        projects_index = path_parts.index("projects")
        return path_parts[projects_index + 1]
    except (ValueError, IndexError) as exc:
        raise ValueError(
            "FOUNDRY_PROJECT_ENDPOINT must end with /api/projects/<project-name>"
        ) from exc


def send_arm_request(
    *,
    credential: DefaultAzureCredential,
    request_url: str,
    method: str,
    body: dict | None = None,
    accepted_error_codes: frozenset[str] = frozenset(),
) -> dict:
    request_body = json.dumps(body).encode("utf-8") if body else None
    token = credential.get_token(
        "https://management.azure.com/.default"
    ).token
    request = Request(
        request_url,
        data=request_body,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )

    try:
        with urlopen(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as exc:
        error_body = exc.read().decode("utf-8", errors="replace")
        try:
            error_code = json.loads(error_body).get("error", {}).get("code")
        except json.JSONDecodeError:
            error_code = None
        if error_code in accepted_error_codes:
            return {}
        raise RuntimeError(
            f"ARM request failed: {method} {request_url}: "
            f"HTTP {exc.code}: {error_body}"
        ) from exc
    except URLError as exc:
        raise RuntimeError(
            f"ARM request failed: {method} {request_url}: {exc.reason}"
        ) from exc


def get_project_identity_principal_id(
    *,
    credential: DefaultAzureCredential,
    project_resource_id: str,
) -> str:
    project = send_arm_request(
        credential=credential,
        request_url=(
            f"https://management.azure.com{project_resource_id}"
            "?api-version=2025-06-01"
        ),
        method="GET",
    )
    principal_id = project.get("identity", {}).get("principalId")
    if not principal_id:
        raise RuntimeError(
            "The Foundry project does not have a system-assigned managed identity."
        )
    return principal_id


def ensure_foundry_user_role(
    *,
    credential: DefaultAzureCredential,
    subscription_id: str,
    account_resource_id: str,
    principal_id: str,
) -> None:
    role_definition_id = (
        f"/subscriptions/{subscription_id}/providers/Microsoft.Authorization"
        f"/roleDefinitions/{FOUNDRY_USER_ROLE_ID}"
    )
    assignment_id = uuid.uuid5(
        uuid.NAMESPACE_URL,
        f"{account_resource_id}|{principal_id}|{role_definition_id}",
    )
    send_arm_request(
        credential=credential,
        request_url=(
            f"https://management.azure.com{account_resource_id}"
            f"/providers/Microsoft.Authorization/roleAssignments/{assignment_id}"
            "?api-version=2022-04-01"
        ),
        method="PUT",
        body={
            "properties": {
                "roleDefinitionId": role_definition_id,
                "principalId": principal_id,
                "principalType": "ServicePrincipal",
            }
        },
        accepted_error_codes=frozenset({"RoleAssignmentExists"}),
    )


def create_project_identity_connection(
    *,
    credential: DefaultAzureCredential,
    project_resource_id: str,
    connection_name: str,
    target: str,
) -> str:
    resource_id = f"{project_resource_id}/connections/{connection_name}"
    request_url = (
        "https://management.azure.com"
        f"{'/'.join(quote(part, safe='') for part in resource_id.split('/'))}"
        "?api-version=2025-04-01-preview"
    )
    result = send_arm_request(
        credential=credential,
        request_url=request_url,
        method="PUT",
        body={
            "properties": {
                "authType": "ProjectManagedIdentity",
                "category": "RemoteTool",
                "target": target,
                "audience": "https://ai.azure.com",
            }
        },
    )
    return result.get("id", resource_id)


def load_skill(path: Path) -> SkillDocument:
    content = path.read_text(encoding="utf-8")
    if not content.startswith("---\n"):
        raise ValueError(f"{path} must start with YAML front matter")

    front_matter, separator, body = content[4:].partition("\n---\n")
    if not separator:
        raise ValueError(f"{path} has incomplete YAML front matter")

    metadata: dict[str, str] = {}
    for line in front_matter.splitlines():
        key, separator, value = line.partition(":")
        if not separator:
            raise ValueError(f"Invalid front matter line in {path}: {line}")
        metadata[key.strip()] = value.strip()

    try:
        return SkillDocument(
            name=metadata["name"],
            description=metadata["description"],
            instructions=body.strip(),
        )
    except KeyError as exc:
        raise ValueError(f"{path} is missing required field {exc.args[0]}") from exc


def main() -> None:
    load_dotenv()

    endpoint = required_env(
        "FOUNDRY_PROJECT_ENDPOINT",
        "FOUNDRY_PROJECT_CONNECTION_STRING",
        "AZURE_AI_FOUNDRY_CONNECTION_STRING",
    )
    model = required_env(
        "FOUNDRY_MODEL_NAME",
        "AZURE_OPENAI_CHAT_DEPLOYMENT_NAME",
    )
    subscription_id = required_env("AZURE_AI_FOUNDRY_SUBSCRIPTION_ID")
    resource_group = required_env("AZURE_AI_FOUNDRY_RESOURCE_GROUP")
    account_name = required_env("AZURE_AI_FOUNDRY_NAME")
    project_name = project_name_from_endpoint(endpoint)
    account_resource_id = (
        f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{account_name}"
    )
    project_resource_id = (
        f"{account_resource_id}/projects/{project_name}"
    )
    agent_name = os.environ.get("NEWS_EDITOR_AGENT_NAME", "news-editor")
    toolbox_name = os.environ.get("NEWS_EDITOR_TOOLBOX_NAME", "news-editor-toolbox")
    toolbox_connection_name = os.environ.get(
        "NEWS_EDITOR_TOOLBOX_CONNECTION_NAME",
        "news-editor-toolbox-project-identity",
    )
    skill_documents = [load_skill(path) for path in SKILL_PATHS]

    with (
        DefaultAzureCredential() as credential,
        AIProjectClient(
            endpoint=endpoint,
            credential=credential,
            allow_preview=True,
        ) as project_client,
    ):
        skill_versions = []
        for skill in skill_documents:
            created = project_client.beta.skills.create(
                name=skill.name,
                inline_content=SkillInlineContent(
                    description=skill.description,
                    instructions=skill.instructions,
                    metadata={"owner": "news-editor"},
                    allowed_tools=["web_search", "code_interpreter"],
                ),
            )
            skill_versions.append(created)
            print(f"Created skill {created.name} version {created.version}")

        toolbox_version = project_client.toolboxes.create_version(
            name=toolbox_name,
            description=(
                "Newsroom toolbox with web research, charting, and reporting skills "
                "for weather, sports, and artificial intelligence."
            ),
            tools=[
                WebSearchToolboxTool(
                    name="web_search",
                    description="Search the public web for current news and primary sources.",
                    search_context_size="high",
                ),
                CodeInterpreterToolboxTool(
                    name="code_interpreter",
                    description=(
                        "Analyze sourced data and create publication-ready news charts."
                    ),
                ),
                ToolSearchToolboxTool(),
            ],
            skills=[
                ToolboxSkillReference(
                    name=skill.name,
                    version=skill.version,
                )
                for skill in skill_versions
            ],
        )
        print(
            f"Created toolbox {toolbox_version.name} "
            f"version {toolbox_version.version}"
        )
        project_client.toolboxes.update(
            name=toolbox_name,
            default_version=toolbox_version.version,
        )
        print(
            f"Set toolbox {toolbox_name} default version to "
            f"{toolbox_version.version}"
        )

        toolbox_mcp_url = (
            f"{endpoint}/toolboxes/{toolbox_name}/mcp?api-version=v1"
        )
        project_identity_principal_id = get_project_identity_principal_id(
            credential=credential,
            project_resource_id=project_resource_id,
        )
        ensure_foundry_user_role(
            credential=credential,
            subscription_id=subscription_id,
            account_resource_id=account_resource_id,
            principal_id=project_identity_principal_id,
        )
        toolbox_connection_id = create_project_identity_connection(
            credential=credential,
            project_resource_id=project_resource_id,
            connection_name=toolbox_connection_name,
            target=toolbox_mcp_url,
        )
        print(
            f"Created or updated project connection "
            f"{toolbox_connection_name}"
        )
        toolbox_tool = MCPTool(
            server_label="newsroom-toolbox",
            server_url=toolbox_mcp_url,
            server_description=(
                "Web search, Code Interpreter, and weather, sports, and AI "
                "reporting skills."
            ),
            project_connection_id=toolbox_connection_id,
            require_approval="never",
        )

        agent = project_client.agents.create_version(
            agent_name=agent_name,
            definition=PromptAgentDefinition(
                model=model,
                instructions=AGENT_INSTRUCTIONS,
                tools=[toolbox_tool],
            ),
        )
        print(
            f"Created prompt agent {agent.name} version {agent.version} "
            f"with toolbox {toolbox_name} version {toolbox_version.version}"
        )


if __name__ == "__main__":
    main()
