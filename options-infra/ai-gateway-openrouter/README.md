# Option: Foundry Public with OpenRouter Integration

This deployment creates a **public Foundry** environment (without agent subnet) that connects to **OpenRouter** as an external model gateway. The goal is to allow **Foundry projects** to use models from OpenRouter, enabling access to a wide variety of AI models through a single API endpoint.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              This Deployment                                    │
│                                                                                 │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │                         AI Foundry (Public)                                │ │
│  │                                                                            │ │
│  │  ┌──────────────────────────────────────────────────────────────────────┐  │ │
│  │  │  Project(s) - NO Capability Hosts / NO Agent Subnet                  │  │ │
│  │  │                                                                      │  │ │
│  │  │  Model Gateway Connection ───────────────────────────────────────────┼──┼─┼──┐
│  │  │  (Static models: gpt-4o-mini, gpt-4.1-mini, qwen3-4b)                │  │ │  │
│  │  └──────────────────────────────────────────────────────────────────────┘  │ │  │
│  └────────────────────────────────────────────────────────────────────────────┘ │  │
│                                                                                 │  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │  │
│  │                      Supporting Services                                   │ │  │
│  │  Key Vault │ Log Analytics │ App Insights                                  │ │  │
│  └────────────────────────────────────────────────────────────────────────────┘ │  │
│                                                                                 │  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │  │
│  │                      Azure Policy                                          │ │  │
│  │  Blocks all Cognitive Services model deployments (empty allowlist)         │ │  │
│  └────────────────────────────────────────────────────────────────────────────┘ │  │
└─────────────────────────────────────────────────────────────────────────────────┘  │
                                                                                     │
                                         (Public Internet)                           │
                                                                                     ▼
                                    ┌────────────────────────────────────────────────────┐
                                    │              OpenRouter API                        │
                                    │              https://openrouter.ai/api/v1          │
                                    │                                                    │
                                    │    Available Models (via aliases):                 │
                                    │    - gpt-4o-mini    → openai/gpt-4o-mini           │
                                    │    - gpt-4.1-mini   → moonshotai/kimi-k2:free      │
                                    │    - qwen3-4b       → qwen/qwen3-4b:free           │
                                    └────────────────────────────────────────────────────┘
```

## Key Characteristics

| Feature | Value |
|---------|-------|
| **Foundry Mode** | Public (no VNet integration) |
| **Agent Subnet** | None |
| **Capability Hosts** | Not deployed |
| **Model Source** | OpenRouter (external) |
| **Authentication** | API Key |
| **Network** | Public internet |

## Deployed Resources

### Foundry
- **Foundry account** (public network access enabled)
- **Foundry project(s)** without Capability Hosts
- **Model Gateway Connection** (static) to OpenRouter

### Supporting Services
- **Key Vault** for secrets storage
- **Log Analytics Workspace**
- **Application Insights** for telemetry
- **Managed Identities** for Foundry and Projects

### Azure Policy
- **Custom Policy Definition** to block Cognitive Services model deployments
- **Policy Assignment** with empty allowlist (blocks all direct model deployments)

## Prerequisites

Set the following environment variable before deployment:

```bash
export OPENROUTER_API_KEY="your-openrouter-api-key"
```

Get your API key from [OpenRouter](https://openrouter.ai/keys).

### Optional Parameters
| Parameter | Description | Default |
|-----------|-------------|---------|
| `EXISTING_FOUNDRY_NAME` | Use an existing Foundry account | Create new |
| `PROJECTS_COUNT` | Number of Foundry projects to create | 1 |

## Deployment

```bash
cd options-infra/option_ai-gateway-openrouter
azd up
```

## Outputs

| Output | Description |
|--------|-------------|
| `FOUNDRY_PROJECTS_CONNECTION_STRINGS` | Connection strings for Foundry projects |
| `FOUNDRY_PROJECT_NAMES` | Names of the deployed Foundry projects |
| `FOUNDRY_NAME` | Name of the Foundry account |
| `CONFIG_VALIDATION_RESULT` | Validation status of the configuration |

## Model Aliases

The deployment creates static model definitions that map friendly aliases to OpenRouter model IDs:

| Alias | OpenRouter Model |
|-------|------------------|
| `gpt-4o-mini` | `openai/gpt-4o-mini` |
| `gpt-4.1-mini` | `moonshotai/kimi-k2:free` |
| `qwen3-4b` | `qwen/qwen3-4b:free` |

## Comparison with Other Options

| Feature | `openrouter` | `ai-gateway` | `ai-gateway-internal` |
|---------|--------------|--------------|----------------------|
| Foundry Mode | Public | With VNet | With VNet |
| Agent Subnet | ❌ None | ✅ Yes | ✅ Yes |
| Capability Hosts | ❌ No | ✅ Yes | ✅ Yes |
| Model Source | OpenRouter | Azure OpenAI | Azure OpenAI |
| APIM Gateway | ❌ No | ✅ External | ✅ Internal |
| Private Endpoints | ❌ No | ✅ Yes | ✅ Yes |
| Use Case | Dev/Testing | Dev/Production | Enterprise |

## Use Cases

- **Development/Testing**: Quick setup without Azure OpenAI provisioning
- **Cost Optimization**: Access to free-tier models via OpenRouter
- **Model Variety**: Access to models from multiple providers
- **Simple Architecture**: No networking complexity
- **Policy Enforcement**: Block direct Cognitive Services deployments via Azure Policy
