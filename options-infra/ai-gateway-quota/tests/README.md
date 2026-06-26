# ai-gateway pytest suite

Live integration tests for the unified AI Gateway. Run against any deployed `ai-gateway-*` APIM instance — the suite **auto-adapts** to the gateway it points at:

- **Mode detection** — probes `/ai-gateway/config.json`. If 200 the gateway is in *quota mode* (contracts wired); if 404 it's in *open mode*. Tests marked `@pytest.mark.quota` (config endpoints, contract assertions, quota headers) are auto-skipped in open mode.
- **Model availability** — calls `/inference/deployments` once per session. The `model`/`failover_model` fixtures skip when the configured `TEST_MODEL` isn't present. `anthropic_model`/`embedding_model` fixtures additionally probe for an APIM backend pool (skip on 404).
- **SKU gating** — `test_openai_v1_surface` is skipped on SKUs that can't host the 100+ operation OpenAI v1 spec (only StandardV2/Premium qualify); set `APIM_SKU=BasicV2` (or similar) to skip cleanly.

## Run

```bash
cd options-infra/ai-gateway-quota/tests
uv sync
cp .env.example .env  # then fill in
uv run pytest -v
```

Run only the generic suite (skip quota-only tests):

```bash
uv run pytest -m "not quota"
```

The tests call real Azure resources and are not run in CI by default.
