"""Tests for subscription management."""

import os

# Ensure mock data is used for tests
os.environ["USE_MOCK_DATA"] = "true"

import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture
def client():
    """Create test client."""
    return TestClient(app)


class TestHealthCheck:
    """Test health check endpoint."""

    def test_health_check(self, client):
        """Test that health check returns healthy status."""
        response = client.get("/health")
        assert response.status_code == 200
        assert response.json()["status"] == "healthy"


class TestDashboard:
    """Test dashboard pages."""

    def test_index_page(self, client):
        """Test that index page renders."""
        response = client.get("/")
        assert response.status_code == 200
        assert "Dashboard" in response.text

    def test_subscriptions_page(self, client):
        """Test that subscriptions page renders."""
        response = client.get("/subscriptions")
        assert response.status_code == 200
        assert "Subscriptions" in response.text


class TestSubscriptionAPI:
    """Test subscription API endpoints."""

    def test_list_subscriptions(self, client):
        """Test listing subscriptions."""
        response = client.get("/api/subscriptions")
        assert response.status_code == 200
        data = response.json()
        assert "subscriptions" in data
        assert "total_count" in data
        assert len(data["subscriptions"]) > 0

    def test_list_subscriptions_html(self, client):
        """Test listing subscriptions as HTML."""
        response = client.get("/api/subscriptions/list")
        assert response.status_code == 200
        assert "text/html" in response.headers["content-type"]

    def test_list_subscriptions_with_filter(self, client):
        """Test filtering subscriptions by state."""
        response = client.get("/api/subscriptions?state=active")
        assert response.status_code == 200
        data = response.json()
        for sub in data["subscriptions"]:
            assert sub["state"] == "active"

    def test_get_subscription_detail(self, client):
        """Test getting a single subscription's detail page."""
        # First get list to find an ID
        response = client.get("/api/subscriptions")
        data = response.json()
        if data["subscriptions"]:
            sub_id = data["subscriptions"][0]["id"]
            response = client.get(f"/subscriptions/{sub_id}")
            assert response.status_code == 200
            assert "text/html" in response.headers["content-type"]

    def test_subscription_has_expected_fields(self, client):
        """Test that subscriptions have all required fields."""
        response = client.get("/api/subscriptions")
        data = response.json()
        required_fields = ["id", "name", "state", "created_date"]
        for sub in data["subscriptions"]:
            for field in required_fields:
                assert field in sub, f"Missing field: {field}"


class TestUsageAPI:
    """Test usage API endpoints."""

    def test_get_stats(self, client):
        """Test getting usage stats."""
        response = client.get("/api/usage/stats/json")
        assert response.status_code == 200
        data = response.json()
        assert "total_subscriptions" in data
        assert "total_tokens_today" in data

    def test_get_stats_html(self, client):
        """Test getting usage stats as HTML partial."""
        response = client.get("/api/usage/stats")
        assert response.status_code == 200
        assert "text/html" in response.headers["content-type"]

    def test_get_chart_data(self, client):
        """Test getting chart data."""
        response = client.get("/api/usage/chart-data/json")
        assert response.status_code == 200
        data = response.json()
        assert "labels" in data
        assert "values" in data
        assert isinstance(data["labels"], list)
        assert isinstance(data["values"], list)

    def test_get_top_consumers(self, client):
        """Test getting top consumers."""
        response = client.get("/api/usage/top-consumers/json")
        assert response.status_code == 200
        data = response.json()
        assert isinstance(data, list)
        if len(data) > 0:
            assert "total_tokens" in data[0]
            assert "name" in data[0]


class TestSubscriptionActions:
    """Test subscription modification actions."""

    def test_suspend_subscription(self, client):
        """Test suspending a subscription."""
        # Get an active subscription
        response = client.get("/api/subscriptions?state=active")
        data = response.json()
        if data["subscriptions"]:
            sub_id = data["subscriptions"][0]["id"]
            response = client.post(f"/api/subscriptions/{sub_id}/suspend")
            assert response.status_code == 200

    def test_activate_subscription(self, client):
        """Test activating a subscription."""
        # Get a suspended subscription
        response = client.get("/api/subscriptions?state=suspended")
        data = response.json()
        if data["subscriptions"]:
            sub_id = data["subscriptions"][0]["id"]
            response = client.post(f"/api/subscriptions/{sub_id}/activate")
            assert response.status_code == 200


class TestModels:
    """Test Pydantic models."""

    def test_subscription_model(self):
        """Test Subscription model validation."""
        from datetime import datetime

        from app.models.subscription import Subscription, SubscriptionState

        sub = Subscription(
            id="test-sub",
            name="Test Subscription",
            display_name="Test Subscription",
            state=SubscriptionState.ACTIVE,
            scope="/products/llm-api",
            created_date=datetime.now(),
        )
        assert sub.id == "test-sub"
        assert sub.state == SubscriptionState.ACTIVE

    def test_usage_stats_model(self):
        """Test UsageStats model."""
        from app.models.usage import UsageStats

        stats = UsageStats(
            total_subscriptions=10,
            active_subscriptions=8,
            total_tokens_today=50000,
            total_tokens_this_month=1200000,
        )
        assert stats.total_subscriptions == 10
        assert stats.active_subscriptions == 8

    def test_token_limit_model(self):
        """Test TokenLimit model."""
        from app.models.subscription import TokenLimit

        limit = TokenLimit(
            max_tokens_per_day=100000,
            max_tokens_per_month=3000000,
        )
        assert limit.max_tokens_per_day == 100000
        assert limit.max_tokens_per_month == 3000000
