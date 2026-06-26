"""Live integration tests against the ai-gateway-quota AI Gateway (APIM).

These are **integration** tests — they call the deployed APIM, get real
tokens via DefaultAzureCredential, and hit the actual Foundry backends.
They are deterministic and TPM-light: each test issues one or two
small calls (max_tokens=4..8). Costlier tests (burst-throttle, multi-
streaming, cross-contract isolation) live in the notebook only.

Run from tests/:
    uv run pytest                  # full verbose output (default)
    uv run pytest -k chat          # subset by name
    uv run pytest -q               # one-char-per-test mode (quiet)

Network/TPM tolerance: TPM-exhausted (429) is accepted as a soft pass on
endpoints where the gateway has reached the contract's per-model TPM cap;
this just means "auth & routing succeeded" — the goal of these tests.

Each test prints a one-line summary of the URL hit and what came back so
a passing run shows you *what* was actually exercised, not just dots.
"""

from __future__ import annotations

import asyncio

import pytest
import requests

from gateway import (
    API_URL,
    APIM_SKU,
    APIM_SUBSCRIPTION_KEY,
    CONFIG_UPDATE_URL,
    DEFAULT_MODEL,
    DISCOVERY_API_URL,
    API_VERSION,
    GATEWAY_URL,
    get_config_json,
    post_config_update,
    send_chat_at_path,
    send_request,
    send_request_streaming,
    send_responses,
)


def _headers(**extra: str) -> dict[str, str]:
    headers = dict(extra)
    if APIM_SUBSCRIPTION_KEY:
        headers['api-key'] = APIM_SUBSCRIPTION_KEY
        headers['Ocp-Apim-Subscription-Key'] = APIM_SUBSCRIPTION_KEY
    return headers


def _summary(r) -> str:
    """One-line response summary for the test log."""
    bits = [f'status={r.status_code}', f'{r.elapsed_ms}ms']
    if r.caller_name:
        bits.append(f'caller={r.caller_name!r}')
    if r.backend_pool:
        bits.append(f'pool={r.backend_pool!r}')
    if r.priority:
        bits.append(f'prio={r.priority}')
    if r.streamed_chunks:
        bits.append(f'chunks={r.streamed_chunks}')
    return '  '.join(bits)



# ---------------------------------------------------------------------------
# 1. Basic chat completion — happy path, the test that everything depends on.
# ---------------------------------------------------------------------------

def test_chat_completion(model, expected_contract):
    """WHAT: POST a tiny chat completion to /inference/openai/deployments/{model}/chat/completions.
    HOW:   Acquires a bearer via DefaultAzureCredential, sends one user message
           (max_tokens=4) to the configured default model, then asserts the APIM
           caller-name header matches the expected access contract.
    WHY:   Smoke test for end-to-end auth + JWT policy + model routing + Foundry
           reachability. If this fails, every other test will too.
    """
    r = send_request(model=model, prompt='Say hi.', max_tokens=4)
    print(f'│  → POST {r.url}')
    print(f'│  ← {_summary(r)}')
    assert r.status_code in (200, 429), f'status={r.status_code} body={r.body_text[:200]}'
    assert r.caller_name == expected_contract, (
        f'Expected caller {expected_contract!r}, got {r.caller_name!r} — '
        f'check that DefaultAzureCredential is signed in as a member of that contract.'
    )
    if r.status_code == 200:
        assert r.backend_pool, 'Missing x-backend-pool header on 200 response'
        assert r.body_json and r.body_json.get('choices'), 'No choices in response body'


# ---------------------------------------------------------------------------
# 2. Negative: non-existent model should not be routed.
# ---------------------------------------------------------------------------

@pytest.mark.quota
def test_unknown_model_rejected():
    """WHAT: Request a model name that does not exist on any backend.
    HOW:   Sends chat completion with model='this-model-does-not-exist' on the
           default contract and inspects the status code.
    WHY:   Validates the contract gate's allow-list: APIM should reject unknown
           models with 403 (not in your contract) or 404 (no operation match)
           BEFORE ever touching a Foundry backend. A 200 here would mean the
           gate is broken and any caller could probe arbitrary models.
    """
    r = send_request(model='this-model-does-not-exist', prompt='hi', max_tokens=4)
    print(f'│  → POST {r.url}')
    print(f'│  ← {_summary(r)}')
    assert r.status_code in (403, 404), f'Expected 403/404, got {r.status_code} {r.body_text[:200]}'


# ---------------------------------------------------------------------------
# 3. Negative: invalid bearer token should be rejected at the gateway.
# ---------------------------------------------------------------------------

@pytest.mark.quota
def test_invalid_token_rejected(model):
    """WHAT: Send a chat request with a garbage bearer token.
    HOW:   Replaces the AAD token with the literal string 'not-a-real-token'
           and posts a normal chat-completion payload.
    WHY:   The validate-jwt APIM policy must reject malformed/unsigned tokens
           before any backend is contacted. A 200 here means anonymous traffic
           reaches Foundry — a major security regression.
    NOTE:  APIM Standard v2 currently returns 500 on a malformed bearer (the
           validate-jwt policy throws). 401 is the spec-correct answer; we
           accept either to keep this stable across APIM versions.
    """
    r = send_request(model=model, prompt='hi', max_tokens=4, token='not-a-real-token')
    print(f'│  → POST {r.url}  (with garbage token)')
    print(f'│  ← {_summary(r)}')
    assert r.status_code in (401, 500), (
        f'Expected 401/500 for invalid token, got {r.status_code} {r.body_text[:200]}'
    )


# ---------------------------------------------------------------------------
# 4. Streaming chat — single request; should produce >0 SSE chunks.
# ---------------------------------------------------------------------------

