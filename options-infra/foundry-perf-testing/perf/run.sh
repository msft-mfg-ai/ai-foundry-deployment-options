#!/usr/bin/env sh
# Runs the k6 harness for all three variants in sequence, pulling endpoints and
# an AAD token from the current azd env.
#
# Requires: k6 (https://k6.io), az cli logged in.
#
# Usage:
#   perf/run.sh                   # run all three variants
#   perf/run.sh custom            # run only the specified variant(s)
#   perf/run.sh hosted prompt

set -eu
# Workaround: ~/bin/az is a stale wrapper pointing at a broken Python venv.
# Prepend /usr/bin so azd auth token's AzureCLICredential fallback finds the working az.
export PATH="/usr/bin:${PATH}"

cd "$(dirname "$0")"
mkdir -p results

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6 not found. Install: https://grafana.com/docs/k6/latest/set-up/install-k6/"
  exit 1
fi

# Pull azd env values from the perf-testing option directory.
AZD_DIR="$(cd .. && pwd)"
azd_get() { (cd "${AZD_DIR}" && azd env get-value "$1" 2>/dev/null) || echo ''; }

export CUSTOM_AGENT_URL="$(azd_get SERVICE_SUPPORT_AGENT_CUSTOM_ENDPOINT)"
export PROJECT_ENDPOINT="$(azd_get PROJECT_ENDPOINT)"
export HOSTED_AGENT_NAME="${HOSTED_AGENT_NAME:-support-agent-hosted}"
export PROMPT_AGENT_NAME="${PROMPT_AGENT_NAME:-support-agent-prompt}"
export AAD_TOKEN="$(azd auth token --scope https://ai.azure.com/.default --output json | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])")"

echo "── perf harness config ──"
echo "CUSTOM_AGENT_URL=${CUSTOM_AGENT_URL}"
echo "PROJECT_ENDPOINT=${PROJECT_ENDPOINT}"
echo "HOSTED_AGENT_NAME=${HOSTED_AGENT_NAME}"
echo "PROMPT_AGENT_NAME=${PROMPT_AGENT_NAME}"
echo ""

VARIANTS="${@:-custom hosted prompt}"

# How many sandbox sessions to pre-provision for the hosted variant.
# Baseline scenario: 1 session shared across all VUs. A separate multi-session
# scenario is planned as a follow-up.
HOSTED_SESSION_POOL="${HOSTED_SESSION_POOL:-1}"

for v in ${VARIANTS}; do
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  Running VARIANT=${v}"
  echo "════════════════════════════════════════════════════════════"

  if [ "${v}" = "hosted" ]; then
    ./provision-sessions.sh "${HOSTED_SESSION_POOL}"
    trap './cleanup-sessions.sh || true' EXIT INT TERM
  fi

  STAMP="$(date -u +%Y-%m-%dT%H-%M-%S)"
  LOGFILE="results/${v}-${STAMP}.log"
  VARIANT="${v}" k6 run k6-load.js 2>&1 | tee "${LOGFILE}"
  # k6 wraps console.log() as: level=info msg="..." source=console with Go-style
  # escaping. Parse it back into clean JSONL so results are one-per-line JSON.
  /usr/bin/python3 -c '
import re, sys, json
pat = re.compile(r"msg=\"((?:\\.|[^\"\\])*)\"")
esc = re.compile(r"\\(.)")
def unesc(m):
    c = m.group(1)
    return {"n":"\n","t":"\t","r":"\r","\\":"\\","\"":"\""}.get(c, c)
with open(sys.argv[1]) as f, open(sys.argv[2], "w") as out:
    for line in f:
        m = pat.search(line)
        if not m: continue
        s = esc.sub(unesc, m.group(1))
        if not s.startswith("__ITER__"): continue
        try:
            obj = json.loads(s[len("__ITER__"):])
        except Exception:
            continue
        out.write(json.dumps(obj) + "\n")
' "${LOGFILE}" "results/${v}-${STAMP}.jsonl"
  echo "  → per-iteration log: ${LOGFILE}"
  echo "  → per-iteration jsonl: results/${v}-${STAMP}.jsonl ($(wc -l < "results/${v}-${STAMP}.jsonl") records)"

  if [ "${v}" = "hosted" ]; then
    ./cleanup-sessions.sh || true
    trap - EXIT INT TERM
  fi
done

echo ""
echo "── Results ──"
ls -la results/
