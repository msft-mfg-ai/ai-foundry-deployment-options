from __future__ import annotations

import csv
import json
import os
import pathlib
import time
from dataclasses import asdict, dataclass, field

import pytest
from dotenv import dotenv_values, load_dotenv

HERE = pathlib.Path(__file__).parent

# Load ui-tests/.env first, then fall back to values from the sibling tests/.env
# (subscription/RG/project names produced by `azd up`).
load_dotenv(HERE / ".env")
_tests_env = HERE.parent / "tests" / ".env"
if _tests_env.exists():
    for k, v in dotenv_values(_tests_env).items():
        os.environ.setdefault(k, v or "")

OUTPUT_DIR = HERE / "output"
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)


# --------------------------------------------------------------------------- #
# Fixtures                                                                    #
# --------------------------------------------------------------------------- #


@pytest.fixture(scope="session")
def user_label() -> str:
    return os.environ.get("UI_USER_LABEL", "unknown-user")


@pytest.fixture(scope="session")
def portal_home() -> str:
    return os.environ.get("FOUNDRY_PORTAL_HOME", "https://ai.azure.com/").rstrip("/") + "/"


@pytest.fixture(scope="session")
def project_url(portal_home) -> str:
    override = os.environ.get("FOUNDRY_PROJECT_URL", "").strip()
    if override:
        return override
    sub = os.environ.get("AZURE_SUBSCRIPTION_ID", "")
    rg = os.environ.get("AZURE_RESOURCE_GROUP", "")
    proj = os.environ.get("FOUNDRY_PROJECT_NAME", "")
    # Foundry portal deep-link pattern for a project overview.
    if sub and rg and proj:
        return (
            f"{portal_home}resource/overview?"
            f"tid={os.environ.get('AZURE_TENANT_ID','')}"
            f"&wsid=/subscriptions/{sub}/resourceGroups/{rg}"
            f"/providers/Microsoft.CognitiveServices/accounts/"
            f"{os.environ.get('FOUNDRY_ACCOUNT_NAME','')}/projects/{proj}"
        )
    return portal_home


@pytest.fixture(scope="session")
def storage_state_path() -> str:
    p = HERE / os.environ.get("STORAGE_STATE_PATH", ".auth/joe.json")
    if not p.exists():
        pytest.exit(
            f"Storage state {p} not found. Run `uv run python auth_setup.py` first "
            f"and sign in as the user under test."
        )
    return str(p)


@pytest.fixture(scope="session")
def browser_context_args(browser_context_args, storage_state_path):
    """pytest-playwright hook: reuse the interactively-saved auth cookies."""
    return {
        **browser_context_args,
        "storage_state": storage_state_path,
        "viewport": {"width": 1440, "height": 900},
    }


# --------------------------------------------------------------------------- #
# Evidence recorder                                                           #
# --------------------------------------------------------------------------- #


@dataclass
class UiEvidenceRow:
    testId: str
    userLabel: str
    scenario: str  # positive | negative
    operation: str
    expectedOutcome: str
    actualOutcome: str
    passed: bool
    timestampUtc: str = field(default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    notes: str = ""


class UiEvidenceRecorder:
    def __init__(self) -> None:
        self.rows: list[UiEvidenceRow] = []

    def record(self, **kw) -> None:
        self.rows.append(UiEvidenceRow(**kw))

    def dump(self) -> None:
        if not self.rows:
            return
        data = [asdict(r) for r in self.rows]
        (OUTPUT_DIR / "ui-validation-results.json").write_text(json.dumps(data, indent=2))
        fieldnames = list(data[0].keys())
        with (OUTPUT_DIR / "ui-validation-results.csv").open("w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=fieldnames)
            w.writeheader()
            for r in data:
                w.writerow(r)


_RECORDER = UiEvidenceRecorder()


@pytest.fixture(scope="session")
def ui_evidence():
    yield _RECORDER
    _RECORDER.dump()
