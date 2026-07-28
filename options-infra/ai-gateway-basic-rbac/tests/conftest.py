"""Shared pytest fixtures for the Foundry RBAC validation harness.

Provides:
    * per-persona ClientSecretCredential (builder/runtime/platform/project-admin/none)
    * bearer-token helpers for ARM and Foundry data-plane scopes
    * evidence recorder that emits output/rbac-validation-results.{json,csv}
      per the schema in foundry-rbac-ghcp-implementation-spec.html
"""
from __future__ import annotations

import csv
import json
import os
import time
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Iterable

import httpx
import pytest
from azure.identity import ClientSecretCredential
from dotenv import load_dotenv


REPO_ROOT = Path(__file__).resolve().parents[3]
TESTS_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = TESTS_DIR / "output"
OUTPUT_DIR.mkdir(exist_ok=True)

load_dotenv(TESTS_DIR / ".env")


# --------------------------------------------------------------------------- #
# Environment                                                                 #
# --------------------------------------------------------------------------- #


def _env(name: str, default: str = "") -> str:
    val = os.environ.get(name, default)
    if not val and default == "":
        raise RuntimeError(
            f"Environment variable {name} is not set. Run `azd up` in "
            "options-infra/ai-gateway-basic-rbac/ to generate tests/.env."
        )
    return val


@dataclass
class Persona:
    persona: str
    role: str
    scope: str
    app_id: str
    object_id: str
    display_name: str
    client_secret: str
    tenant_id: str = ""


def _load_personas() -> dict[str, Persona]:
    sp_json = _env("RBAC_SP_JSON", "[]")
    secrets_json = _env("RBAC_SP_SECRETS_JSON", "{}")
    tid = _env("AZURE_TENANT_ID", "")
    sps = json.loads(sp_json) if sp_json else []
    secrets = json.loads(secrets_json) if secrets_json else {}
    out: dict[str, Persona] = {}
    for sp in sps:
        key = sp["persona"]
        out[key] = Persona(
            persona=key,
            role=sp.get("role", ""),
            scope=sp.get("scope", "none"),
            app_id=sp["appId"],
            object_id=sp["objectId"],
            display_name=sp["displayName"],
            client_secret=secrets.get(key, ""),
            tenant_id=tid,
        )
    return out


PERSONAS = _load_personas()


@pytest.fixture(scope="session")
def personas() -> dict[str, Persona]:
    return PERSONAS


@pytest.fixture(scope="session")
def tenant_id() -> str:
    return _env("AZURE_TENANT_ID")


@pytest.fixture(scope="session")
def subscription_id() -> str:
    return _env("AZURE_SUBSCRIPTION_ID")


@pytest.fixture(scope="session")
def resource_group() -> str:
    return _env("AZURE_RESOURCE_GROUP")


@pytest.fixture(scope="session")
def location() -> str:
    return _env("AZURE_LOCATION")


@pytest.fixture(scope="session")
def foundry_name() -> str:
    return _env("FOUNDRY_NAME")


@pytest.fixture(scope="session")
def foundry_endpoint() -> str:
    return _env("FOUNDRY_ENDPOINT")


@pytest.fixture(scope="session")
def foundry_project_endpoint() -> str:
    return _env("FOUNDRY_PROJECT_ENDPOINT")


@pytest.fixture(scope="session")
def foundry_project_name() -> str:
    return _env("FOUNDRY_PROJECT_NAME")


@pytest.fixture(scope="session")
def account_scope(subscription_id, resource_group, foundry_name) -> str:
    return (
        f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{foundry_name}"
    )


@pytest.fixture(scope="session")
def project_scope(account_scope, foundry_project_name) -> str:
    return f"{account_scope}/projects/{foundry_project_name}"


# --------------------------------------------------------------------------- #
# Credentials                                                                 #
# --------------------------------------------------------------------------- #


def _credential_for(p: Persona, tenant_id: str) -> ClientSecretCredential:
    if not p.client_secret:
        pytest.skip(f"Persona {p.persona} has no client secret in RBAC_SP_SECRETS_JSON.")
    return ClientSecretCredential(
        tenant_id=tenant_id,
        client_id=p.app_id,
        client_secret=p.client_secret,
    )


@pytest.fixture(scope="session")
def cred_builder(personas, tenant_id):
    return _credential_for(personas["builder"], tenant_id)


@pytest.fixture(scope="session")
def cred_runtime(personas, tenant_id):
    return _credential_for(personas["runtime"], tenant_id)


@pytest.fixture(scope="session")
def cred_responses(personas, tenant_id):
    return _credential_for(personas["responses"], tenant_id)


@pytest.fixture(scope="session")
def cred_platform(personas, tenant_id):
    return _credential_for(personas["platform"], tenant_id)


@pytest.fixture(scope="session")
def cred_project_admin(personas, tenant_id):
    return _credential_for(personas["project-admin"], tenant_id)


@pytest.fixture(scope="session")
def cred_none(personas, tenant_id):
    return _credential_for(personas["none"], tenant_id)


ARM_SCOPE = "https://management.azure.com/.default"
FOUNDRY_SCOPE = "https://ai.azure.com/.default"


def get_arm_token(cred: ClientSecretCredential) -> str:
    return cred.get_token(ARM_SCOPE).token


def get_foundry_token(cred: ClientSecretCredential) -> str:
    return cred.get_token(FOUNDRY_SCOPE).token


# --------------------------------------------------------------------------- #
# HTTP helpers                                                                #
# --------------------------------------------------------------------------- #


