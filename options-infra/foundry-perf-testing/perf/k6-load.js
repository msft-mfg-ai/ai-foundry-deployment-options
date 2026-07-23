// k6 load-test harness for the three-way agent perf comparison.
//
// Run:
//   VARIANT=custom  k6 run k6-load.js
//   VARIANT=hosted  k6 run k6-load.js
//   VARIANT=prompt  k6 run k6-load.js
//
// Env vars (all read from `azd env get-values` — see run.sh):
//   VARIANT                  custom | hosted | prompt
//   CUSTOM_AGENT_URL         https://support-agent-custom.<env-domain>
//   PROJECT_ENDPOINT         https://<foundry>.services.ai.azure.com/api/projects/<project>
//   HOSTED_AGENT_NAME        support-agent-hosted        (from azure.yaml)
//   PROMPT_AGENT_NAME        support-agent-prompt        (from seed-prompt-agent.sh)
//   AAD_TOKEN                Bearer token for the hosted+prompt variants (aud=https://ai.azure.com)
//
// Emits JSON summary to `results/<variant>-<timestamp>.json` (via handleSummary).

import http from 'k6/http';
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import { Counter, Trend } from 'k6/metrics';

const VARIANT = __ENV.VARIANT || 'custom';
const PROMPTS = JSON.parse(open('./prompts.json'));

// Hosted agents run in per-session sandbox VMs, capped at 50 concurrent per
// region/sub. For this baseline we pin ALL VUs to a SINGLE session, so we
// measure pure model+APIM+overhead latency without any sandbox spin-up in the
// hot path. Multi-session behaviour is a separate scenario we'll add later.
//   learn.microsoft.com/en-us/azure/foundry/agents/how-to/manage-hosted-sessions
let HOSTED_SESSION_ID = null;
if (VARIANT === 'hosted') {
  const arr = new SharedArray('hosted_sessions', () => {
    try {
      const a = JSON.parse(open('./sessions.json'));
      if (!Array.isArray(a) || a.length === 0) throw new Error('empty');
      return a;
    } catch (e) {
      throw new Error(
        `VARIANT=hosted requires perf/sessions.json — run perf/provision-sessions.sh first (${e.message})`,
      );
    }
  });
  HOSTED_SESSION_ID = arr[0];
}

const CUSTOM_AGENT_URL   = __ENV.CUSTOM_AGENT_URL;
const PROJECT_ENDPOINT   = __ENV.PROJECT_ENDPOINT;
const HOSTED_AGENT_NAME  = __ENV.HOSTED_AGENT_NAME || 'support-agent-hosted';
const PROMPT_AGENT_NAME  = __ENV.PROMPT_AGENT_NAME || 'support-agent-prompt';
const AAD_TOKEN          = __ENV.AAD_TOKEN || '';

// Per-variant trends so the summary can be split cleanly.
const agentLatency = new Trend(`agent_latency_${VARIANT}`, true);
const toolCallCount = new Counter(`tool_calls_${VARIANT}`);
const agentErrors = new Counter(`agent_errors_${VARIANT}`);

export const options = {
  discardResponseBodies: false,
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 1,
      stages: [
        { duration: '30s', target: 1 },    // warm-up
        { duration: '2m',  target: 5 },
        { duration: '2m',  target: 20 },
        { duration: '2m',  target: 50 },
        { duration: '2m',  target: 100 },
        { duration: '1m',  target: 0 },
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    [`agent_latency_${VARIANT}`]: [
      'p(50) < 10000',
      'p(95) < 30000',
    ],
    [`agent_errors_${VARIANT}`]: ['count < 100'],
  },
};

function pickPrompt() {
  return PROMPTS[Math.floor(Math.random() * PROMPTS.length)];
}

