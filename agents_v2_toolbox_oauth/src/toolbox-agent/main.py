# Copyright (c) Microsoft. All rights reserved.

import asyncio
import os
from pathlib import Path
from typing import Any

from agent_framework import Agent, tool
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import FoundryToolbox, ResponsesHostServer
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential


def _session_path(relative_path: str) -> Path:
    configured_root = os.environ.get("SESSION_FILES_ROOT")
    default_root = Path("/files") if Path("/files").is_dir() else Path.home()
    root = Path(configured_root or default_root).resolve()
    path = (root / relative_path).resolve()
    if path != root and root not in path.parents:
        raise ValueError("Path must remain inside the hosted session directory.")
    return path


@tool
def list_session_files(directory: str = ".") -> list[str]:
    """List files in a directory within the hosted agent session."""
    path = _session_path(directory)
    root = _session_path(".")
    return sorted(str(item.relative_to(root)) for item in path.iterdir())


def _process_session_file_with_native_code_interpreter(
    file_path: str,
    task: str,
) -> dict[str, Any]:
    source_path = _session_path(file_path)
    if not source_path.is_file():
        raise FileNotFoundError(f"Session file not found: {file_path}")

    credential = DefaultAzureCredential()
    project = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=credential,
    )
    openai = project.get_openai_client()
    container = openai.containers.create(name=f"session-file-{source_path.stem[:40]}")

    try:
        with source_path.open("rb") as source:
            openai.containers.files.create(container.id, file=source)

        response = openai.responses.create(
            model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
            input=(
                f"{task}\n\n"
                "Use the file attached to the Code Interpreter container. Save "
                "every requested output file and cite it in the final response "
                "so it can be downloaded."
            ),
            tools=[
                {
                    "type": "code_interpreter",
                    "container": container.id,
                }
            ],
        )

        output_text: list[str] = []
        generated_files: list[str] = []
        for item in response.output:
            for content in getattr(item, "content", []) or []:
                text = getattr(content, "text", None)
                if text:
                    output_text.append(text)

                for annotation in getattr(content, "annotations", []) or []:
                    if getattr(annotation, "type", None) != "container_file_citation":
                        continue

                    destination = _session_path(Path(annotation.filename).name)
                    file_content = openai.containers.files.content.retrieve(
                        file_id=annotation.file_id,
                        container_id=annotation.container_id,
                    )
                    destination.write_bytes(file_content.read())
                    generated_files.append(
                        str(destination.relative_to(_session_path(".")))
                    )

        return {
            "response": "\n".join(output_text),
            "generated_files": generated_files,
        }
    finally:
        openai.containers.delete(container.id)
        openai.close()
        project.close()
        credential.close()


@tool
async def process_session_file_with_code_interpreter(
    file_path: str,
    task: str,
) -> dict[str, Any]:
    """Attach a session file to native Code Interpreter, run a task, and copy generated files back to the session."""
    # Toolbox currently ignores explicit container IDs and creates a new automatic
    # container, so runtime session files must use the native container/files API.
    return await asyncio.to_thread(
        _process_session_file_with_native_code_interpreter,
        file_path,
        task,
    )


async def main() -> None:
    credential = DefaultAzureCredential()
    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        credential=credential,
    )
    if os.environ.get("CODE_INTERPRETER_MODE") == "native":
        instructions = (
            "You are a concise file-analysis agent. Use list_session_files to "
            "discover uploads, then use process_session_file_with_code_interpreter "
            "for all analysis, transformations, and generated artifacts. State the "
            "exact downloadable session paths returned by the tool."
        )
        tools = [
            list_session_files,
            process_session_file_with_code_interpreter,
        ]
    else:
        instructions = (
            "You are a concise toolbox diagnostic agent. Always use the OAuth "
            "pass-through MCP tools when requested, and state which tool you used."
        )
        tools = FoundryToolbox(credential)

    agent = Agent(
        client=client,
        instructions=instructions,
        tools=tools,
        default_options={"store": False},
    )

    server = ResponsesHostServer(agent)
    await server.run_async()


if __name__ == "__main__":
    asyncio.run(main())
