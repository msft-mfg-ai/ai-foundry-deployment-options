"""
Large Context Agent - Handles file processing and large context operations.

This module wraps the Large Context Agent, which is responsible for:
- Processing files and extracting content
- Summarizing and analyzing documents
- Handling large context window operations

(Single Responsibility Principle - this class only handles Large Context Agent operations)
"""

from typing import Optional, AsyncIterator

from semantic_kernel import Kernel
from semantic_kernel.functions import KernelArguments
from semantic_kernel.agents import AzureAIAgent, AzureAIAgentThread
from semantic_kernel.contents import FunctionCallContent
from semantic_kernel.contents.chat_message_content import TextContent

from agents.base import BaseAgent
from instructions import LARGE_CONTEXT_AGENT_INSTRUCTIONS
from models import InvokeResult
from telemetry import get_tracer, get_logger
from plugins import FileProcessorPlugin

logger = get_logger("large_context_agent")
tracer = get_tracer("large_context_agent")


class LargeContextAgentPlugin:
    """Plugin that provides file processing tools for the Large Context Agent."""

    def __init__(self, file_processor: FileProcessorPlugin):
        self._file_processor = file_processor

    async def process_file(self, file_name: str) -> str:
        """Process a file and return its content."""
        logger.info(f"Large Context Agent processing file: {file_name}")
        return await self._file_processor.process_file(file_name)


class LargeContextAgentWrapper(BaseAgent):
    """Wrapper for the Large Context Agent.

    Manages the Large Context Agent lifecycle and invocation.
    Each invocation creates a new thread to support concurrent users.
    """

    def __init__(self, file_processor: FileProcessorPlugin):
        self._agent: Optional[AzureAIAgent] = None
        self._definition = None
        self._client = None
        self._plugin = LargeContextAgentPlugin(file_processor)
        self._file_processor = file_processor

    @property
    def agent_id(self) -> Optional[str]:
        return self._definition.id if self._definition else None

    @property
    def agent_name(self) -> str:
        return "LargeContextAgent"

    @property
    def is_ready(self) -> bool:
        return self._agent is not None

    async def setup(self, client, settings, existing_agents: dict) -> None:
        """Setup the Large Context Agent in Azure AI Foundry."""
        self._client = client

        if self.agent_name in existing_agents:
            # Update existing agent
            self._definition = existing_agents[self.agent_name]
            logger.info(f"Updating existing Large Context Agent: {self._definition.id}")
            self._definition = await client.agents.update_agent(
                agent_id=self._definition.id,
                instructions=LARGE_CONTEXT_AGENT_INSTRUCTIONS,
                model=settings.model_deployment_name,
                temperature=0.2,
            )
            logger.info(f"Updated Large Context Agent: {self._definition.id}")
        else:
            # Create new agent
            logger.info("Creating new Large Context Agent...")
            self._definition = await client.agents.create_agent(
                model=settings.model_deployment_name,
                name=self.agent_name,
                instructions=LARGE_CONTEXT_AGENT_INSTRUCTIONS,
                temperature=0.2,
            )
            logger.info(f"Created Large Context Agent: {self._definition.id}")

        # Create the Semantic Kernel AzureAIAgent with plugin
        # Note: We use kernel_function decorator in the plugin class
        from semantic_kernel.functions import kernel_function
        from typing import Annotated

        # Create a proper SK plugin class with kernel_function decorator
        class SKLargeContextPlugin:
            def __init__(self, file_processor: FileProcessorPlugin):
                self._file_processor = file_processor

            @kernel_function(
                name="process_file",
                description="Process a file and return its content for analysis. Use this to fetch file content before summarizing.",
            )
            async def process_file(
                self, file_name: Annotated[str, "The name of the file to process"]
            ) -> Annotated[str, "The processed file content"]:
                """Process a file and return its content."""
                logger.info(f"Large Context Agent processing file: {file_name}")
                return await self._file_processor.process_file(file_name)

        self._sk_plugin = SKLargeContextPlugin(self._file_processor)

        self._agent = AzureAIAgent(
            client=client,
            definition=self._definition,
            plugins=[self._sk_plugin],
            kernel=Kernel(),
        )

        logger.info(
            f"Large Context Agent ready - ID: {self._definition.id}, Name: {self._definition.name}"
        )

    async def invoke(
        self,
        message: str,
        user_id: Optional[str] = None,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
        **kwargs,
    ) -> InvokeResult:
        """Invoke the Large Context Agent with a message."""
        with tracer.start_as_current_span("large_context_agent_invoke") as span:
            span.set_attribute("message.length", len(message))
            if user_id:
                span.set_attribute("user.id", user_id)

            plugins_invoked = []
            thread = None

            try:
                if not self._agent:
                    raise RuntimeError("Large Context Agent not initialized")

                # Create a NEW thread for each invocation
                thread = AzureAIAgentThread(client=self._client)
                logger.info(
                    f"Created new Large Context Agent thread for user: {user_id or 'anonymous'}"
                )

                # Create per-request KernelArguments
                arguments = KernelArguments(
                    user_id=user_id or "anonymous",
                    user_first_name=user_first_name or "",
                    user_last_name=user_last_name or "",
                )

                response_text = ""

                logger.info(
                    f"Invoking Large Context Agent with message: {message[:100]}..."
                )

                async for agent_response in self._agent.invoke(
                    messages=message,
                    thread=thread,
                    arguments=arguments,
                ):
                    for item in agent_response.items or []:
                        if isinstance(item, TextContent):
                            response_text = item.text
                        elif isinstance(item, FunctionCallContent):
                            plugins_invoked.append(item.name)

                    thread = agent_response.thread

                if not response_text and agent_response:
                    response_text = (
                        str(agent_response.content)
                        if agent_response.content
                        else str(agent_response)
                    )

                # Clean up thread
                try:
                    await thread.delete()
                except Exception as cleanup_error:
                    logger.warning(f"Failed to delete thread: {cleanup_error}")

                return InvokeResult(
                    response=response_text,
                    agent_used="large_context_agent",
                    plugins_invoked=plugins_invoked,
                )

            except Exception as e:
                logger.exception(f"Error in Large Context Agent: {e}")
                span.record_exception(e)

                return InvokeResult(
                    response=f"Error processing file: {str(e)}",
                    agent_used="large_context_agent",
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
        """Invoke the Large Context Agent with streaming response."""
        # Large Context Agent typically returns complete responses
        # so we just yield the full result
        result = await self.invoke(
            message=message,
            user_id=user_id,
            user_first_name=user_first_name,
            user_last_name=user_last_name,
            **kwargs,
        )
        yield result.response

    async def mock_response(self, message: str) -> str:
        """Generate mock response for testing without Azure connection."""
        if ":" in message:
            file_name = message.split(":")[-1].strip().split("\n")[0].strip()
        else:
            file_name = "unknown_file"

        content = await self._plugin.process_file(file_name)

        return f"""
## Large Context Agent Analysis

**File:** {file_name}

### Summary
{content}

### Key Points
- This is a mock response from the Large Context Agent
- In production, this agent uses Azure AI Foundry to analyze content
- The file processor service was called to retrieve the file content
"""