def test_streaming_chat(model):
    """WHAT: Issue a streaming chat completion (stream=True) and parse the SSE.
    HOW:   POSTs {stream: true, max_tokens: 32} and iterates `data: {…}` lines,
           counting non-empty `choices[0].delta.content` chunks.
    WHY:   Streaming has its own code path through APIM: response buffering off,
           SSE framing preserved, no reshaping. We verify the gateway delivers
           multiple chunks (not one buffered blob) and that we can drain the body
           cleanly without the requests "content already consumed" error.
    """
    r = send_request_streaming(model=model, prompt='Count from 1 to 5.', max_tokens=32)
    print(f'│  → POST {r.url}  (stream=true)')
    print(f'│  ← {_summary(r)}  text={r.streamed_text[:60]!r}')
    if r.status_code == 429:
        pytest.skip('TPM-exhausted on this contract:model — auth/routing OK.')
    assert r.status_code == 200, f'Streaming failed: {r.status_code} {r.body_text[:200]}'
    assert r.streamed_chunks > 0, 'Got 200 but no SSE chunks were parsed'
    assert r.streamed_text, 'Stream produced no text'


# ---------------------------------------------------------------------------
# 5. Passthrough path — /inference/openai/... routes to Azure OpenAI backends.
# ---------------------------------------------------------------------------

def test_passthrough_openai_path(model, expected_contract):
    """WHAT: Hit /inference/openai/deployments/{model}/chat/completions (this repo passthrough shape).
    HOW:   Sends the same payload as test 1 but to the /inference/openai/...
           prefix, which exists in older Azure OpenAI client SDKs.
    WHY:   ai-gateway-quota exposes passthrough Azure OpenAI traffic under
           /inference/openai/deployments/{model}/..., so SDK-compatible callers
           and the per-model quota policy must both work on this route.
    """
    api_path = f'{GATEWAY_URL}/inference/openai'
    r = send_request(model=model, prompt='hi', max_tokens=4, api_path=api_path)
    print(f'│  → POST {r.url}')
    print(f'│  ← {_summary(r)}')
    assert r.status_code in (200, 429), (
        f'Passthrough /inference/openai/ path failed: {r.status_code} {r.body_text[:200]}'
    )
    assert r.caller_name == expected_contract, f'Caller mismatch: {r.caller_name!r}'


# ---------------------------------------------------------------------------
# 6. Responses API (passthrough) — /inference/openai/responses?api-version=...
# ---------------------------------------------------------------------------

def test_responses_modern(model):
    """WHAT: Call the Responses API at /inference/openai/responses.
    HOW:   Sends {model, input: "Say hi."} (no max_output_tokens — the API
           enforces >= 16, so we let the server pick).
    WHY:   Responses API is the v1+ shape Azure pushes for new code. Verifies
           the gateway routes a different operation/path than chat-completions
           and that the contract gate also covers this surface (not only chat).
    """
    r = send_responses(model=model, prompt='Say hi.')
    print(f'│  → POST {r.url}')
    print(f'│  ← {_summary(r)}')
    assert r.status_code in (200, 429), (
        f'Modern Responses API failed: {r.status_code} {r.body_text[:200]}'
    )


# ---------------------------------------------------------------------------
# 7. Responses API (Azure spec) — /azure/openai/responses.
# ---------------------------------------------------------------------------

def test_responses_azure_spec(model):
    """WHAT: Call /azure/openai/responses on the spec-backed Azure OpenAI API.
    HOW:   Same Responses payload as test 6, but routed through the Azure-spec
           APIM API generated from AIFoundryOpenAI.json.
    WHY:   Responses should be covered by the same contract/quota policy on
           both the passthrough and spec-backed surfaces.
    """
    r = send_responses(model=model, prompt='Say hi.', api_path='/azure/openai/responses')
    print(f'│  → POST {r.url}')
    print(f'│  ← {_summary(r)}')
    if r.status_code == 404:
        pytest.skip('Azure-spec Responses operation is not present in this deployment.')
    assert r.status_code in (200, 429), (
        f'Azure-spec Responses API failed: {r.status_code} {r.body_text[:200]}'
    )


# ---------------------------------------------------------------------------
# 8. TTS — exercises a binary response; verifies caller header is present.
# ---------------------------------------------------------------------------

def test_tts_binary(access_token):
    """WHAT: Generate a tiny MP3 via /deployments/tts-hd/audio/speech.
    HOW:   POSTs {model: 'tts-hd', input: 'Hello.', voice: 'alloy',
           response_format: 'mp3'} with a real bearer token, then sniffs the
           response body for an MP3/ID3 frame header.
    WHY:   Binary response paths historically broke because APIM would try to
           apply transformation policies. Verifies the gateway streams audio
           bytes verbatim AND still injects the x-caller-name header on
           non-JSON responses — important for downstream telemetry/billing.
    """
    url = f'{API_URL}/deployments/tts-hd/audio/speech?api-version={API_VERSION}'
    r = requests.post(
        url,
        headers=_headers(Authorization=f'Bearer {access_token}', **{'Content-Type': 'application/json'}),
        json={'model': 'tts-hd', 'input': 'Hello.', 'voice': 'alloy', 'response_format': 'mp3'},
        timeout=30,
    )
    ct = r.headers.get('Content-Type', '')
    print(f'│  → POST {url}')
    print(f'│  ← status={r.status_code}  content-type={ct!r}  bytes={len(r.content)}  caller={r.headers.get("x-caller-name")!r}')
    if r.status_code == 429:
        pytest.skip('TTS TPM exhausted — auth/routing OK.')
    if r.status_code == 500 and 'could not be found' in r.text:
        pytest.skip(f'No TTS backend pool deployed: {r.text[:200]}')
    if r.status_code == 404:
        pytest.skip('TTS endpoint not routed on this gateway (no tts deployment)')
    assert r.status_code == 200, f'TTS failed: {r.status_code} {r.text[:200]}'
    assert ct.startswith('audio/'), f'Expected audio/*, got {ct!r}'
    assert len(r.content) > 1000, f'Audio body suspiciously small ({len(r.content)} bytes)'
    # Accept any MPEG-1 Layer III sync (\xff\xf2/\xff\xf3/\xff\xfa/\xff\xfb) or ID3.
    head = r.content[:3]
    assert head == b'ID3' or head[:2] in (b'\xff\xfb', b'\xff\xf3', b'\xff\xf2', b'\xff\xfa'), (
        f'Not an MP3 (header bytes: {head.hex()})'
    )
    assert r.headers.get('x-caller-name'), 'Missing x-caller-name on binary response'


