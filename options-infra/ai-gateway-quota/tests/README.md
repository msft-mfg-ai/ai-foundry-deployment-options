# ai-gateway-quota pytest suite

Live integration tests for the unified AI Gateway suite. They exercise chat, streaming, TTS, Whisper, discovery, contract/quota headers, config endpoints, OpenAI-compatible surfaces, and retry/failover behavior against a deployed `ai-gateway-quota` APIM instance.

## Run

```bash
cd options-infra/ai-gateway-quota/tests
uv sync
cp .env.example .env  # then fill in
uv run pytest -v
```

The tests call real Azure resources and are not run in CI by default.
