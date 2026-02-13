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