---
name: foundry-network-diagnostics
description: Deploy and use Microsoft's hosted Foundry diagnostic agent inside an existing Foundry project's runtime sandbox to test DNS, TCP, TLS, HTTP, public egress, private endpoints, and direct IP reachability. Use when the user asks for "foundry-network-diagnostics", "deploy the diagnostic agent", "test networking from inside Foundry", "probe a private endpoint from the agent subnet", "check Foundry DNS from the hosted runtime", or needs runtime evidence that control-plane VNet/NSG inspection cannot provide.
---

# Foundry Network Diagnostics

Deploy and invoke Microsoft's upstream diagnostic hosted-agent sample:

`microsoft-foundry/foundry-samples/samples/python/hosted-agents/bring-your-own/invocations/diagnostic-agent`

The agent runs without an LLM or model deployment. It reports what the hosted
runtime can resolve and reach from inside Foundry.

## Workflow

1. Resolve the target Foundry project.
2. Inspect control-plane networking before deployment.
3. Deploy the upstream diagnostic agent in ZIP/Python mode.
4. Invoke targeted probes from the hosted runtime.
5. Interpret the structured report.
6. Preserve evidence and remove the agent when diagnostics are complete.

## Resolve the project

Use the first available full project ARM ID:

1. `FOUNDRY_PROJECT_ARM_ID`
2. `FOUNDRY_PROJECT_RESOURCE_ID`
3. `AZURE_AI_PROJECT_RESOURCE_ID`
4. `AZURE_AI_PROJECT_ID`
5. An active option's azd outputs (`AZURE_SUBSCRIPTION_ID`,
   `AZURE_RESOURCE_GROUP`, `FOUNDRY_NAME`, first value in
   `FOUNDRY_PROJECT_NAMES`)

Derive the endpoint as:

```text
https://<account>.services.ai.azure.com/api/projects/<project>
```

If the ARM ID still cannot be resolved, ask for it. Never guess the resource
group, account, project, subscription, or tenant.

Confirm `az account show` uses the project's subscription and tenant.

## Check the control plane

Before deploying, verify:

- account and project capability hosts are `Succeeded`;
- the account capability host has the expected `customerSubnet`;
- private DNS zones are linked to the VNet containing that subnet;
- the caller can read the project and deploy hosted agents.

Use `foundry-agent-vnet-integration-diagnostics` for subnet/NSG inspection and
`foundry-agent-vnet-capability-host-diagnostics` for capability-host checks
when available. These inspect configuration; the hosted agent tests the actual
runtime path.

## Deploy

Run:

```bash
bash .github/skills/foundry-network-diagnostics/scripts/deploy.sh \
  --project-id "$FOUNDRY_PROJECT_ARM_ID"
```

The script:

- sparse-clones or updates the official sample in a user cache;
- uses the upstream ZIP/Python hosted-agent configuration;
- configures a dedicated azd environment;
- runs `AZD_DISABLE_AGENT_DETECT=1 azd deploy --no-prompt`;
- prints the project endpoint and invocations URL.

Do not run `azd up`; this sample deploys into existing infrastructure.

If the upstream sample changes back to Docker/container mode, stop before
deploying and either switch it to Python ZIP mode or explicitly obtain an ACR
endpoint. Prefer ZIP mode for network diagnosis so ACR connectivity is not a
prerequisite for the diagnostic itself.

## Invoke

Probe one or more hostnames:

```bash
bash .github/skills/foundry-network-diagnostics/scripts/invoke.sh \
  --project-endpoint "https://<account>.services.ai.azure.com/api/projects/<project>" \
  --host "<apim>.azure-api.net" \
  --host "<keycloak>.<environment>.<region>.azurecontainerapps.io"
```

Add direct IP targets to separate DNS failure from route failure:

```bash
... --direct-target "10.0.1.10:443" --direct-target "10.0.1.9:443"
```

For intermittent DNS or startup propagation:

```bash
... --dns-attempts 20 --gai-attempts 20 --parallel \
  --dns-propagation-seconds 30
```

Use `--payload-file` for the full upstream request contract. The script writes
the complete JSON report to `diagnostic-results/` unless `--output` is given.

## Interpret

Read `summary.status`, `summary.targets_failed`, and
`summary.top_findings` first. Then inspect the matching entries in `results[]`.

Use [references/interpretation.md](references/interpretation.md) for stable
finding codes and expected private-service fingerprints.

Always distinguish:

- **DNS failure**: hostname fails but `direct_targets` succeeds.
- **Routing/firewall failure**: DNS resolves but TCP times out.
- **Endpoint rejection**: TCP/TLS succeeds and HTTP returns a service-specific
  401/403/400.
- **TLS interception**: certificate issuer/SAN differs from the Azure service.
- **Startup propagation**: initial DNS failures recover during the timed probe.

Do not treat HTTP 401/403 as network failure when it is the expected
unauthenticated service response.

## Report

Return:

1. Project/account and UTC invocation interval.
2. Hosted agent name and invocations URL.
3. Targets and direct IPs tested.
4. Runtime container IP, gateway, resolver, and search-domain details.
5. Per-target DNS, TCP, TLS, and HTTP results.
6. Top finding codes with evidence.
7. Failure boundary and confidence.
8. Least-disruptive remediation.
9. Path to the saved raw JSON report.

Keep credentials and token values out of reports. The diagnostic response
redacts credential-shaped environment values, but review evidence before
attaching it to an incident.

## Cleanup

Hosted diagnostics should be temporary. After evidence collection, remove the
agent through the Foundry portal or from the cached sample directory:

```bash
AZD_DISABLE_AGENT_DETECT=1 azd ai agent delete \
  diagnostic-agent-python-invocations --force --no-prompt
```

Confirm the agent no longer appears in the project.

Do not delete the Foundry project, capability hosts, networking resources, or
the cached upstream source as part of routine cleanup.