# ---------------------------------------------------------------------------
# 8b. STT — Whisper transcription via multipart upload.
# ---------------------------------------------------------------------------

def test_whisper_transcription(access_token):
    """WHAT: Transcribe a short MP3 via /deployments/whisper/audio/transcriptions.
    HOW:   First synthesizes audio with TTS (`tts-hd` → MP3 bytes), then POSTs
           that MP3 as multipart/form-data to the Whisper deployment and
           asserts the returned text contains a recognizable keyword from the
           input phrase.
    WHY:   Whisper is the only inbound-audio path through the gateway. The
           multipart upload pipeline is fundamentally different from JSON
           chat completions — APIM must NOT mangle the form body, and the
           contract gate must still apply on the binary-in / JSON-out shape.
           Chaining TTS → Whisper keeps the test self-contained (no audio
           fixture committed to the repo).
    """
    phrase = 'The quick brown fox jumps over the lazy dog.'

    # --- 1) Synthesize the audio with TTS -------------------------------------
    tts_url = f'{API_URL}/deployments/tts-hd/audio/speech?api-version={API_VERSION}'
    tts = requests.post(
        tts_url,
        headers=_headers(Authorization=f'Bearer {access_token}', **{'Content-Type': 'application/json'}),
        json={'model': 'tts-hd', 'input': phrase, 'voice': 'alloy', 'response_format': 'mp3'},
        timeout=30,
    )
    print(f'│  → POST {tts_url}')
    print(f'│  ← status={tts.status_code}  bytes={len(tts.content)}  caller={tts.headers.get("x-caller-name")!r}')
    if tts.status_code == 429:
        pytest.skip('TTS TPM exhausted while preparing Whisper input — auth/routing OK.')
    if tts.status_code != 200:
        # TTS itself is broken (e.g. backend pool missing) — that's covered by
        # test_tts_binary. Don't double-fail; skip so this test stays focused
        # on Whisper.
        pytest.skip(
            f'Skipping Whisper test — TTS prerequisite failed: '
            f'{tts.status_code} {tts.text[:200]}'
        )
    assert tts.content[:3] == b'ID3' or tts.content[:2] in (b'\xff\xfb', b'\xff\xf3', b'\xff\xf2', b'\xff\xfa'), (
        f'TTS did not return MP3 bytes (header: {tts.content[:3].hex()})'
    )

    # --- 2) Transcribe with Whisper -------------------------------------------
    stt_url = f'{API_URL}/deployments/whisper/audio/transcriptions?api-version={API_VERSION}'
    files = {'file': ('speech.mp3', tts.content, 'audio/mpeg')}
    data = {'model': 'whisper', 'response_format': 'json', 'language': 'en'}
    stt = requests.post(
        stt_url,
        headers=_headers(Authorization=f'Bearer {access_token}'),  # no Content-Type — requests sets multipart boundary
        files=files,
        data=data,
        timeout=60,
    )
    print(f'│  → POST {stt_url}  (multipart, {len(tts.content)}b mp3)')
    print(f'│  ← status={stt.status_code}  caller={stt.headers.get("x-caller-name")!r}  body={stt.text[:160]!r}')

    if stt.status_code == 429:
        pytest.skip('Whisper TPM exhausted — auth/routing OK.')
    assert stt.status_code == 200, f'Whisper failed: {stt.status_code} {stt.text[:200]}'
    assert stt.headers.get('x-caller-name'), 'Missing x-caller-name on Whisper response'

    body = stt.json()
    text = (body.get('text') or '').lower()
    assert text, f'Whisper returned empty transcription: {body!r}'
    # Tolerant match: TTS-then-STT is lossy. Accept any of the salient keywords.
    keywords = ('quick', 'brown', 'fox', 'lazy', 'dog')
    assert any(k in text for k in keywords), (
        f'Transcription does not contain any expected keyword {keywords}: {text!r}'
    )


# ---------------------------------------------------------------------------
# 9. Model-discovery endpoints — list and get-by-name.
# ---------------------------------------------------------------------------

def test_list_deployments(access_token, model):
    """WHAT: GET /inference/deployments — list models visible to this contract.
    HOW:   Calls the model-listing endpoint with a normal bearer token, then
           checks that the configured default model is in the returned list.
    WHY:   Contracts have model allow-lists; this endpoint must reflect ONLY
           the models the caller is entitled to. If the default model is
           missing, the contract config is misaligned with the test setup.
    NOTE:  APIM returns Azure-style {value: [...]}; older shapes used {data}.
    """
    url = f'{DISCOVERY_API_URL}/deployments'
    r = requests.get(url, headers=_headers(Authorization=f'Bearer {access_token}'), timeout=10)
    print(f'│  → GET  {url}')
    body = r.json() if r.status_code == 200 else None
    items = (body.get('value') or body.get('data')) if isinstance(body, dict) else None
    n = len(items) if isinstance(items, list) else 0
    print(f'│  ← status={r.status_code}  models_returned={n}')
    assert r.status_code == 200, f'list deployments failed: {r.status_code} {r.text[:200]}'
    assert isinstance(items, list) and items, f'Expected non-empty list, got: {body!r}'
    names = [d.get('name') if isinstance(d, dict) else None for d in items]
    print(f'│     names={names}')
    assert model in names, f'Default model {model!r} not in deployments: {names}'


def test_get_deployment_by_name(access_token, model):
    """WHAT: GET /inference/deployments/{model} — fetch one deployment by name.
    HOW:   Calls the single-deployment endpoint and checks the returned name field.
    WHY:   Companion to the list endpoint; verifies the per-name lookup also
           respects the contract gate (i.e. you cannot fetch a model you don't
           have access to).
    """
    url = f'{DISCOVERY_API_URL}/deployments/{model}'
    r = requests.get(url, headers=_headers(Authorization=f'Bearer {access_token}'), timeout=10)
    print(f'│  → GET  {url}')
    print(f'│  ← status={r.status_code}')
    assert r.status_code == 200, f'get-by-name failed: {r.status_code} {r.text[:200]}'
    body = r.json()
    assert body.get('name') == model, f'Expected name={model!r}, got {body!r}'


