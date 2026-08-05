// k6 load-test harness for the perf agent comparison.
//
// Variants (VARIANT env):
//   custom-mock         | custom-real          — ASP.NET Core /invoke, `mode` field picks agent
//   hosted-mock         | hosted-real          — Foundry hosted agents (project-connection path)
//   hosted-bypass-mock  | hosted-bypass-real   — Foundry hosted agents (BYPASS: APIM direct via Instance MI)
//   prompt-mock         | prompt-real          — Foundry prompt agents  (2 seeded)
//
// -mock lanes: no MCP tools, APIM /inference-mock canned reply → measures
//   framework + Foundry-proxy overhead in isolation from model latency.
// -real lanes: MCP case-management tools attached, APIM /inference → real
//   gpt-5-mini → full customer-support workload.
//
// Env vars (populated by run.sh from `azd env get-values`):
//   VARIANT                    one of the above
//   CUSTOM_AGENT_URL           https://support-agent-custom.<env-domain>
//   PROJECT_ENDPOINT           https://<foundry>.services.ai.azure.com/api/projects/<project>
//   HOSTED_AGENT_MOCK          default: support-agent-hosted-mock
//   HOSTED_AGENT_REAL          default: support-agent-hosted-real
//   HOSTED_BYPASS_MOCK         default: support-agent-hosted-bypass-mock
//   HOSTED_BYPASS_REAL         default: support-agent-hosted-bypass-real
//   PROMPT_AGENT_MOCK          default: support-agent-prompt-mock
//   PROMPT_AGENT_REAL          default: support-agent-prompt-real
//   AAD_TOKEN                  bearer for hosted+prompt variants (aud=https://ai.azure.com)

import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import { Counter, Trend } from 'k6/metrics';

const VARIANT = __ENV.VARIANT || 'custom-mock';
const PROMPTS = JSON.parse(open('./prompts.json'));

// Variant format: <family>-<lane>  OR  hosted-bypass-<lane>.
// Family: custom | hosted | hosted-bypass | prompt.  Lane: mock | real.
let FAMILY, LANE;
{
  const validFamilies = ['custom', 'hosted', 'hosted-bypass', 'prompt'];
  const idx = VARIANT.lastIndexOf('-');
  if (idx < 0) throw new Error(`VARIANT missing '-<lane>' suffix: ${VARIANT}`);
  FAMILY = VARIANT.slice(0, idx);
  LANE = VARIANT.slice(idx + 1);
  if (!validFamilies.includes(FAMILY) || !['mock', 'real'].includes(LANE)) {
    throw new Error(`VARIANT must be one of ${validFamilies.map(f => `${f}-mock/${f}-real`).join(', ')}. Got: ${VARIANT}`);
  }
}

// Hosted agents run in per-session sandbox VMs, capped at 50 concurrent per
// region/sub. We pin ALL VUs of this run to a SINGLE session, per variant.
let HOSTED_SESSION_ID = null;
if (FAMILY === 'hosted' || FAMILY === 'hosted-bypass') {
  const key = `${FAMILY.replace('-', '_')}_${LANE}`;
  const sessFile = `./sessions-${FAMILY}-${LANE}.json`;
  const arr = new SharedArray(`hosted_sessions_${key}`, () => {
    try {
      const a = JSON.parse(open(sessFile));
      if (!Array.isArray(a) || a.length === 0) throw new Error('empty');
      return a;
    } catch (e) {
      throw new Error(
        `VARIANT=${VARIANT} requires ${sessFile} — run perf/provision-sessions.sh first (${e.message})`,
      );
    }
  });
  HOSTED_SESSION_ID = arr[0];
}