function endpointForVariant() {
  switch (VARIANT) {
    case 'custom':
      if (!CUSTOM_AGENT_URL) throw new Error('CUSTOM_AGENT_URL is required for VARIANT=custom');
      return { url: `${CUSTOM_AGENT_URL}/invoke`, needsAad: false };
    case 'hosted':
      if (!PROJECT_ENDPOINT || !AAD_TOKEN) throw new Error('PROJECT_ENDPOINT + AAD_TOKEN required for VARIANT=hosted');
      return {
        // Responses protocol endpoint per manage-hosted-sessions doc.
        url: `${PROJECT_ENDPOINT}/agents/${HOSTED_AGENT_NAME}/endpoint/protocols/openai/responses?api-version=v1`,
        needsAad: true,
      };
    case 'prompt':
      if (!PROJECT_ENDPOINT || !AAD_TOKEN) throw new Error('PROJECT_ENDPOINT + AAD_TOKEN required for VARIANT=prompt');
      return {
        // Same Responses protocol as hosted, for apples-to-apples comparison
        // on wire shape. Prompt agents don't use sandbox sessions.
        url: `${PROJECT_ENDPOINT}/agents/${PROMPT_AGENT_NAME}/endpoint/protocols/openai/responses?api-version=v1`,
        needsAad: true,
      };
    default:
      throw new Error(`Unknown VARIANT=${VARIANT} (expected custom|hosted|prompt)`);
  }
}

const { url, needsAad } = endpointForVariant();

export default function () {
  const prompt = pickPrompt();

  const body = VARIANT === 'custom'
    ? JSON.stringify({ input: prompt })
    : VARIANT === 'hosted'
      // All VUs share ONE sandbox session for this baseline scenario. We
      // intentionally omit previous_response_id so each call is stateless
      // from the model's perspective — only the sandbox VM is reused.
      ? JSON.stringify({ input: prompt, stream: false, agent_session_id: HOSTED_SESSION_ID })
      // Prompt agents use the same Responses shape, minus the sandbox session.
      : JSON.stringify({ input: prompt, stream: false });

  const headers = { 'Content-Type': 'application/json' };
  if (needsAad) headers['Authorization'] = `Bearer ${AAD_TOKEN}`;
  if (VARIANT === 'hosted') headers['Foundry-Features'] = 'HostedAgents=V1Preview';

  const start = Date.now();
  const resp = http.post(url, body, { headers, timeout: '120s' });
  const elapsed = Date.now() - start;

  agentLatency.add(elapsed);

  const ok = check(resp, {
    'status 2xx': (r) => r.status >= 200 && r.status < 300,
  });
  // Parse tool-call count across the three response shapes.
  let toolCalls = 0;
  let replyText = '';
  try {
    const j = resp.json();
    if (j && j.tool_calls) toolCalls = j.tool_calls.length;
    else if (j && j.output) {
      // Responses API — count both function-call and mcp_call items.
      toolCalls = (j.output || []).filter(
        (o) => o && (o.type === 'function_call' || o.type === 'mcp_call'),
      ).length;
      // Extract final assistant message text if present.
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

  // Emit one JSONL line per iteration, prefixed with a marker so run.sh
  // can grep it out of k6's mixed stdout into a clean .jsonl file.
  console.log('__ITER__' + JSON.stringify({
    v: VARIANT,
    vu: __VU,
    it: __ITER,
    status: resp.status,
    ms: elapsed,
    ok,
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

// Minimal ASCII summary so we don't pull in the k6 summary lib.
function textSummary(data) {
  const m = data.metrics;
  const lat = m[`agent_latency_${VARIANT}`] && m[`agent_latency_${VARIANT}`].values;
  const err = m[`agent_errors_${VARIANT}`] && m[`agent_errors_${VARIANT}`].values;
  const tools = m[`tool_calls_${VARIANT}`] && m[`tool_calls_${VARIANT}`].values;
  const lines = [
    `\n=== VARIANT=${VARIANT} ===`,
    lat ? `  latency p50=${lat['p(50)']?.toFixed(0)}ms  p95=${lat['p(95)']?.toFixed(0)}ms  p99=${lat['p(99)']?.toFixed(0)}ms  max=${lat.max?.toFixed(0)}ms  count=${lat.count}` : '  latency: no data',
    err ? `  errors: ${err.count || 0}` : '  errors: 0',
    tools ? `  total tool_calls: ${tools.count || 0}` : '',
    '',
  ];
  return lines.join('\n');
}