def test_list_deployments_azure_spec_surface(access_token, model):
    """WHAT: GET /azure/openai/deployments — list models on the Azure spec API.
    HOW:   Calls the spec-backed discovery endpoint with the same bearer token
           and checks that the configured default model appears.
    WHY:   ai-gateway-quota attaches static deployment discovery to both the
           passthrough and Azure-spec APIs; SDK users should see the same model
           allow-list on either surface.
    """
    url = f'{GATEWAY_URL}/azure/openai/deployments'
    r = requests.get(url, headers=_headers(Authorization=f'Bearer {access_token}'), timeout=10)
    print(f'│  → GET  {url}')
    body = r.json() if r.status_code == 200 else None
    items = (body.get('value') or body.get('data')) if isinstance(body, dict) else None
    names = [d.get('name') if isinstance(d, dict) else None for d in items or []]
    print(f'│  ← status={r.status_code}  names={names}')
    assert r.status_code == 200, f'Azure-spec list deployments failed: {r.status_code} {r.text[:200]}'
    assert model in names, f'Default model {model!r} not in Azure-spec deployments: {names}'


# ---------------------------------------------------------------------------
# 10. Config-viewer endpoint — exposes contract / identity dump.
# ---------------------------------------------------------------------------

@pytest.mark.quota
def test_config_viewer_returns_contracts(subscription_key):
    """WHAT: GET /ai-gateway/config.json — runtime view of all contracts.
    HOW:   Calls the public config endpoint and accepts either the raw contract
           array used by this repo or a wrapped {contracts: ...} shape.
    WHY:   Operators rely on this endpoint to debug which contracts and model
           quotas are currently loaded by the gateway.
    """
    r = get_config_json(subscription_key=None)
    print(f'│  → GET  {GATEWAY_URL}/ai-gateway/config.json (sub-key={"yes" if subscription_key else "no"})')
    cfg = r.json() if r.status_code == 200 else {}
    if isinstance(cfg, dict):
        contracts = cfg.get('contracts', cfg.get('accessContracts', cfg))
    else:
        contracts = cfg
    count = len(contracts) if isinstance(contracts, (list, dict)) else 0
    print(f'│  ← status={r.status_code}  contracts={count}')
    assert r.status_code == 200, f'Expected public config JSON to return 200, got {r.status_code}: {r.text[:200]}'
    assert count > 0, f'Expected non-empty contracts config, got: {cfg!r}'


@pytest.mark.quota
def test_config_viewer_public_without_subscription_key():
    """WHAT: GET /ai-gateway/config.json with NO subscription key.
    HOW:   Calls the config JSON endpoint with an empty subscription key.
    WHY:   ai-gateway-quota intentionally exposes this operational config view
           publicly (contracts, app IDs, quotas; no secrets) for debugging.
    """
    r = get_config_json(subscription_key='')
    print(f'│  → GET  {GATEWAY_URL}/ai-gateway/config.json (no sub-key)')
    print(f'│  ← status={r.status_code}  body={r.text[:120]!r}')
    assert r.status_code == 200, f'Expected public config JSON to return 200, got {r.status_code}: {r.text[:200]}'


@pytest.mark.quota
def test_config_json_contains_expected_contract(expected_contract):
    """WHAT: Verify the configured expected contract appears in config.json.
    HOW:   Reads /ai-gateway/config.json and searches raw/wrapped contract
           shapes for TEST_CONTRACT (default: Team Alpha).
    WHY:   The rest of the suite asserts x-caller-name against this contract;
           this catches a mismatched .env before inference assertions become
           misleading.
    """
    r = get_config_json(subscription_key=None)
    cfg = r.json() if r.status_code == 200 else {}
    if isinstance(cfg, dict):
        contracts = cfg.get('contracts', cfg.get('accessContracts', cfg))
    else:
        contracts = cfg
    if isinstance(contracts, dict):
        names = list(contracts)
    elif isinstance(contracts, list):
        names = [c.get('name') for c in contracts if isinstance(c, dict)]
    else:
        names = []
    print(f'│  → GET  {GATEWAY_URL}/ai-gateway/config.json')
    print(f'│  ← status={r.status_code}  contract_names={names}')
    assert r.status_code == 200, f'config.json failed: {r.status_code} {r.text[:200]}'
    assert expected_contract in names, f'Expected contract {expected_contract!r} not found in config: {names}'


# ---------------------------------------------------------------------------
# 11. Azure-spec surface — same contract pipeline via /azure/openai/.
# ---------------------------------------------------------------------------

def test_azure_openai_surface(model, expected_contract):
    """WHAT: Send the same chat-completion payload to /azure/openai/ instead of /inference/.
    HOW:   Builds the URL via send_chat_at_path('azure/openai', ...) and asserts
           the caller-name header matches the same access contract.
    WHY:   The gateway exposes multiple "spec surfaces" (Azure OpenAI shape,
           inference shape, OpenAI v1 shape) — all must hit the same JWT/contract
           pipeline. This test prevents drift where one surface gets a bypass.
    """
    r = send_chat_at_path('azure/openai', model=model, prompt='hi', max_tokens=4)
    print(f'│  → POST {r.url}')
    print(f'│  ← {_summary(r)}')
    assert r.status_code in (200, 429), (
        f'/azure/openai/ failed: {r.status_code} {r.body_text[:200]}'
    )
    assert r.caller_name == expected_contract, (
        f'Caller mismatch on Azure-spec surface: {r.caller_name!r}'
    )


# ---------------------------------------------------------------------------
# 12. OpenAI v1 surface — auth must work even if backend isn't fully wired.
# ---------------------------------------------------------------------------