const CUSTOM_AGENT_URL   = __ENV.CUSTOM_AGENT_URL;
const PROJECT_ENDPOINT   = __ENV.PROJECT_ENDPOINT;
const HOSTED_AGENT_MOCK  = __ENV.HOSTED_AGENT_MOCK  || 'support-agent-hosted-mock';
const HOSTED_AGENT_REAL  = __ENV.HOSTED_AGENT_REAL  || 'support-agent-hosted-real';
const HOSTED_BYPASS_MOCK = __ENV.HOSTED_BYPASS_MOCK || 'support-agent-hosted-bypass-mock';
const HOSTED_BYPASS_REAL = __ENV.HOSTED_BYPASS_REAL || 'support-agent-hosted-bypass-real';
const PROMPT_AGENT_MOCK  = __ENV.PROMPT_AGENT_MOCK  || 'support-agent-prompt-mock';
const PROMPT_AGENT_REAL  = __ENV.PROMPT_AGENT_REAL  || 'support-agent-prompt-real';
const AAD_TOKEN          = __ENV.AAD_TOKEN || '';

// Metric key: k6 doesn't allow '-' in metric names for threshold selectors.
const METRIC_KEY = `${FAMILY.replace(/-/g, '_')}_${LANE}`;
const agentLatency = new Trend(`agent_latency_${METRIC_KEY}`, true);
const toolCallCount = new Counter(`tool_calls_${METRIC_KEY}`);
const agentErrors = new Counter(`agent_errors_${METRIC_KEY}`);

const PROFILE = (__ENV.K6_PROFILE || 'full').toLowerCase();
const STAGES = PROFILE === 'short'
  ? [
      { duration: '20s', target: 5 },
      { duration: '40s', target: 20 },
      { duration: '40s', target: 50 },
      { duration: '20s', target: 0 },
    ]
  : [
      { duration: '30s', target: 1 },
      { duration: '2m',  target: 5 },
      { duration: '2m',  target: 20 },
      { duration: '2m',  target: 50 },
      { duration: '2m',  target: 100 },
      { duration: '1m',  target: 0 },
    ];

export const options = {
  discardResponseBodies: false,
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: STAGES,
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    [`agent_latency_${METRIC_KEY}`]: [
      'p(50) < 10000',
      'p(95) < 30000',
    ],
    [`agent_errors_${METRIC_KEY}`]: ['count < 100'],
  },
};

function pickPrompt() {
  return PROMPTS[Math.floor(Math.random() * PROMPTS.length)];
}

function newRequestId() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.floor(Math.random() * 16);
    return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
  });
}

function responseHeader(response, ...names) {
  for (const name of names) {
    const wanted = name.toLowerCase();
    for (const [key, value] of Object.entries(response.headers || {})) {
      if (key.toLowerCase() === wanted) return Array.isArray(value) ? value[0] : value;
    }
  }
  return '';
}

function endpointForVariant() {
  let agentName;
  if (FAMILY === 'hosted') {
    agentName = LANE === 'mock' ? HOSTED_AGENT_MOCK : HOSTED_AGENT_REAL;
  } else if (FAMILY === 'hosted-bypass') {
    agentName = LANE === 'mock' ? HOSTED_BYPASS_MOCK : HOSTED_BYPASS_REAL;
  } else if (FAMILY === 'prompt') {
    agentName = LANE === 'mock' ? PROMPT_AGENT_MOCK : PROMPT_AGENT_REAL;
  }

  switch (FAMILY) {
    case 'custom':
      if (!CUSTOM_AGENT_URL) throw new Error(`CUSTOM_AGENT_URL is required for VARIANT=${VARIANT}`);
      return { url: `${CUSTOM_AGENT_URL}/invoke`, needsAad: false };
    case 'hosted':
    case 'hosted-bypass':
    case 'prompt':
      if (!PROJECT_ENDPOINT || !AAD_TOKEN) throw new Error(`PROJECT_ENDPOINT + AAD_TOKEN required for VARIANT=${VARIANT}`);
      return {
        url: `${PROJECT_ENDPOINT}/agents/${agentName}/endpoint/protocols/openai/responses?api-version=v1`,
        needsAad: true,
      };
    default:
      throw new Error(`Unknown VARIANT family=${FAMILY}`);
  }
}

const { url, needsAad } = endpointForVariant();

