"""
Master Agent - Orchestrates tasks and delegates to specialized agents.

This module wraps the Master Agent, which is responsible for:
- Understanding user requests
- Delegating to the Large Context Agent for file processing
- Providing capabilities and status information
- Orchestrating multi-step tasks

(Single Responsibility Principle - this class only handles Master Agent operations)
"""

from datetime import date
import uuid
from typing import Optional, Annotated, Callable, AsyncIterator

from semantic_kernel import Kernel
from semantic_kernel.functions import KernelArguments, kernel_function
from semantic_kernel.agents import AzureAIAgent, AzureAIAgentThread
from semantic_kernel.contents import FunctionCallContent, FunctionResultContent
from semantic_kernel.contents.chat_message_content import (
    ChatMessageContent,
    TextContent,
)

from agents.base import BaseAgent, AgentInvoker
from instructions import MASTER_AGENT_INSTRUCTIONS
from models import InvokeResult
from telemetry import get_tracer, get_logger
from plugins import KnowledgePlugin

logger = get_logger("master_agent")
tracer = get_tracer("master_agent")


class MasterAgentPlugin:
    """Plugin that provides tools for the Master Agent.

    Uses AgentInvoker protocol to invoke Large Context Agent,
    following Dependency Inversion Principle.
    """

    def __init__(self, invoker: AgentInvoker):
        self._invoker = invoker
        self.knowledge_plugin = KnowledgePlugin()

    @kernel_function(
        name="invoke_large_context_agent",
        description="Invoke the Large Context Agent to process and summarize a SINGLE file. Call this tool once per file - if you have 3 files, call this 3 times.",
    )
    async def invoke_large_context_agent(
        self,
        task_description: Annotated[str, "Description of what to do with the file"],
        file_name: Annotated[str, "The name of a SINGLE file to process"],
        arguments: KernelArguments,
    ) -> Annotated[str, "Result from the Large Context Agent"]:
        """Invoke the Large Context Agent for a single file."""
        user_id = arguments.get("user_id", "anonymous")
        user_name = (
            f"{arguments.get('user_first_name', '')} {arguments.get('user_last_name', '')}".strip()
            or "Anonymous"
        )

        logger.info(
            f"Master Agent invoking Large Context Agent for file: {file_name} (user: {user_name}, id: {user_id})"
        )

        message = f"Process the following file: {file_name}\n\nTask: {task_description}\n\nRequested by: {user_name}"

        result = await self._invoker.invoke_large_context_agent(
            message=message,
            user_id=user_id,
            user_first_name=arguments.get("user_first_name"),
            user_last_name=arguments.get("user_last_name"),
        )

        return result.response

    @kernel_function(
        name="get_capabilities",
        description="Get information about what the agent can do and its capabilities",
    )
    async def get_capabilities(
        self,
        arguments: KernelArguments,
    ) -> Annotated[str, "Agent capabilities information"]:
        """Return agent capabilities with personalized greeting."""
        user_name = f"{arguments.get('user_first_name', '')} {arguments.get('user_last_name', '')}".strip()
        capabilities = await self.knowledge_plugin.get_capabilities()
        if user_name:
            return f"Hello {user_name}!\n\n{capabilities}"
        return capabilities

    @kernel_function(
        name="get_system_status",
        description="Get the current system status and health information",
    )
    async def get_system_status(
        self,
        arguments: KernelArguments,
    ) -> Annotated[str, "System status information"]:
        """Return system status."""
        user_id = arguments.get("user_id", "anonymous")
        logger.info(f"System status requested by user: {user_id}")
        return await self.knowledge_plugin.get_system_status()


