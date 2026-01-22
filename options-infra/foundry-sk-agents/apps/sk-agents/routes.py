"""
API routes for the SK Agents service.
"""

from typing import Optional

from fastapi import APIRouter, HTTPException
from fastapi.responses import HTMLResponse

from models import InvokeRequest, InvokeResponse, HealthResponse
from templates import get_ui_html
from telemetry import get_logger

logger = get_logger("routes")

# Router instance - agent_manager will be set by main.py
router = APIRouter()
agent_manager = None


def set_agent_manager(manager) -> None:
    """Set the agent manager instance for the routes."""
    global agent_manager
    agent_manager = manager


@router.get("/health", response_model=HealthResponse)
async def health_check() -> HealthResponse:
    """Health check endpoint."""
    return HealthResponse(
        status="healthy",
        service="sk-agents",
        agents_initialized=agent_manager is not None and agent_manager.is_initialized
    )


@router.post("/invoke", response_model=InvokeResponse)
async def invoke_agent(request: InvokeRequest) -> InvokeResponse:
    """
    Invoke the master agent with a message.
    The master agent will determine which plugins and sub-agents to use.
    """
    if not agent_manager or not agent_manager.is_initialized:
        raise HTTPException(status_code=503, detail="Agents not initialized")
    
    try:
        result = await agent_manager.invoke_master_agent(
            message=request.message,
            context=request.context
        )
        
        return InvokeResponse(
            response=result.response,
            agent_used=result.agent_used,
            plugins_invoked=result.plugins_invoked
        )
        
    except Exception as e:
        logger.exception(f"Error invoking agent: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.get("/", response_class=HTMLResponse)
async def root() -> str:
    """Serve the simple web UI."""
    return get_ui_html()


@router.get("/api/agents")
async def list_agents() -> dict:
    """List available agents and their capabilities."""
    if not agent_manager or not agent_manager.is_initialized:
        raise HTTPException(status_code=503, detail="Agents not initialized")
    
    return agent_manager.get_agents_info()
