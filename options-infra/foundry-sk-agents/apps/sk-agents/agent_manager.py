"""
Agent Manager - Facade for managing agents using Semantic Kernel with Azure AI Foundry.

This is the main entry point for agent operations. It follows the Facade pattern
to provide a simplified interface to the complex agent subsystem.

Responsibilities:
- Initialize and coordinate agents (delegated to agent wrappers)
- Provide a unified interface for routes.py
- Handle mock mode when Azure is not configured

SOLID Principles applied:
- Single Responsibility: Each agent wrapper handles its own logic
- Open/Closed: New agents can be added without modifying this class
- Liskov Substitution: Agents implement BaseAgent interface
- Interface Segregation: AgentInvoker protocol for loose coupling
- Dependency Inversion: Depends on abstractions (BaseAgent, AgentInvoker)
"""

from typing import Optional, Callable, AsyncIterator

from azure.identity.aio import DefaultAzureCredential
from semantic_kernel.agents import AzureAIAgent, AzureAIAgentSettings
from semantic_kernel.contents.chat_message_content import ChatMessageContent

from config import settings
from models import InvokeResult
from telemetry import get_tracer, get_logger
from plugins import FileProcessorPlugin

from agents.master_agent import MasterAgentWrapper
from agents.large_context_agent import LargeContextAgentWrapper
from agents.mock_responses import MockResponseGenerator

logger = get_logger("agent_manager")
tracer = get_tracer("agent_manager")


