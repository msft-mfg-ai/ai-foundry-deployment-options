"""
Base Agent - Abstract base classes and protocols for agents.

Defines the interface that all agent wrappers must implement,
following the Interface Segregation and Dependency Inversion principles.
"""

from abc import ABC, abstractmethod
from typing import Optional, AsyncIterator, Protocol, runtime_checkable

from models import InvokeResult


@runtime_checkable
class AgentInvoker(Protocol):
    """Protocol for invoking the Large Context Agent.

    This protocol allows MasterAgentPlugin to invoke the Large Context Agent
    without depending on the concrete AgentManager implementation.
    (Dependency Inversion Principle)
    """

    async def invoke_large_context_agent(
        self,
        message: str,
        user_id: Optional[str] = None,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
    ) -> InvokeResult:
        """Invoke the Large Context Agent with a message."""
        ...


class BaseAgent(ABC):
    """Abstract base class for agent wrappers.

    Each agent wrapper is responsible for:
    - Managing its own AzureAIAgent instance
    - Creating/updating the agent definition in Azure AI Foundry
    - Invoking the agent with per-request threads

    (Single Responsibility Principle)
    """

    @abstractmethod
    async def setup(self, client, settings, existing_agents: dict) -> None:
        """Setup the agent in Azure AI Foundry.

        Args:
            client: Azure AI Agent client
            settings: AzureAIAgentSettings
            existing_agents: Dict of existing agent names to definitions
        """
        ...

    @abstractmethod
    async def invoke(
        self,
        message: str,
        user_id: Optional[str] = None,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
        **kwargs,
    ) -> InvokeResult:
        """Invoke the agent with a message.

        Args:
            message: Message to send to the agent
            user_id: Optional user ID for tracking
            user_first_name: Optional user first name
            user_last_name: Optional user last name
            **kwargs: Additional arguments

        Returns:
            InvokeResult with response and metadata
        """
        ...

    @abstractmethod
    async def invoke_stream(
        self,
        message: str,
        user_id: Optional[str] = None,
        user_first_name: Optional[str] = None,
        user_last_name: Optional[str] = None,
        **kwargs,
    ) -> AsyncIterator[str]:
        """Invoke the agent with streaming response.

        Args:
            message: Message to send to the agent
            user_id: Optional user ID for tracking
            user_first_name: Optional user first name
            user_last_name: Optional user last name
            **kwargs: Additional arguments

        Yields:
            Streamed response chunks
        """
        ...

    @property
    @abstractmethod
    def agent_id(self) -> Optional[str]:
        """Get the agent's ID in Azure AI Foundry."""
        ...

    @property
    @abstractmethod
    def agent_name(self) -> str:
        """Get the agent's name."""
        ...

    @property
    @abstractmethod
    def is_ready(self) -> bool:
        """Check if the agent is ready for invocation."""
        ...
