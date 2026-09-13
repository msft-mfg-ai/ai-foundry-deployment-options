# Option: LiteLLM Gateway with Foundry Private CA Trust

This deployment option demonstrates Foundry's private CA trust support. LiteLLM is exposed on an Azure Container Apps custom domain with a self-signed certificate, while the Foundry account trusts the issuing root CA through a versioned Key Vault secret.

Foundry connects directly to the LiteLLM custom domain. No nginx trust proxy is deployed.

> This feature requires an allowlisted subscription and the preview APIs described in `spec.tmp`. The reference scenario uses `canadacentral`.

## Architecture

```text
Foundry account
  - user-assigned managed identity
  - trustedCertificates -> Key Vault secret version
  - account-level LiteLLM ModelGateway connections
  - projects + capability hosts
               |
               | HTTPS, private CA validated by Foundry
               v
LiteLLM custom domain
  - private DNS -> ACA managed-environment private endpoint
  - ACA ingress terminates TLS with the self-signed leaf PFX
  - LiteLLM container remains HTTP-only on port 4000

Key Vault
  - public root CA PEM secret
  - Foundry identity: Key Vault Secrets User
```

Application Gateway continues to target LiteLLM's default `*.azurecontainerapps.io` hostname. That backend uses a Microsoft-trusted certificate and does not depend on Foundry's private CA configuration.

## Prerequisites

- Azure CLI and Azure Developer CLI (`azd`)
- `openssl` on `PATH`
- An allowlisted Azure subscription
- Deployment in a region that supports the preview feature (`canadacentral` in the supplied specification)
- Permission to create Foundry, Key Vault, networking, role-assignment, and Container Apps resources
- Control of public DNS for the LiteLLM custom domain

Configure the existing Azure OpenAI dependency:

```bash
azd env set OPENAI_API_BASE "https://<your-aoai>.openai.azure.com"
azd env set OPENAI_RESOURCE_ID "/subscriptions/.../resourceGroups/.../providers/Microsoft.CognitiveServices/accounts/<aoai>"
```

LiteLLM uses its Container App user-assigned managed identity for Azure OpenAI. The deployment grants that identity `Cognitive Services OpenAI User`; local authentication and API keys are not required.

## Deployment flow

ACA validates ownership before accepting a custom-domain binding. For a new ACA environment, its default hostname or custom-domain verification ID is not available until the environment exists, so bootstrap uses two `azd provision` runs.

### Phase 1: create LiteLLM infrastructure

```bash
azd env set LITELLM_DOMAIN ""
AZD_DISABLE_AGENT_DETECT=1 azd provision
```

Phase 1 creates networking, dependencies, the Foundry Key Vault, LiteLLM, its ACA environment, private endpoints, and Application Gateway. It does not create the Foundry account, projects, capability hosts, or ModelGateway connections. Foundry, networking, Storage, and AI Search remain in Canada Central; Cosmos DB is placed in East US 2 because this subscription currently has no Cosmos DB creation capacity in Canada Central.

Use the deployed ACA hostname or environment custom-domain verification ID to configure one of these public DNS records:

- `CNAME <LITELLM_DOMAIN> -> <LiteLLM default ACA hostname>`
- `TXT asuid.<LITELLM_DOMAIN> -> <ACA environment custom-domain verification ID>`

### Phase 2: bind the domain and create Foundry

```bash
azd env set LITELLM_DOMAIN "litellm.your-domain.example.com"
AZD_DISABLE_AGENT_DETECT=1 azd provision
```

The preprovision hook generates:

- a self-signed root CA;
- a leaf certificate for `LITELLM_DOMAIN`;
- a PFX containing the leaf key and certificate chain;
- the public root CA PEM.

The deployment then:

