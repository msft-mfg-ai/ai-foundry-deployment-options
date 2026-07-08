---
name: foundry-troubleshooting
description: >
  Diagnose and repair Azure AI Foundry deployments — capability hosts stuck in
  Failed state, VNet-injection / network-secured agent issues, project
  connections (storage, cosmos, search, Bing grounding), agent/assistant listing,
  and chat-completion smoke tests. Use when the user asks to "troubleshoot
  foundry", "capability host failed", "caphost stuck", "recreate capability
  host", "check foundry connections", "verify foundry network", "test foundry
  agent", "delete failed caphost", "foundry not working", "agent service broken",
  or references files under `utils/` such as
  `network-secured-agent-setup.ipynb` or `network-secured-agent.http`.
---

# Azure AI Foundry Troubleshooting

Diagnose and repair Azure AI Foundry accounts and projects — especially
network-injected ("network-secured agent") deployments — using the scripts
and notebook already in `utils/`.

## When to use this skill

- Capability host (account or project) is stuck in `Failed` / `Provisioning`
- Agent Service isn't reachable from a VNet-injected Foundry
- Project connections (storage, cosmos, AI Search, Bing grounding) are missing
  or misconfigured
- Need to verify which subnet a Foundry account is injected into
- Need to smoke-test chat completions or list agents on a private Foundry
- User references `utils/network-secured-agent-setup.ipynb`,
  `utils/network-secured-agent.http`, or `utils/test.http`

## Resources in this repo

| File | Purpose |
|------|---------|
| `utils/network-secured-agent-setup.ipynb` | Python notebook — get/create/delete account & project capability hosts, list connections, list agents, chat-completion smoke test. Uses `DefaultAzureCredential`. |
| `utils/network-secured-agent.http` | REST Client `.http` file with the same operations (bearer token from `az account get-access-token`). |
| `utils/test.http` | Additional Foundry REST probes. |
| `utils/.env.example` | Template for `projectResourceId`, `subnetId`, `tenantId`, etc. |

Related diagnostic skills (custom, may already be installed):
`foundry-agent-vnet-integration-diagnostics`,
`foundry-agent-vnet-capability-host-diagnostics`,
`foundry-agent-communications`,
`foundry-byo-model-apim-diagnostics`,
`foundry-low-level-network-diagnostics`. Prefer those for deep network / VNet
tracing; use **this** skill for the hands-on ARM/REST fix-it loop backed by
`utils/`.

## Setup (do this once per Foundry account under investigation)

```bash
cd utils
cp .env.example .env   # then edit
```

Fill `.env` with at minimum:

```
projectResourceId=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry>/projects/<project>
subnetId=/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>   # only for creating a caphost
tenantId=<tenant-guid>   # multi-tenant users
```

Then authenticate (subscription must match `projectResourceId`):

```bash
az login --tenant <tenantId>
az account set --subscription <sub>
```

## Standard diagnostic loop

Run the notebook end-to-end, or use the equivalent `az rest` commands the
first cell prints. The notebook does this:

1. **Parse `projectResourceId`** → `subscriptionId`, `rg`, `foundryName`, `projectName`.
2. **`get_account_caphost()`** — reports the injected `customerSubnet` or flags
   `❌ Foundry is NOT VNET INJECTED`.
3. **`get_project_caphost()`** — shows project caphost state and its three
   required connections (`vectorStoreConnections`, `storageConnections`,
   `threadStorageConnections`).
4. **List connections** — enumerates all project connections with category.
5. **List agents / chat-completion** — proves the data plane works
   (uses `https://ai.azure.com/.default` token, not ARM).

## Fixing a Failed capability host

**Order matters — always delete the project caphost before the account caphost.**

```bash
# 1. Delete PROJECT caphost
az rest --method delete \
  --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry>/projects/<project>/capabilityHosts/projcaphost?api-version=2025-04-01-preview"

# 2. Delete ACCOUNT caphost
az rest --method delete \
  --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry>/capabilityHosts/<foundry>@aml_aiagentservice?api-version=2025-06-01"

# 3. Recreate ACCOUNT caphost (VNet-injected)
az rest --method put \
  --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry>/capabilityHosts/<foundry>caphost?api-version=2025-06-01" \
  --body '{"properties":{"capabilityHostKind":"Agents","customerSubnet":"<subnetId>"}}'

# 4. Recreate PROJECT caphost with its three connections
az rest --method put \
  --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<foundry>/projects/<project>/capabilityHosts/projcaphost?api-version=2025-06-01" \
  --body '{"properties":{"capabilityHostKind":"Agents","vectorStoreConnections":["<search-conn-name>"],"storageConnections":["<storage-conn-name>"],"threadStorageConnections":["<cosmos-conn-name>"]}}'
```

The connection names are the **connection resource names** (as returned by the
"List connections" cell in the notebook), not the underlying resource names —
though in this repo's Bicep they typically match.

## Common failure modes (from repository memories & prior incidents)

- **Project caphost missing one of the three connections** → recreate with all
  three. Cross-check via the connections list cell.
- **Account caphost `customerSubnet` empty** → Foundry was never VNet-injected;
  redeploy or PUT with `customerSubnet` set.
- **Deleting account caphost while project caphost still exists** → API returns
  a dependency error. Delete project first (step 1 above).
- **BYO storage `defaultAction=Deny` blocks file uploads** → the file-upload
  service calls from a public Microsoft IP; `bypass=AzureServices` + trusted
  Cognitive Services rule is NOT sufficient. Either flip to `Allow` or ensure
  a per-region `ca-fileapi-*` Container App exists (regional rollout).
- **Foundry connections to APIM-fronted models** need
  `category: 'ApiManagement'` and metadata with `deploymentInPath`,
  `inferenceAPIVersion`, and either `staticModels` or `modelDiscovery` — never
  both (see `modules/ai/connection-apim-gateway.bicep`).

## Data-plane smoke tests

Once the control plane looks healthy, run the last three notebook cells:

- **List deployments** on `https://<foundry>.services.ai.azure.com/api/projects/<project>/deployments?api-version=v1`
- **Chat completion** on `https://<foundry>.services.ai.azure.com/models/chat/completions?api-version=2024-05-01-preview`
- **List assistants/agents** on `https://<foundry>.services.ai.azure.com/api/projects/<project>/assistants?api-version=v1`

These use the AI-plane audience `https://ai.azure.com/.default`, not the ARM
audience. A 401 here usually means the caller lacks
`Azure AI User` (or higher) on the project.

## Escalation to specialist diagnostic skills

If the loop above shows the control plane is healthy but agents still fail:

- Network / NSG blocking → `foundry-agent-vnet-integration-diagnostics`
- Capability host provisioned manually (unsupported) → `foundry-agent-vnet-capability-host-diagnostics`
- Cross-project or cross-Foundry agent calls failing → `foundry-agent-communications`
- BYO / APIM model connection failing → `foundry-byo-model-apim-diagnostics`
- DNS / TCP / TLS issues → `foundry-low-level-network-diagnostics`
