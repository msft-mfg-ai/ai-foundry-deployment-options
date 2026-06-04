# Option: LiteLLM Gateway with Self-Signed Cert + nginx Proxy

This deployment option demonstrates an enterprise pattern where **the LiteLLM
endpoint is fronted by a self-signed certificate** on a caller-supplied
custom domain (simulating an internal/private CA), and Foundry — which
cannot validate self-signed certs — reaches it through an **nginx reverse
proxy** that trusts the self-signed root.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              This Deployment                                │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────┐      │
│  │                      AI Foundry                                   │      │
│  │  ┌─────────────┐  ┌─────────────┐                                 │      │
│  │  │  Project 1  │  │  Project 2  │  (Agent Service)                │      │
│  │  │ + CapHost   │  │ + CapHost   │                                 │      │
│  │  └──────┬──────┘  └──────┬──────┘                                 │      │
│  │         │ ModelGateway connection targets nginx (MS-trusted cert) │      │
│  └─────────┼─────────────────┼─────────────────────────────────────-─┘      │
│            │                 │                                              │
│            ▼                 ▼                                              │
│  ┌─────────────────────────────────────┐                                    │
│  │  litellm-proxy (nginx ACA)          │                                    │
│  │  ─ default *.azurecontainerapps.io  │                                    │
│  │    FQDN, MS-trusted cert            │                                    │
│  │  ─ init container installs root CA  │                                    │
│  │  ─ proxy_ssl_verify on              │                                    │
│  │  ─ proxy_ssl_name LITELLM_DOMAIN    │                                    │
│  └────────────────┬────────────────────┘                                    │
│                   │  https → custom domain, ACA presents self-signed cert   │
│                   ▼                                                         │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  ACA ingress on LITELLM_DOMAIN — terminates TLS with self-signed    │    │
│  │  PFX bound to managed-environment certificate resource.             │    │
│  │  Forwards plain HTTP to:                                            │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │  LiteLLM container (port 4000, no internal TLS)             │    │    │
│  │  └─────────────────────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────┐       │
│  │  Supporting: VNet | Key Vault | PostgreSQL | Log Analytics       │       │
│  └──────────────────────────────────────────────────────────────────┘       │
└────────────────────────────────────────────────────────────────────────────-┘
```

**Where TLS actually terminates.** ACA HTTP ingress always terminates TLS at
the platform — that's where the bound certificate is presented. Binding
`LITELLM_DOMAIN` to the LiteLLM container app with the self-signed PFX makes
ACA present that cert for any request hitting `https://<LITELLM_DOMAIN>`.
The LiteLLM container itself stays HTTP-only on port 4000; the cert never
touches the container. (Trying to do end-to-end TLS would conflict with
ACA's HTTP probes and ingress routing.)

**Why the proxy?** Foundry's ModelGateway connections validate TLS against
the system trust store and have no hook for adding a custom root CA. nginx
in the middle gives Foundry a `*.azurecontainerapps.io` endpoint (MS-trusted)
while the nginx → LiteLLM hop uses the self-signed cert, validated against
the root CA loaded by an init container.

## Prerequisites

### 1. Environment variables

```bash
azd env set OPENAI_API_KEY      "<your-aoai-key>"
azd env set OPENAI_API_BASE     "https://<your-aoai>.openai.azure.com"
azd env set OPENAI_RESOURCE_ID  "/subscriptions/.../Microsoft.CognitiveServices/accounts/<aoai>"

# FQDN the self-signed cert will cover. Must be a domain you control DNS for.
azd env set LITELLM_DOMAIN "litellm.your-domain.example.com"
```

### 2. DNS prerequisite — ACA custom domain validation

When Azure Container Apps binds a custom hostname, it validates ownership by
**resolving the hostname via public DNS** before accepting the binding.
Before running `azd up`, configure **one** of:

- **CNAME**: `<LITELLM_DOMAIN>` → `<aca-litellm-{token}>.<region>.azurecontainerapps.io`
- **TXT**: `asuid.<LITELLM_DOMAIN>` → `<custom-domain-verification-id of the ACA env>`

Because the target FQDN and verification ID don't exist until the ACA
environment is created, the **recommended flow is two-phase**:

1. **First `azd provision`** — leave `LITELLM_DOMAIN` _empty_:
   ```bash
   azd env set LITELLM_DOMAIN ""
   azd provision
   ```
   This brings everything up *without* the custom-domain binding. From the
   outputs / portal grab the LiteLLM container app's default FQDN and the
   managed environment's verification ID.

2. **Configure DNS** at your registrar (CNAME or `asuid` TXT, see above).

3. **Second `azd provision`** — set `LITELLM_DOMAIN` and re-run:
   ```bash
   azd env set LITELLM_DOMAIN "litellm.your-domain.example.com"
   azd provision
   ```
   The preprovision hook now generates the cert, Bicep binds the custom
   domain, and the proxy starts validating against the issued root CA.

Subsequent deploys are idempotent.

### 3. `openssl` on `PATH`

Used by the preprovision hook. Standard on Linux/macOS; on Windows install
via `winget install ShiningLight.OpenSSL` or use Git for Windows.

## Deployment

```bash
cd options-infra/ai-gateway-litellm-cert
azd up
```

Flow:

1. **`preprovision` hook** (`scripts/preprovision-litellm-cert.{sh,ps1}`)
   generates a self-signed root CA + leaf cert for `LITELLM_DOMAIN` and
   writes three base64 vars to the azd env (`LITELLM_CERT_PFX_BASE64`,
   `LITELLM_CERT_PFX_PASSWORD`, `LITELLM_ROOT_CA_PEM_BASE64`). When
   `LITELLM_DOMAIN` is empty the hook still emits a warning + skips, so the
   first-phase deploy works.
2. **Bicep deploy** brings up the LiteLLM container app (plain HTTP on 4000),
   optionally adds an `ACA managed-environment certificate` + `customDomains`
   binding so ACA terminates TLS for `LITELLM_DOMAIN` with the self-signed
   leaf, then deploys the nginx proxy with init containers that decode the
   root CA + render the nginx config.
3. **Foundry ModelGateway connections** (dynamic + static) are created
   pointing at the nginx proxy (MS-trusted FQDN).
4. **App Gateway** publishes the nginx proxy publicly for the LiteLLM admin
   UI / Swagger.

## Cert lifecycle

Certs are regenerated only when at least one of the three cert env vars is
missing. To force a rotation:

```bash
for v in LITELLM_CERT_PFX_BASE64 LITELLM_CERT_PFX_PASSWORD LITELLM_ROOT_CA_PEM_BASE64; do
  azd env set "$v" ""
done
azd provision
```

Or set `FORCE_REGENERATE=1` before `azd provision`.

## Deployed Resources

### Networking
- VNet with subnets for PE, ACA, Application Gateway, Foundry agents
- Private DNS zones: ACA, PostgreSQL, Key Vault, Storage, Cosmos DB, AI Search

### Foundry
- Foundry account + 3 projects with capability hosts (Standard mode)
- AI Dependencies (Storage / Cosmos DB / AI Search) with private endpoints

### LiteLLM (cert variant)
- ACA managed environment with a **`Microsoft.App/managedEnvironments/certificates`** resource holding the leaf PFX
- LiteLLM container app:
  - `customDomains: [{ name: <LITELLM_DOMAIN>, bindingType: 'SniEnabled', certificateId: <cert>.id }]` — ACA terminates TLS with the self-signed cert on this hostname
  - Container itself runs HTTP on port 4000 (no `--ssl_*` flags)
- PostgreSQL Flexible Server for LiteLLM persistence
- Key Vault: stores `openaiapikey`, `litelllmasterkey`

### Proxy
- `aca-litellm-proxy-{token}` running `nginx:1.27-alpine`
- Init containers:
  - `ca-installer` — decodes the root CA from an inline Container Apps secret to `/ca-trust/rootCA.crt`
  - `nginx-conf-renderer` — `envsubst` over a template (only `$LITELLM_DOMAIN` is substituted; nginx variables stay literal)
- nginx config: `proxy_ssl_trusted_certificate /ca-trust/rootCA.crt`, `proxy_ssl_verify on`, `proxy_ssl_name <LITELLM_DOMAIN>`, runtime DNS (`resolver 168.63.129.16`), streaming-friendly (`proxy_buffering off`, `proxy_http_version 1.1`).

### Public Access
- Application Gateway with public IP → nginx proxy (the proxy serves LiteLLM Admin UI / Swagger to operators).

## Outputs

| Output | Description |
|---|---|
| `FOUNDRY_PROJECTS_CONNECTION_STRINGS` | Connection strings for the Foundry projects |
| `FOUNDRY_PROJECT_NAMES` | Names of the Foundry projects |
| `LITELLM_DOMAIN` | Custom domain bound to LiteLLM (self-signed cert) |
| `LITELLM_PROXY_FQDN` | nginx proxy FQDN (what Foundry connections target) |
| `LITELLM_INTERNAL_FQDN` | LiteLLM's default `*.azurecontainerapps.io` FQDN (MS-trusted cert; useful for in-VNet smoke tests) |
| `LITELLM_UI_URL` / `LITELLM_SWAGGER_URL` | App Gateway public URL for the admin UI / Swagger |

## Troubleshooting

- **`Failed to validate custom domain`** during deploy → DNS for
  `LITELLM_DOMAIN` is missing or hasn't propagated. See **DNS prerequisite**
  above. Either clear `LITELLM_DOMAIN`, redeploy, and grab the verification
  ID, or wait for DNS to propagate and retry `azd provision`.
- **`x509: certificate signed by unknown authority`** in Foundry agent
  logs → the proxy's init container didn't install the root CA. Check the
  `ca-installer` init container logs on the `aca-litellm-proxy-*` revision.
- **`502 Bad Gateway` from nginx** → LiteLLM's custom domain isn't resolving
  yet from inside the VNet. Verify the custom domain binding completed on
  the LiteLLM container app and check the `nginx-conf-renderer` init
  container's logs for the rendered config.
- **Long requests cut off near 240s** → that's the Azure Container Apps HTTP
  ingress timeout, and it is enforced *before* nginx's 600s `proxy_read_timeout`.
  Streaming responses (SSE) that produce regular chunks generally survive
  longer than 240s of total wall-clock time, but a single idle gap >240s
  will be terminated. There is no Bicep knob to extend this; if you need
  longer requests, consider serving LiteLLM via a non-ACA-ingress path.

## Differences from `ai-gateway-litellm`

- Adds `customDomain` + `certPfxBase64` + `certPfxPassword` + `createFoundryConnections` + `liteLlmMasterKeyOverride` params on `modules/litellm/lite-llm.bicep`
- Adds `customDomains` passthrough on `modules/aca/container-app.bicep`
- New module `modules/litellm/litellm-proxy.bicep` (nginx + 2 init containers)
- Foundry ModelGateway connections targetUrl = proxy FQDN (not LiteLLM FQDN)
- AGW backend points at the proxy (not LiteLLM)
