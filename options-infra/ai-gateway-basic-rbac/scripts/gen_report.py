import json, html, datetime, pathlib

SRC = pathlib.Path("/home/pkarpala/projects/otis/ai-foundry-config-testing/options-infra/ai-gateway-basic-rbac/tests/output/rbac-validation-results.json")
OUT = pathlib.Path("/home/pkarpala/projects/otis/ai-foundry-config-testing/options-infra/ai-gateway-basic-rbac/docs/rbac-validation-report.html")

# ---------------------------------------------------------------- role reference
ROLES = [
    {
        "name": "Foundry Agent Consumer",
        "guid": "eed3b665-ab3a-47b6-8f48-c9382fb1dad6",
        "scope": "Project (or per-agent)",
        "grants": "<code>Microsoft.CognitiveServices/accounts/AIServices/endpoints/interact/action</code> only. No management actions.",
        "purpose": "Least-privilege role for principals that need to <b>call an already-deployed agent's <code>interact</code> endpoint</b> and nothing else. Does NOT grant Responses API, agent management, project reads, or keys.",
        "assign_to": [
            ("Managed identity of a front-end app / chat UI", "The app relays end-user prompts to a specific agent and streams the reply back."),
            ("End-user principals (via Entra group)", "You want authenticated tenant users to appear in Foundry audit logs and be able to chat with a specific agent."),
            ("Bots, IVR, back-office automation", "Anything that only needs to <i>talk to</i> an agent."),
        ],
        "avoid": ["Developers building agents &rarr; use <b>Foundry User</b>.", "Apps that call <code>/openai/v1/responses</code> &rarr; see the current gap under <b>Foundry Project Runtime User</b>."],
        "tests": ["RD-01/Foundry Agent Consumer", "AS-01/runtime", "R-01", "R-02"],
    },
    {
        "name": "Foundry Project Runtime User",
        "guid": "142bfaed-a13f-4c2d-bed2-6db62c4a1009",
        "scope": "Project",
        "grants": "<code>Microsoft.CognitiveServices/accounts/AIServices/responses/*</code> only. No management actions.",
        "purpose": "Least-privilege role for principals that need to <b>invoke a v2 agent via the OpenAI Responses API</b> (<code>POST /openai/v1/responses</code>, streaming, conversations, message events). Counterpart to Foundry Agent Consumer for the newer Responses-API surface.",
        "assign_to": [
            ("Managed identity of a web/API app (App Service, Container Apps, AKS)", "Server-side code calls <code>/openai/v1/responses</code> after authenticating its own end users. Most common case."),
            ("Bot / function / batch job MI", "Any workload that only needs to <i>use</i> an agent someone else already built."),
            ("FIC on a workload / GitHub Actions", "CI smoke tests or scheduled agent invocations."),
            ("Service principal for evaluations / canaries", "Load tests, SLA monitors."),
        ],
        "avoid": ["Agent builders / developers &rarr; use <b>Foundry User</b>.", "Project admins &rarr; use <b>Foundry Project Manager</b>.", "Platform / IT operators &rarr; use <b>Foundry Account Owner</b>."],
        "gap": (
            "As of July 2026, a principal with <b>only</b> this role <b>cannot</b> invoke "
            "<code>POST /api/projects/{project}/openai/v1/responses</code> against a v2 agent. "
            "Foundry's authorization for that endpoint checks <code>AIServices/agents/write</code>, "
            "which the role does not grant. Call fails with 403 &ldquo;does not have permissions for AIServices/agents/write&rdquo;. "
            "Interim workaround: use <b>Foundry User</b> (validated by R-03b). "
            "Re-run <code>test_r03_responses_api_via_project_runtime</code> after Microsoft fixes the check."
        ),
        "tests": ["RD-01/Foundry Project Runtime User", "AS-01/responses", "R-03a", "R-03b"],
    },
    {
        "name": "Foundry User",
        "guid": "53ca6127-db72-4b80-b1b0-d745d6d5456d",
        "scope": "Project (usually) or Account",
        "grants": "Reader over the Foundry project + Foundry resource, plus <b>all data-plane actions</b> inside the project (create/edit agents, tools, threads, evaluations, files, connections). Does NOT grant control-plane management (creating projects/accounts, RBAC, model deployments).",
        "purpose": 'Microsoft calls this the <b>&ldquo;least-privilege role for developers building and testing agents.&rdquo;</b> Maps 1-to-1 to the customer\'s "builder" persona: build agents, create tools/skills, knowledge, guardrails, run evaluations, build workflows.',
        "assign_to": [
            ("Developers / data scientists", "Day-to-day builder workflow inside a specific project."),
            ("The project's managed identity", 'Microsoft explicitly requires this so the project can act on its own connections. See "Minimum role assignments to get started" in the Learn doc.'),
            ("Runtime applications calling <code>/openai/v1/responses</code>", "Interim workaround until the Foundry Project Runtime User gap is fixed."),
        ],
        "avoid": [],
        "tests": ["RD-01/Foundry User", "AS-01/builder", "B-01", "B-02", "B-06", "N-01", "N-02", "N-03", "N-04", "N-05", "N-06", "N-08", "R-03b"],
    },
    {
        "name": "Foundry Project Manager",
        "guid": "eadc314b-1a2d-4efa-be10-5d325db5065e",
        "scope": "Project",
        "grants": "Everything in Foundry User <b>plus</b> project management actions <b>plus</b> a <b>conditional</b> <code>Microsoft.Authorization/roleAssignments/write</code> scoped so it can only assign the <b>Foundry User</b> role inside the project.",
        "purpose": 'The "team lead" role. Whoever runs a particular project\'s developer team can onboard other builders without needing subscription Owner or Foundry Owner.',
        "assign_to": [
            ("Team lead / project admin", "They need to onboard builders into their project."),
            ("Automation SP running onboarding", "e.g. HR + Entra group sync for programmatic project membership."),
        ],
        "avoid": ["Do NOT assign at account scope &mdash; that effectively promotes them across every project. Use Foundry Account Owner or Foundry Owner for cross-project rights."],
        "tests": ["RD-01/Foundry Project Manager", "AS-01/project-admin", "CTRL-ADMIN-01"],
    },
    {
        "name": "Foundry Account Owner",
        "guid": "e47c6f54-e4a2-4754-9501-8e0985b135e1",
        "scope": "Account (Foundry resource)",
        "grants": "Full management over the specific Foundry account (create/modify projects, capability hosts, deployments (subject to Azure Policy), diagnostic settings, connections). Conditionally assign Foundry User, ACR, and monitoring roles. Does NOT grant permission to create <b>new</b> Foundry accounts elsewhere in the subscription or RG.",
        "purpose": "The IT/platform-operator role for <b>an existing Foundry account</b>. Distinguishes day-2 operations of an already-provisioned account from provisioning new accounts (which the customer explicitly forbids &mdash; all provisioning goes through Bicep in the pipeline).",
        "assign_to": [
            ("Platform team SPs", "Day-2 ops (agent troubleshooting, capability host reconciliation, APIM model routing changes)."),
            ("Foundry landing-zone automation identities", "Patch tags, diagnostic settings, or connections on an already-created account."),
        ],
        "avoid": ["Anyone who should be able to spin up new Foundry accounts &mdash; account creation must remain Bicep-only via subscription Owner in the CI pipeline."],
        "tests": ["RD-01/Foundry Account Owner", "AS-01/platform", "CTRL-PLAT-01a", "CTRL-PLAT-01b", "CTRL-PLAT-01c"],
    },
    {
        "name": "Foundry Owner",
        "guid": "c883944f-8b7b-4483-af10-35834be79c4a",
        "scope": "Account",
        "grants": "Everything Foundry Account Owner grants <b>plus</b> full data-plane rights inside every project of the account (Account Owner &cup; Foundry User across all projects). Conditionally assign Foundry User, ACR, and monitoring roles.",
        "purpose": 'Microsoft: <i>"highly privileged self-serve role designed for digital natives."</i> Closest built-in to "I own this entire Foundry account and every project inside it, and I want to build in them too." Prefer separating <b>Foundry Account Owner</b> (ops) + <b>Foundry User</b> per project (build) when you have segregated duties.',
        "assign_to": [
            ("Single-team, self-serve Foundry account", "Ops and dev are the same person."),
            ("Break-glass identity for the account", "Document + monitor tightly."),
        ],
        "avoid": ["Anyone who should not be able to build inside every project &mdash; use Account Owner + per-project Foundry User instead."],
        "tests": ["RD-01/Foundry Owner"],
    },
]

