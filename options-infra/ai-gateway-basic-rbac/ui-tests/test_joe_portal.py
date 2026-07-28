"""
UI tests executed as an interactively-logged-in user (default: Joe = Foundry User
at project scope). Storage state is populated by auth_setup.py.

These tests are deliberately resilient — the Foundry portal DOM changes often,
so assertions target the highest-signal signals we can find (landing page,
`ai-foundry-` account name in the URL, presence/absence of "New project"
buttons, error toasts, etc.) rather than brittle CSS paths.

Numbering (UI-*) is aligned with the manual-ui-test-plan.md IDs so evidence
rolls up cleanly into the HTML report.
"""
from __future__ import annotations

import re

import pytest
from playwright.sync_api import Page, expect


# ------------------------------------------------------------------ helpers


def _dismiss_common_dialogs(page: Page) -> None:
    """Best-effort dismissal of cookie / tour / "what's new" dialogs."""
    for label in ("Accept", "Got it", "Close", "Dismiss", "Skip"):
        try:
            btn = page.get_by_role("button", name=re.compile(label, re.I))
            if btn.count() > 0 and btn.first.is_visible():
                btn.first.click(timeout=1500)
        except Exception:
            pass


def _record(ui_evidence, *, test_id, scenario, operation, expected, actual, passed, user_label, notes=""):
    ui_evidence.record(
        testId=test_id,
        userLabel=user_label,
        scenario=scenario,
        operation=operation,
        expectedOutcome=expected,
        actualOutcome=actual,
        passed=passed,
        notes=notes,
    )


# ============================================================ POSITIVE tests
# Joe (Foundry User at project scope) MUST be able to:
#   - open the Foundry portal
#   - see and open the project he has access to
#   - open the Agents playground for that project


@pytest.mark.positive
def test_ui01_can_open_portal(page: Page, portal_home, user_label, ui_evidence):
    """UI-01: Joe can load the Foundry portal home and is authenticated."""
    page.goto(portal_home, wait_until="domcontentloaded")
    _dismiss_common_dialogs(page)

    # If we got kicked back to login.microsoftonline.com the storage state expired.
    assert "login.microsoftonline.com" not in page.url, (
        "Storage state expired — re-run `uv run python auth_setup.py`."
    )
    # Foundry sets its own domain in the URL; any *.azure.com host is fine.
    passed = "azure.com" in page.url
    _record(ui_evidence, test_id="UI-01", scenario="positive",
            operation=f"GET {portal_home}", expected="Loaded, authenticated (no login redirect)",
            actual=f"URL={page.url}", passed=passed, user_label=user_label)
    assert passed


@pytest.mark.positive
def test_ui02_can_see_project(page: Page, project_url, user_label, ui_evidence):
    """UI-02: Joe can navigate to his assigned Foundry project."""
    page.goto(project_url, wait_until="domcontentloaded")
    _dismiss_common_dialogs(page)
    page.wait_for_timeout(3000)  # let the SPA settle

    body = page.locator("body").inner_text(timeout=5000).lower()
    # Any of these strings appearing on a fully-rendered project overview means
    # Joe actually reached the project (vs. an access-denied splash).
    reachable = any(kw in body for kw in ("playground", "agents", "models", "overview"))
    denied = any(kw in body for kw in (
        "you don't have access", "access denied", "not authorized", "you do not have permission",
    ))

    passed = reachable and not denied
    _record(ui_evidence, test_id="UI-02", scenario="positive",
            operation=f"GET {project_url}",
            expected="Project overview visible, no access-denied message",
            actual=f"URL={page.url}; reachable={reachable}; denied={denied}",
            passed=passed, user_label=user_label,
            notes="Foundry User at project scope — should have full project data-plane read/write.")
    assert passed, f"Expected Joe to see project, got body head: {body[:300]}"


@pytest.mark.positive
def test_ui03_agents_playground_visible(page: Page, project_url, user_label, ui_evidence):
    """UI-03: Joe can see the Agents / Playground area of his project."""
    page.goto(project_url, wait_until="domcontentloaded")
    _dismiss_common_dialogs(page)
    page.wait_for_timeout(3000)

    # Try to find any nav link/button that indicates the agents surface is exposed to Joe.
    candidates = [
        page.get_by_role("link", name=re.compile(r"^\s*agents\s*$", re.I)),
        page.get_by_role("link", name=re.compile("playground", re.I)),
        page.get_by_role("button", name=re.compile(r"^\s*agents\s*$", re.I)),
        page.get_by_text(re.compile(r"^\s*agents\s*$", re.I), exact=False),
    ]
    hit = False
    for c in candidates:
        try:
            if c.count() > 0 and c.first.is_visible():
                hit = True
                break
        except Exception:
            continue

    _record(ui_evidence, test_id="UI-03", scenario="positive",
            operation="Locate Agents / Playground entry point on project overview",
            expected="Agents / Playground link or button visible",
            actual=f"visible={hit}",
            passed=hit, user_label=user_label)
    assert hit, "Could not find an Agents/Playground nav entry — expected for Foundry User."


