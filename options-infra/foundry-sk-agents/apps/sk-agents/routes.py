"""
API routes for the SK Agents service.
"""

import asyncio
import json

from fastapi import APIRouter, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse

from models import InvokeRequest, InvokeResponse, HealthResponse
from templates import get_ui_html
from telemetry import get_logger
from semantic_kernel.contents import FunctionCallContent, FunctionResultContent
from semantic_kernel.contents.chat_message_content import (
    ChatMessageContent,
    TextContent,
)

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
        agents_initialized=agent_manager is not None and agent_manager.is_initialized,
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
            message=request.message, context=request.context
        )

        return InvokeResponse(
            response=result.response,
            agent_used=result.agent_used,
            plugins_invoked=result.plugins_invoked,
        )

    except Exception as e:
        logger.exception(f"Error invoking agent: {e}")
        raise HTTPException(status_code=500, detail=str(e))


@router.post("/invoke/stream")
async def invoke_agent_stream(request: InvokeRequest):
    """
    Invoke the master agent with streaming response using Server-Sent Events.
    Shows intermediate steps like tool calls and results.
    """
    if not agent_manager or not agent_manager.is_initialized:
        raise HTTPException(status_code=503, detail="Agents not initialized")

    logger.info(f"Stream started - message length: {len(request.message)}")

    async def generate_events():
        """Generate SSE events from agent response."""
        event_queue = asyncio.Queue()
        events_sent = 0

        async def on_intermediate(agent_response: ChatMessageContent):
            """Handle intermediate messages and queue them as SSE events."""
            for item in agent_response.items or []:
                if isinstance(item, FunctionCallContent):
                    event_data = {
                        "type": "tool_call",
                        "tool": item.name,
                        "arguments": (
                            str(item.arguments)[:200] if item.arguments else None
                        ),
                    }
                    await event_queue.put(event_data)
                elif isinstance(item, FunctionResultContent):
                    result_preview = (
                        str(item.result)[:200] + "..."
                        if len(str(item.result)) > 200
                        else str(item.result)
                    )
                    event_data = {
                        "type": "tool_result",
                        "tool": item.name,
                        "result": result_preview,
                    }
                    await event_queue.put(event_data)
                elif isinstance(item, TextContent):
                    if item.text:
                        event_data = {
                            "type": "text_chunk",
                            "content": (
                                item.text[:100] + "..."
                                if len(item.text) > 100
                                else item.text
                            ),
                        }
                        await event_queue.put(event_data)

        async def invoke_agent():
            """Run the agent invocation in background."""
            try:
                result = await agent_manager.invoke_master_agent(
                    message=request.message,
                    context=request.context,
                    on_intermediate=on_intermediate,
                )
                # Signal completion with final result
                await event_queue.put(
                    {
                        "type": "final",
                        "response": result.response,
                        "agent_used": result.agent_used,
                        "plugins_invoked": result.plugins_invoked,
                    }
                )
            except Exception as e:
                logger.exception(f"Error in streaming: {e}")
                await event_queue.put({"type": "error", "message": str(e)})
            finally:
                await event_queue.put(None)  # Signal end

        # Start agent invocation in background task
        task = asyncio.create_task(invoke_agent())

        # Yield events as they come
        while True:
            event = await event_queue.get()
            if event is None:
                break
            events_sent += 1
            yield f"data: {json.dumps(event)}\n\n"

        # Ensure task completes
        await task

        logger.info(f"Stream ended - events sent: {events_sent}")

    return StreamingResponse(
        generate_events(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
        },
    )


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
