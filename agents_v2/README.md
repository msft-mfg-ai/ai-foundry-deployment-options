# AI Foundry Agents v2 Testing

Testing notebooks for AI Foundry agents and gateway connections.

## Setup

1. Install [uv](https://docs.astral.sh/uv/)
2. Run `uv sync` in this directory
3. In VSCode: `Ctrl+Shift+P` → `Python: Select Interpreter` → select `.venv` from this folder
4. Copy `.env.example` to `.env` and fill in your Azure credentials

## Notebooks

**testing-llm-gateway-agents.ipynb** - Creates and runs agents via AI Foundry. Tests gateway connections (static/dynamic) and MCP tool integration.

**gateway-random-traffic.ipynb** - Generates random traffic across multiple Foundry projects and model deployments for load testing.

## News editor prompt agent

`create_news_editor_agent.py` creates:

- Versioned weather, sports, and AI reporting skills from `skills/*/SKILL.md`
- A toolbox containing web search, Code Interpreter, tool search, and the three skills
- A `news-editor` prompt agent connected to the toolbox's default-version MCP endpoint

Toolbox skills are exposed as MCP resources. Foundry prompt agents can call tools
from a toolbox, but their tool search does not currently load those skill
resources. This sample intentionally keeps the skills only in the toolbox and
instructs the prompt agent to load one before answering. It is a negative
capability test for prompt-agent support of toolbox skills; there is no embedded
prompt fallback.

Each run promotes the newly created toolbox version to `default_version`. The
agent uses the unversioned consumer endpoint, so future default-version changes
take effect without creating another agent version.

Set `FOUNDRY_PROJECT_ENDPOINT` and `FOUNDRY_MODEL_NAME` in `.env`, then run:

```bash
uv run python create_news_editor_agent.py
```

The toolbox and Skills APIs are preview features. The identity running the script and the prompt agent identity need the Foundry User role on the project.

The script grants the project's system-assigned managed identity the Foundry
User role on the Foundry account, creates or updates a
`ProjectManagedIdentity` connection through the Foundry ARM API, and references
it from the MCP tool. Agent Service acquires and refreshes the
`https://ai.azure.com` token at runtime. No developer access token is persisted
in the agent definition.