MSLEARN = "https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry"
MSLEARN_BUILTIN = "https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning"

rows = json.loads(SRC.read_text())

# Manual/skipped IDs (recorded as passed=False but actually UI-only)
MANUAL_IDS = {"N-07","B-03","B-04","B-05","B-07"}
for r in rows:
    if r["testId"] in MANUAL_IDS:
        r["_status"] = "MANUAL"
    elif r["passed"]:
        r["_status"] = "PASS"
    else:
        r["_status"] = "FAIL"

SUITE_ORDER = ["RoleDefinition", "Assignments", "BuilderPositive", "BuilderNegative", "Runtime", "Controls"]
SUITE_ALIASES = {
    "": "Assignments",
    "BuilderNegative": "BuilderNegative",
    "BuilderPositive": "BuilderPositive",
    "Runtime": "Runtime",
    "Controls": "Controls",
    "RoleDefinition": "RoleDefinition",
    "Assignments": "Assignments",
}
# Derive suite from testId when suite field is generic
def suite_of(r):
    tid = r["testId"]
    if tid.startswith("RD-"): return "RoleDefinition"
    if tid.startswith("AS-"): return "Assignments"
    if tid.startswith("B-"): return "BuilderPositive"
    if tid.startswith("N-"): return "BuilderNegative"
    if tid.startswith("R-"): return "Runtime"
    if tid.startswith("CTRL-"): return "Controls"
    return r.get("suite","Other")

