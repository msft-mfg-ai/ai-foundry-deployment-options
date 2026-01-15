"""Pydantic models for subscriptions."""

from datetime import datetime
from enum import Enum

from pydantic import BaseModel, Field


class SubscriptionState(str, Enum):
    """Subscription state enumeration."""

    ACTIVE = "active"
    SUSPENDED = "suspended"
    CANCELLED = "cancelled"
    SUBMITTED = "submitted"
    REJECTED = "rejected"


class TokenLimit(BaseModel):
    """Token limit configuration for a subscription."""

    max_tokens_per_day: int | None = Field(
        default=None, description="Maximum tokens allowed per day"
    )
    max_tokens_per_month: int | None = Field(
        default=None, description="Maximum tokens allowed per month"
    )
    max_requests_per_minute: int | None = Field(
        default=None, description="Maximum requests per minute"
    )


class Subscription(BaseModel):
    """Represents an API Management subscription."""

    id: str = Field(..., description="Unique subscription identifier")
    name: str = Field(..., description="Display name of the subscription")
    display_name: str = Field(..., description="User-friendly display name")
    scope: str = Field(..., description="Scope of the subscription (product/API)")
    state: SubscriptionState = Field(
        ..., description="Current state of the subscription"
    )
    primary_key: str | None = Field(
        default=None, description="Primary subscription key"
    )
    secondary_key: str | None = Field(
        default=None, description="Secondary subscription key"
    )
    created_date: datetime | None = Field(
        default=None, description="When the subscription was created"
    )
    start_date: datetime | None = Field(
        default=None, description="When the subscription became active"
    )
    expiration_date: datetime | None = Field(
        default=None, description="When the subscription expires"
    )
    owner_id: str | None = Field(default=None, description="Owner user ID")
    owner_email: str | None = Field(default=None, description="Owner email address")

    # Custom fields for LLM management
    token_limit: TokenLimit | None = Field(
        default=None, description="Token usage limits"
    )
    notes: str | None = Field(
        default=None, description="Admin notes about this subscription"
    )
    usage_today: int = Field(default=0, description="Token usage today")


class SubscriptionCreate(BaseModel):
    """Request model for creating a new subscription."""

    display_name: str = Field(
        ...,
        min_length=1,
        max_length=100,
        description="Display name for the subscription",
    )
    scope: str = Field(..., description="Product or API scope")
    owner_email: str | None = Field(default=None, description="Owner email address")
    token_limit: TokenLimit | None = Field(
        default=None, description="Initial token limits"
    )
    notes: str | None = Field(default=None, description="Admin notes")


class SubscriptionUpdate(BaseModel):
    """Request model for updating a subscription."""

    display_name: str | None = Field(
        default=None, max_length=100, description="New display name"
    )
    state: SubscriptionState | None = Field(default=None, description="New state")
    token_limit: TokenLimit | None = Field(
        default=None, description="Updated token limits"
    )
    notes: str | None = Field(default=None, description="Updated admin notes")


class SubscriptionListResponse(BaseModel):
    """Response model for listing subscriptions."""

    subscriptions: list[Subscription]
    total_count: int
    page: int = 1
    page_size: int = 50
