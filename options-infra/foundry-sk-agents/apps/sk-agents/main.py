"""
Semantic Kernel Agents Service with Azure AI Foundry

This is the main entry point for the SK Agents FastAPI application.
Features:
- Master Agent that orchestrates plugins and other agents
- Large Context Agent that calls file processing API
- Simple web UI for invoking the master agent
- OpenTelemetry instrumentation for App Insights
"""

from dotenv import load_dotenv

load_dotenv()  # Load .env file before other imports

from contextlib import asynccontextmanager  # noqa: E402

from fastapi import FastAPI  # noqa: E402
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor  # noqa: E402

from config import settings  # noqa: E402
from telemetry import setup_telemetry, get_logger  # noqa: E402
from agent_manager import AgentManager  # noqa: E402
from routes import router, set_agent_manager  # noqa: E402

# Use named logger
logger = get_logger("main")

# Global agent manager
agent_manager: AgentManager | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    global agent_manager

    # Startup
    setup_telemetry()
    logger.info("SK Agents Service starting...")

    # Initialize agent manager
    agent_manager = AgentManager()
    await agent_manager.initialize()

    # Set the agent manager for routes
    set_agent_manager(agent_manager)

    logger.info("SK Agents Service started successfully")
    yield

    # Shutdown
    if agent_manager:
        await agent_manager.cleanup()
    logger.info("SK Agents Service shutting down")


# Create FastAPI app
app = FastAPI(
    title="SK Agents Service",
    description="Semantic Kernel Agents with Azure AI Foundry integration",
    version=settings.SERVICE_VERSION,
    lifespan=lifespan,
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routes
app.include_router(router)

# Instrument FastAPI with OpenTelemetry
FastAPIInstrumentor.instrument_app(app)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=3000)
