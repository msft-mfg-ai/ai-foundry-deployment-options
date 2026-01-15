"""API routes for usage tracking and metrics."""

from pathlib import Path

from fastapi import APIRouter, Query, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.models.usage import UsageStats
from app.services.usage_service import get_usage_service

router = APIRouter()

# Setup templates
TEMPLATES_DIR = Path(__file__).resolve().parent.parent / "templates"
templates = Jinja2Templates(directory=TEMPLATES_DIR)


@router.get("/stats", response_class=HTMLResponse)
async def get_usage_stats_html(request: Request):
    """Get usage statistics as HTML partial (HTMX endpoint)."""
    service = get_usage_service()
    stats = await service.get_usage_stats()

    return templates.TemplateResponse(
        request=request,
        name="partials/stats_cards.html",
        context={"stats": stats},
    )


@router.get("/stats/json", response_model=UsageStats)
async def get_usage_stats_json():
    """Get usage statistics as JSON."""
    service = get_usage_service()
    return await service.get_usage_stats()


@router.get("/chart-data", response_class=HTMLResponse)
async def get_chart_data_html(
    request: Request,
    days: int = Query(30, ge=1, le=365, description="Number of days to include"),
):
    """Get chart data as HTML with embedded chart (HTMX endpoint)."""
    service = get_usage_service()
    chart_data = await service.get_chart_data(days)

    return templates.TemplateResponse(
        request=request,
        name="partials/usage_chart.html",
        context={
            "labels": chart_data["labels"],
            "values": chart_data["values"],
        },
    )


@router.get("/chart-data/json")
async def get_chart_data_json(
    days: int = Query(30, ge=1, le=365),
):
    """Get chart data as JSON for client-side rendering."""
    service = get_usage_service()
    return await service.get_chart_data(days)


@router.get("/top-consumers", response_class=HTMLResponse)
async def get_top_consumers_html(
    request: Request,
    days: int = Query(30, ge=1, le=365),
    limit: int = Query(5, ge=1, le=20),
):
    """Get top token consumers as HTML partial (HTMX endpoint)."""
    service = get_usage_service()
    consumers = await service.get_top_consumers(days, limit)

    return templates.TemplateResponse(
        request=request,
        name="partials/top_consumers.html",
        context={"consumers": consumers},
    )


@router.get("/top-consumers/json")
async def get_top_consumers_json(
    days: int = Query(30, ge=1, le=365),
    limit: int = Query(5, ge=1, le=20),
):
    """Get top consumers as JSON."""
    service = get_usage_service()
    return await service.get_top_consumers(days, limit)


@router.get("/subscription/{subscription_id}/chart", response_class=HTMLResponse)
async def get_subscription_chart_html(
    request: Request,
    subscription_id: str,
    days: int = Query(30, ge=1, le=365),
):
    """Get subscription-specific chart as HTML (HTMX endpoint)."""
    service = get_usage_service()
    chart_data = await service.get_subscription_chart_data(subscription_id, days)

    # Return chart HTML with multiple datasets
    return templates.TemplateResponse(
        request=request,
        name="partials/subscription_usage_chart.html",
        context={
            "subscription_id": subscription_id,
            "labels": chart_data["labels"],
            "total_values": chart_data["values"],
            "prompt_tokens": chart_data["prompt_tokens"],
            "completion_tokens": chart_data["completion_tokens"],
        },
    )


@router.get("/subscription/{subscription_id}/daily", response_class=HTMLResponse)
async def get_subscription_daily_usage_html(
    request: Request,
    subscription_id: str,
    days: int = Query(30, ge=1, le=365),
):
    """Get daily usage table for a subscription (HTMX endpoint)."""
    service = get_usage_service()
    usage = await service.get_subscription_usage(subscription_id, days)

    return templates.TemplateResponse(
        request=request,
        name="partials/daily_usage_table.html",
        context={
            "daily_usage": usage.daily_usage,
            "total_tokens": usage.total_tokens,
            "total_requests": usage.total_requests,
        },
    )


@router.get("/subscription/{subscription_id}/json")
async def get_subscription_usage_json(
    subscription_id: str,
    days: int = Query(30, ge=1, le=365),
):
    """Get subscription usage data as JSON."""
    service = get_usage_service()
    return await service.get_subscription_usage(subscription_id, days)