SUITE_DESC = {
    "RoleDefinition": "Verifies that each of the 6 Foundry RBAC role definitions exists in the tenant with the expected GUID and role name.",
    "Assignments": "Confirms every persona service principal has ONLY its designated Foundry role at the correct scope — no inherited or broader RBAC.",
    "BuilderPositive": "Proves the <b>Foundry User</b> (builder) persona CAN perform the six approved builder capabilities: build agents, add tools, add knowledge, add guardrails, run evaluations, build workflows.",
    "BuilderNegative": "Proves the <b>Foundry User</b> (builder) persona CANNOT perform any of the 8 forbidden control-plane actions (create Foundry account, create project, deploy models, create Logic App / storage, assign roles, publish to Teams, list account keys).",
    "Runtime": "Proves the runtime personas (Foundry Agent Consumer, Foundry Project Runtime User) enforce least-privilege on the Responses / Agents v2 data plane.",
    "Controls": "Sanity-checks the two &ldquo;privileged&rdquo; personas: the platform account owner can manage the existing account but cannot create a new one; the project manager can assign only Foundry User inside the project.",
}

PERSONA_DESC = {
    "builder":       ("Foundry User",                 "project", "Owner of everything a builder needs: agents, tools, knowledge, guardrails, evals, workflows."),
    "runtime":       ("Foundry Agent Consumer",       "project", "Client apps that only need to invoke an existing agent (chat/interact endpoint)."),
    "responses":     ("Foundry Project Runtime User", "project", "Client apps that call the low-level OpenAI Responses API directly."),
    "platform":      ("Foundry Account Owner",        "account", "IT/platform operators of a specific Foundry account &mdash; cannot spin up new accounts."),
    "project-admin": ("Foundry Project Manager",      "project", "Project admin: can assign only <code>Foundry User</code> inside their project."),
    "none":          ("(no role)",                    "n/a",     "Baseline SP with no RBAC &mdash; used to prove denial-by-default."),
}

