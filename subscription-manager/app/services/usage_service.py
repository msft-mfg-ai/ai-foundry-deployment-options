"""Usage tracking service for token consumption metrics.

This service queries Azure Monitor Log Analytics to retrieve token usage data
from the ApiManagementGatewayLlmLog table, following the AI-Gateway FinOps framework.
"""

import logging
import random
from datetime import date, datetime, timedelta
from typing import Any

from azure.identity import DefaultAzureCredential
from azure.monitor.query import LogsQueryClient, LogsQueryStatus

from app.config import get_settings
from app.models.usage import (
    DailyUsageSummary,
    UsageOverTime,
    UsageStats,
)

logger = logging.getLogger(__name__)


class UsageService:
    """Service for tracking and querying token usage metrics from Azure Monitor.

    Uses KQL queries against ApiManagementGatewayLlmLog and ApiManagementGatewayLogs
    tables following the AI-Gateway FinOps framework pattern.
    """

    # KQL query to get top consumers
    KQL_TOP_CONSUMERS = """
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != ''
| where TimeGenerated >= ago({days}d);
llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| summarize TotalTokens = sum(TotalTokens), RequestCount = count() by SubscriptionId = ApimSubscriptionId
| top {limit} by TotalTokens desc
"""

    # KQL query to get daily usage
    KQL_DAILY_USAGE = """
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != ''
{time_filter};
let llmLogsWithSubscriptionId = llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| project
    TimeGenerated,
    SubscriptionId = ApimSubscriptionId,
    DeploymentName,
    PromptTokens,
    CompletionTokens,
    TotalTokens;
llmLogsWithSubscriptionId
{subscription_filter}
| summarize
    SumPromptTokens = sum(PromptTokens),
    SumCompletionTokens = sum(CompletionTokens),
    SumTotalTokens = sum(TotalTokens),
    RequestCount = count()
by bin(TimeGenerated, 1d), SubscriptionId
| order by TimeGenerated asc
"""

    def __init__(self):
        settings = get_settings()
        self.subscription_id = settings.azure_subscription_id
        self.resource_group = settings.azure_resource_group
        self.apim_service_name = settings.apim_service_name
        self.workspace_id = settings.log_analytics_workspace_id
        self.use_mock = settings.use_mock_data
        self._client: LogsQueryClient | None = None

    @property
    def client(self) -> LogsQueryClient:
        """Get or create the Log Analytics client."""
        if self._client is None:
            credential = DefaultAzureCredential()
            self._client = LogsQueryClient(credential)
        return self._client

    def _should_use_mock(self) -> bool:
        """Check if we should use mock data (explicitly set or no workspace configured)."""
        if self.use_mock:
            return True
        if not self.workspace_id:
            logger.warning("LOG_ANALYTICS_WORKSPACE_ID not configured, using mock data")
            return True
        return False

    async def _execute_query(
        self, query: str, timespan: timedelta | None = None
    ) -> list[dict[str, Any]]:
        """Execute a KQL query against Log Analytics.

        Args:
            query: The KQL query to execute
            timespan: Optional timespan to limit the query

        Returns:
            List of dictionaries with query results
        """
        try:
            if timespan is None:
                timespan = timedelta(days=30)

            response = self.client.query_workspace(
                workspace_id=self.workspace_id,
                query=query,
                timespan=timespan,
            )

            if response.status == LogsQueryStatus.SUCCESS:
                results = []
                for table in response.tables:
                    # Get column names - handle both object and string formats
                    column_names = []
                    for col in table.columns:
                        if hasattr(col, "name"):
                            column_names.append(col.name)
                        else:
                            column_names.append(str(col))

                    for row in table.rows:
                        row_dict = {}
                        for i, col_name in enumerate(column_names):
                            row_dict[col_name] = row[i]
                        results.append(row_dict)
                return results
            elif response.status == LogsQueryStatus.PARTIAL:
                logger.warning(f"Partial query results: {response.partial_error}")
                results = []
                for table in response.partial_data:
                    column_names = []
                    for col in table.columns:
                        if hasattr(col, "name"):
                            column_names.append(col.name)
                        else:
                            column_names.append(str(col))

                    for row in table.rows:
                        row_dict = {}
                        for i, col_name in enumerate(column_names):
                            row_dict[col_name] = row[i]
                        results.append(row_dict)
                return results
            else:
                logger.error(f"Query failed: {response.status}")
                return []

        except Exception as e:
            logger.error(f"Error executing query: {e}")
            raise

    async def get_usage_stats(self) -> UsageStats:
        """Get overall usage statistics."""
        if self._should_use_mock():
            return self._get_mock_stats()

        try:
            # Get today's and monthly stats using FinOps framework KQL pattern
            query = """
let todayLogs = ApiManagementGatewayLlmLog
| where DeploymentName != ''
| where TimeGenerated >= startofday(now())
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| summarize TodayTokens = sum(TotalTokens), TodayRequests = count();
let monthLogs = ApiManagementGatewayLlmLog
| where DeploymentName != ''
| where TimeGenerated >= startofmonth(now())
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| summarize MonthTokens = sum(TotalTokens), MonthRequests = count();
todayLogs
| extend MonthTokens = toscalar(monthLogs | project MonthTokens)
| extend MonthRequests = toscalar(monthLogs | project MonthRequests)
"""
            results = await self._execute_query(query, timedelta(days=31))

            today_tokens = 0
            month_tokens = 0
            month_requests = 0

            if results:
                row = results[0]
                today_tokens = int(row.get("TodayTokens", 0) or 0)
                month_tokens = int(row.get("MonthTokens", 0) or 0)
                month_requests = int(row.get("MonthRequests", 0) or 0)

            # Get top consumers
            top_consumers = await self.get_top_consumers(days=30, limit=3)

            # Get unique subscription count
            sub_query = """
ApiManagementGatewayLlmLog
| where DeploymentName != ''
| where TimeGenerated >= startofmonth(now())
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| summarize by ApimSubscriptionId
| count
"""
            sub_results = await self._execute_query(sub_query, timedelta(days=31))
            active_subscriptions = (
                int(sub_results[0].get("Count", 0)) if sub_results else 0
            )

            return UsageStats(
                total_subscriptions=active_subscriptions,
                active_subscriptions=active_subscriptions,
                total_tokens_today=today_tokens,
                total_tokens_this_month=month_tokens,
                avg_tokens_per_request=(
                    month_tokens // month_requests if month_requests > 0 else 0
                ),
                top_consumers=[
                    {
                        "name": c.get("subscription_id", "Unknown"),
                        "tokens": c.get("total_tokens", 0),
                    }
                    for c in top_consumers
                ],
            )
        except Exception as e:
            logger.error(f"Error getting usage stats from Azure Monitor: {e}")
            return self._get_mock_stats()

    async def get_usage_over_time(
        self,
        subscription_id: str | None = None,
        start_date: date | None = None,
        end_date: date | None = None,
        days: int = 30,
    ) -> list[DailyUsageSummary]:
        """Get daily token usage over a time period."""
        if end_date is None:
            end_date = date.today()
        if start_date is None:
            start_date = end_date - timedelta(days=days)

        if self._should_use_mock():
            return self._get_mock_daily_usage(subscription_id, start_date, end_date)

        try:
            # Build the query with time filter using FinOps framework pattern
            end_date_next = (end_date + timedelta(days=1)).isoformat()
            time_filter = (
                f"| where TimeGenerated >= datetime({start_date.isoformat()}) "
                f"and TimeGenerated < datetime({end_date_next})"
            )

            subscription_filter = ""
            if subscription_id:
                subscription_filter = f"| where SubscriptionId == '{subscription_id}'"

            query = self.KQL_DAILY_USAGE.format(
                time_filter=time_filter, subscription_filter=subscription_filter
            )

            results = await self._execute_query(query, timedelta(days=days + 1))

            usage = []
            for row in results:
                time_generated = row.get("TimeGenerated")
                if isinstance(time_generated, datetime):
                    usage_date = time_generated.date()
                else:
                    usage_date = datetime.fromisoformat(
                        str(time_generated).replace("Z", "+00:00")
                    ).date()

                usage.append(
                    DailyUsageSummary(
                        usage_date=usage_date,
                        subscription_id=row.get(
                            "SubscriptionId", subscription_id or "all"
                        ),
                        total_requests=int(row.get("RequestCount", 0) or 0),
                        total_prompt_tokens=int(row.get("SumPromptTokens", 0) or 0),
                        total_completion_tokens=int(
                            row.get("SumCompletionTokens", 0) or 0
                        ),
                        total_tokens=int(row.get("SumTotalTokens", 0) or 0),
                        avg_tokens_per_request=(
                            int(row.get("SumTotalTokens", 0) or 0)
                            // max(int(row.get("RequestCount", 1) or 1), 1)
                        ),
                        models_used=[],
                    )
                )

            # Fill in missing days with zeros
            existing_dates = {u.usage_date for u in usage}
            current_date = start_date
            while current_date <= end_date:
                if current_date not in existing_dates:
                    usage.append(
                        DailyUsageSummary(
                            usage_date=current_date,
                            subscription_id=subscription_id or "all",
                            total_requests=0,
                            total_prompt_tokens=0,
                            total_completion_tokens=0,
                            total_tokens=0,
                            avg_tokens_per_request=0,
                            models_used=[],
                        )
                    )
                current_date += timedelta(days=1)

            usage.sort(key=lambda x: x.usage_date)
            return usage

        except Exception as e:
            logger.error(f"Error getting usage over time from Azure Monitor: {e}")
            return self._get_mock_daily_usage(subscription_id, start_date, end_date)

    async def get_subscription_usage(
        self,
        subscription_id: str,
        days: int = 30,
    ) -> UsageOverTime:
        """Get usage data for a specific subscription."""
        end_date = date.today()
        start_date = end_date - timedelta(days=days)

        daily_usage = await self.get_usage_over_time(
            subscription_id=subscription_id,
            start_date=start_date,
            end_date=end_date,
        )

        total_tokens = sum(d.total_tokens for d in daily_usage)
        total_requests = sum(d.total_requests for d in daily_usage)

        return UsageOverTime(
            subscription_id=subscription_id,
            subscription_name=f"Subscription {subscription_id}",
            start_date=start_date,
            end_date=end_date,
            daily_usage=daily_usage,
            total_tokens=total_tokens,
            total_requests=total_requests,
        )

    async def get_top_consumers(self, days: int = 30, limit: int = 5) -> list[dict]:
        """Get top token-consuming subscriptions using FinOps framework KQL pattern."""
        if self._should_use_mock():
            return self._get_mock_top_consumers(limit)

        try:
            query = self.KQL_TOP_CONSUMERS.format(days=days, limit=limit)
            results = await self._execute_query(query, timedelta(days=days))

            consumers = []
            total_tokens = sum(int(r.get("TotalTokens", 0) or 0) for r in results)

            for row in results:
                tokens = int(row.get("TotalTokens", 0) or 0)
                consumers.append(
                    {
                        "subscription_id": row.get("SubscriptionId", "Unknown"),
                        "name": row.get("SubscriptionId", "Unknown"),
                        "total_tokens": tokens,
                        "request_count": int(row.get("RequestCount", 0) or 0),
                        "percentage": (
                            round((tokens / total_tokens) * 100, 1)
                            if total_tokens > 0
                            else 0
                        ),
                    }
                )

            return consumers

        except Exception as e:
            logger.error(f"Error getting top consumers from Azure Monitor: {e}")
            return self._get_mock_top_consumers(limit)

    async def get_chart_data(self, days: int = 30) -> dict:
        """Get chart-ready data for token usage visualization."""
        end_date = date.today()
        start_date = end_date - timedelta(days=days)

        daily_usage = await self.get_usage_over_time(
            start_date=start_date, end_date=end_date
        )

        labels = [d.usage_date.strftime("%b %d") for d in daily_usage]
        values = [d.total_tokens for d in daily_usage]

        return {
            "labels": labels,
            "values": values,
        }

    async def get_subscription_chart_data(
        self, subscription_id: str, days: int = 30
    ) -> dict:
        """Get chart data for a specific subscription."""
        usage = await self.get_subscription_usage(subscription_id, days)

        labels = [d.usage_date.strftime("%b %d") for d in usage.daily_usage]
        values = [d.total_tokens for d in usage.daily_usage]
        prompt_tokens = [d.total_prompt_tokens for d in usage.daily_usage]
        completion_tokens = [d.total_completion_tokens for d in usage.daily_usage]

        return {
            "labels": labels,
            "values": values,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
        }

    async def get_usage_by_subscription(self, days: int = 30) -> list[dict]:
        """Get token usage aggregated by subscription using FinOps framework KQL pattern."""
        if self._should_use_mock():
            return self._get_mock_top_consumers(10)

        try:
            query = f"""
let llmHeaderLogs = ApiManagementGatewayLlmLog
| where DeploymentName != ''
| where TimeGenerated >= ago({days}d);
llmHeaderLogs
| join kind=leftouter ApiManagementGatewayLogs on CorrelationId
| summarize
    SumPromptTokens = sum(PromptTokens),
    SumCompletionTokens = sum(CompletionTokens),
    SumTotalTokens = sum(TotalTokens),
    RequestCount = count()
by SubscriptionId = ApimSubscriptionId, DeploymentName
| order by SumTotalTokens desc
"""
            results = await self._execute_query(query, timedelta(days=days))

            return [
                {
                    "subscription_id": row.get("SubscriptionId", "Unknown"),
                    "deployment_name": row.get("DeploymentName", "Unknown"),
                    "prompt_tokens": int(row.get("SumPromptTokens", 0) or 0),
                    "completion_tokens": int(row.get("SumCompletionTokens", 0) or 0),
                    "total_tokens": int(row.get("SumTotalTokens", 0) or 0),
                    "request_count": int(row.get("RequestCount", 0) or 0),
                }
                for row in results
            ]
        except Exception as e:
            logger.error(f"Error getting usage by subscription from Azure Monitor: {e}")
            return self._get_mock_top_consumers(10)

    # Mock data methods
    def _get_mock_stats(self) -> UsageStats:
        """Return mock usage statistics."""
        return UsageStats(
            total_subscriptions=5,
            active_subscriptions=4,
            total_tokens_today=random.randint(50000, 150000),
            total_tokens_this_month=random.randint(1500000, 4000000),
            avg_tokens_per_request=random.randint(500, 1500),
            top_consumers=[
                {"name": "Production API", "tokens": 1250000},
                {"name": "Partner Integration", "tokens": 890000},
                {"name": "Development Team", "tokens": 450000},
            ],
        )

    def _get_mock_daily_usage(
        self,
        subscription_id: str | None,
        start_date: date,
        end_date: date,
    ) -> list[DailyUsageSummary]:
        """Generate mock daily usage data."""
        usage = []
        current_date = start_date

        # Use subscription_id to seed random for consistent data
        if subscription_id:
            random.seed(hash(subscription_id) % 2**32)

        while current_date <= end_date:
            # Generate realistic-looking usage patterns
            # Lower on weekends, with some variation
            is_weekend = current_date.weekday() >= 5
            base_tokens = (
                random.randint(10000, 50000)
                if is_weekend
                else random.randint(50000, 200000)
            )

            # Add some daily variation
            variation = random.uniform(0.7, 1.3)
            total_tokens = int(base_tokens * variation)

            prompt_ratio = random.uniform(0.3, 0.5)
            prompt_tokens = int(total_tokens * prompt_ratio)
            completion_tokens = total_tokens - prompt_tokens

            requests = (
                random.randint(100, 500) if is_weekend else random.randint(300, 1500)
            )

            usage.append(
                DailyUsageSummary(
                    usage_date=current_date,
                    subscription_id=subscription_id or "all",
                    total_requests=requests,
                    total_prompt_tokens=prompt_tokens,
                    total_completion_tokens=completion_tokens,
                    total_tokens=total_tokens,
                    avg_tokens_per_request=(
                        total_tokens / requests if requests > 0 else 0
                    ),
                    models_used=["gpt-4", "gpt-4-turbo"],
                )
            )
            current_date += timedelta(days=1)

        # Reset random seed
        random.seed()

        return usage

    def _get_mock_top_consumers(self, limit: int) -> list[dict]:
        """Return mock top consumers data."""
        consumers = [
            {
                "subscription_id": "sub-001",
                "name": "Production API Access",
                "total_tokens": 1250000,
            },
            {
                "subscription_id": "sub-004",
                "name": "Partner Integration",
                "total_tokens": 890000,
            },
            {
                "subscription_id": "sub-002",
                "name": "Development Team",
                "total_tokens": 450000,
            },
            {
                "subscription_id": "sub-005",
                "name": "Internal Tools",
                "total_tokens": 320000,
            },
            {
                "subscription_id": "sub-003",
                "name": "Testing Environment",
                "total_tokens": 85000,
            },
        ]

        # Calculate percentage
        total = sum(c["total_tokens"] for c in consumers)
        for c in consumers:
            c["percentage"] = round((c["total_tokens"] / total) * 100, 1)

        return consumers[:limit]


# Singleton instance
_usage_service: UsageService | None = None


def get_usage_service() -> UsageService:
    """Get the usage service instance."""
    global _usage_service
    if _usage_service is None:
        _usage_service = UsageService()
    return _usage_service
