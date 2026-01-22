"""
Pydantic models for API requests and responses.
"""

from typing import Optional
from pydantic import BaseModel


class InvokeRequest(BaseModel):
    """Request model for agent invocation."""

    message: str
    context: Optional[dict] = None


class InvokeResponse(BaseModel):
    """Response model for agent invocation."""

    response: str
    agent_used: str
    plugins_invoked: list[str]


class InvokeResult(BaseModel):
    """Internal result from agent invocation."""

    response: str
    agent_used: str
    plugins_invoked: list[str]


class HealthResponse(BaseModel):
    """Health check response."""

    status: str
    service: str
    agents_initialized: bool


class AgentInfo(BaseModel):
    """Information about an agent."""

    name: str
    description: str
    status: str


class PluginInfo(BaseModel):
    """Information about a plugin."""

    name: str
    functions: list[str]


class AgentsInfoResponse(BaseModel):
    """Response containing information about all agents and plugins."""

    agents: list[AgentInfo]
    plugins: list[PluginInfo]
