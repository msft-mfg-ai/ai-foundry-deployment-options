# Hosted agent implementations

This directory contains the canonical source packages for Foundry agents
declared with `kind: hosted`. Deployment manifests remain with their owning
infrastructure samples so each sample can still be provisioned independently.

| Package | Hosted-agent registrations | Owning sample |
|---|---|---|
| `byom-canary` | `byom-canary` | `options-infra/ai-gateway-pe-testing` |
| `copilot-canary` | `copilot-canary` | `options-infra/ai-gateway-pe-testing` |
| `vnet-mcp-agent` | `hosted-agent-no-cap`, `hosted-agent-with-cap` | `options-infra/foundry-byo-vnet-no-dependencies` |
| `toolbox-agent` | `toolbox-oauth-test`, `toolbox-code-interpreter-test` | `hosted-agents/toolbox-agent` |
| `teams-agent` | `teams-hosted-agent` | `options-infra/foundry-teams-hosted` |
| `perf-support-agent/hosted` | `support-agent-hosted-bypass-mock`, `support-agent-hosted-bypass-real`, `support-agent-hosted-mock`, `support-agent-hosted-real` | `options-infra/foundry-perf-testing` |

`perf-support-agent/custom` is the Container Apps comparison implementation,
and `perf-support-agent/shared` is compiled by both the custom and hosted
entrypoints. They are colocated to preserve a narrow Docker build context and
keep the performance variants on the same shared implementation.

Run deployments from the owning sample directory. Because azd rejects service
paths containing `..`, sample-local manifests use a `prepackage` hook that
copies canonical packages into an ignored `.hosted-agent-build` staging
directory. Each staging directory contains a local `.gitignore`; do not edit
generated copies.

`toolbox-agent` is self-contained: its `azure.yaml` is colocated with its
source, so it uses `project: .` and does not need staging.
