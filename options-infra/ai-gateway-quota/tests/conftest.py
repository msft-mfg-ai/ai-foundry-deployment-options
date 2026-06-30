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
    APIM_SKU,
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
    config.addinivalue_line(
        'markers',
        'quota: test requires the gateway to be deployed with access contracts (quota mode). '
        'Auto-skipped on open-mode deployments (no /ai-gateway/config.json endpoint).',
    )


def pytest_report_header(config) -> list[str]:
    """Banner printed once at the start of the run."""
    return [
        '',
        '=' * 78,
        'ai-gateway live integration tests',
        '=' * 78,
        f'  gateway:  {GATEWAY_URL}',
        f'  model:    {DEFAULT_MODEL}',
        f'  failover: {FAILOVER_MODEL}',
        f'  contract: {DEFAULT_CONTRACT_NAME}',
        f'  apim sku: {APIM_SKU or "(not set — v1 spec tests will run)"}',
        f'  sub-key:  {"set" if APIM_SUBSCRIPTION_KEY else "(not set)"}',
        f'  token:    {"explicit (TEST_ACCESS_TOKEN)" if TEST_ACCESS_TOKEN else "client secret / DefaultAzureCredential"}',
        '',
        'Each test prints WHAT it checks, HOW it checks it, and WHY it matters.',
        'A line starting with "→" shows the URL/path hit; "←" shows what came back.',
        '=' * 78,
    ]


def _probe_gateway_mode() -> str:
    """Detect whether the gateway is in quota mode or open mode.

    quota mode: contracts are wired, /ai-gateway/config.json returns 200.
    open mode:  no contracts, /ai-gateway/config.json returns 404 (endpoint
                isn't deployed).

    Returns 'quota' or 'open'. We probe ANONYMOUSLY because the config.json
    endpoint is intentionally public (the page is a viewer). Even if the
    endpoint requires a key, 404 vs 401/403 still disambiguates.
    """
    import requests
    try:
        r = requests.get(f'{GATEWAY_URL}/ai-gateway/config.json', timeout=10)
    except Exception:
        return 'open'
    # 200 → endpoint is wired (quota mode). 401/403 → endpoint exists but
    # requires auth → still quota. Only a clean 404 means the endpoint isn't
    # deployed at all (open mode).
    return 'open' if r.status_code == 404 else 'quota'


def pytest_collection_modifyitems(config, items) -> None:
    """Auto-skip @pytest.mark.quota tests on open-mode deployments."""
    mode = _probe_gateway_mode()
    config._gateway_mode = mode  # exposed via the gateway_mode fixture
    if mode == 'open':
        skip_quota = pytest.mark.skip(
            reason='Gateway is in open mode (no /ai-gateway/config.json). '
                   'Deploy ai-gateway-quota with contracts to exercise these tests.'
        )
        for item in items:
            if 'quota' in item.keywords:
                item.add_marker(skip_quota)


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
def gateway_mode(request) -> str:
    """'quota' if /ai-gateway/config.json is wired, else 'open'. Cached by
    pytest_collection_modifyitems; falls back to a fresh probe for ad-hoc
    runs (e.g. --collect-only didn't run)."""
    return getattr(request.config, '_gateway_mode', None) or _probe_gateway_mode()


def _deployed_model_names(deployed_models: list[dict]) -> set[str]:
    return {(d.get('name') or '').strip() for d in deployed_models if d.get('name')}


@pytest.fixture(scope='session')
def model(deployed_models) -> str:
    """Configured TEST_MODEL. Skips when not present in /inference/deployments.
    Keeps the suite portable across gateways with different model catalogs."""
    if deployed_models and DEFAULT_MODEL not in _deployed_model_names(deployed_models):
        pytest.skip(
            f"Configured TEST_MODEL={DEFAULT_MODEL!r} is not in "
            f"/inference/deployments. Available: "
            f"{sorted(_deployed_model_names(deployed_models))!r}. "
            f"Set TEST_MODEL to one of those, or deploy {DEFAULT_MODEL!r}."
        )
    return DEFAULT_MODEL


@pytest.fixture(scope='session')
def failover_model(deployed_models) -> str:
    """Configured TEST_FAILOVER_MODEL. Skips when not deployed."""
    if deployed_models and FAILOVER_MODEL not in _deployed_model_names(deployed_models):
        pytest.skip(
            f"Configured TEST_FAILOVER_MODEL={FAILOVER_MODEL!r} is not in "
            f"/inference/deployments."
        )
    return FAILOVER_MODEL


