# Option: AI Gateway private endpoint testing infrastructure

Ephemeral CI infrastructure for the `msft-mfg-ai/foundry-byom-feature-support` BYOM feature-support matrix.

This variant deploys the same private-networked Foundry + APIM Standard v2 private-endpoint topology as [`ai-gateway-pe-custom`](../ai-gateway-pe-custom/), but removes the landing-zone MCP/OpenAPI API hardcodes and uses deterministic naming from `AZURE_ENV_NAME` so BYOM CI environment variables stay stable across `azd up` cycles.

## What deploys

- Private-networked AI Foundry account and one Foundry project by default.
- APIM Standard v2 with VNet injection and a private endpoint.
- Private endpoints from APIM to the OpenAI/Foundry instances listed in `FOUNDRY_INSTANCES_JSON`.
- Per-model APIM routing for the discovered deployments.
- Two Foundry project APIM connections:
  - static model metadata (`metadata.models`) for `AI_GATEWAY_CONNECTION_STATIC`
  - dynamic model discovery (`modelDiscovery`) for `AI_GATEWAY_CONNECTION_DYNAMIC`

No MCP/OpenAPI landing-zone APIs are deployed unless `apiServices` is explicitly supplied.

## Required environment

- `AZURE_ENV_NAME` - fixed deterministic token used in names. Defaults to `byomtest`.
- `FOUNDRY_INSTANCES_JSON` - populated by the `preprovision-list-foundry-models` hook from existing OpenAI/Foundry model deployments.

The backing instance list must include at least one non-APIM OpenAI/Foundry instance. For the BYOM matrix, include a deployment named `gpt-4o-mini` at minimum. Optional useful deployments include `gpt-4o`, `dall-e-2`, `gpt-image-1`, and `o3-mini`; do not add sora, realtime, or embeddings just for this matrix.

## Connection names

With the default `projectsCount = 1`, project names are generated as:

```text
ai-project-${resourceToken}-1
```

`connections-apim-gateway.bicep` then creates these OpenAI project connections:

```text
AI_GATEWAY_CONNECTION_STATIC  = apim-${resourceToken}-openai-s-for-ai-project-${resourceToken}-1
AI_GATEWAY_CONNECTION_DYNAMIC = apim-${resourceToken}-openai-d-for-ai-project-${resourceToken}-1
```

For the default/fixed token `AZURE_ENV_NAME=byomtest`, set the BYOM GitHub Environment variables to:

```text
AI_GATEWAY_CONNECTION_STATIC=apim-byomtest-openai-s-for-ai-project-byomtest-1
AI_GATEWAY_CONNECTION_DYNAMIC=apim-byomtest-openai-d-for-ai-project-byomtest-1
```

## CI-consumed outputs

| Output | Description |
|--------|-------------|
| `PROJECT_ENDPOINT` | `https://<foundry>.services.ai.azure.com/api/projects/<project>` |
| `AI_GATEWAY_CONNECTION_STATIC` | Static APIM connection name for BYOM tests |
| `AI_GATEWAY_CONNECTION_DYNAMIC` | Dynamic APIM connection name for BYOM tests |
| `RESOURCE_GROUP` | Resource group name, for teardown |
| `FOUNDRY_NAME` | Foundry account name, for purge |
| `project_connection_strings` | Existing project endpoint list |
| `project_names` | Existing project name list |
| `config_validation_result` | Fails deployment when `FOUNDRY_INSTANCES_JSON` is empty |

## Deployment

```bash
cd options-infra/ai-gateway-pe-testing
azd up
```
