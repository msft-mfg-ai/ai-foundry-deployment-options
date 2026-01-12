"""Main FastAPI application entry point."""

from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from app.config import get_settings
from app.routers import subscriptions, usage

# Initialize FastAPI app
app = FastAPI(
    title="Subscription Manager",
    description="Manage Azure API Management subscriptions for LLM access",
    version="0.1.0",
)

# Setup paths
BASE_DIR = Path(__file__).resolve().parent
TEMPLATES_DIR = BASE_DIR / "templates"
STATIC_DIR = BASE_DIR / "static"

# Mount static files
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

# Setup templates
templates = Jinja2Templates(directory=TEMPLATES_DIR)

# Include routers
app.include_router(
    subscriptions.router, prefix="/api/subscriptions", tags=["subscriptions"]
)
app.include_router(usage.router, prefix="/api/usage", tags=["usage"])


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    """Render the main dashboard page."""
    settings = get_settings()
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "title": "Subscription Manager",
            "is_configured": settings.is_configured,
            "use_mock_data": settings.use_mock_data,
        },
    )


@app.get("/subscriptions", response_class=HTMLResponse)
async def subscriptions_page(request: Request):
    """Render the subscriptions management page."""
    settings = get_settings()
    return templates.TemplateResponse(
        request=request,
        name="subscriptions.html",
        context={
            "title": "Manage Subscriptions",
            "is_configured": settings.is_configured,
        },
    )


@app.get("/subscriptions/{subscription_id}", response_class=HTMLResponse)
async def subscription_detail_page(request: Request, subscription_id: str):
    """Render the subscription detail page."""
    return templates.TemplateResponse(
        request=request,
        name="subscription_detail.html",
        context={
            "title": "Subscription Details",
            "subscription_id": subscription_id,
        },
    )


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {"status": "healthy"}
