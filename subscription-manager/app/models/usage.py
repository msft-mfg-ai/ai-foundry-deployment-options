"""Pydantic models for token usage tracking."""

from datetime import date, datetime

from pydantic import BaseModel, Field


class TokenUsageRecord(BaseModel):
    """Single record of token usage."""

    timestamp: datetime = Field(..., description="When the usage occurred")
    subscription_id: str = Field(
        ..., description="Subscription that generated the usage"
    )
    prompt_tokens: int = Field(default=0, description="Number of prompt tokens used")
    completion_tokens: int = Field(
        default=0, description="Number of completion tokens used"
    )
    total_tokens: int = Field(default=0, description="Total tokens used")
    model: str | None = Field(default=None, description="LLM model used")
    operation: str | None = Field(default=None, description="API operation called")


class DailyUsageSummary(BaseModel):
    """Aggregated daily usage summary."""

    usage_date: date = Field(..., description="The date for this summary")
    subscription_id: str = Field(..., description="Subscription ID")
    total_requests: int = Field(default=0, description="Total number of requests")
    total_prompt_tokens: int = Field(default=0, description="Total prompt tokens")
    total_completion_tokens: int = Field(
        default=0, description="Total completion tokens"
    )
    total_tokens: int = Field(default=0, description="Total tokens used")
    avg_tokens_per_request: float = Field(
        default=0, description="Average tokens per request"
    )
    models_used: list[str] = Field(
        default_factory=list, description="List of models used"
    )


class UsageOverTime(BaseModel):
    """Token usage data over a time period."""

    subscription_id: str = Field(..., description="Subscription ID")
    subscription_name: str = Field(..., description="Subscription display name")
    start_date: date = Field(..., description="Start of the period")
    end_date: date = Field(..., description="End of the period")
    daily_usage: list[DailyUsageSummary] = Field(
        default_factory=list, description="Daily usage data"
    )
    total_tokens: int = Field(default=0, description="Total tokens in the period")
    total_requests: int = Field(default=0, description="Total requests in the period")


class UsageStats(BaseModel):
    """Overall usage statistics."""

    total_subscriptions: int = Field(
        default=0, description="Total number of subscriptions"
    )
    active_subscriptions: int = Field(
        default=0, description="Number of active subscriptions"
    )
    total_tokens_today: int = Field(default=0, description="Tokens used today")
    total_tokens_this_month: int = Field(
        default=0, description="Tokens used this month"
    )
    top_consumers: list[dict] = Field(
        default_factory=list, description="Top token consumers"
    )


class UsageQueryParams(BaseModel):
    """Parameters for querying usage data."""

    subscription_id: str | None = Field(
        default=None, description="Filter by subscription"
    )
    start_date: date | None = Field(default=None, description="Start date filter")
    end_date: date | None = Field(default=None, description="End date filter")
    granularity: str = Field(
        default="day", description="Data granularity: hour, day, week, month"
    )