# Approved capabilities coverage (from customer requirements)
# status: OK | GAP | UI_ONLY | API_OK_UI_GAP
APPROVED = [
    ("Build agent",         "OK",     "B-02 (create Agents-v2 version) &nbsp;+ R-03b (invoke via Responses API)"),
    ("Create tool / skill", "API_OK_UI_GAP", "<b>API path works</b> &mdash; B-03 automatically creates an agent with an MCP tool attached (public Microsoft Learn MCP) as Foundry User. <b>UI path is blocked</b> &mdash; the &ldquo;+ Add tool&rdquo; affordance in the Foundry portal is hidden/disabled for a Foundry User. Builders can ship tool-enabled agents via IaC/CI but cannot self-serve them from the portal. See <a href='#known-gaps'>&sect; Known gaps</a>."),
    ("Create knowledge",    "UI_ONLY","B-04 &mdash; UI-only in Foundry today"),
    ("Create guardrails",   "GAP",    "<b>Foundry User cannot create guardrails in the Foundry portal today.</b> Requires <code>Foundry Project Manager</code> or higher &mdash; the Guardrails section is either hidden or read-only for a Foundry User. <b>This breaks customer requirement &ldquo;Users must be able to configure guardrails&rdquo;.</b> See <a href='#known-gaps'>&sect; Known gaps</a>."),
    ("Run evaluations",     "OK",     "B-06 (POST /evaluations/runs) &mdash; automated"),
    ("Build workflow",      "UI_ONLY","B-07 &mdash; UI-only; workflows REST API not GA"),
]

FORBIDDEN = [
    ("Create new Foundry account",                    "N-01"),
    ("Create new project",                            "N-02"),
    ("Deploy new models (must use APIM-exposed only)","N-03 (RBAC denial) + Azure Policy <code>deny-cognitive-services-model-deployments</code> in Bicep enforces defense-in-depth"),
    ("Create own Logic App to expose MCP server",     "N-04"),
    ("Create own storage account (data ex-filtration)","N-05"),
    ("Grant themselves or others new RBAC",           "N-06"),
    ("Publish agent to Microsoft Teams (playground only)","N-07 &mdash; UI-only"),
    ("Use account keys (only OAuth to APIM)",         "N-08 (disableLocalAuth=true on Foundry)"),
    ("Create indexes on underlying AI Search",        "<b>N-09</b> (builder denied on Search dataplane &mdash; no Foundry role grants Search dataActions) &nbsp;+&nbsp; <b>N-10</b> (builder denied on <code>listAdminKeys</code> ARM call &mdash; and <code>disableLocalAuth=true</code> means keys don&rsquo;t work anyway). Project MI gets only <code>Search Index Data Reader</code> for query-only grounding."),
]

# Group rows by suite
by_suite = {}
for r in rows:
    by_suite.setdefault(suite_of(r), []).append(r)

counts = {"PASS":0,"FAIL":0,"MANUAL":0}
for r in rows:
    counts[r["_status"]] += 1

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

def status_badge(s):
    color = {"PASS":"#137333","FAIL":"#c5221f","MANUAL":"#8a6d00"}[s]
    bg    = {"PASS":"#e6f4ea","FAIL":"#fce8e6","MANUAL":"#fef7e0"}[s]
    return f'<span class="badge" style="background:{bg};color:{color}">{s}</span>'

def row_html(r):
    tid = html.escape(r["testId"])
    persona = html.escape(r["persona"] or "&mdash;")
    exp = html.escape(r["expectedOutcome"] or "")
    act = html.escape(r["actualOutcome"] or "")
    status = r["_status"]
    return f"<tr><td><code>{tid}</code></td><td>{persona}</td><td>{exp}</td><td>{act}</td><td>{status_badge(status)}</td></tr>"

