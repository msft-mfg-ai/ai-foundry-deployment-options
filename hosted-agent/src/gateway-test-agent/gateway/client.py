"""HTTP client for the AI Gateway.

All live-call helpers used by the notebook and pytest live here.
Keep things simple: requests for HTTP, azure-identity for tokens.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from typing import Optional

import requests
from azure.identity import ClientSecretCredential, DefaultAzureCredential

from . import config

# A single shared credential per process; tokens are cached internally by
# DefaultAzureCredential so repeated get_token() calls are cheap.
_credential: Optional[DefaultAzureCredential | ClientSecretCredential] = None


def get_credential() -> DefaultAzureCredential | ClientSecretCredential:
    global _credential
    if _credential is None:
        if config.CLIENT_ID and config.CLIENT_SECRET:
            _credential = ClientSecretCredential(
                tenant_id=config.TENANT_ID,
                client_id=config.CLIENT_ID,
                client_secret=config.CLIENT_SECRET,
            )
        else:
            _credential = DefaultAzureCredential()
    return _credential


def get_token() -> str:
    """Return the bearer token used by the test suite.

    If `TEST_ACCESS_TOKEN` is set in the environment / `.env`, it is returned
    verbatim — useful when running tests as a different identity than the
    local az/Workload login (e.g. a token minted via
    `az account get-access-token --resource https://cognitiveservices.azure.com`).

    Otherwise, acquires a token via DefaultAzureCredential against the
    cognitive-services audience.
    """
    if config.TEST_ACCESS_TOKEN:
        return config.TEST_ACCESS_TOKEN
    return get_credential().get_token(f'{config.AUDIENCE}/.default').token


@dataclass
class GatewayResponse:
    """Normalized view of an APIM response — what tests actually inspect."""

    status_code: int
    url: str = ''
    caller_name: Optional[str] = None
    matched_identity: Optional[str] = None
    backend_pool: Optional[str] = None
    backend_url: Optional[str] = None
    priority: Optional[str] = None
    # Per-model TPM rate-limit (resets every minute)
    ratelimit_limit_tokens: Optional[int] = None
    ratelimit_remaining_tokens: Optional[int] = None
    tokens_consumed: Optional[int] = None
    # Monthly quota (cost cap, resets monthly)
    quota_limit_tokens: Optional[int] = None
    quota_remaining_tokens: Optional[int] = None
    quota_tokens_consumed: Optional[int] = None
    body_text: str = ''
    body_json: Optional[dict] = None
    headers: dict = field(default_factory=dict)
    elapsed_ms: int = 0
    streamed_chunks: int = 0
    streamed_text: str = ''


def _build_response(r: requests.Response, url: str, elapsed_ms: int) -> GatewayResponse:
    """Pull the standard APIM caller/backend/rate-limit headers off a response."""
    h = r.headers
    body_text = ''
    body_json: Optional[dict] = None
    try:
        body_json = r.json()
    except Exception:
        body_text = r.text

    def _int(v: Optional[str]) -> Optional[int]:
        try:
            return int(v) if v is not None else None
        except ValueError:
            return None

    return GatewayResponse(
        status_code=r.status_code,
        url=url,
        caller_name=h.get('x-caller-name'),
        matched_identity=h.get('x-matched-identity'),
        backend_pool=h.get('x-backend-pool'),
        backend_url=h.get('x-backend-url'),
        priority=h.get('x-caller-priority') or h.get('x-priority'),
        ratelimit_limit_tokens=_int(h.get('x-ratelimit-limit-tokens')),
        ratelimit_remaining_tokens=_int(h.get('x-ratelimit-remaining-tokens')),
        tokens_consumed=_int(h.get('x-tokens-consumed')),
        quota_limit_tokens=_int(h.get('x-quota-limit-tokens')),
        quota_remaining_tokens=_int(h.get('x-quota-remaining-tokens')),
        quota_tokens_consumed=_int(h.get('x-quota-tokens-consumed')),
        body_text=body_text,
        body_json=body_json,
        headers=dict(h),
        elapsed_ms=elapsed_ms,
    )


def send_request(
    model: str = config.DEFAULT_MODEL,
    prompt: str = 'Say hi.',
    max_tokens: int = 8,
    api_path: Optional[str] = None,
    token: Optional[str] = None,
    timeout: int = 30,
) -> GatewayResponse:
    """POST to /deployments/{model}/chat/completions on the inference API.

    Note: the public arg is still `max_tokens` for stable test ergonomics, but
    we send it as `max_completion_tokens` in the payload — newer reasoning-style
    models (e.g. gpt-5.x) reject `max_tokens` outright, and the older gpt-4.1
    family accepts both. The new key is the forward-compatible choice.
    """
    base = api_path.rstrip('/') if api_path else config.API_URL
    url = f'{base}/deployments/{model}/chat/completions?api-version={config.API_VERSION}'
    payload = {
        'model': model,
        'messages': [{'role': 'user', 'content': prompt}],
        'max_completion_tokens': max_tokens,
    }
    headers = {
        'Authorization': f'Bearer {token or get_token()}',
        'Content-Type': 'application/json',
    }
    headers.update(_subscription_headers())
    t0 = time.time()
    r = requests.post(url, headers=headers, json=payload, timeout=timeout)
    return _build_response(r, url, int((time.time() - t0) * 1000))


def send_chat_at_path(
    api_path: str,
    model: str = config.DEFAULT_MODEL,
    prompt: str = 'Say hi.',
    max_tokens: int = 8,
    token: Optional[str] = None,
    timeout: int = 30,
) -> GatewayResponse:
    """Same as send_request but lets the caller pick the API path explicitly
    (e.g. /azure/openai for the Azure-spec surface, /openai/v1 for OpenAI)."""
    return send_request(
        model=model,
        prompt=prompt,
        max_tokens=max_tokens,
        api_path=f'{config.GATEWAY_URL}/{api_path.strip("/")}',
        token=token,
        timeout=timeout,
    )


def send_request_streaming(
    model: str = config.DEFAULT_MODEL,
    prompt: str = 'Count from 1 to 5.',
    max_tokens: int = 32,
    token: Optional[str] = None,
    timeout: int = 60,
) -> GatewayResponse:
    """POST a streaming chat completion. Drains the SSE body fully so callers
    can read response.body_* (avoids the requests "content already consumed"
    RuntimeError).
    """
    url = f'{config.API_URL}/deployments/{model}/chat/completions?api-version={config.API_VERSION}'
    payload = {
        'model': model,
        'messages': [{'role': 'user', 'content': prompt}],
        'max_completion_tokens': max_tokens,
        'stream': True,
    }
    headers = {
        'Authorization': f'Bearer {token or get_token()}',
        'Content-Type': 'application/json',
    }
    headers.update(_subscription_headers())
    t0 = time.time()
    r = requests.post(url, headers=headers, json=payload, stream=True, timeout=timeout)

    # Errors arrive as a complete JSON body, not SSE. Read the whole thing
    # before iterating (or `r.text` later raises ContentConsumed).
    if r.status_code >= 400:
        try:
            r.json()  # populate cache
        except Exception:
            _ = r.text
        r.close()
        return _build_response(r, url, int((time.time() - t0) * 1000))

    chunks = 0
    pieces: list[str] = []
    try:
        for line in r.iter_lines(decode_unicode=True):
            if not line or not line.startswith('data:'):
                continue
            data = line[5:].strip()
            if data == '[DONE]':
                break
            try:
                obj = json.loads(data)
                choices = obj.get('choices') or []
                if not choices:
                    continue  # usage-stats / final chunks have empty choices
                delta = (choices[0].get('delta') or {}).get('content')
                if delta:
                    chunks += 1
                    pieces.append(delta)
            except json.JSONDecodeError:
                continue
    finally:
        r.close()

    resp = _build_response(r, url, int((time.time() - t0) * 1000))
    resp.streamed_chunks = chunks
    resp.streamed_text = ''.join(pieces)
    return resp


def send_responses(
    model: str = config.DEFAULT_MODEL,
    prompt: str = 'Say hi.',
    max_output_tokens: Optional[int] = None,
    api_path: str = '/inference/openai/responses',
    token: Optional[str] = None,
    timeout: int = 30,
) -> GatewayResponse:
    """Hit the Responses API surface (passthrough: /inference/openai/responses).

    Note: Responses API enforces max_output_tokens >= 16. We default to None
    (no override) to let the server pick a safe default for small probes.
    """
    url = f'{config.GATEWAY_URL}{api_path}?api-version={config.API_VERSION}'
    payload: dict = {'model': model, 'input': prompt}
    if max_output_tokens is not None:
        payload['max_output_tokens'] = max_output_tokens
    headers = {
        'Authorization': f'Bearer {token or get_token()}',
        'Content-Type': 'application/json',
    }
    headers.update(_subscription_headers())
    t0 = time.time()
    r = requests.post(url, headers=headers, json=payload, timeout=timeout)
    return _build_response(r, url, int((time.time() - t0) * 1000))


def _subscription_headers(subscription_key: Optional[str] = None) -> dict[str, str]:
    sk = subscription_key if subscription_key is not None else config.APIM_SUBSCRIPTION_KEY
    return {'Ocp-Apim-Subscription-Key': sk, 'api-key': sk} if sk else {}


def get_config_json(subscription_key: Optional[str] = None) -> requests.Response:
    """GET /ai-gateway/config.json — used to inspect contracts/identities."""
    return requests.get(config.CONFIG_JSON_URL, headers=_subscription_headers(subscription_key), timeout=10)


def get_config_html(subscription_key: Optional[str] = None) -> requests.Response:
    """GET /ai-gateway/config — the styled HTML contracts viewer (no auth required)."""
    return requests.get(
        f'{config.GATEWAY_URL}/ai-gateway/config',
        headers=_subscription_headers(subscription_key),
        timeout=10,
    )


def post_config_update(body: str = '', subscription_key: Optional[str] = None) -> requests.Response:
    """POST /ai-gateway/config/update. Tests only send empty/invalid payloads."""
    return requests.post(
        config.CONFIG_UPDATE_URL,
        headers=_subscription_headers(subscription_key),
        data=body,
        timeout=10,
    )


def _status_visual(code: int) -> tuple[str, str]:
    """Return (emoji, css-color) for a status code."""
    if 200 <= code < 300:
        return ('✅', '#16a34a')
    if 300 <= code < 400:
        return ('🔀', '#0284c7')
    if code in (401, 403):
        return ('🔒', '#dc2626')
    if code == 404:
        return ('🔍', '#ea580c')
    if code == 429:
        return ('🐢', '#ca8a04')
    if 400 <= code < 500:
        return ('⚠️', '#ea580c')
    if 500 <= code < 600:
        return ('❌', '#dc2626')
    return ('•', '#64748b')


def _in_notebook() -> bool:
    """True iff running inside an IPython kernel that can display HTML."""
    try:
        from IPython import get_ipython  # type: ignore
        return get_ipython() is not None and 'IPKernelApp' in get_ipython().config
    except Exception:
        return False


def _html_escape(s: str) -> str:
    return (s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
             .replace('"', '&quot;').replace("'", '&#39;'))


def _render_trail(trail: Optional[str]) -> str:
    """Render 'host:code,host:code' as one row per attempt with status-colored chips."""
    if not trail or trail == 'none':
        return '<span style="color:#94a3b8">none</span>'
    rows = []
    for i, entry in enumerate(trail.split(',')):
        if ':' not in entry:
            continue
        host, _, code_s = entry.rpartition(':')
        try:
            code = int(code_s)
        except ValueError:
            code = 0
        emoji, color = _status_visual(code)
        rows.append(
            f'<div style="font-family:monospace;font-size:12px;padding:2px 0">'
            f'<span style="color:#94a3b8">attempt {i + 1}:</span> '
            f'<span style="display:inline-block;min-width:48px;text-align:center;'
            f'background:{color};color:white;border-radius:4px;padding:1px 6px;'
            f'font-weight:600">{emoji} {code}</span> '
            f'<span style="color:#334155">{_html_escape(host)}</span>'
            f'</div>'
        )
    return ''.join(rows) or '<span style="color:#94a3b8">(empty)</span>'


def _render_bar(used: Optional[int], limit: Optional[int], color: str) -> str:
    """Inline horizontal usage bar. used/limit may be None."""
    if limit is None or limit <= 0:
        return ''
    u = used if used is not None else 0
    pct = max(0, min(100, int(round(100 * u / limit))))
    return (
        f'<div style="background:#e2e8f0;border-radius:4px;height:6px;width:140px;'
        f'display:inline-block;vertical-align:middle;margin-left:6px;overflow:hidden">'
        f'<div style="background:{color};height:6px;width:{pct}%"></div></div> '
        f'<span style="color:#64748b;font-size:11px">{pct}%</span>'
    )


def _render_response_html(label: str, r: GatewayResponse) -> str:
    emoji, color = _status_visual(r.status_code)
    h = r.headers

    # Header bar
    parts = [
        f'<div style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;'
        f'border:1px solid #e2e8f0;border-radius:8px;margin:8px 0;overflow:hidden">',
        f'<div style="background:{color};color:white;padding:8px 12px;'
        f'display:flex;align-items:center;gap:10px">'
        f'<span style="font-size:20px">{emoji}</span>'
        f'<span style="font-weight:700;font-size:16px">{r.status_code}</span>'
        f'<span style="font-weight:500">{_html_escape(label)}</span>'
        f'<span style="margin-left:auto;font-size:12px;opacity:0.9">{r.elapsed_ms} ms</span>'
        f'</div>',
        f'<div style="padding:10px 12px;background:#f8fafc">',
    ]
    if r.url:
        parts.append(
            f'<div style="font-family:monospace;font-size:11px;color:#475569;'
            f'word-break:break-all;margin-bottom:8px">{_html_escape(r.url)}</div>'
        )

    # Two-column info table
    def _cell(title: str, body: str) -> str:
        return (
            f'<div style="margin-bottom:8px">'
            f'<div style="font-size:10px;text-transform:uppercase;letter-spacing:0.5px;'
            f'color:#64748b;font-weight:600;margin-bottom:2px">{title}</div>'
            f'<div style="font-size:13px;color:#1e293b">{body}</div>'
            f'</div>'
        )

    caller_html = ''
    if r.caller_name or h.get('x-caller-name'):
        name = r.caller_name or h.get('x-caller-name')
        ident = r.matched_identity or h.get('x-caller-identity') or '—'
        prio = r.priority or h.get('x-caller-priority') or '—'
        contract_id = h.get('x-caller-id', '—')
        caller_html = _cell(
            'Caller',
            f'<b>{_html_escape(name)}</b> &nbsp;·&nbsp; priority {_html_escape(str(prio))}<br>'
            f'<span style="font-family:monospace;font-size:11px;color:#64748b">'
            f'id={_html_escape(str(contract_id))} · identity={_html_escape(str(ident)[:40])}'
            f'</span>'
        )

    backend_html = ''
    if r.backend_pool or h.get('x-backend-pool'):
        pool = r.backend_pool or h.get('x-backend-pool')
        rc = h.get('x-backend-retry-count', '0')
        model = h.get('x-requested-model', '—')
        trail_html = _render_trail(h.get('x-backend-attempt-trail'))
        failover = h.get('x-inference-failover', 'none')
        backend_html = _cell(
            'Backend',
            f'<b>{_html_escape(str(pool))}</b> &nbsp;·&nbsp; model={_html_escape(model)} '
            f'&nbsp;·&nbsp; retries={rc}<br>'
            f'<div style="margin-top:6px">{trail_html}</div>'
            + (f'<div style="font-family:monospace;font-size:11px;color:#64748b;'
               f'margin-top:4px;word-break:break-all">{_html_escape(failover)}</div>'
               if failover and failover != 'none' else '')
        )

    limits_html = ''
    if r.ratelimit_limit_tokens is not None or r.quota_limit_tokens is not None:
        rows = []
        if r.ratelimit_limit_tokens is not None:
            used = (r.ratelimit_limit_tokens - (r.ratelimit_remaining_tokens or 0))
            rows.append(
                f'<div style="font-size:12px;margin-bottom:4px">'
                f'<b>TPM</b> {r.ratelimit_remaining_tokens}/{r.ratelimit_limit_tokens} left '
                f'(used this call: {r.tokens_consumed or 0})'
                f'{_render_bar(used, r.ratelimit_limit_tokens, "#0284c7")}'
                f'</div>'
            )
        if r.quota_limit_tokens is not None:
            used = (r.quota_limit_tokens - (r.quota_remaining_tokens or 0))
            rows.append(
                f'<div style="font-size:12px">'
                f'<b>Quota</b> {r.quota_remaining_tokens}/{r.quota_limit_tokens} left this month '
                f'(used: {r.quota_tokens_consumed or 0})'
                f'{_render_bar(used, r.quota_limit_tokens, "#7c3aed")}'
                f'</div>'
            )
        limits_html = _cell('Limits', ''.join(rows))

    error_html = ''
    if h.get('x-error-reason') or h.get('x-error-source'):
        reason = h.get('x-error-reason', '—')
        src = h.get('x-error-source', '—')
        section = h.get('x-error-section', '—')
        msg = h.get('x-error-message', '')
        error_html = _cell(
            'Error',
            f'<b style="color:#dc2626">{_html_escape(reason)}</b> '
            f'<span style="color:#64748b">in {_html_escape(section)} · '
            f'source={_html_escape(src)}</span>'
            + (f'<div style="font-family:monospace;font-size:11px;color:#475569;'
               f'margin-top:4px">{_html_escape(msg[:300])}</div>' if msg else '')
        )

    parts.append(
        f'<div style="display:grid;grid-template-columns:1fr 1fr;gap:12px">'
        f'{caller_html}{backend_html}{limits_html}{error_html}'
        f'</div>'
    )

    # Body
    if r.streamed_chunks:
        body_str = f'{r.streamed_chunks} chunks: {r.streamed_text[:300]}'
    elif r.body_json is not None:
        body_str = json.dumps(r.body_json, indent=2)[:1500]
    elif r.body_text:
        body_str = r.body_text[:1500]
    else:
        body_str = ''
    if body_str:
        parts.append(
            f'<details style="margin-top:8px"><summary style="cursor:pointer;'
            f'font-size:11px;color:#64748b;text-transform:uppercase;font-weight:600">'
            f'Body ({len(body_str)} chars)</summary>'
            f'<pre style="background:#1e293b;color:#e2e8f0;padding:10px;border-radius:6px;'
            f'font-size:11px;overflow-x:auto;margin-top:6px">{_html_escape(body_str)}</pre>'
            f'</details>'
        )

    # All headers (collapsible)
    if h:
        hdr_rows = ''.join(
            f'<tr style="background:{("#ffffff", "#f1f5f9")[i % 2]}">'
            f'<td style="padding:3px 10px;color:#0f172a;font-family:monospace;'
            f'font-size:11px;white-space:nowrap;font-weight:600;'
            f'vertical-align:top;width:1%">{_html_escape(k)}</td>'
            f'<td style="padding:3px 10px;font-family:monospace;font-size:11px;'
            f'color:#334155;word-break:break-all;line-height:1.4">{_html_escape(str(v))}</td></tr>'
            for i, (k, v) in enumerate(sorted(h.items()))
        )
        parts.append(
            f'<details style="margin-top:8px;max-width:760px"><summary style="cursor:pointer;'
            f'font-size:11px;color:#64748b;text-transform:uppercase;font-weight:600">'
            f'All headers ({len(h)})</summary>'
            f'<div style="background:#ffffff;border:1px solid #e2e8f0;border-radius:6px;'
            f'margin-top:6px;max-height:320px;overflow:auto">'
            f'<table style="border-collapse:collapse;width:100%;table-layout:auto">{hdr_rows}</table>'
            f'</div>'
            f'</details>'
        )

    parts.append('</div></div>')
    return ''.join(parts)


def print_response(label: str, r: GatewayResponse) -> None:
    """Pretty-print a GatewayResponse. In a Jupyter notebook, renders a rich
    HTML card (status emoji, color-coded attempt trail, usage bars, collapsible
    body and full headers). Outside a notebook, falls back to plain text."""
    if _in_notebook():
        try:
            from IPython.display import HTML, display  # type: ignore
            display(HTML(_render_response_html(label, r)))
            return
        except Exception:
            pass

    # Plain-text fallback
    print(f'--- {label} ---')
    if r.url:
        print(f'  → {r.url}')
    print(f'  status:  {r.status_code}  ({r.elapsed_ms} ms)')
    if r.caller_name:
        print(f'  caller:  {r.caller_name}  identity={r.matched_identity}  priority={r.priority}')
    if r.backend_pool:
        print(f'  pool:    {r.backend_pool}  backend={r.backend_url}')
        trail = r.headers.get('x-backend-attempt-trail')
        rc = r.headers.get('x-backend-retry-count')
        if trail:
            print(f'  retry:   count={rc}  trail={trail}')
    if r.ratelimit_limit_tokens is not None or r.ratelimit_remaining_tokens is not None:
        print(f'  tpm:     limit={r.ratelimit_limit_tokens}  remaining={r.ratelimit_remaining_tokens}  consumed_this_call={r.tokens_consumed}  (per-model, resets every minute)')
    if r.quota_limit_tokens is not None or r.quota_remaining_tokens is not None:
        print(f'  quota:   limit={r.quota_limit_tokens}  remaining={r.quota_remaining_tokens}  consumed_this_month={r.quota_tokens_consumed}  (monthly, all models)')
    if r.streamed_chunks:
        print(f'  stream:  {r.streamed_chunks} chunks  text={r.streamed_text!r}')
    elif r.body_json is not None:
        print(f'  body:    {json.dumps(r.body_json)[:200]}')
    elif r.body_text:
        print(f'  body:    {r.body_text[:200]}')
    print()