@pytest.fixture(scope='session')
def expected_contract(gateway_mode) -> str:
    """In quota mode → the configured TEST_CONTRACT (e.g. 'Team Alpha').
    In open mode → 'anonymous' (the caller-identity default when no contracts
    are wired). This lets the same generic chat tests pass in both modes;
    contract-specific assertions belong on @pytest.mark.quota tests."""
    return DEFAULT_CONTRACT_NAME if gateway_mode == 'quota' else 'anonymous'


@pytest.fixture(scope='session')
def access_token() -> str:
    """Acquire one bearer token per session — saves time across tests."""
    return get_token()


@pytest.fixture(scope='session')
def deployed_models(access_token) -> list[dict]:
    """Discover what's deployed by calling the gateway's /inference/deployments
    endpoint once per session. Returns the raw `value[]` list, where each
    entry has shape `{"name": str, "properties": {"model": {"name", "version",
    "format"}}}`. Used by capability-conditional fixtures (model,
    failover_model, anthropic_model, embedding_model) to skip tests when a
    model class isn't present.
    """
    import requests
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
    Detected by `properties.model.format == 'Anthropic'` in
    /inference/deployments. Discovery is authoritative — if a 404 comes back
    from the actual test call, that's a gateway bug, not a test problem."""
    name = _pick_model(deployed_models, lambda d: _model_format(d).lower() == 'anthropic')
    if not name:
        pytest.skip('No Anthropic model deployed (no deployment with format=Anthropic)')
    return name


@pytest.fixture(scope='session')
def embedding_model(deployed_models) -> str:
    """First deployed embedding model, or skip the test if none.
    Detected by name (embedding/ada-*) — embeddings share the OpenAI format
    value with chat models, so name matching is the only signal."""
    name = _pick_model(
        deployed_models,
        lambda d: 'embedding' in (d.get('name') or '').lower()
                  or (d.get('name') or '').lower().startswith('ada-'),
    )
    if not name:
        pytest.skip('No embedding model deployed in /inference/deployments')
    return name


@pytest.fixture(scope='session')
def tts_model(deployed_models) -> str:
    """First deployed text-to-speech model (tts-* or any deployment named
    containing 'tts'), or skip. Used by test_tts_binary and
    test_whisper_transcription (which synthesizes its input first)."""
    name = _pick_model(
        deployed_models,
        lambda d: (d.get('name') or '').lower().startswith('tts')
                  or 'tts' in (d.get('name') or '').lower(),
    )
    if not name:
        pytest.skip('No TTS model deployed in /inference/deployments')
    return name


@pytest.fixture(scope='session')
def whisper_model(deployed_models) -> str:
    """First deployed Whisper / speech-to-text model, or skip."""
    name = _pick_model(
        deployed_models,
        lambda d: 'whisper' in (d.get('name') or '').lower(),
    )
    if not name:
        pytest.skip('No Whisper model deployed in /inference/deployments')
    return name


@pytest.fixture(scope='session')
def subscription_key() -> str:
    return APIM_SUBSCRIPTION_KEY


# ---------------------------------------------------------------------------
# Agent-service fixtures (Foundry v2 agents going through the gateway).
# ---------------------------------------------------------------------------

import os
import random


def _foundry_project_endpoints() -> list[str]:
    """Discover Foundry project endpoints. Priority:
      1. FOUNDRY_PROJECT_ENDPOINT       — single endpoint override (.env)
      2. FOUNDRY_PROJECT_ENDPOINTS      — comma-separated list override
      3. FOUNDRY_PROJECTS_CONNECTION_STRINGS — JSON array (azd env, as set by
         the gateway's preprovision hook)
    """
    import json
    single = (os.environ.get('FOUNDRY_PROJECT_ENDPOINT') or '').strip()
    if single:
        return [single]
    multi = (os.environ.get('FOUNDRY_PROJECT_ENDPOINTS') or '').strip()
    if multi:
        return [s.strip() for s in multi.split(',') if s.strip()]
    raw = (os.environ.get('FOUNDRY_PROJECTS_CONNECTION_STRINGS') or '').strip()
    if raw:
        try:
            value = json.loads(raw)
            if isinstance(value, list):
                return [str(v).strip() for v in value if str(v).strip()]
        except Exception:
            pass
    return []


@pytest.fixture(scope='session')
def foundry_project_endpoint() -> str:
    """Pick the first available Foundry project endpoint or skip the test."""
    endpoints = _foundry_project_endpoints()
    if not endpoints:
        pytest.skip(
            'No Foundry project endpoint configured. Set FOUNDRY_PROJECT_ENDPOINT, '
            'FOUNDRY_PROJECT_ENDPOINTS, or FOUNDRY_PROJECTS_CONNECTION_STRINGS '
            '(JSON array, as written by the gateway preprovision hook).'
        )
    return endpoints[0]