1. Binds the PFX to the LiteLLM ACA custom domain.
2. Stores only the public root CA PEM as the `litellm-root-ca-pem` Key Vault secret.
3. Grants the Foundry user-assigned identity `Key Vault Secrets User`.
4. Creates the Foundry account with `trustedCertificates` pinned to the deployed secret version.
5. Creates projects and capability hosts after the trust configuration and RBAC assignment.
6. Creates dynamic and static ModelGateway connections targeting `https://<LITELLM_DOMAIN>`.

If the required public DNS record is already configured for the ACA environment, phase 2 can be the only deployment run.

## Certificate lifecycle

Certificate material is reused while all three azd environment values are present:

- `LITELLM_CERT_PFX_BASE64`
- `LITELLM_CERT_PFX_PASSWORD`
- `LITELLM_ROOT_CA_PEM_BASE64`

To rotate the certificate:

```bash
for value in LITELLM_CERT_PFX_BASE64 LITELLM_CERT_PFX_PASSWORD LITELLM_ROOT_CA_PEM_BASE64; do
  azd env set "$value" ""
done

FORCE_REGENERATE=1 AZD_DISABLE_AGENT_DETECT=1 azd provision
```

The deployment writes a new Key Vault secret version and updates the Foundry account reference. Per the preview feature contract, existing project capability hosts must then be deleted and recreated so they load the rotated CA.

## Deployed resources

### Networking and dependencies

- VNet and delegated subnets for Foundry agents, ACA, private endpoints, and Application Gateway
- Private DNS zones for ACA, PostgreSQL, Key Vault, Storage, Cosmos DB, and AI Search
- Foundry Storage, Cosmos DB, and AI Search dependencies

### LiteLLM

- Private ACA managed environment and private endpoint
- LiteLLM Container App
- PostgreSQL Flexible Server
- LiteLLM Key Vault for application secrets
- Self-signed certificate bound to the LiteLLM custom domain

### Foundry Key Vault

- Private endpoint and private DNS
- `litellm-root-ca-pem` secret containing the public root CA in PEM format
- `Key Vault Secrets User` role assignment for the Foundry account identity

### Foundry

- Foundry account configured with the Key Vault secret in `trustedCertificates`
- Two projects with capability hosts
- Dynamic and static account-level ModelGateway connections targeting the LiteLLM custom domain

### Public operator access

- Application Gateway with a public IP
- Backend target set to LiteLLM's default ACA hostname

## Outputs

| Output | Description |
|---|---|
| `FOUNDRY_PROJECTS_CONNECTION_STRINGS` | Project connection strings; empty in phase 1 |
| `FOUNDRY_PROJECT_NAMES` | Project names; empty in phase 1 |
| `LITELLM_DOMAIN` | Custom domain bound to LiteLLM |
| `LITELLM_FOUNDRY_TARGET_URL` | Direct HTTPS URL used by Foundry; empty in phase 1 |
| `LITELLM_INTERNAL_FQDN` | Default Microsoft-trusted ACA hostname |
| `LITELLM_UI_URL` | Application Gateway URL for the LiteLLM UI |
| `LITELLM_SWAGGER_URL` | Application Gateway URL for LiteLLM APIs |
| `PHASE` | Current bootstrap or trusted-Foundry phase |

## Troubleshooting

- **Custom-domain validation fails:** confirm the public CNAME or `asuid` TXT record has propagated, then rerun phase 2.
- **Foundry receives an unknown-authority error:** verify `properties.trustedCertificates` contains the expected vault ID, secret name, and version; verify the Foundry identity has `Key Vault Secrets User`; recreate existing capability hosts after any trust change.
- **The custom domain does not resolve from Foundry:** verify the private DNS zone for `LITELLM_DOMAIN` is linked to the Foundry VNet and its apex A record points to the ACA managed-environment private endpoint IP.
- **Application Gateway returns a backend TLS error:** confirm its backend is the default LiteLLM ACA hostname, not the self-signed custom domain.
- **Phase 1 has no Foundry projects:** this is expected; set `LITELLM_DOMAIN`, complete public DNS validation, and run phase 2.
