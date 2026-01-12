"""End-to-end Playwright tests for the Subscription Manager app."""

import os
import re
import subprocess
import time

import pytest
from playwright.sync_api import Page, expect

# Ensure mock data is used for tests
os.environ["USE_MOCK_DATA"] = "true"


@pytest.fixture(scope="module")
def app_server():
    """Start the app server for E2E tests."""
    env = os.environ.copy()
    env["USE_MOCK_DATA"] = "true"

    # Start the server
    process = subprocess.Popen(
        [
            "uv",
            "run",
            "uvicorn",
            "app.main:app",
            "--host",
            "127.0.0.1",
            "--port",
            "8001",
        ],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    # Wait for server to start
    time.sleep(2)

    yield "http://127.0.0.1:8001"

    # Cleanup
    process.terminate()
    process.wait()


class TestDashboardPage:
    """E2E tests for the dashboard page."""

    def test_dashboard_loads(self, page: Page, app_server: str):
        """Test that the dashboard page loads correctly."""
        page.goto(app_server)

        # Check page title
        expect(page).to_have_title(re.compile("Subscription Manager"))

        # Check main heading
        expect(page.get_by_role("heading", name="Dashboard")).to_be_visible()

    def test_dashboard_shows_stats_cards(self, page: Page, app_server: str):
        """Test that stats cards load via HTMX."""
        page.goto(app_server)

        # Wait for HTMX to load the stats
        page.wait_for_selector("text=Total Subscriptions", timeout=5000)

        # Verify stats are displayed
        expect(page.get_by_text("Total Subscriptions")).to_be_visible()
        expect(page.get_by_text("Tokens Today")).to_be_visible()

    def test_dashboard_shows_top_consumers(self, page: Page, app_server: str):
        """Test that top consumers section loads."""
        page.goto(app_server)

        # Wait for top consumers to load
        page.wait_for_selector("text=Top Token Consumers", timeout=5000)

        # Verify top consumers heading
        expect(page.get_by_text("Top Token Consumers")).to_be_visible()

        # Should show subscription links
        expect(
            page.get_by_role("link", name="Production API Access").first
        ).to_be_visible()

    def test_dashboard_shows_recent_subscriptions(self, page: Page, app_server: str):
        """Test that recent subscriptions section loads."""
        page.goto(app_server)

        # Wait for recent subscriptions to load
        page.wait_for_selector("text=Recent Subscriptions", timeout=5000)

        # Verify recent subscriptions heading
        expect(page.get_by_text("Recent Subscriptions")).to_be_visible()

    def test_navigate_to_subscriptions_page(self, page: Page, app_server: str):
        """Test navigation from dashboard to subscriptions page."""
        page.goto(app_server)

        # Click on Subscriptions link in nav
        page.get_by_role("link", name="Subscriptions", exact=True).click()

        # Verify we're on the subscriptions page
        expect(page).to_have_url(re.compile("/subscriptions"))
        expect(page.get_by_role("heading", name="Subscriptions")).to_be_visible()


class TestSubscriptionsPage:
    """E2E tests for the subscriptions list page."""

    def test_subscriptions_page_loads(self, page: Page, app_server: str):
        """Test that the subscriptions page loads correctly."""
        page.goto(f"{app_server}/subscriptions")

        # Check main heading
        expect(page.get_by_role("heading", name="Subscriptions")).to_be_visible()

        # Check for search and filter controls
        expect(page.get_by_placeholder("Search subscriptions...")).to_be_visible()
        expect(page.get_by_role("combobox", name="State")).to_be_visible()

    def test_subscriptions_table_loads(self, page: Page, app_server: str):
        """Test that the subscriptions table loads with data."""
        page.goto(f"{app_server}/subscriptions")

        # Wait for table to load via HTMX
        page.wait_for_selector("table", timeout=5000)

        # Verify table headers
        expect(page.get_by_role("columnheader", name="Subscription")).to_be_visible()
        expect(page.get_by_role("columnheader", name="State")).to_be_visible()
        expect(page.get_by_role("columnheader", name="Token Limit")).to_be_visible()

        # Verify subscription data is displayed
        expect(page.get_by_role("link", name="Production API Access")).to_be_visible()
        expect(page.get_by_role("link", name="Development Team")).to_be_visible()

    def test_filter_by_state(self, page: Page, app_server: str):
        """Test filtering subscriptions by state."""
        page.goto(f"{app_server}/subscriptions")

        # Wait for initial load
        page.wait_for_selector("table", timeout=5000)

        # Select 'Suspended' state filter
        page.get_by_role("combobox", name="State").select_option("suspended")

        # Wait for filtered results - HTMX will reload the table
        page.wait_for_timeout(1000)  # Give HTMX time to update

        # Should show suspended subscription (Testing Environment)
        expect(page.get_by_role("link", name="Testing Environment")).to_be_visible()

    def test_click_subscription_opens_detail(self, page: Page, app_server: str):
        """Test clicking a subscription opens the detail page."""
        page.goto(f"{app_server}/subscriptions")

        # Wait for table to load
        page.wait_for_selector("table", timeout=5000)

        # Click on a subscription
        page.get_by_role("link", name="Production API Access").click()

        # Verify we're on the detail page
        expect(page).to_have_url(re.compile("/subscriptions/sub-001"))
        expect(
            page.get_by_role("heading", name="Production API Access")
        ).to_be_visible()


class TestSubscriptionDetailPage:
    """E2E tests for the subscription detail page."""

    def test_subscription_detail_loads(self, page: Page, app_server: str):
        """Test that the subscription detail page loads correctly."""
        page.goto(f"{app_server}/subscriptions/sub-001")

        # Check main heading
        expect(
            page.get_by_role("heading", name="Production API Access")
        ).to_be_visible()

        # Check subscription info is displayed
        expect(page.get_by_text("sub-001")).to_be_visible()
        expect(page.get_by_text("team-a@example.com")).to_be_visible()

    def test_subscription_shows_token_limits(self, page: Page, app_server: str):
        """Test that token limits section is displayed."""
        page.goto(f"{app_server}/subscriptions/sub-001")

        # Check token limits section
        expect(page.get_by_text("Token Limits")).to_be_visible()
        expect(page.get_by_text("Max Tokens/Day")).to_be_visible()
        expect(page.get_by_text("1,000,000")).to_be_visible()

    def test_subscription_shows_daily_usage_table(self, page: Page, app_server: str):
        """Test that daily usage table loads."""
        page.goto(f"{app_server}/subscriptions/sub-001")

        # Wait for daily usage table to load via HTMX
        page.wait_for_selector("text=Daily Usage Details", timeout=5000)

        # Check table is displayed
        expect(page.get_by_text("Daily Usage Details")).to_be_visible()

        # Wait for table content
        page.wait_for_selector(
            "table:below(:text('Daily Usage Details'))", timeout=5000
        )

        # Verify table has data
        expect(page.get_by_role("columnheader", name="Requests")).to_be_visible()
        expect(page.get_by_role("columnheader", name="Total Tokens")).to_be_visible()

    def test_back_navigation(self, page: Page, app_server: str):
        """Test back navigation to subscriptions list."""
        page.goto(f"{app_server}/subscriptions/sub-001")

        # Click back link
        page.get_by_role("link", name="Back to Subscriptions").click()

        # Verify we're back on the subscriptions page
        expect(page).to_have_url(re.compile("/subscriptions$"))

    def test_suspend_button_visible_for_active_subscription(
        self, page: Page, app_server: str
    ):
        """Test that suspend button is visible for active subscriptions."""
        page.goto(f"{app_server}/subscriptions/sub-001")

        # Check suspend button is visible
        expect(page.get_by_role("button", name="Suspend")).to_be_visible()

    def test_activate_button_visible_for_suspended_subscription(
        self, page: Page, app_server: str
    ):
        """Test that activate button is visible for suspended subscriptions."""
        page.goto(
            f"{app_server}/subscriptions/sub-003"
        )  # Testing Environment is suspended

        # Wait for page to load
        page.wait_for_selector("text=Testing Environment", timeout=5000)

        # Check activate button is visible
        expect(page.get_by_role("button", name="Activate")).to_be_visible()


class TestNavigation:
    """E2E tests for navigation elements."""

    def test_navbar_links(self, page: Page, app_server: str):
        """Test that navbar links work correctly."""
        page.goto(app_server)

        # Check navbar links are present
        expect(page.get_by_role("link", name="Dashboard")).to_be_visible()
        expect(
            page.get_by_role("link", name="Subscriptions", exact=True)
        ).to_be_visible()

        # Click subscriptions
        page.get_by_role("link", name="Subscriptions", exact=True).click()
        expect(page).to_have_url(re.compile("/subscriptions"))

        # Click dashboard
        page.get_by_role("link", name="Dashboard").click()
        expect(page).to_have_url(f"{app_server}/")

    def test_logo_link_goes_to_dashboard(self, page: Page, app_server: str):
        """Test that clicking the logo goes to dashboard."""
        page.goto(f"{app_server}/subscriptions")

        # Click logo/brand link
        page.get_by_role("link", name="Subscription Manager").click()

        # Should be on dashboard
        expect(page).to_have_url(f"{app_server}/")


class TestResponsiveness:
    """E2E tests for responsive design."""

    def test_mobile_viewport(self, page: Page, app_server: str):
        """Test that the app works on mobile viewport."""
        # Set mobile viewport
        page.set_viewport_size({"width": 375, "height": 667})

        page.goto(app_server)

        # Dashboard should still load
        expect(page.get_by_role("heading", name="Dashboard")).to_be_visible()

    def test_tablet_viewport(self, page: Page, app_server: str):
        """Test that the app works on tablet viewport."""
        # Set tablet viewport
        page.set_viewport_size({"width": 768, "height": 1024})

        page.goto(f"{app_server}/subscriptions")

        # Subscriptions table should load
        page.wait_for_selector("table", timeout=5000)
        expect(page.get_by_role("columnheader", name="Subscription")).to_be_visible()
