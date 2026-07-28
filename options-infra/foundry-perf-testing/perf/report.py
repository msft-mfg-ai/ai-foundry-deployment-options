#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "azure-identity>=1.19.0",
#   "azure-monitor-query>=1.4.0",
#   "tabulate>=0.9.0",
# ]
# ///
"""
Ingests k6 result JSON files from perf/results/ and (optionally) enriches them
with App Insights latency-budget breakdowns, then prints a compact markdown
comparison table.

Usage:
  uv run report.py                                    # local-only summary
  uv run report.py --workspace <LAW-GUID>            # with App Insights KQL
  uv run report.py --workspace <GUID> --hours 1      # narrow the KQL window

Reads: perf/results/*.json  (k6 handleSummary output)
Writes: perf/results/report-<timestamp>.md
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

RESULTS_DIR = Path(__file__).parent / "results"


def load_variant_files() -> dict[str, list[Path]]:
    """Group k6 result JSON files by variant, newest last."""
    out: dict[str, list[Path]] = {"custom": [], "hosted": [], "prompt": []}
    for f in sorted(RESULTS_DIR.glob("*.json")):
        for variant in out:
            if f.name.startswith(f"{variant}-"):
                out[variant].append(f)
    return out


def summarise_variant(path: Path, variant: str) -> dict:
    """Extract the trend + counter metrics we care about from a k6 JSON dump."""
    data = json.loads(path.read_text())
    m = data.get("metrics", {})
    lat = m.get(f"agent_latency_{variant}", {}).get("values", {}) or {}
    errs = m.get(f"agent_errors_{variant}", {}).get("values", {}) or {}
    tools = m.get(f"tool_calls_{variant}", {}).get("values", {}) or {}
    reqs = m.get("http_reqs", {}).get("values", {}) or {}
    return {
        "file": path.name,
        "requests": int(lat.get("count", 0)),
        "p50_ms": round(lat.get("p(50)", 0), 0),
        "p95_ms": round(lat.get("p(95)", 0), 0),
        "p99_ms": round(lat.get("p(99)", 0), 0),
        "max_ms": round(lat.get("max", 0), 0),
        "errors": int(errs.get("count", 0)),
        "tool_calls": int(tools.get("count", 0)),
        "rps": round(reqs.get("rate", 0), 2),
    }


def query_appinsights(workspace_id: str, hours: int) -> str:
    """Run a per-role latency breakdown KQL query. Returns markdown table."""
    try:
        from azure.identity import DefaultAzureCredential
        from azure.monitor.query import LogsQueryClient
    except ImportError as e:
        return f"(App Insights query skipped — missing dependency: {e})"

    client = LogsQueryClient(DefaultAzureCredential())
    query = """
    let window = timespan;
    AppRequests
    | where TimeGenerated > ago(window)
    | where AppRoleName in ('support-agent-custom', 'support-agent-hosted', 'agentsv2')
    | summarize
        count = count(),
        p50 = percentile(DurationMs, 50),
        p95 = percentile(DurationMs, 95),
        p99 = percentile(DurationMs, 99),
        fail_rate = countif(Success == false) * 100.0 / count()
      by AppRoleName
    | order by AppRoleName asc
    """.replace("timespan", f"{hours}h")

    resp = client.query_workspace(workspace_id=workspace_id, query=query,
                                  timespan=timedelta(hours=hours))
    if not resp.tables:
        return "(App Insights query returned no rows.)"
    t = resp.tables[0]
    lines = ["| " + " | ".join(t.columns) + " |",
             "|" + "---|" * len(t.columns)]
    for row in t.rows:
        lines.append("| " + " | ".join(str(v) for v in row) + " |")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--workspace", help="Log Analytics workspace GUID for App Insights enrichment")
    ap.add_argument("--hours", type=int, default=2, help="KQL time window in hours (default 2)")
    args = ap.parse_args()

    files_by_variant = load_variant_files()
    if not any(files_by_variant.values()):
        print(f"No k6 result files found under {RESULTS_DIR}/. Run perf/run.sh first.", file=sys.stderr)
        return 1

    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
    out_lines: list[str] = [
        f"# Perf comparison report — {stamp}",
        "",
        "## k6 harness — latest run per variant",
        "",
        "| Variant | Requests | RPS | p50 (ms) | p95 (ms) | p99 (ms) | Max (ms) | Errors | Tool calls |",
        "|---------|---------:|----:|---------:|---------:|---------:|---------:|-------:|-----------:|",
    ]
    for variant in ("prompt", "hosted", "custom"):
        files = files_by_variant[variant]
        if not files:
            out_lines.append(f"| {variant} | _(no run)_ | | | | | | | |")
            continue
        s = summarise_variant(files[-1], variant)
        out_lines.append(
            f"| {variant} | {s['requests']} | {s['rps']} | {s['p50_ms']:.0f} | {s['p95_ms']:.0f} | "
            f"{s['p99_ms']:.0f} | {s['max_ms']:.0f} | {s['errors']} | {s['tool_calls']} |"
        )
    out_lines += ["", f"_Source files: `{RESULTS_DIR}/`_", ""]

    if args.workspace:
        out_lines += ["## App Insights — per-role latency (last {}h)".format(args.hours), ""]
        out_lines.append(query_appinsights(args.workspace, args.hours))
        out_lines.append("")

    out_lines += [
        "## Notes",
        "",
        "- Baseline (byom-canary): see `session/files/perf-baseline.md`.",
        "- Custom vs Hosted delta ≈ Foundry Responses overhead (~1.15 s in baseline).",
        "- Prompt-agent latency includes an extra planning round-trip vs hosted.",
    ]

    body = "\n".join(out_lines) + "\n"
    print(body)

    out_file = RESULTS_DIR / f"report-{stamp}.md"
    out_file.write_text(body)
    print(f"\nWrote {out_file}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