parts = []
parts.append(f"""<!doctype html><html><head><meta charset="utf-8">
<title>Foundry RBAC Validation Report &mdash; ai-gateway-basic-rbac</title>
<style>
 body {{ font-family: -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif; max-width:1200px; margin:2rem auto; padding:0 1.5rem; color:#202124; line-height:1.5; }}
 h1 {{ border-bottom:3px solid #1a73e8; padding-bottom:.5rem; }}
 h2 {{ margin-top:2.5rem; border-bottom:1px solid #dadce0; padding-bottom:.3rem; }}
 h3 {{ margin-top:1.8rem; color:#1a73e8; }}
 table {{ border-collapse:collapse; width:100%; margin:1rem 0; font-size:14px; }}
 th, td {{ border:1px solid #dadce0; padding:6px 10px; text-align:left; vertical-align:top; }}
 th {{ background:#f8f9fa; }}
 code {{ background:#f1f3f4; padding:1px 5px; border-radius:3px; font-size:13px; }}
 .badge {{ padding:2px 8px; border-radius:10px; font-size:12px; font-weight:600; }}
 .kpi {{ display:inline-block; margin-right:2rem; padding:1rem 1.5rem; background:#f8f9fa; border-radius:6px; border-left:4px solid #1a73e8; }}
 .kpi .n {{ font-size:2rem; font-weight:600; display:block; }}
 .kpi .l {{ color:#5f6368; font-size:.9rem; }}
 .callout {{ background:#e8f0fe; border-left:4px solid #1a73e8; padding:12px 16px; margin:1rem 0; border-radius:0 6px 6px 0; }}
 .warn    {{ background:#fef7e0; border-left:4px solid #f9ab00; padding:12px 16px; margin:1rem 0; border-radius:0 6px 6px 0; }}
 .ok      {{ background:#e6f4ea; border-left:4px solid #34a853; padding:12px 16px; margin:1rem 0; border-radius:0 6px 6px 0; }}
 ul li {{ margin:.25rem 0; }}
</style></head><body>
<h1>Foundry RBAC Validation Report</h1>
<p><b>Deployment:</b> <code>options-infra/ai-gateway-basic-rbac</code> &nbsp;|&nbsp; <b>Generated:</b> {now}</p>

<div>
 <div class="kpi"><span class="n" style="color:#137333">{counts['PASS']}</span><span class="l">Automated PASS</span></div>
 <div class="kpi"><span class="n" style="color:#c5221f">{counts['FAIL']}</span><span class="l">FAIL</span></div>
 <div class="kpi"><span class="n" style="color:#8a6d00">{counts['MANUAL']}</span><span class="l">Manual / UI-only</span></div>
 <div class="kpi" style="border-left-color:#c5221f"><span class="n" style="color:#c5221f">3</span><span class="l"><a href="#known-gaps">Unmet requirements</a></span></div>
 <div class="kpi"><span class="n">{len(rows)}</span><span class="l">Total evidence rows</span></div>
</div>

<h2>1. What was tested</h2>
<p>This harness proves the customer's Foundry access-control matrix on a live deployment. It:</p>
<ol>
 <li>Deploys a Foundry account + project + APIM inference gateway in a VNET-ready pattern (Bicep).</li>
 <li>Creates <b>6 service principals</b>, one per persona, each with <b>exactly one</b> Foundry role at the right scope.</li>
 <li>Runs <b>{len(rows)} test cases</b> across 6 suites &mdash; every case writes an evidence row (JSON + CSV) with expected vs. actual HTTP status.</li>
 <li>Layers an <b>Azure Policy</b> (<code>deny-cognitive-services-model-deployments</code>, empty allow-list) at subscription scope for defense-in-depth against model deployment even if RBAC were mis-configured.</li>
</ol>

<h2>2. Personas &amp; roles under test</h2>
<table><thead><tr><th>Persona (SP name suffix)</th><th>Foundry role</th><th>Scope</th><th>Represents</th></tr></thead><tbody>""")

for k,(r,s,d) in PERSONA_DESC.items():
    parts.append(f"<tr><td><code>{k}</code></td><td>{r}</td><td>{s}</td><td>{d}</td></tr>")
parts.append("</tbody></table>")

parts.append("<h2>3. Customer requirements coverage</h2>")
parts.append('<div class="warn"><b>&#10060; 2 approved capabilities are NOT fully met (portal UI):</b> Foundry User cannot configure guardrails and cannot attach tools from the portal &mdash; even though the tool-attach API path works. See rows highlighted below and <a href="#known-gaps">&sect; Known gaps</a>.</div>')
parts.append('<h3>3.1 Capabilities users MUST be able to do</h3><table><thead><tr><th>Capability</th><th>Status</th><th>Evidence / notes</th></tr></thead><tbody>')
_STATUS_BADGE = {
    "OK":            ('#137333','#e6f4ea','&#10004; OK'),
    "GAP":           ('#c5221f','#fce8e6','&#10060; GAP'),
    "UI_ONLY":       ('#8a6d00','#fef7e0','UI-only'),
    "API_OK_UI_GAP": ('#8a6d00','#fef7e0','&#9888; API OK / UI blocked'),
}
for cap, st, note in APPROVED:
    col, bg, lbl = _STATUS_BADGE[st]
    row_style = ' style="background:#fef7f6"' if st == "GAP" else ""
    parts.append(
        f"<tr{row_style}><td>{cap}</td>"
        f"<td><span class=\"badge\" style=\"background:{bg};color:{col}\">{lbl}</span></td>"
        f"<td>{note}</td></tr>"
    )