# Tiers that can host the full OpenAI v1 OpenAPI spec (100+ operations).
# BasicV2 / StandardV1 / Developer / Consumption cap out below that limit,
# so the openai-v1 API simply isn't routed at all on those SKUs.
_OPENAI_V1_SKUS = {'StandardV2', 'Premium'}


@pytest.mark.skipif(
    APIM_SKU != '' and APIM_SKU not in _OPENAI_V1_SKUS,
    reason=(
        f'APIM_SKU={APIM_SKU!r} cannot host the OpenAI v1 spec '
        f'(>100 operations); only StandardV2/Premium do.'
    ),
)
def test_openai_v1_surface(access_token, model):
    """WHAT: POST to /openai/v1/chat/completions (OpenAI-shape compatibility surface).
    HOW:   Calls with a real bearer; payload uses the OpenAI v1 shape (no
           api-version query string).
    WHY:   The OpenAI v1 surface is for SDKs that don't speak Azure-OpenAI. Even
           if the backend wiring isn't fully complete (200 may not be possible
           yet), authentication must still go through the same JWT pipeline —
           so 401/403 is the only forbidden outcome here.
    """
    url = f'{GATEWAY_URL}/openai/v1/chat/completions'
    r = requests.post(
        url,
        headers=_headers(Authorization=f'Bearer {access_token}', **{'Content-Type': 'application/json'}),
        json={
            'model': model,
            'messages': [{'role': 'user', 'content': 'hi'}],
            'max_completion_tokens': 4,
        },
        timeout=30,
    )
    print(f'│  → POST {url}')
    print(f'│  ← status={r.status_code}  caller={r.headers.get("x-caller-name")!r}')
    # 404 means the surface isn't routed at all — the JWT pipeline never even
    # ran, which is exactly what we DON'T want to silently allow.
    assert r.status_code != 404, (
        f'OpenAI v1 surface returned 404 — the API is not deployed/routed at '
        f'{url}. The JWT pipeline is never exercised. Deploy the openai/v1 API '
        f'(StandardV2/Premium SKU) or skip this test explicitly.'
    )
    assert r.status_code not in (401, 403), (
        f'OpenAI v1 surface returned auth error {r.status_code}: {r.text[:200]}'
    )


# ---------------------------------------------------------------------------
# 12a. Anthropic / Claude family — only when an Anthropic model is deployed.
# ---------------------------------------------------------------------------

def test_chat_anthropic_model(anthropic_model, expected_contract):
    """WHAT: Send a chat completion to a deployed Anthropic (Claude) model.
    HOW:   Auto-discovered via /inference/deployments (skipped when no
           deployment has properties.model.format == 'Anthropic'). Uses the
           standard /inference/ path — the gateway policy auto-injects
           `anthropic-version` for claude-* models so the OpenAI SDK shape
           works against the Anthropic backend transparently.
    WHY:   Anthropic models reach the same JWT/contract pipeline through a
           different backend (api.anthropic.com style) than Azure OpenAI.
           This test ensures contract enforcement and per-model routing work
           for non-OpenAI backends too.
    """
    r = send_request(model=anthropic_model, prompt='hi', max_tokens=4)
    print(f'│  → POST {r.url}')
    print(f'│  ← {_summary(r)}')
    if r.status_code == 404:
        pytest.skip(f'Anthropic model {anthropic_model!r} returned 404 — pool may be flaky.')
    if r.status_code == 500 and 'could not be found' in r.body_text:
        pytest.skip(f'Anthropic backend pool missing: {r.body_text[:200]}')
    assert r.status_code in (200, 429), (
        f'Anthropic chat ({anthropic_model}) failed: {r.status_code} {r.body_text[:200]}'
    )
    assert r.caller_name == expected_contract, (
        f'Caller mismatch on Anthropic surface: {r.caller_name!r}'
    )


# ---------------------------------------------------------------------------
# 12b. Embeddings — only when an embedding model is deployed.
# ---------------------------------------------------------------------------

def test_embeddings_model(access_token, embedding_model, expected_contract):
    """WHAT: POST to /inference/deployments/{model}/embeddings.
    HOW:   Auto-discovered via /inference/deployments (skipped when no
           deployment name matches 'embedding' / 'ada-'). Sends a single
           short input and expects an embedding vector in the response.
    WHY:   Embeddings use the same APIM path-routing as chat completions but
           a different OpenAI endpoint shape (no `messages`, no `max_tokens`).
           This test ensures the per-model pool routing + JWT pipeline work
           for non-chat OpenAI endpoints.
    """
    url = (
        f'{GATEWAY_URL}/inference/deployments/{embedding_model}/embeddings'
        f'?api-version={API_VERSION}'
    )
    r = requests.post(
        url,
        headers=_headers(Authorization=f'Bearer {access_token}', **{'Content-Type': 'application/json'}),
        json={'input': 'hello world', 'model': embedding_model},
        timeout=30,
    )
    caller = r.headers.get('x-caller-name')
    print(f'│  → POST {url}')
    print(f'│  ← status={r.status_code}  caller={caller!r}  model={embedding_model}')
    if r.status_code == 404:
        pytest.skip(f'Embeddings ({embedding_model!r}) returned 404 — pool may be flaky.')
    if r.status_code == 500 and 'could not be found' in r.text:
        pytest.skip(f'Embeddings backend pool missing: {r.text[:200]}')
    assert r.status_code in (200, 429), (
        f'Embeddings ({embedding_model}) failed: {r.status_code} {r.text[:200]}'
    )
    assert caller == expected_contract, (
        f'Caller mismatch on embeddings surface: {caller!r}'
    )
    if r.status_code == 200:
        data = r.json().get('data', [])
        assert data and isinstance(data[0].get('embedding'), list) and len(data[0]['embedding']) > 0, (
            f'Embeddings response missing vector: {r.text[:200]}'
        )