export default function () {
  const prompt = pickPrompt();

  const body = FAMILY === 'custom'
    ? JSON.stringify({ input: prompt, mode: LANE })
    : (FAMILY === 'hosted' || FAMILY === 'hosted-bypass')
      ? JSON.stringify({ input: prompt, stream: false, agent_session_id: HOSTED_SESSION_ID })
      : JSON.stringify({ input: prompt, stream: false });

  const clientRequestId = newRequestId();
  const headers = {
    'Content-Type': 'application/json',
    'x-ms-client-request-id': clientRequestId,
  };
  if (needsAad) headers['Authorization'] = `Bearer ${AAD_TOKEN}`;
  if (FAMILY === 'hosted' || FAMILY === 'hosted-bypass') headers['Foundry-Features'] = 'HostedAgents=V1Preview';

  const start = Date.now();
  const resp = http.post(url, body, { headers, timeout: '120s' });
  const elapsed = Date.now() - start;

  agentLatency.add(elapsed);

  const ok = check(resp, {
    'status 2xx': (r) => r.status >= 200 && r.status < 300,
  });

  let toolCalls = 0;
  let replyText = '';
  try {
    const j = resp.json();
    if (j && j.tool_calls) toolCalls = j.tool_calls.length;
    else if (j && j.output) {
      toolCalls = (j.output || []).filter(
        (o) => o && (o.type === 'function_call' || o.type === 'mcp_call'),
      ).length;
      for (const o of j.output || []) {
        if (o && o.type === 'message') {
          for (const c of o.content || []) {
            if (c && c.text) replyText += c.text;
          }
        }
      }
    } else if (j && j.messages) {
      toolCalls = (j.messages || []).filter((m) => m && m.role === 'tool').length;
    }
    if (!replyText && j && typeof j.reply === 'string') replyText = j.reply;
    if (!replyText && j && typeof j.output_text === 'string') replyText = j.output_text;
  } catch (_e) { /* non-JSON body — ignore */ }
  if (toolCalls) toolCallCount.add(toolCalls);

  console.log('__ITER__' + JSON.stringify({
    v: VARIANT,
    vu: __VU,
    it: __ITER,
    status: resp.status,
    ms: elapsed,
    ok,
    client_request_id: clientRequestId,
    request_id: responseHeader(resp, 'x-ms-request-id', 'request-id', 'x-request-id'),
    apim_request_id: responseHeader(resp, 'apim-request-id'),
    traceparent: responseHeader(resp, 'traceparent'),
    tool_calls: toolCalls,
    prompt: prompt.slice(0, 120),
    reply: (replyText || (resp.body || '').toString()).slice(0, 400),
  }));

  if (!ok) {
    agentErrors.add(1);
    return;
  }

  sleep(0.5);
}

export function handleSummary(data) {
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const file = `results/${VARIANT}-${stamp}.json`;
  return {
    stdout: textSummary(data),
    [file]: JSON.stringify(data, null, 2),
  };
}

function textSummary(data) {
  const m = data.metrics;
  const lat = m[`agent_latency_${METRIC_KEY}`] && m[`agent_latency_${METRIC_KEY}`].values;
  const err = m[`agent_errors_${METRIC_KEY}`] && m[`agent_errors_${METRIC_KEY}`].values;
  const tools = m[`tool_calls_${METRIC_KEY}`] && m[`tool_calls_${METRIC_KEY}`].values;
  const lines = [
    `\n=== VARIANT=${VARIANT} ===`,
    lat ? `  latency p50=${lat['p(50)']?.toFixed(0)}ms  p95=${lat['p(95)']?.toFixed(0)}ms  p99=${lat['p(99)']?.toFixed(0)}ms  max=${lat.max?.toFixed(0)}ms  count=${lat.count}` : '  latency: no data',
    err ? `  errors: ${err.count || 0}` : '  errors: 0',
    tools ? `  total tool_calls: ${tools.count || 0}` : '',
    '',
  ];
  return lines.join('\n');
}