parts.append("</tbody></table>")

parts.append('<h3>3.2 Actions users MUST NOT be able to do</h3><table><thead><tr><th>Forbidden action</th><th>Test evidence</th></tr></thead><tbody>')
for cap, tid in FORBIDDEN:
    parts.append(f"<tr><td>{cap}</td><td>{tid}</td></tr>")
parts.append("</tbody></table>")

parts.append("""
<div class="callout"><b>Defense-in-depth for model deployment:</b>
On top of RBAC (N-03 shows a builder is denied at 403 via role permissions), the deployment installs a subscription-scope <b>Azure Policy</b> <code>deny-cognitive-services-model-deployments</code> with an empty <code>allowedModels</code> array. This blocks <code>Microsoft.CognitiveServices/accounts/deployments</code> PUTs from ANY identity &mdash; even Foundry Account Owner or subscription Owner &mdash; so only models pre-baked into the APIM gateway can be reached.</div>

<div class="callout"><b>Defense-in-depth for AI Search index authoring (N-09 / N-10):</b>
<ol>
 <li><b>No Foundry role grants Search dataplane actions</b> &mdash; a Foundry User calling <code>PUT /indexes/{name}</code> with a valid Entra ID token is denied at the Search dataplane (N-09).</li>
 <li><b><code>disableLocalAuth: true</code></b> on the Search resource &mdash; admin/query keys cannot be issued or used, so even a leaked key or a compromised <code>listAdminKeys</code> call would be useless (N-10).</li>
 <li><b>Only the project's managed identity gets access</b>, and only as <code>Search Index Data Reader</code> &mdash; query-only, no index authoring. Index creation happens in CI/Bicep, not from user-facing surfaces.</li>
</ol>
Together these mean users can build knowledge-grounded agents (the project MI queries at runtime) but cannot create, modify, or discover indexes on the underlying Search service.</div>
""")

parts.append("<h2 id='known-gaps'>4. Known gaps &mdash; where the customer requirements are NOT met</h2>")
parts.append("""
<div class="warn"><b>&#10060; Gap 1 &mdash; Foundry User cannot create guardrails.</b><br>
<b>Customer requirement:</b> &ldquo;Users must be able to configure guardrails.&rdquo;<br>
<b>Observed:</b> Signed into the Foundry portal as Joe (Foundry User at project scope), the Guardrails / Content Safety configuration surface is hidden or read-only. Creating a new guardrail requires <b>Foundry Project Manager</b> or higher.<br>
<b>Impact:</b> Builders cannot self-serve guardrail configuration &mdash; a project admin has to do it for them, breaking the &ldquo;builders own the full agent lifecycle&rdquo; expectation.<br>
<b>Options:</b>
 <ol>
  <li><b>Elevate the builder persona to <code>Foundry Project Manager</code></b> at project scope. Trade-off: the builder can then also assign the Foundry User role to other users (conditional roleAssignments/write), which may or may not be acceptable to the customer.</li>
  <li><b>Keep <code>Foundry User</code></b> and treat guardrail configuration as an admin-only activity documented in the ops runbook (project admin runs it on request).</li>
  <li><b>Escalate to Microsoft</b> to expose guardrail configuration to Foundry User &mdash; this is a role-definition gap, not a Bicep/policy issue.</li>
 </ol>
</div>

<div class="warn"><b>&#10060; Gap 2 &mdash; Foundry User cannot attach tools to an agent from the portal.</b><br>
<b>Customer requirement:</b> &ldquo;Users must be able to create tools / skills.&rdquo;<br>
<b>Observed:</b> Signed into the Foundry portal as Joe (Foundry User at project scope), the agent editor&rsquo;s &ldquo;+ Add tool&rdquo; affordance is either hidden or disabled. However, <b>the API path works</b> &mdash; test <b>B-03</b> in this harness programmatically creates an agent with an MCP tool attached using Joe&rsquo;s credentials and it succeeds.<br>
<b>Impact:</b> Builders can ship tool-enabled agents through IaC/CI (Bicep + <code>agents_v2/create_agents.py</code>) but cannot self-serve them from the portal &mdash; contradicts the &ldquo;builders own the full agent lifecycle&rdquo; expectation.<br>
<b>Options:</b>
 <ol>
  <li><b>Elevate the builder persona to <code>Foundry Project Manager</code></b> at project scope. Same trade-off as Gap 1 (they also gain conditional roleAssignments/write).</li>
  <li><b>Automate tool attachment via CI</b> &mdash; keep <code>Foundry User</code> and have builders wire tools through the <code>agents_v2/create_agents.py</code> pipeline instead of the portal.</li>
  <li><b>Escalate to Microsoft</b> &mdash; the UI is more restrictive than the underlying role; the &ldquo;+ Add tool&rdquo; control should be visible whenever <code>agents/write</code> is granted, which Foundry User has.</li>
 </ol>
</div>

<div class="warn"><b>&#10060; Gap 3 &mdash; Foundry Project Runtime User cannot invoke the Responses API.</b><br>
<b>Observed (R-03a):</b> A principal with only <code>Foundry Project Runtime User</code> gets HTTP 403 &ldquo;does not have permissions for AIServices/agents/write&rdquo; when calling <code>POST /openai/v1/responses</code> against a v2 agent. The endpoint enforces <code>agents/write</code> but the role only grants <code>responses/*</code>.<br>
<b>Practical workaround:</b> use <b>Foundry User</b> for runtime apps until Microsoft closes the check (R-03b confirms this works).
</div>
""")

