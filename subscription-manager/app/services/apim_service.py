"""Azure API Management service for subscription management."""

import logging
from datetime import datetime

from azure.identity import DefaultAzureCredential
from azure.mgmt.apimanagement import ApiManagementClient
from azure.mgmt.apimanagement.models import (
    SubscriptionContract,
    SubscriptionCreateParameters,
    SubscriptionUpdateParameters,
)
from azure.mgmt.apimanagement.models import (
    SubscriptionState as AzureSubscriptionState,
)

from app.config import get_settings
from app.models.subscription import (
    Subscription,
    SubscriptionCreate,
    SubscriptionState,
    SubscriptionUpdate,
    TokenLimit,
)

logger = logging.getLogger(__name__)


class APIMService:
    """Service for interacting with Azure API Management."""

    def __init__(self):
        settings = get_settings()
        self.subscription_id = settings.azure_subscription_id
        self.resource_group = settings.azure_resource_group
        self.service_name = settings.apim_service_name
        self.use_mock = settings.use_mock_data
        self._client: ApiManagementClient | None = None

    @property
    def client(self) -> ApiManagementClient:
        """Get or create the APIM client."""
        if self._client is None:
            credential = DefaultAzureCredential()
            self._client = ApiManagementClient(credential, self.subscription_id)
        return self._client

    def _convert_state(self, azure_state: str) -> SubscriptionState:
        """Convert Azure subscription state to our model."""
        state_map = {
            "active": SubscriptionState.ACTIVE,
            "suspended": SubscriptionState.SUSPENDED,
            "cancelled": SubscriptionState.CANCELLED,
            "submitted": SubscriptionState.SUBMITTED,
            "rejected": SubscriptionState.REJECTED,
        }
        return state_map.get(azure_state.lower(), SubscriptionState.ACTIVE)

    def _convert_to_model(self, contract: SubscriptionContract) -> Subscription:
        """Convert Azure SubscriptionContract to our Subscription model."""
        return Subscription(
            id=contract.name or "",
            name=contract.name or "",
            display_name=contract.display_name or "",
            scope=contract.scope or "",
            state=(
                self._convert_state(contract.state)
                if contract.state
                else SubscriptionState.ACTIVE
            ),
            primary_key=contract.primary_key,
            secondary_key=contract.secondary_key,
            created_date=contract.created_date,
            start_date=contract.start_date,
            expiration_date=contract.expiration_date,
            owner_id=contract.owner_id,
            token_limit=None,  # Token limits stored separately (e.g., in a database or APIM policies)
            notes=None,
        )

    async def list_subscriptions(
        self,
        search: str | None = None,
        state: str | None = None,
        page: int = 1,
        page_size: int = 50,
    ) -> tuple[list[Subscription], int]:
        """List all subscriptions with optional filtering."""
        if self.use_mock:
            return self._get_mock_subscriptions(search, state, page, page_size)

        try:
            subscriptions = []
            skip = (page - 1) * page_size

            # Build filter
            filter_parts = []
            if search:
                filter_parts.append(f"contains(displayName, '{search}')")
            if state:
                filter_parts.append(f"state eq '{state}'")
            filter_str = " and ".join(filter_parts) if filter_parts else None

            result = self.client.subscription.list(
                resource_group_name=self.resource_group,
                service_name=self.service_name,
                filter=filter_str,
                skip=skip,
                top=page_size,
            )

            for contract in result:
                subscriptions.append(self._convert_to_model(contract))

            # Get total count (Azure doesn't provide this directly, so we estimate)
            total_count = len(subscriptions) + skip
            if len(subscriptions) == page_size:
                total_count += 1  # Indicate there might be more

            return subscriptions, total_count

        except Exception as e:
            logger.error(f"Error listing subscriptions: {e}")
            raise

    async def get_subscription(self, subscription_id: str) -> Subscription | None:
        """Get a single subscription by ID."""
        if self.use_mock:
            return self._get_mock_subscription(subscription_id)

        try:
            contract = self.client.subscription.get(
                resource_group_name=self.resource_group,
                service_name=self.service_name,
                sid=subscription_id,
            )
            return self._convert_to_model(contract)
        except Exception as e:
            logger.error(f"Error getting subscription {subscription_id}: {e}")
            return None

    async def create_subscription(self, data: SubscriptionCreate) -> Subscription:
        """Create a new subscription."""
        if self.use_mock:
            return self._create_mock_subscription(data)

        try:
            # Generate a unique ID
            import uuid

            subscription_id = str(uuid.uuid4())[:8]

            params = SubscriptionCreateParameters(
                display_name=data.display_name,
                scope=data.scope,
                state=AzureSubscriptionState.ACTIVE,
            )

            contract = self.client.subscription.create_or_update(
                resource_group_name=self.resource_group,
                service_name=self.service_name,
                sid=subscription_id,
                parameters=params,
            )
            return self._convert_to_model(contract)
        except Exception as e:
            logger.error(f"Error creating subscription: {e}")
            raise

    async def update_subscription(
        self, subscription_id: str, data: SubscriptionUpdate
    ) -> Subscription | None:
        """Update an existing subscription."""
        if self.use_mock:
            return self._update_mock_subscription(subscription_id, data)

        try:
            params = SubscriptionUpdateParameters()
            if data.display_name:
                params.display_name = data.display_name
            if data.state:
                params.state = AzureSubscriptionState(data.state.value)

            contract = self.client.subscription.update(
                resource_group_name=self.resource_group,
                service_name=self.service_name,
                sid=subscription_id,
                parameters=params,
                if_match="*",  # Use wildcard for simplicity
            )
            return self._convert_to_model(contract)
        except Exception as e:
            logger.error(f"Error updating subscription {subscription_id}: {e}")
            return None

    async def suspend_subscription(self, subscription_id: str) -> Subscription | None:
        """Suspend a subscription."""
        return await self.update_subscription(
            subscription_id, SubscriptionUpdate(state=SubscriptionState.SUSPENDED)
        )

    async def activate_subscription(self, subscription_id: str) -> Subscription | None:
        """Activate a suspended subscription."""
        return await self.update_subscription(
            subscription_id, SubscriptionUpdate(state=SubscriptionState.ACTIVE)
        )

    # Mock data methods for development
    def _get_mock_subscriptions(
        self, search: str | None, state: str | None, page: int, page_size: int
    ) -> tuple[list[Subscription], int]:
        """Return mock subscription data."""
        mock_subs = [
            Subscription(
                id="sub-001",
                name="sub-001",
                display_name="Production API Access",
                scope="/products/llm-api",
                state=SubscriptionState.ACTIVE,
                primary_key="pk-xxxxx-xxxxx-xxxxx",
                created_date=datetime(2024, 1, 15),
                owner_email="team-a@example.com",
                token_limit=TokenLimit(
                    max_tokens_per_day=1000000, max_tokens_per_month=25000000
                ),
            ),
            Subscription(
                id="sub-002",
                name="sub-002",
                display_name="Development Team",
                scope="/products/llm-api",
                state=SubscriptionState.ACTIVE,
                primary_key="pk-yyyyy-yyyyy-yyyyy",
                created_date=datetime(2024, 2, 20),
                owner_email="dev-team@example.com",
                token_limit=TokenLimit(max_tokens_per_day=500000),
            ),
            Subscription(
                id="sub-003",
                name="sub-003",
                display_name="Testing Environment",
                scope="/products/llm-api",
                state=SubscriptionState.SUSPENDED,
                primary_key="pk-zzzzz-zzzzz-zzzzz",
                created_date=datetime(2024, 3, 10),
                owner_email="qa@example.com",
            ),
            Subscription(
                id="sub-004",
                name="sub-004",
                display_name="Partner Integration",
                scope="/products/llm-api",
                state=SubscriptionState.ACTIVE,
                primary_key="pk-aaaaa-aaaaa-aaaaa",
                created_date=datetime(2024, 4, 5),
                owner_email="partner@external.com",
                token_limit=TokenLimit(
                    max_tokens_per_day=2000000, max_tokens_per_month=50000000
                ),
            ),
            Subscription(
                id="sub-005",
                name="sub-005",
                display_name="Internal Tools",
                scope="/products/llm-api",
                state=SubscriptionState.ACTIVE,
                primary_key="pk-bbbbb-bbbbb-bbbbb",
                created_date=datetime(2024, 5, 1),
                owner_email="internal@example.com",
                token_limit=TokenLimit(max_tokens_per_month=10000000),
            ),
        ]

        # Apply filters
        if search:
            mock_subs = [
                s for s in mock_subs if search.lower() in s.display_name.lower()
            ]
        if state:
            mock_subs = [s for s in mock_subs if s.state.value == state]

        total = len(mock_subs)
        start = (page - 1) * page_size
        end = start + page_size

        return mock_subs[start:end], total

    def _get_mock_subscription(self, subscription_id: str) -> Subscription | None:
        """Get a single mock subscription."""
        subs, _ = self._get_mock_subscriptions(None, None, 1, 100)
        for sub in subs:
            if sub.id == subscription_id:
                return sub
        return None

    def _create_mock_subscription(self, data: SubscriptionCreate) -> Subscription:
        """Create a mock subscription."""
        import uuid

        return Subscription(
            id=f"sub-{str(uuid.uuid4())[:8]}",
            name=data.display_name,
            display_name=data.display_name,
            scope=data.scope,
            state=SubscriptionState.ACTIVE,
            primary_key=f"pk-{str(uuid.uuid4())[:8]}",
            created_date=datetime.now(),
            owner_email=data.owner_email,
            token_limit=data.token_limit,
            notes=data.notes,
        )

    def _update_mock_subscription(
        self, subscription_id: str, data: SubscriptionUpdate
    ) -> Subscription | None:
        """Update a mock subscription."""
        sub = self._get_mock_subscription(subscription_id)
        if sub:
            if data.display_name:
                sub.display_name = data.display_name
            if data.state:
                sub.state = data.state
            if data.token_limit:
                sub.token_limit = data.token_limit
            if data.notes is not None:
                sub.notes = data.notes
        return sub


# Singleton instance
_apim_service: APIMService | None = None


def get_apim_service() -> APIMService:
    """Get the APIM service instance."""
    global _apim_service
    if _apim_service is None:
        _apim_service = APIMService()
    return _apim_service