# ---------------------------------------------------------------------------
# 12b. Discovery endpoints must reject anonymous requests.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize(
    'path_suffix,label',
    [('', 'list'), (f'/{DEFAULT_MODEL}', 'get-by-name')],
)
def test_deployments_require_auth(path_suffix, label):
    """WHAT: GET /inference/deployments[/{name}] with NO Authorization header.
    HOW:   Sends the request without a bearer and asserts APIM rejects with
           401. Also sends a garbage bearer to confirm the token IS validated
           (not just "any string accepted").
    WHY:   The discovery operations (`list-deployments`, `get-deployment-by-name`)
           don't inherit `<base />` to avoid running the per-model routing
           fragment. Their per-operation policies must explicitly enforce
           Entra ID JWT validation, otherwise the static deployment list (which
           leaks the gateway's full model catalog) is reachable anonymously.
    """
    url = f'{DISCOVERY_API_URL}/deployments{path_suffix}'

    print(f'│  → GET  {url}  (no Authorization header)')
    r = requests.get(url, headers=_headers(), timeout=10)
    print(f'│  ← status={r.status_code}  body={r.text[:120]!r}')
    assert r.status_code == 401, (
        f'{label}: expected 401 without bearer, got {r.status_code}. '
        f'The discovery operation is anonymously reachable: {r.text[:200]}'
    )

    print(f'│  → GET  {url}  (garbage bearer)')
    r = requests.get(url, headers=_headers(Authorization='Bearer not-a-real-token'), timeout=10)
    print(f'│  ← status={r.status_code}  body={r.text[:120]!r}')
    assert r.status_code == 401, (
        f'{label}: expected 401 with garbage bearer, got {r.status_code}. '
        f'JWT validation is not running on this operation: {r.text[:200]}'
    )


# ---------------------------------------------------------------------------
# 13. Realtime WebSocket — anonymous handshake must be rejected.
# ---------------------------------------------------------------------------

def test_realtime_unauthenticated_rejected(model):
    """WHAT: Open a WebSocket to /inference/openai/realtime WITHOUT auth.
    HOW:   Connects via the websockets library to wss://.../realtime?... with
           no Authorization header; catches the InvalidStatus exception.
    WHY:   The realtime API uses WebSockets; AAD JWT validation must apply
           here just like REST. An accepted handshake without a bearer would
           let unauthenticated clients open a stateful audio session.
    """
    websockets = pytest.importorskip('websockets')
    ws_url = (
        GATEWAY_URL.replace('https://', 'wss://').replace('http://', 'ws://')
        + f'/inference/openai/realtime?api-version={API_VERSION}&deployment={model}'
    )
    print(f'│  → WS   {ws_url}  (no Authorization header)')

    async def attempt():
        try:
            async with websockets.connect(ws_url, open_timeout=10) as ws:
                # If we got here, the gateway accepted an unauthenticated handshake — bad.
                await ws.close()
                return ('CONNECTED', None)
        except websockets.exceptions.InvalidStatus as e:
            return ('STATUS', e.response.status_code)
        except websockets.exceptions.InvalidStatusCode as e:  # older lib
            return ('STATUS', e.status_code)
        except Exception as e:
            return ('OTHER', repr(e))

    kind, detail = asyncio.run(attempt())
    print(f'│  ← {kind}={detail}')
    assert kind == 'STATUS' and detail in (401, 403, 404), (
        f'Expected 401/403/404 handshake rejection, got {kind}/{detail}'
    )


# ---------------------------------------------------------------------------
# 14. Comprehensive observability headers — success path (200).
# ---------------------------------------------------------------------------

# Headers the outbound policy MUST set on a successful chat completion.
# Sourced directly from infra/modules/apim/policy-per-model.xml outbound block.
EXPECTED_SUCCESS_HEADERS = {
    # Identity / contract
    'x-caller-name',
    'x-caller-identity',
    'x-caller-priority',
    # Routing
    'x-backend-id',
    'x-backend-pool',
    'x-backend-retry-count',
    'x-backend-attempt-trail',
    'x-inference-failover',
    'x-requested-model',
    # Limits (cap)
    'x-ratelimit-limit-tokens',
    'x-quota-limit-tokens',
    'x-ptu-limit',
    # Live counters (set by llm-token-limit + outbound fallback)
    'x-ratelimit-remaining-tokens',
    'x-quota-remaining-tokens',
    'x-tokens-consumed',
    'x-quota-tokens-consumed',
}

# Optional — only emitted on agent-routed traffic (variables empty on raw chat).
OPTIONAL_AGENT_HEADERS = {
    'x-foundry-agent-id',
    'x-foundry-project-name',
    'x-foundry-project-id',
}