# ============================================================ NEGATIVE tests
# Joe (Foundry User) MUST NOT be able to:
#   - see a "create new Foundry project" affordance from a place he shouldn't
#   - see a "deploy a new model" affordance
#   - see a "publish to Teams" / M365 tab in an agent
# The UI hides these buttons for lower-privilege users; the harness asserts
# that the buttons are absent OR clicking them yields an access-denied error.


@pytest.mark.negative
def test_ui04_no_new_project_button(page: Page, portal_home, user_label, ui_evidence):
    """UI-04: no 'New / Create project' button in the account picker for Joe."""
    page.goto(portal_home, wait_until="domcontentloaded")
    _dismiss_common_dialogs(page)
    page.wait_for_timeout(3000)

    # Foundry's global chrome exposes a "+ New project" affordance to users with
    # sufficient rights (Project Manager / Account Owner). Foundry User should
    # not see it, or clicking should error out.
    candidates = [
        page.get_by_role("button", name=re.compile(r"new\s*project", re.I)),
        page.get_by_role("link", name=re.compile(r"new\s*project", re.I)),
        page.get_by_role("button", name=re.compile(r"create.*project", re.I)),
    ]
    visible = 0
    for c in candidates:
        try:
            if c.count() > 0 and c.first.is_visible():
                visible += 1
        except Exception:
            pass

    passed = visible == 0
    _record(ui_evidence, test_id="UI-04", scenario="negative",
            operation="Look for 'New project' / 'Create project' controls on Foundry home",
            expected="No creation controls visible for Foundry User",
            actual=f"visible_candidate_controls={visible}",
            passed=passed, user_label=user_label,
            notes=(
                "If the button is visible, verify that clicking it errors out — "
                "Foundry User at project scope MUST NOT create new projects."
            ))
    assert passed, f"Found {visible} project-creation control(s) — Foundry User should not see them."


@pytest.mark.negative
def test_ui05_no_model_deployment_action(page: Page, project_url, user_label, ui_evidence):
    """UI-05: Joe should not be able to deploy a new base model.

    This is enforced by BOTH RBAC (N-03 in the API suite) AND the Azure Policy
    `deny-cognitive-services-model-deployments`. The UI usually hides the
    'Deploy model' primary button for Foundry User — assert that.
    """
    page.goto(project_url, wait_until="domcontentloaded")
    _dismiss_common_dialogs(page)

    # Try to navigate to "Models + endpoints" if the link is exposed.
    for name in ("Models + endpoints", "Models and endpoints", "Model catalog", "Deployments"):
        try:
            link = page.get_by_role("link", name=re.compile(name, re.I))
            if link.count() > 0 and link.first.is_visible():
                link.first.click(timeout=2000)
                page.wait_for_timeout(2500)
                break
        except Exception:
            continue

    deploy_buttons = [
        page.get_by_role("button", name=re.compile(r"deploy\s*(a\s*)?(base\s*)?model", re.I)),
        page.get_by_role("button", name=re.compile(r"^\s*deploy\s*$", re.I)),
    ]
    visible = 0
    for c in deploy_buttons:
        try:
            if c.count() > 0 and c.first.is_visible():
                visible += 1
        except Exception:
            pass

    passed = visible == 0
    _record(ui_evidence, test_id="UI-05", scenario="negative",
            operation="Look for 'Deploy model' primary button in Models + endpoints",
            expected="No deploy controls visible for Foundry User",
            actual=f"visible_deploy_buttons={visible}; url={page.url}",
            passed=passed, user_label=user_label,
            notes="Layered defense: role denies + Azure Policy deny-cognitive-services-model-deployments.")
    assert passed, f"Found {visible} 'Deploy model' control(s) — should be hidden for Foundry User."


@pytest.mark.negative
def test_ui06_no_publish_to_teams(page: Page, project_url, user_label, ui_evidence):
    """UI-06: Joe should not see a 'Publish to Microsoft Teams / M365' option.

    Customer requirement: playground only, no Teams publishing.
    """
    page.goto(project_url, wait_until="domcontentloaded")
    _dismiss_common_dialogs(page)
    page.wait_for_timeout(2000)

    body_text = page.locator("body").inner_text(timeout=5000).lower()
    matches = [t for t in ("publish to teams", "microsoft 365", "publish to m365") if t in body_text]

    passed = len(matches) == 0
    _record(ui_evidence, test_id="UI-06", scenario="negative",
            operation="Search project overview for Teams / M365 publish affordances",
            expected="No Teams / M365 publish affordance present for Foundry User",
            actual=f"matches={matches}",
            passed=passed, user_label=user_label,
            notes="Repeat on an individual agent detail page if publishing surfaces there.")
    assert passed, f"Unexpected Teams/M365 publish surface: {matches}"