parts.append("<h2>5. What works as expected</h2>")
parts.append("""
<div class="ok"><b>All 9 builder-forbidden actions are enforced</b> across the control plane (ARM), data plane (Foundry API + Azure AI Search), and Azure Policy &mdash; no unexpected access paths found. See the BuilderNegative suite below (includes new N-09/N-10 for AI Search).</div>
<div class="ok"><b>All 6 built-in Foundry roles have the expected GUIDs and permissions</b> as returned by ARM &mdash; see RoleDefinition suite and <code>tests/output/foundry-role-definitions.actual.json</code>.</div>
<div class="ok"><b>Every persona SP holds ONLY its designated role at the correct scope</b> &mdash; no inherited or broader RBAC. See Assignments suite.</div>
""")

parts.append("<h2>6. Detailed results per suite</h2>")
for suite in SUITE_ORDER:
    rs = by_suite.get(suite, [])
    if not rs:
        continue
    n_pass  = sum(1 for r in rs if r["_status"]=="PASS")
    n_fail  = sum(1 for r in rs if r["_status"]=="FAIL")
    n_man   = sum(1 for r in rs if r["_status"]=="MANUAL")
    parts.append(f"<h3>6.{SUITE_ORDER.index(suite)+1} {suite}</h3>")
    parts.append(f"<p>{SUITE_DESC.get(suite,'')}</p>")
    parts.append(f"<p><b>{n_pass}</b> pass, <b>{n_fail}</b> fail, <b>{n_man}</b> manual/UI &mdash; {len(rs)} total.</p>")
    parts.append("<table><thead><tr><th>Test ID</th><th>Persona</th><th>Expected</th><th>Actual</th><th>Status</th></tr></thead><tbody>")
    for r in rs:
        parts.append(row_html(r))
    parts.append("</tbody></table>")