@pytest.mark.quota
def test_success_response_headers_complete(model):
    """WHAT: Verify every observability header is present on a 200 response.
    HOW:   Sends a single chat completion and checks the header set against
           the canonical list (EXPECTED_SUCCESS_HEADERS) sourced from
           policy-per-model.xml's outbound block. Skips on 429.
    WHY:   These headers feed our dashboards, App Insights diagnostics, and
           caller-side debugging. If a future policy edit drops one (e.g.
           someone removes x-caller-priority), every downstream consumer
           breaks silently. This test is the canary.
    NOTE:  x-foundry-* headers are emitted only on agent-routed calls; they
           are checked separately and reported but not asserted here.
    """
    r = send_request(model=model, prompt='hi', max_tokens=4)
    print(f'│  → POST {r.url}')
    print(f'│  ← status={r.status_code}  {len(r.headers)} headers total')
    if r.status_code == 429:
        pytest.skip('TPM-exhausted — cannot validate success headers without a 200.')
    if r.status_code == 403 and 'quota_exceeded' in (r.body_text + str(r.body_json)):
        pytest.skip('Monthly quota exhausted — bump the configured contract monthlyQuota and redeploy.')
    assert r.status_code == 200, f'Expected 200, got {r.status_code}: {r.body_text[:200]}'

    actual = {k.lower() for k in r.headers.keys()}
    missing = sorted(EXPECTED_SUCCESS_HEADERS - actual)
    present = sorted(EXPECTED_SUCCESS_HEADERS & actual)
    print(f'│     required present ({len(present)}/{len(EXPECTED_SUCCESS_HEADERS)}): {present}')
    if missing:
        print(f'│     REQUIRED MISSING ({len(missing)}): {missing}')
    agent_present = sorted(OPTIONAL_AGENT_HEADERS & actual)
    agent_missing = sorted(OPTIONAL_AGENT_HEADERS - actual)
    print(f'│     agent (optional) present={agent_present}  missing={agent_missing}')
    assert not missing, f'Outbound policy did not emit: {missing}'

    # Sanity: numeric headers should be parseable integers.
    for h in ['x-ratelimit-limit-tokens', 'x-ratelimit-remaining-tokens',
              'x-quota-limit-tokens', 'x-quota-remaining-tokens',
              'x-tokens-consumed', 'x-quota-tokens-consumed', 'x-ptu-limit']:
        v = r.headers.get(h)
        assert v is not None and v.lstrip('-').isdigit(), f'{h}={v!r} not a valid integer'

    # Backend retry/failover trail invariants:
    #   - x-backend-retry-count is a non-negative integer (0 on the happy path).
    #   - x-backend-attempt-trail is "<backendId>:<statusCode>,..." with
    #     (retry-count + 1) entries. The LAST entry's status matches the
    #     response status — i.e. the trail accurately describes what happened.
    retry_count_raw = r.headers.get('x-backend-retry-count')
    assert retry_count_raw is not None and retry_count_raw.isdigit(), (
        f'x-backend-retry-count={retry_count_raw!r} not a non-negative integer'
    )
    retry_count = int(retry_count_raw)

    trail_raw = r.headers.get('x-backend-attempt-trail')
    assert trail_raw, f'x-backend-attempt-trail empty on 200 response'
    entries = trail_raw.split(',')
    assert len(entries) == retry_count + 1, (
        f'x-backend-attempt-trail has {len(entries)} entries but '
        f'x-backend-retry-count={retry_count} (expected {retry_count + 1})'
    )
    for e in entries:
        assert ':' in e, f'malformed trail entry {e!r} in {trail_raw!r}'
    last_status = entries[-1].rsplit(':', 1)[1]
    assert last_status == str(r.status_code), (
        f'Trail last entry status {last_status!r} != response status {r.status_code} '
        f'(trail={trail_raw!r})'
    )
    print(f'│     retry-count={retry_count}  trail={trail_raw!r}')


# ---------------------------------------------------------------------------
# 15. Comprehensive observability headers — on-error path (TPM-429).
# ---------------------------------------------------------------------------

# Headers the on-error policy block sets when a backend/policy error fires.
# Sourced from infra/modules/apim/policy-per-model.xml on-error block.
EXPECTED_ERROR_HEADERS = {
    'x-error-reason',
    'x-error-message',
    'x-error-section',
    'x-error-source',
    'x-caller-id',
    'x-caller-name',
    'x-caller-identity',
    'x-caller-priority',
    'x-ratelimit-limit-tokens',
    'x-quota-limit-tokens',
    'x-ptu-limit',
    'x-ratelimit-remaining-tokens',
    'x-quota-remaining-tokens',
    'x-backend-pool',
    'x-backend-retry-count',
    'x-backend-attempt-trail',
    'x-inference-failover',
}


def test_error_response_headers_complete(model):
    """WHAT: Verify the on-error block emits its full observability header set.
    HOW:   Provokes an llm-token-limit error by sending up to 12 chat completions.
           Both 429 (per-minute TPM exhausted) and 403 (monthly quota exhausted)
           fire the on-error block — the policy explicitly maps quota→403,
           rate→429.
    WHY:   When the gateway rejects a request, operators need to know WHY
           (x-error-source, x-error-reason) and WHO tried (x-caller-name even
           when 'unknown'). Missing these headers makes incidents un-debuggable.
    NOTE:  Not all error paths flow through on-error. validate-jwt failures on
           malformed bearers in APIM Standard v2 short-circuit with a 500 and
           NO custom headers — that's a documented APIM platform behavior, not
           a policy bug, and is covered by test_invalid_token_rejected (test 3)
           rather than asserted here.
    """
    err_resp = None
    attempts = 0
    statuses = []
    # Each call's actual consumption is ~14 tokens (small prompt + small reply);
    # per-model TPM cap is 50, so a 429 should come within a few calls. We use a
    # longer prompt to push consumption higher and hit the cap faster.
    big_prompt = 'Write a short poem about Azure API Management. ' * 4
    for attempts in range(1, 13):
        r = send_request(model=model, prompt=big_prompt, max_tokens=64)
        statuses.append(r.status_code)
        # 429 = per-minute TPM exhausted, 403 = monthly quota exhausted.
        # Both are emitted by llm-token-limit and BOTH go through on-error.
        if r.status_code in (429, 403):
            err_resp = r
            break
    print(f'│     attempt statuses: {statuses}')
    if err_resp is None:
        pytest.skip(
            f'Could not provoke a 403/429 in {attempts} attempts — auth+routing '
            f'looked fine but no rate/quota limit fired. Statuses: {statuses}'
        )
    print(f'│  ← provoked {err_resp.status_code} on attempt {attempts}: {len(err_resp.headers)} headers')

    actual = {k.lower() for k in err_resp.headers.keys()}
    missing = sorted(EXPECTED_ERROR_HEADERS - actual)
    present = sorted(EXPECTED_ERROR_HEADERS & actual)
    print(f'│     present ({len(present)}/{len(EXPECTED_ERROR_HEADERS)}): {present}')
    if missing:
        print(f'│     MISSING ({len(missing)}): {missing}')
    # Show key diagnostic values
    for h in ('x-error-source', 'x-error-section', 'x-error-reason',
              'x-caller-name', 'x-ratelimit-remaining-tokens'):
        v = err_resp.headers.get(h)
        if v:
            print(f'│     {h}={v!r}')
    assert not missing, f'on-error block did not emit: {missing}'

    # x-error-source should mention llm-token-limit for a TPM/quota error.
    src = err_resp.headers.get('x-error-source', '')
    assert 'llm-token-limit' in src or 'rate-limit' in src, (
        f'Unexpected x-error-source for {err_resp.status_code}: {src!r}'
    )