def arm_request(
    method: str,
    url: str,
    token: str,
    *,
    api_version: str = "2023-05-01",
    json_body: dict | None = None,
    extra_params: dict | None = None,
) -> httpx.Response:
    params = {"api-version": api_version}
    if extra_params:
        params.update(extra_params)
    headers = {
        "Authorization": f"Bearer {token}",
        "x-ms-client-request-id": str(uuid.uuid4()),
    }
    with httpx.Client(timeout=30.0) as client:
        return client.request(method, url, headers=headers, params=params, json=json_body)


def foundry_request(
    method: str,
    url: str,
    token: str,
    *,
    api_version: str = "v1",
    json_body: dict | None = None,
) -> httpx.Response:
    params = {"api-version": api_version}
    headers = {
        "Authorization": f"Bearer {token}",
        "x-ms-client-request-id": str(uuid.uuid4()),
    }
    with httpx.Client(timeout=60.0) as client:
        return client.request(method, url, headers=headers, params=params, json=json_body)


# --------------------------------------------------------------------------- #
# Evidence recorder                                                           #
# --------------------------------------------------------------------------- #


@dataclass
class EvidenceRow:
    testId: str
    suite: str
    persona: str
    principalObjectId: str
    roleAssignments: list[dict[str, str]]
    operation: str
    expectedOutcome: str
    actualOutcome: str
    httpStatus: int | None
    passed: bool
    requestId: str = ""
    correlationId: str = ""
    timestampUtc: str = field(default_factory=lambda: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    notes: str = ""


class EvidenceRecorder:
    def __init__(self) -> None:
        self.rows: list[EvidenceRow] = []

    def record(self, row: EvidenceRow) -> None:
        self.rows.append(row)

    def record_response(
        self,
        *,
        test_id: str,
        suite: str,
        persona: Persona | None,
        operation: str,
        expected: str,
        response: httpx.Response | None,
        passed: bool,
        notes: str = "",
    ) -> None:
        request_id = ""
        correlation_id = ""
        status = None
        actual = "no-response"
        if response is not None:
            request_id = response.headers.get("x-ms-request-id", "") or response.headers.get("x-request-id", "")
            correlation_id = response.headers.get("x-ms-correlation-request-id", "")
            status = response.status_code
            actual = f"HTTP {status}"
        role_assignments: list[dict[str, str]] = []
        if persona is not None and persona.role:
            role_assignments.append({"roleName": persona.role, "scope": persona.scope})
        self.record(
            EvidenceRow(
                testId=test_id,
                suite=suite,
                persona=persona.persona if persona else "",
                principalObjectId=persona.object_id if persona else "",
                roleAssignments=role_assignments,
                operation=operation,
                expectedOutcome=expected,
                actualOutcome=actual,
                httpStatus=status,
                passed=passed,
                requestId=request_id,
                correlationId=correlation_id,
                notes=notes,
            )
        )

    def record_raw(
        self,
        *,
        test_id: str,
        suite: str,
        persona: Persona | None,
        operation: str,
        expected: str,
        status_code: int | None,
        response_body: str,
        passed: bool,
        notes: str = "",
    ) -> None:
        role_assignments: list[dict[str, str]] = []
        if persona is not None and persona.role:
            role_assignments.append({"roleName": persona.role, "scope": persona.scope})
        self.record(
            EvidenceRow(
                testId=test_id,
                suite=suite,
                persona=persona.persona if persona else "",
                principalObjectId=persona.object_id if persona else "",
                roleAssignments=role_assignments,
                operation=operation,
                expectedOutcome=expected,
                actualOutcome=(f"HTTP {status_code}" if status_code else "no-response") + (
                    f" — {response_body[:200]}" if response_body else ""
                ),
                httpStatus=status_code,
                passed=passed,
                notes=notes,
            )
        )

    def dump(self) -> None:
        json_path = OUTPUT_DIR / "rbac-validation-results.json"
        csv_path = OUTPUT_DIR / "rbac-validation-results.csv"
        data = [asdict(r) for r in self.rows]
        json_path.write_text(json.dumps(data, indent=2))
        if self.rows:
            fieldnames = list(asdict(self.rows[0]).keys())
            with csv_path.open("w", newline="") as fh:
                writer = csv.DictWriter(fh, fieldnames=fieldnames)
                writer.writeheader()
                for r in data:
                    row = {**r, "roleAssignments": json.dumps(r["roleAssignments"])}
                    writer.writerow(row)


_RECORDER = EvidenceRecorder()


@pytest.fixture(scope="session")
def evidence() -> Iterable[EvidenceRecorder]:
    yield _RECORDER
    _RECORDER.dump()


# --------------------------------------------------------------------------- #
# Skip helpers                                                                #
# --------------------------------------------------------------------------- #


def skip_manual_required(test_id: str, ui_id: str, reason: str) -> None:
    """Signal a ManualRequired result — Foundry data-plane path has no stable API."""
    _RECORDER.record(
        EvidenceRow(
            testId=test_id,
            suite="ManualRequired",
            persona="",
            principalObjectId="",
            roleAssignments=[],
            operation=reason,
            expectedOutcome="Manual UI",
            actualOutcome="ManualRequired",
            httpStatus=None,
            passed=False,
            notes=f"See docs/manual-ui-test-plan.md {ui_id}.",
        )
    )
    pytest.skip(f"ManualRequired ({ui_id}): {reason}")
