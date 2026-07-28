#!/usr/bin/env sh
# Runs the k6 harness for the 6-variant matrix (custom/hosted/prompt × mock/real).
#
# Usage:
#   perf/run.sh                                   # all 6 variants (full 9m30s ramp each)
#   perf/run.sh custom-mock                       # subset
#   perf/run.sh hosted-mock hosted-real
#   K6_PROFILE=short perf/run.sh custom-real      # 2-min ramp for smoke/iteration
#   COOLDOWN=0 perf/run.sh ...                    # back-to-back (skip 60s settle)

set -eu
export PATH="/usr/bin:${PATH}"

cd "$(dirname "$0")"
mkdir -p results

if ! command -v k6 >/dev/null 2>&1; then
  echo "k6 not found. Install: https://grafana.com/docs/k6/latest/set-up/install-k6/"
  exit 1
fi

AZD_DIR="$(cd .. && pwd)"
azd_get() { (cd "${AZD_DIR}" && azd env get-value "$1" 2>/dev/null) || echo ''; }

export CUSTOM_AGENT_URL="$(azd_get SERVICE_SUPPORT_AGENT_CUSTOM_ENDPOINT)"
export PROJECT_ENDPOINT="$(azd_get PROJECT_ENDPOINT)"
export HOSTED_AGENT_MOCK="${HOSTED_AGENT_MOCK:-support-agent-hosted-mock}"
export HOSTED_AGENT_REAL="${HOSTED_AGENT_REAL:-support-agent-hosted-real}"
export HOSTED_BYPASS_MOCK="${HOSTED_BYPASS_MOCK:-support-agent-hosted-bypass-mock}"
export HOSTED_BYPASS_REAL="${HOSTED_BYPASS_REAL:-support-agent-hosted-bypass-real}"
export PROMPT_AGENT_MOCK="${PROMPT_AGENT_MOCK:-support-agent-prompt-mock}"
export PROMPT_AGENT_REAL="${PROMPT_AGENT_REAL:-support-agent-prompt-real}"
export AAD_TOKEN="$(azd auth token --scope https://ai.azure.com/.default --output json | /usr/bin/python3 -c "import sys,json; print(json.load(sys.stdin)[\"token\"])")"

echo "── perf harness config ──"
echo "CUSTOM_AGENT_URL=${CUSTOM_AGENT_URL}"
echo "PROJECT_ENDPOINT=${PROJECT_ENDPOINT}"
echo "HOSTED_AGENT_MOCK=${HOSTED_AGENT_MOCK}"
echo "HOSTED_AGENT_REAL=${HOSTED_AGENT_REAL}"
echo "PROMPT_AGENT_MOCK=${PROMPT_AGENT_MOCK}"
echo "PROMPT_AGENT_REAL=${PROMPT_AGENT_REAL}"
echo ""

# Default full matrix: mock lane first for each family (fast, warms things up),
# then real lane. Users can pass a subset on the CLI.
DEFAULT_VARIANTS="custom-mock hosted-mock hosted-bypass-mock prompt-mock custom-real hosted-real hosted-bypass-real prompt-real"
VARIANTS="${@:-${DEFAULT_VARIANTS}}"

COOLDOWN="${COOLDOWN:-60}"
HOSTED_SESSION_POOL="${HOSTED_SESSION_POOL:-1}"

first_variant=1
for v in ${VARIANTS}; do
  if [ "${first_variant}" -eq 0 ] && [ "${COOLDOWN}" -gt 0 ]; then
    echo ""
    echo "── Cooling down ${COOLDOWN}s before ${v} (backends settle, breakers reset) ──"
    sleep "${COOLDOWN}"
  fi
  first_variant=0
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  Running VARIANT=${v}"
  echo "════════════════════════════════════════════════════════════"

  # Parse family/lane. Family can be 'hosted-bypass' (2 words); lane is
  # the trailing token after the last '-'.
  case "${v}" in
    hosted-bypass-*)
      fam="hosted-bypass"
      lane="${v#hosted-bypass-}"
      ;;
    *)
      fam=$(printf '%s' "${v}" | cut -d- -f1)
      lane=$(printf '%s' "${v}" | cut -d- -f2)
      ;;
  esac

  # Hosted / hosted-bypass variants need pre-provisioned sandbox sessions per lane.
  if [ "${fam}" = "hosted" ] || [ "${fam}" = "hosted-bypass" ]; then
    case "${fam}-${lane}" in
      hosted-mock)          hosted_agent="${HOSTED_AGENT_MOCK}" ;;
      hosted-real)          hosted_agent="${HOSTED_AGENT_REAL}" ;;
      hosted-bypass-mock)   hosted_agent="${HOSTED_BYPASS_MOCK}" ;;
      hosted-bypass-real)   hosted_agent="${HOSTED_BYPASS_REAL}" ;;
    esac
    sessions_file="sessions-${fam}-${lane}.json"
    ./provision-sessions.sh "${HOSTED_SESSION_POOL}" "${hosted_agent}" "${sessions_file}"
    trap "./cleanup-sessions.sh \"${hosted_agent}\" \"${sessions_file}\" || true" EXIT INT TERM
  fi

  STAMP="$(date -u +%Y-%m-%dT%H-%M-%S)"
  LOGFILE="results/${v}-${STAMP}.log"
  VARIANT="${v}" K6_PROFILE="${K6_PROFILE:-full}" k6 run k6-load.js 2>&1 | tee "${LOGFILE}"

  # Extract per-iteration JSONL from the k6 log (unescape Go-style msg="...").
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

  if [ "${fam}" = "hosted" ] || [ "${fam}" = "hosted-bypass" ]; then
    ./cleanup-sessions.sh "${hosted_agent}" "${sessions_file}" || true
    trap - EXIT INT TERM
  fi
done

echo ""
echo "── Results ──"
ls -la results/