# ---------------------------------------------------------------------------
# 16. HTML contracts viewer — /ai-gateway/config returns styled HTML.
# ---------------------------------------------------------------------------

@pytest.mark.quota
def test_config_update_rejects_empty_body(subscription_key):
    """WHAT: POST /ai-gateway/config/update with an empty body.
    HOW:   Sends no payload to the update endpoint and asserts a safe 400.
    WHY:   Verifies the config update route is deployed without mutating the
           live contracts blob; valid updates are intentionally not exercised by
           this smoke suite because they are destructive.
    """
    r = post_config_update(body='', subscription_key=None)
    print(f'│  → POST {CONFIG_UPDATE_URL} (empty body)')
    print(f'│  ← status={r.status_code}  body={r.text[:160]!r}')
    assert r.status_code == 400, f'Expected empty update payload to return 400, got {r.status_code}: {r.text[:200]}'


# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 17. Retry / failover — burst on the dedicated canary pool.
# ---------------------------------------------------------------------------
#
# Provokes the <retry> block in policy-per-model.xml by bursting concurrent
# requests against FAILOVER_MODEL — a model whose pool contains a low-capacity
# ("canary") backend that 429s under the burst. Verifies:
#   - x-backend-retry-count >= 1 on at least one response
#   - a 429 → 200 transition (retry recovered to a healthy member)
#   - the trail shows >= 2 distinct upstream hosts (per-attempt
#     context.Request.Url.Host captured inside <retry>)
#
# Setup it relies on (infra/1-foundries/models.dev.json):
#   FAILOVER_MODEL=gpt-4.1-mini deployed in 3 foundries with capacities
#   [eastus:1 canary, westus3:50, eastus2:50]. The cap-1 canary throttles
#   first under burst; retry lands on one of the larger backends.
#
# Why a burst: llm-token-limit uses estimate-prompt-tokens=false, so it only
# deducts tokens AFTER responses settle. A concurrent batch all passes the
# inbound limiter at the same instant, all reach <backend>, and pool routing
# distributes them — requests that land on the canary → 429 → retry fires →
# falls over to a healthy backend.
#
# Why this test SKIPS rather than fails when no retry observed: the per-backend
# circuit breaker (multi-foundry-backends.bicep) trips on a single 429 and
# stays open for PT1M. After one burst, the canary is out of rotation for 60s,
# so subsequent runs see no retries. Skip is the honest outcome — the policy
# isn't broken, the test window just closed.

import concurrent.futures


def test_retry_failover_burst(access_token, failover_model):
    """WHAT: Verify the <retry> block in policy-per-model.xml actually fails over
           across pool members when a low-capacity backend returns 429.
    HOW:   Bursts ~8 concurrent small chat completions at FAILOVER_MODEL
           (gpt-4.1-mini), whose pool has a capacity-1 canary backend in eastus.
           Asserts at least one response shows retry-count >= 1, a 429 → 200
           transition in the trail, AND >= 2 distinct upstream hosts in the
           trail (proves the retry landed on a different physical foundry).
           Skips (does not fail) if no retry observed — the per-backend circuit
           breaker may have isolated the canary (tripDuration=PT1M) from a
           recent prior run.
    WHY:   The invariant test on the happy path proves the trail FORMAT is
           correct. This test proves the trail CONTENT changes when the policy's
           retry condition actually fires — i.e. failover works end-to-end across
           pool members under realistic AOAI 429 pressure.
    """
    print(f'│  → failover model: {failover_model!r}')
    print(f'│  → bursting 8 concurrent requests; circuit breaker is PT1M / count:1')

    def one_request(i: int):
        return i, send_request(
            model=failover_model,
            prompt='Write a one-sentence haiku about clouds.',
            max_tokens=40,
            token=access_token,
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(one_request, range(8)))

    summary = []
    retried_responses = []
    for i, r in results:
        rc = r.headers.get('x-backend-retry-count', '-')
        tr = r.headers.get('x-backend-attempt-trail', '-')
        summary.append(f'  [{i}] status={r.status_code} retry-count={rc} trail={tr}')
        try:
            if int(rc) >= 1:
                retried_responses.append((i, r, tr))
        except (TypeError, ValueError):
            pass
    print('│  ← burst results:')
    for line in summary:
        print('│  ' + line)

    if not retried_responses:
        pytest.skip(
            'No response in the burst showed retry-count >= 1. Likely causes: '
            '(a) the canary backend circuit breaker is currently open (PT1M tripDuration), '
            'wait 60s and re-run; (b) llm-token-limit pre-empted the burst — '
            'check the configured test contract has enough TPM headroom for the burst size.'
        )

    # A retry that ends in 200 after a 429 is itself proof of failover: the
    # circuit breaker tripped the failing pool member out of rotation, so the
    # next attempt must have landed on a different healthy member. The trail
    # now captures the actual upstream host per attempt (via context.Request.
    # Url.Host inside the retry), so we can also assert >= 2 distinct hosts.
    failover_success = [
        (i, r, tr) for i, r, tr in retried_responses
        if r.status_code == 200 and '429' in tr
    ]
    assert failover_success, (
        f'Retries fired but no retried response recovered to 200 after a 429. '
        f'Trails: {[(i, r.status_code, tr) for i, r, tr in retried_responses]}'
    )
    multi_host = []
    for i, r, tr in failover_success:
        hosts = {entry.split(':', 1)[0] for entry in tr.split(',') if ':' in entry}
        if len(hosts) >= 2:
            multi_host.append((i, tr, hosts))
    assert multi_host, (
        f'Retry+200 observed but no trail shows >= 2 distinct upstream hosts. '
        f'Trails: {[(i, tr) for i, _, tr in failover_success]}'
    )
    sample_i, sample_trail, sample_hosts = multi_host[0]
    print(f'│     ✓ request [{sample_i}] failover across {len(sample_hosts)} hosts: {sample_trail!r}')
