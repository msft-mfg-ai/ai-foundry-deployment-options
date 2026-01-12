"""API routes for subscription management."""

from pathlib import Path

from fastapi import APIRouter, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.models.subscription import (
    Subscription,
    SubscriptionCreate,
    SubscriptionListResponse,
    SubscriptionUpdate,
    TokenLimit,
)
from app.services.apim_service import get_apim_service

router = APIRouter()

# Setup templates
TEMPLATES_DIR = Path(__file__).resolve().parent.parent / "templates"
templates = Jinja2Templates(directory=TEMPLATES_DIR)


@router.get("", response_model=SubscriptionListResponse)
async def list_subscriptions(
    search: str | None = Query(None, description="Search by display name"),
    state: str | None = Query(None, description="Filter by state"),
    page: int = Query(1, ge=1, description="Page number"),
    limit: int = Query(50, ge=1, le=100, description="Items per page"),
):
    """List all subscriptions with optional filtering."""
    service = get_apim_service()
    subscriptions, total_count = await service.list_subscriptions(
        search=search,
        state=state,
        page=page,
        page_size=limit,
    )
    return SubscriptionListResponse(
        subscriptions=subscriptions,
        total_count=total_count,
        page=page,
        page_size=limit,
    )


@router.get("/recent", response_class=HTMLResponse)
async def get_recent_subscriptions_html(
    request: Request,
    limit: int = Query(5, ge=1, le=20),
):
    """Return HTML partial for recent subscriptions (HTMX endpoint for dashboard)."""
    service = get_apim_service()
    subscriptions, _ = await service.list_subscriptions(
        page=1,
        page_size=limit,
    )

    return templates.TemplateResponse(
        request=request,
        name="partials/recent_subscriptions.html",
        context={"subscriptions": subscriptions},
    )


@router.get("/list", response_class=HTMLResponse)
async def list_subscriptions_html(
    request: Request,
    search: str | None = Query(None),
    state: str | None = Query(None),
    page: int = Query(1, ge=1),
):
    """Return HTML partial for subscriptions table (HTMX endpoint)."""
    service = get_apim_service()
    subscriptions, total_count = await service.list_subscriptions(
        search=search,
        state=state,
        page=page,
        page_size=50,
    )

    # Add mock usage data for display
    for sub in subscriptions:
        # This would normally come from the usage service
        sub.usage_today = 0  # Will be populated by usage service

    return templates.TemplateResponse(
        request=request,
        name="partials/subscriptions_table.html",
        context={
            "subscriptions": subscriptions,
            "total_count": total_count,
            "page": page,
            "page_size": 50,
        },
    )


@router.get("/{subscription_id}", response_class=HTMLResponse)
async def get_subscription_html(request: Request, subscription_id: str):
    """Get subscription details as HTML partial (HTMX endpoint)."""
    service = get_apim_service()
    subscription = await service.get_subscription(subscription_id)

    if not subscription:
        raise HTTPException(status_code=404, detail="Subscription not found")

    return templates.TemplateResponse(
        request=request,
        name="partials/subscription_detail.html",
        context={"subscription": subscription},
    )


@router.get("/{subscription_id}/json", response_model=Subscription)
async def get_subscription_json(subscription_id: str):
    """Get subscription details as JSON."""
    service = get_apim_service()
    subscription = await service.get_subscription(subscription_id)

    if not subscription:
        raise HTTPException(status_code=404, detail="Subscription not found")

    return subscription


@router.post("", response_class=HTMLResponse)
async def create_subscription(
    request: Request,
    display_name: str = Form(...),
    scope: str = Form(...),
    owner_email: str | None = Form(None),
    max_tokens_per_day: int | None = Form(None),
    max_tokens_per_month: int | None = Form(None),
    notes: str | None = Form(None),
):
    """Create a new subscription and return updated table."""
    service = get_apim_service()

    token_limit = None
    if max_tokens_per_day or max_tokens_per_month:
        token_limit = TokenLimit(
            max_tokens_per_day=max_tokens_per_day,
            max_tokens_per_month=max_tokens_per_month,
        )

    data = SubscriptionCreate(
        display_name=display_name,
        scope=scope,
        owner_email=owner_email,
        token_limit=token_limit,
        notes=notes,
    )

    await service.create_subscription(data)

    # Return updated subscriptions list
    subscriptions, total_count = await service.list_subscriptions(page=1, page_size=50)

    return templates.TemplateResponse(
        request=request,
        name="partials/subscriptions_table.html",
        context={
            "subscriptions": subscriptions,
            "total_count": total_count,
            "page": 1,
            "page_size": 50,
        },
    )


@router.put("/{subscription_id}", response_model=Subscription)
async def update_subscription(subscription_id: str, data: SubscriptionUpdate):
    """Update an existing subscription."""
    service = get_apim_service()
    subscription = await service.update_subscription(subscription_id, data)

    if not subscription:
        raise HTTPException(status_code=404, detail="Subscription not found")

    return subscription


@router.post("/{subscription_id}/suspend", response_class=HTMLResponse)
async def suspend_subscription(request: Request, subscription_id: str):
    """Suspend a subscription and return updated table."""
    service = get_apim_service()
    subscription = await service.suspend_subscription(subscription_id)

    if not subscription:
        raise HTTPException(status_code=404, detail="Subscription not found")

    # Return updated subscriptions list
    subscriptions, total_count = await service.list_subscriptions(page=1, page_size=50)

    return templates.TemplateResponse(
        request=request,
        name="partials/subscriptions_table.html",
        context={
            "subscriptions": subscriptions,
            "total_count": total_count,
            "page": 1,
            "page_size": 50,
        },
    )


@router.post("/{subscription_id}/activate", response_class=HTMLResponse)
async def activate_subscription(request: Request, subscription_id: str):
    """Activate a suspended subscription and return updated table."""
    service = get_apim_service()
    subscription = await service.activate_subscription(subscription_id)

    if not subscription:
        raise HTTPException(status_code=404, detail="Subscription not found")

    # Return updated subscriptions list
    subscriptions, total_count = await service.list_subscriptions(page=1, page_size=50)

    return templates.TemplateResponse(
        request=request,
        name="partials/subscriptions_table.html",
        context={
            "subscriptions": subscriptions,
            "total_count": total_count,
            "page": 1,
            "page_size": 50,
        },
    )


@router.put("/{subscription_id}/limits", response_class=HTMLResponse)
async def update_subscription_limits(
    request: Request,
    subscription_id: str,
    max_tokens_per_day: int | None = Form(None),
    max_tokens_per_month: int | None = Form(None),
    max_requests_per_minute: int | None = Form(None),
):
    """Update subscription token limits."""
    service = get_apim_service()

    token_limit = TokenLimit(
        max_tokens_per_day=max_tokens_per_day,
        max_tokens_per_month=max_tokens_per_month,
        max_requests_per_minute=max_requests_per_minute,
    )

    data = SubscriptionUpdate(token_limit=token_limit)
    subscription = await service.update_subscription(subscription_id, data)

    if not subscription:
        raise HTTPException(status_code=404, detail="Subscription not found")

    return templates.TemplateResponse(
        request=request,
        name="partials/subscription_detail.html",
        context={"subscription": subscription},
    )