async def on_intermediate_message(agent_response: ChatMessageContent):
    """Handle intermediate messages from the agent during streaming."""
    logger.info("Intermediate response from Agent")
    for item in agent_response.items or []:
        if isinstance(item, FunctionResultContent):
            result_preview = (
                str(item.result)[:100] + "..."
                if len(str(item.result)) > 100
                else str(item.result)
            )
            logger.info(f"Function Result for '{item.name}': {result_preview}")
        elif isinstance(item, FunctionCallContent):
            logger.info(f"Function Call: {item.name} with arguments: {item.arguments}")
        elif isinstance(item, TextContent):
            text_preview = (
                item.text[:100] + "..." if len(item.text) > 100 else item.text
            )
            logger.info(f"Text: {text_preview}")
        else:
            logger.info(f"Other content: {type(item).__name__}")


class MasterAgentWrapper(BaseAgent):
    """Wrapper for the Master Agent.

    Manages the Master Agent lifecycle and invocation.
    Each invocation creates a new thread to support concurrent users.
    """

    def __init__(self, invoker: AgentInvoker):
        self._agent: Optional[AzureAIAgent] = None
        self._definition = None
        self._client = None
        self._plugin = MasterAgentPlugin(invoker)
        self._invoker = invoker

    @property
    def agent_id(self) -> Optional[str]:
        return self._definition.id if self._definition else None

    @property
    def agent_name(self) -> str:
        return "MasterAgent"

    @property
    def is_ready(self) -> bool:
        return self._agent is not None

    @property
    def plugin(self) -> MasterAgentPlugin:
        """Get the plugin instance (for mock mode)."""
        return self._plugin

    async def setup(self, client, settings, existing_agents: dict) -> None:
        """Setup the Master Agent in Azure AI Foundry."""
        self._client = client

        if self.agent_name in existing_agents:
            self._definition = existing_agents[self.agent_name]
            logger.info(f"Updating existing Master Agent: {self._definition.id}")
            self._definition = await client.agents.update_agent(
                agent_id=self._definition.id,
                instructions=MASTER_AGENT_INSTRUCTIONS,
                model=settings.model_deployment_name,
                temperature=0.2,
            )
            logger.info(f"Updated Master Agent: {self._definition.id}")
        else:
            logger.info("Creating new Master Agent...")
            self._definition = await client.agents.create_agent(
                model=settings.model_deployment_name,
                name=self.agent_name,
                instructions=MASTER_AGENT_INSTRUCTIONS,
                temperature=0.2,
            )
            logger.info(f"Created Master Agent: {self._definition.id}")

        self._agent = AzureAIAgent(
            client=client,
            definition=self._definition,
            plugins=[self._plugin],
            kernel=Kernel(),
        )

        logger.info(
            f"Master Agent ready - ID: {self._definition.id}, Name: {self._definition.name}"
        )

    async def invoke(
        self,
        message: str,
        user_id: Optional[str] = None,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
        on_intermediate: Optional[Callable[[ChatMessageContent], None]] = None,
        **kwargs,
    ) -> InvokeResult:
        """Invoke the Master Agent with a message."""
        request_id = str(uuid.uuid4())

        with tracer.start_as_current_span("master_agent_invoke") as span:
            span.set_attribute("message.length", len(message))
            span.set_attribute("request.id", request_id)
            if user_id:
                span.set_attribute("user.id", user_id)

            plugins_invoked = []
            thread = None

            try:
                if not self._agent:
                    raise RuntimeError("Master Agent not initialized")

                thread = AzureAIAgentThread(client=self._client)
                user_display = (
                    f"{user_first_name or ''} {user_last_name or ''}".strip()
                    or user_id
                    or "anonymous"
                )
                logger.info(
                    f"Created new Master Agent thread for user: {user_display} (request: {request_id})"
                )

                arguments = KernelArguments(
                    user_id=user_id or "anonymous",
                    user_first_name=user_first_name or "",
                    user_last_name=user_last_name or "",
                    request_id=request_id,
                )

                response_text = ""
                response_count = 0
                additional_instructions = (
                    f"Today is {date.today().strftime('%Y-%m-%d')}. "
                    f"You are assisting user: {user_display}."
                )

                logger.info(f"Invoking Master Agent with message: {message[:100]}...")

                async for agent_response in self._agent.invoke(
                    messages=message,
                    thread=thread,
                    arguments=arguments,
                    additional_instructions=additional_instructions,
                    on_intermediate_message=on_intermediate or on_intermediate_message,
                    parallel_tool_calls=True,
                ):
                    response_count += 1
                    logger.info(f"Processing response #{response_count}")

                    for item in agent_response.items or []:
                        if isinstance(item, TextContent):
                            response_text = item.text
                            logger.info(f"Got text response: {response_text[:100]}...")
                        elif isinstance(item, FunctionCallContent):
                            plugins_invoked.append(item.name)
                            logger.info(f"Function called: {item.name}")
                        elif isinstance(item, FunctionResultContent):
                            logger.info(f"Function result for: {item.name}")

                    thread = agent_response.thread

                logger.info(
                    f"Master Agent completed for user {user_id or 'anonymous'}. Processed {response_count} responses."
                )

                if not response_text and agent_response:
                    response_text = (
                        str(agent_response.content)
                        if agent_response.content
                        else str(agent_response)
                    )

                try:
                    await thread.delete()
                    logger.info(f"Deleted thread for request: {request_id}")
                except Exception as cleanup_error:
                    logger.warning(f"Failed to delete thread: {cleanup_error}")

                span.set_attribute("response.length", len(response_text))
                span.set_attribute("plugins.invoked", ", ".join(plugins_invoked))

                return InvokeResult(
                    response=response_text,
                    agent_used="master_agent",
                    plugins_invoked=plugins_invoked,
                )

            except Exception as e:
                logger.exception(f"Error in master agent: {e}")
                span.record_exception(e)

                return InvokeResult(
                    response=f"I encountered an error processing your request: {str(e)}. Please try again.",
                    agent_used="master_agent",
                    plugins_invoked=plugins_invoked,
                )

    async def invoke_stream(
        self,
        message: str,
        user_id: Optional[str] = None,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
        **kwargs,
    ) -> AsyncIterator[str]:
        """Invoke the Master Agent with streaming response."""
        request_id = str(uuid.uuid4())

        with tracer.start_as_current_span("master_agent_invoke_stream") as span:
            span.set_attribute("message.length", len(message))
            span.set_attribute("request.id", request_id)
            if user_id:
                span.set_attribute("user.id", user_id)

            thread = None

            try:
                if not self._agent:
                    raise RuntimeError("Master Agent not initialized")

                thread = AzureAIAgentThread(client=self._client)
                user_display = (
                    f"{user_first_name or ''} {user_last_name or ''}".strip()
                    or user_id
                    or "anonymous"
                )

                arguments = KernelArguments(
                    user_id=user_id or "anonymous",
                    user_first_name=user_first_name or "",
                    user_last_name=user_last_name or "",
                    request_id=request_id,
                )

                additional_instructions = (
                    f"Today is {date.today().strftime('%Y-%m-%d')}. "
                    f"You are assisting user: {user_display}."
                )

                async for agent_response in self._agent.invoke(
                    messages=message,
                    thread=thread,
                    arguments=arguments,
                    additional_instructions=additional_instructions,
                    on_intermediate_message=on_intermediate_message,
                    parallel_tool_calls=True,
                ):
                    for item in agent_response.items or []:
                        if isinstance(item, TextContent):
                            yield item.text
                        elif isinstance(item, FunctionCallContent):
                            yield f"\n[Calling tool: {item.name}]\n"
                        elif isinstance(item, FunctionResultContent):
                            yield f"\n[Tool {item.name} completed]\n"

                    thread = agent_response.thread

                try:
                    await thread.delete()
                except Exception:
                    pass

            except Exception as e:
                logger.exception(f"Error in streaming: {e}")
                yield f"Error: {str(e)}"