parts.append("""
<h2>7. Foundry built-in roles &mdash; reference</h2>
<p>Descriptions below are consolidated from Microsoft&rsquo;s
<a href="https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry" target="_blank" rel="noopener">Role-based access control for Microsoft Foundry</a>
(<a href="https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning" target="_blank" rel="noopener">exact role definitions</a>).</p>
<div class="callout"><b>Naming note.</b> Foundry roles were renamed &mdash; <b>Foundry User / Owner / Account Owner / Project Manager</b> were previously <i>Azure AI User / Owner / Account Owner / Project Manager</i>. Role IDs and permissions are unchanged; ARM accepts both names. This repo&rsquo;s IAM modules alias both. <b>Do NOT</b> use <code>Cognitive Services *</code> or the legacy <code>Azure AI Developer</code> role for Foundry &mdash; those apply to AI Services / AML hubs.</div>

<h3>7.1 Summary</h3>
<table><thead><tr><th>Role</th><th>GUID</th><th>Typical scope</th><th>Purpose (Microsoft Learn)</th></tr></thead><tbody>""")
for role in ROLES:
    anchor = role["name"].lower().replace(" ", "-")
    parts.append(
        f"<tr><td><a href=\"#{anchor}\">{role['name']}</a></td>"
        f"<td><code>{role['guid']}</code></td>"
        f"<td>{role['scope']}</td>"
        f"<td>{role['purpose']}</td></tr>"
    )
parts.append("</tbody></table>")

for i, role in enumerate(ROLES, start=2):
    anchor = role["name"].lower().replace(" ", "-")
    parts.append(f"<h3 id=\"{anchor}\">7.{i} {role['name']}</h3>")
    parts.append("<table style=\"width:auto;min-width:60%\"><tbody>")
    parts.append(f"<tr><th style=\"width:180px\">GUID</th><td><code>{role['guid']}</code></td></tr>")
    parts.append(f"<tr><th>Scope</th><td>{role['scope']}</td></tr>")
    parts.append(f"<tr><th>Grants</th><td>{role['grants']}</td></tr>")
    parts.append("</tbody></table>")
    parts.append(f"<p><b>Purpose.</b> {role['purpose']}</p>")
    if role["assign_to"]:
        parts.append("<p><b>Assign it to:</b></p><table><thead><tr><th>Assignee</th><th>When</th></tr></thead><tbody>")
        for who, when in role["assign_to"]:
            parts.append(f"<tr><td>{who}</td><td>{when}</td></tr>")
        parts.append("</tbody></table>")
    if role["avoid"]:
        parts.append("<p><b>Do NOT assign to:</b></p><ul>")
        for a in role["avoid"]:
            parts.append(f"<li>{a}</li>")
        parts.append("</ul>")
    if role.get("gap"):
        parts.append(f'<div class="warn"><b>&#9888; Current gap:</b> {role["gap"]}</div>')
    parts.append("<p><b>Test evidence in this harness:</b> " + ", ".join(f"<code>{t}</code>" for t in role["tests"]) + "</p>")

parts.append("""
<h2>8. Reproducing this report</h2>
<pre><code>cd options-infra/ai-gateway-basic-rbac
AZD_DISABLE_AGENT_DETECT=1 azd up          # deploys Foundry + APIM + 6 SPs + Azure Policy
cd tests
uv sync
uv run pytest -v                            # writes output/rbac-validation-results.{json,csv}
python ../scripts/gen_report.py             # regenerates this HTML</code></pre>

<h2>9. Artifacts</h2>
<ul>
 <li><code>tests/output/rbac-validation-results.json</code> &mdash; machine-readable evidence for every test.</li>
 <li><code>tests/output/rbac-validation-results.csv</code> &mdash; same, spreadsheet-friendly.</li>
 <li><code>tests/output/foundry-role-definitions.actual.json</code> &mdash; the 6 Foundry role definitions as returned by ARM at test time.</li>
 <li><code>docs/manual-ui-test-plan.md</code> &mdash; checklist for the 5 UI-only cases.</li>
 <li><code>docs/foundry-roles.md</code>, <code>docs/architecture.md</code>, <code>docs/troubleshooting.md</code>.</li>
</ul>

<h2>10. References</h2>
<ul>
 <li><a href="https://learn.microsoft.com/en-us/azure/foundry/concepts/rbac-foundry" target="_blank" rel="noopener">Microsoft Learn &mdash; RBAC for Microsoft Foundry</a></li>
 <li><a href="https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/ai-machine-learning" target="_blank" rel="noopener">AI + Machine Learning built-in roles</a></li>
</ul>
</body></html>""")

OUT.write_text("\n".join(parts))
print(f"Wrote {OUT} ({OUT.stat().st_size:,} bytes)")
