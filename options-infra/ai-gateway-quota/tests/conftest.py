"""Pytest fixtures shared by all ai-gateway-quota live integration tests.

Required environment variables:
  APIM_GATEWAY_URL  Base URL of the deployed APIM gateway, e.g. https://x.azure-api.net
  TENANT_ID         Microsoft Entra tenant ID used by the gateway JWT policy

Authentication options, in priority order:
  TEST_ACCESS_TOKEN              Explicit bearer token for https://cognitiveservices.azure.com
  CLIENT_ID + CLIENT_SECRET      App registration credentials (TENANT_ID is reused)
  az login / managed identity    DefaultAzureCredential fallback

Optional variables:
  APIM_SUBSCRIPTION_KEY or APIM_API_KEY  Only if this deployment requires an APIM key
  TEST_MODEL                           Defaults to gpt-4.1-mini
  TEST_FAILOVER_MODEL                  Defaults to TEST_MODEL
  TEST_CONTRACT                        Defaults to Team Alpha
  API_VERSION                          Defaults to 2025-03-01-preview
  AUDIENCE                             Defaults to https://cognitiveservices.azure.com
"""

from __future__ import annotations

import textwrap

import pytest

from gateway import (
    APIM_SUBSCRIPTION_KEY,
    DEFAULT_CONTRACT_NAME,
    DEFAULT_MODEL,
    FAILOVER_MODEL,
    GATEWAY_URL,
    TEST_ACCESS_TOKEN,
    get_token,
    validate_required_config,
)


# ---------------------------------------------------------------------------
# Reporting hooks — make `pytest` self-documenting.
# ---------------------------------------------------------------------------


def pytest_configure(config) -> None:
    validate_required_config()


def pytest_report_header(config) -> list[str]:
    """Banner printed once at the start of the run."""
    return [
        '',
        '=' * 78,
        'ai-gateway-quota live integration tests',
        '=' * 78,
        f'  gateway:  {GATEWAY_URL}',
        f'  model:    {DEFAULT_MODEL}',
        f'  failover: {FAILOVER_MODEL}',
        f'  contract: {DEFAULT_CONTRACT_NAME}',
        f'  sub-key:  {"set" if APIM_SUBSCRIPTION_KEY else "(not set)"}',
        f'  token:    {"explicit (TEST_ACCESS_TOKEN)" if TEST_ACCESS_TOKEN else "client secret / DefaultAzureCredential"}',
        '',
        'Each test prints WHAT it checks, HOW it checks it, and WHY it matters.',
        'A line starting with "→" shows the URL/path hit; "←" shows what came back.',
        '=' * 78,
    ]


def pytest_runtest_setup(item) -> None:
    """Before each test, print its name and docstring."""
    doc = item.function.__doc__ or ''
    print()
    print(f'┌─ {item.name}')
    if doc.strip():
        lines = doc.splitlines()
        first = lines[0].rstrip()
        rest = textwrap.dedent('\n'.join(lines[1:])).splitlines() if len(lines) > 1 else []
        if first:
            print(f'│  {first}')
        for line in rest:
            print(f'│  {line.rstrip()}')
    else:
        print('│  (no docstring)')
    print('├' + '─' * 76)


# ---------------------------------------------------------------------------
# Session-scoped fixtures.
# ---------------------------------------------------------------------------


@pytest.fixture(scope='session')
def gateway_url() -> str:
    return GATEWAY_URL


@pytest.fixture(scope='session')
def model() -> str:
    return DEFAULT_MODEL


@pytest.fixture(scope='session')
def failover_model() -> str:
    return FAILOVER_MODEL


@pytest.fixture(scope='session')
def expected_contract() -> str:
    return DEFAULT_CONTRACT_NAME


@pytest.fixture(scope='session')
def access_token() -> str:
    """Acquire one bearer token per session — saves time across tests."""
    return get_token()


@pytest.fixture(scope='session')
def deployed_models(access_token) -> list[dict]:
    """Discover what's deployed by calling the gateway's /inference/deployments
    endpoint once per session. Returns the raw `value[]` list, where each
    entry has shape `{"name": str, "properties": {"model": {"name", "version",
    "format"}}}`. Used by capability-conditional fixtures (anthropic_model,
    embedding_model) to skip tests when a model class isn't present.
    """
    import requests
    from gateway import GATEWAY_URL
    r = requests.get(
        f'{GATEWAY_URL}/inference/deployments',
        headers={'Authorization': f'Bearer {access_token}'},
        timeout=30,
    )
    if r.status_code != 200:
        return []
    try:
        return r.json().get('value', []) or []
    except Exception:
        return []


def _model_format(d: dict) -> str:
    """Extract the model format ('OpenAI', 'Anthropic', 'Cohere', ...) from a
    deployment dict returned by /inference/deployments."""
    return (((d.get('properties') or {}).get('model') or {}).get('format') or '').strip()


def _pick_model(deployed_models: list[dict], match) -> str | None:
    """Return the first deployment name where `match(deployment)` is True.
    `match` receives the full deployment dict."""
    for d in deployed_models:
        name = (d.get('name') or '').strip()
        if name and match(d):
            return name
    return None


@pytest.fixture(scope='session')
def anthropic_model(deployed_models) -> str:
    """First deployed Anthropic model, or skip the test if none.
    Detected by `properties.model.format == 'Anthropic'`."""
    name = _pick_model(deployed_models, lambda d: _model_format(d).lower() == 'anthropic')
    if not name:
        pytest.skip('No Anthropic model deployed (no deployment with format=Anthropic)')
    return name


@pytest.fixture(scope='session')
def embedding_model(deployed_models) -> str:
    """First deployed embedding model, or skip the test if none.
    Detected by name (e.g. text-embedding-3-small, ada-002) — embeddings use
    the same OpenAI format value as chat models so we can't filter on format."""
    name = _pick_model(
        deployed_models,
        lambda d: 'embedding' in (d.get('name') or '').lower()
                  or (d.get('name') or '').lower().startswith('ada-'),
    )
    if not name:
        pytest.skip('No embedding model deployed in /inference/deployments')
    return name


@pytest.fixture(scope='session')
def subscription_key() -> str:
    return APIM_SUBSCRIPTION_KEY
