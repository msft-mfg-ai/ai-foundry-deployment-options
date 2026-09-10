# Copyright (c) Microsoft. All rights reserved.

import asyncio
import os
from pathlib import Path

from agent_framework import Agent, FileSkillsSource, SkillsProvider
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import FoundryToolbox, ResponsesHostServer
from azure.ai.projects.aio import AIProjectClient
from azure.ai.projects.models import CodeInterpreterTool
from azure.identity.aio import DefaultAzureCredential


def _enabled(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() not in {"0", "false", "no"}


async def main() -> None:
    credential = DefaultAzureCredential()
    project = AIProjectClient(
        endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        credential=credential,
    )
    openai = project.get_openai_client()
    container = None

    try:
        client = FoundryChatClient(
            project_client=project,
            model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        )
        tools = []
        instructions = [
            "You are a concise assistant. Use the available tools rather than "
            "claiming that you performed work without executing it."
        ]

        if os.environ.get("TOOLBOX_NAME"):
            tools.append(FoundryToolbox(credential))
            instructions.append(
                "Use the Foundry Toolbox for requests that require its connected services."
            )

        if _enabled("ENABLE_CODE_INTERPRETER"):
            container = await openai.containers.create(name="toolbox-agent-session")
            tools.append(CodeInterpreterTool(container=container.id))
            instructions.append(
                "Use Code Interpreter for calculations, data processing, charts, and "
                "file generation. Display charts inline and cite every generated file "
                "in the final response."
            )

        context_providers = []
        skills_directory = Path(__file__).parent / "skills"
        if _enabled("ENABLE_PPTX_SKILL") and skills_directory.is_dir():
            context_providers.append(
                SkillsProvider(
                    FileSkillsSource(str(skills_directory)),
                    disable_load_skill_approval=True,
                    disable_read_skill_resource_approval=True,
                )
            )

        agent = Agent(
            client=client,
            instructions="\n\n".join(instructions),
            tools=tools,
            context_providers=context_providers,
            default_options={
                "store": False,
                "include": ["code_interpreter_call.outputs"],
            },
        )

        await ResponsesHostServer(agent).run_async()
    finally:
        if container is not None:
            await openai.containers.delete(container.id)
        await openai.close()
        await project.close()
        await credential.close()


if __name__ == "__main__":
    asyncio.run(main())
