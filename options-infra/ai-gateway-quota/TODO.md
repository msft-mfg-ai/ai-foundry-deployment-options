# TODO — Remaining Work & Known Issues

## Known Issues

- [ ] **`x-quota-remaining-tokens` bounces on APIM StandardV2** — The quota remaining header value fluctuates because it is an estimate, not an exact count. This is platform behavior on APIM StandardV2.
- [ ] **Combined PTU + PAYG quota counter** — For P1 with partial PTU, the monthly quota counts total tokens across both backends. Since PTU tokens are pre-paid, the quota limit acts as a cap on total consumption rather than a precise PAYG cost measure. An alternative approach (returning retries to clients with backend header selection) would allow separate per-LLM quotas.
- [ ] **Event Hub logging not yet implemented in TF** — The Terraform deployment does not include Event Hub logging. The `{eventhub-logger-id}` placeholder is left empty.

## Future Work

- [ ] **Add Event Hub logging to TF deployment** — Wire up Event Hub logger in the Terraform deployment to match Bicep parity.
- [ ] **Add Application Insights integration** — Integrate Application Insights for request tracing and performance monitoring.
- [ ] **Implement token estimation comparison** — Compare behavior with `estimate-prompt-tokens=true` vs `false` to quantify accuracy trade-offs.
- [ ] **Add automated integration tests** — Go beyond the test notebook with automated integration tests that can run in CI/CD.
- [ ] **Multi-region deployment support** — Extend Terraform and Bicep to support deploying across multiple Azure regions.
- [ ] **APIM policy unit tests** — Add unit tests for the XML policy files to catch regressions in routing and quota logic.
- [ ] **Dashboard/workbook for monitoring PTU utilization** — Create an Azure Monitor workbook or dashboard to visualize PTU utilization, spillover rates, and quota consumption.