class AgentManager:
    """
    Manages agents using Semantic Kernel with Azure AI Foundry Agent Service.

    This class acts as a Facade, coordinating the Master Agent and Large Context Agent
    while hiding the complexity of their setup and invocation.
    """

    def __init__(self):
        # Agent wrappers
        self._large_context_agent: Optional[LargeContextAgentWrapper] = None
        self._master_agent: Optional[MasterAgentWrapper] = None

        # Client
        self._agent_client = None
        self._credential: Optional[DefaultAzureCredential] = None
        self._ai_agent_settings: Optional[AzureAIAgentSettings] = None

        # Plugins
        self._file_processor: Optional[FileProcessorPlugin] = None

        # Mock mode
        self._mock_generator: Optional[MockResponseGenerator] = None

        # State
        self.is_initialized = False

    async def initialize(self) -> None:
        """Initialize the agents and plugins."""
        with tracer.start_as_current_span("agent_manager_initialize"):
            try:
                self._credential = DefaultAzureCredential()
                self._file_processor = FileProcessorPlugin()

                # Create agent wrappers (Large Context first since Master depends on it)
                self._large_context_agent = LargeContextAgentWrapper(
                    self._file_processor
                )
                self._master_agent = MasterAgentWrapper(
                    self
                )  # self implements AgentInvoker

                if settings.AZURE_AI_PROJECT_CONNECTION_STRING:
                    logger.info("Initializing with Azure AI Foundry Agent Service")
                    logger.info(
                        f"Connection string: {settings.AZURE_AI_PROJECT_CONNECTION_STRING[:50]}..."
                    )
                    await self._setup_agents()
                else:
                    logger.warning(
                        "No Azure AI connection configured (AZURE_AI_PROJECT_CONNECTION_STRING not set), using mock mode"
                    )
                    # Setup mock generator
                    self._mock_generator = MockResponseGenerator(
                        master_plugin=self._master_agent.plugin,
                        large_context_invoker=self.invoke_large_context_agent,
                    )

                self.is_initialized = True
                logger.info("Agent Manager initialized successfully")

            except Exception as e:
                logger.exception(f"Failed to initialize Agent Manager: {e}")
                raise

    async def _setup_agents(self) -> None:
        """Setup both agents using Azure AI Foundry Agent Service."""
        self._ai_agent_settings = AzureAIAgentSettings(
            endpoint=settings.AZURE_AI_PROJECT_CONNECTION_STRING,
            model_deployment_name=settings.AZURE_OPENAI_DEPLOYMENT,
        )

        logger.info(
            f"AzureAIAgentSettings - endpoint: {self._ai_agent_settings.endpoint}"
        )
        logger.info(
            f"AzureAIAgentSettings - model: {self._ai_agent_settings.model_deployment_name}"
        )

        if not self._ai_agent_settings.endpoint:
            logger.warning("No endpoint configured in AzureAIAgentSettings")
            return

        # Create the Azure AI Agent client
        logger.info("Creating Azure AI Agent client...")
        self._agent_client = AzureAIAgent.create_client(
            credential=self._credential,
            endpoint=self._ai_agent_settings.endpoint,
        )
        logger.info("Azure AI Agent client created")

        # List existing agents
        logger.info("Listing existing agents in Foundry...")
        existing_agents = {}
        async for agent in self._agent_client.agents.list_agents():
            logger.info(
                f"Found agent - ID: {agent.id}, Name: {agent.name}, Model: {agent.model}"
            )
            existing_agents[agent.name] = agent

        # Setup agents (Large Context first since Master depends on it)
        await self._large_context_agent.setup(
            self._agent_client, self._ai_agent_settings, existing_agents
        )
        await self._master_agent.setup(
            self._agent_client, self._ai_agent_settings, existing_agents
        )

        logger.info("Both agents ready!")

    # =========================================================================
    # AgentInvoker Protocol Implementation
    # =========================================================================

    async def invoke_large_context_agent(
        self,
        message: str,
        user_id: Optional[str] = None,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
    ) -> InvokeResult:
        """
        Invoke the Large Context Agent with a message.
        Implements AgentInvoker protocol.
        """
        if self._large_context_agent and self._large_context_agent.is_ready:
            return await self._large_context_agent.invoke(
                message=message,
                user_id=user_id,
                user_first_name=user_first_name,
                user_last_name=user_last_name,
            )
        else:
            # Mock mode
            response = await self._large_context_agent.mock_response(message)
            return InvokeResult(
                response=response,
                agent_used="large_context_agent",
                plugins_invoked=["process_file"],
            )

    # =========================================================================
    # Public API (used by routes.py)
    # =========================================================================

    async def invoke_master_agent(
        self,
        message: str,
        user_id: Optional[str] = None,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
        context: Optional[dict] = None,
        on_intermediate: Optional[Callable[[ChatMessageContent], None]] = None,
    ) -> InvokeResult:
        """
        Invoke the Master Agent with a message.
        Each request gets its own thread for concurrent user support.
        """
        if self._master_agent and self._master_agent.is_ready:
            return await self._master_agent.invoke(
                message=message,
                user_id=user_id,
                user_first_name=user_first_name,
                user_last_name=user_last_name,
                on_intermediate=on_intermediate,
            )
        else:
            # Mock mode
            (
                response_text,
                plugins_invoked,
            ) = await self._mock_generator.generate_master_response(
                message, user_first_name, user_last_name
            )
            return InvokeResult(
                response=response_text,
                agent_used="master_agent",
                plugins_invoked=plugins_invoked,
            )

    async def invoke_master_agent_stream(
        self,
        message: str,
        user_id: Optional[str] = None,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
        context: Optional[dict] = None,
    ) -> AsyncIterator[str]:
        """
        Invoke the Master Agent with streaming response.
        Each request gets its own thread for concurrent user support.
        """
        if self._master_agent and self._master_agent.is_ready:
            async for chunk in self._master_agent.invoke_stream(
                message=message,
                user_id=user_id,
                user_first_name=user_first_name,
                user_last_name=user_last_name,
            ):
                yield chunk
        else:
            # Mock mode
            response_text, _ = await self._mock_generator.generate_master_response(
                message, user_first_name, user_last_name
            )
            yield response_text

    def get_agents_info(self) -> dict:
        """Get information about available agents."""
        master_id = self._master_agent.agent_id if self._master_agent else None
        large_context_id = (
            self._large_context_agent.agent_id if self._large_context_agent else None
        )

        return {
            "agents": [
                {
                    "name": "MasterAgent",
                    "id": master_id,
                    "description": "Orchestrates tasks and delegates to the Large Context Agent",
                    "status": "active" if self.is_initialized else "initializing",
                    "type": "AzureAIAgent (Foundry Agent Service)",
                },
                {
                    "name": "LargeContextAgent",
                    "id": large_context_id,
                    "description": "Processes files and handles large context operations",
                    "status": "active" if self.is_initialized else "initializing",
                    "type": "AzureAIAgent (Foundry Agent Service)",
                },
            ],
            "tools": [
                {
                    "name": "invoke_large_context_agent",
                    "description": "Delegates to Large Context Agent for file processing",
                    "agent": "MasterAgent",
                },
                {
                    "name": "get_capabilities",
                    "description": "Get agent capabilities",
                    "agent": "MasterAgent",
                },
                {
                    "name": "get_system_status",
                    "description": "Get system status",
                    "agent": "MasterAgent",
                },
                {
                    "name": "process_file",
                    "description": "Process a file and return its content",
                    "agent": "LargeContextAgent",
                },
            ],
        }

    async def cleanup(self) -> None:
        """Cleanup resources."""
        try:
            if self._agent_client:
                await self._agent_client.close()
                logger.info("Closed agent client")
        except Exception as e:
            logger.warning(f"Error during agent cleanup: {e}")

        if self._file_processor:
            await self._file_processor.close()

        if self._credential:
            await self._credential.close()