@pytest.fixture
async def project_client(foundry_project_endpoint):
    """Async AIProjectClient pointed at the discovered project endpoint.
    Function-scoped because pytest-asyncio creates a fresh event loop per
    test by default — session-scoped async fixtures end up bound to a loop
    that's already closed by the time the test runs.
    Uses DefaultAzureCredential — the developer's az login (or a managed
    identity in CI) must have at least 'Azure AI User' on the project."""
    from azure.ai.projects.aio import AIProjectClient
    from azure.identity.aio import DefaultAzureCredential
    cred = DefaultAzureCredential()
    client = AIProjectClient(endpoint=foundry_project_endpoint, credential=cred)
    try:
        yield client
    finally:
        await client.close()
        await cred.close()


async def _find_apim_connection(project_client, *, deployment_in_path: bool, format_hint: str) -> str | None:
    """Find an ApiManagement-type project connection whose metadata matches the
    given format. We discriminate by `metadata.deploymentInPath`:
      • True  → OpenAI-style (URL has /deployments/{m}/...)
      • False → Anthropic-style (URL has /v1/messages, model in body)
    Falls back to a name-substring match when metadata is missing.
    """
    async for conn in project_client.connections.list():
        if (getattr(conn, 'type', '') or '').lower() != 'apimanagement':
            continue
        md = getattr(conn, 'metadata', {}) or {}
        raw = md.get('deploymentInPath')
        # metadata values come back as strings — normalize to bool
        if isinstance(raw, str):
            dip = raw.strip().lower() == 'true'
        elif raw is None:
            dip = format_hint in (conn.name or '').lower()
        else:
            dip = bool(raw)
        if dip == deployment_in_path:
            return conn.name
    return None


@pytest.fixture
async def openai_apim_connection(project_client) -> str:
    """ApiManagement project connection wired for OpenAI-style models
    (metadata.deploymentInPath=True). Skips if none."""
    name = await _find_apim_connection(project_client, deployment_in_path=True, format_hint='openai')
    if not name:
        pytest.skip(
            'No project connection of type=ApiManagement with deploymentInPath=true. '
            'Wire the OpenAI-flavored APIM connection (modules/ai/connection-apim-gateway.bicep).'
        )
    return name


@pytest.fixture
async def anthropic_apim_connection(project_client) -> str:
    """ApiManagement project connection wired for Anthropic-style models
    (metadata.deploymentInPath=False). Skips if none."""
    name = await _find_apim_connection(project_client, deployment_in_path=False, format_hint='anthropic')
    if not name:
        pytest.skip(
            'No project connection of type=ApiManagement with deploymentInPath=false. '
            'Wire the Anthropic-flavored APIM connection (modules/ai/connection-apim-gateway.bicep).'
        )
    return name


@pytest.fixture
async def apim_gateway_connection(project_client) -> str:
    """Name of the project connection whose type is 'ApiManagement' (the APIM
    gateway connection). Skips when none is wired."""
    name = None
    async for conn in project_client.connections.list():
        if (getattr(conn, 'type', '') or '').lower() == 'apimanagement':
            name = conn.name
            break
    if not name:
        pytest.skip(
            'No project connection of type=ApiManagement found. Wire the APIM '
            'gateway as a Foundry connection (modules/ai/connection-apim-gateway.bicep).'
        )
    return name


def _pick_random_model(deployed_models: list[dict], match) -> str | None:
    candidates = [
        (d.get('name') or '').strip()
        for d in deployed_models
        if (d.get('name') or '').strip() and match(d)
    ]
    return random.choice(candidates) if candidates else None


@pytest.fixture(scope='session')
def random_openai_chat_model(deployed_models) -> str:
    """Random OpenAI chat-capable deployment from /inference/deployments,
    excluding embeddings, TTS/Whisper/realtime/image/video. Skips if none."""
    excludes = ('embedding', 'ada-', 'tts', 'whisper', 'realtime', 'sora', 'image', 'dall')
    name = _pick_random_model(
        deployed_models,
        lambda d: _model_format(d).lower() == 'openai'
                  and not any(t in (d.get('name') or '').lower() for t in excludes),
    )
    if not name:
        pytest.skip('No OpenAI chat-capable model deployed in /inference/deployments')
    return name


@pytest.fixture(scope='session')
def random_anthropic_model(deployed_models) -> str:
    """Random Anthropic deployment from /inference/deployments. Skips if none."""
    name = _pick_random_model(
        deployed_models,
        lambda d: _model_format(d).lower() == 'anthropic',
    )
    if not name:
        pytest.skip('No Anthropic model deployed in /inference/deployments')
    return name
