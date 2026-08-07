---
name: network-injection-diagnostics
description: Diagnose Foundry VNet connectivity, capability hosts, and private MCP access from inside this hosted agent.
---

# Network injection diagnostics

Use this skill when the user asks about VNet injection, capability hosts,
Azure DNS, DNS resolution, private networking, MCP discovery, or connectivity
from this hosted agent to Microsoft Foundry.

## Procedure

1. Always call `validate_network_injection`; do not infer connectivity from the
   fact that the agent answered.
2. Report each check separately:
   - System DNS resolution of the Foundry project hostname returns PRIVATE IP addresses.
   - Direct DNS response from Azure's platform resolver at `168.63.129.16`.
   - HTTPS/TLS reachability to the exact `FOUNDRY_PROJECT_ENDPOINT`.
   - Account-level and project-level capability hosts returned by Azure Resource Manager.
   - If configured, MCP hostname resolution, private IP addresses, and `tools/list`.
3. Include resolved Foundry and MCP addresses and state whether any are private.
4. For each capability host, report its name, provisioning state, customer
   subnet, and configured storage/search connection arrays when present.
5. Treat any HTTP status as proof that DNS, TCP, and TLS reached Foundry. The
   request is intentionally unauthenticated, so a 401, 403, or 404 is not a
   network failure.
6. If an ARM check returns 403, state that the hosted agent's per-agent
   instance identity needs Reader on the Foundry resource group.
7. If all checks pass, say the hosted runtime network path is operational.
8. If a check fails, identify the failed layer and return its error without
   claiming that another layer caused it.

## Interpretation limits

This tool validates connectivity from inside the hosted agent and reads
capability-host resources through ARM. It does not inspect subnet delegation,
NSGs, route tables, or all properties of the Foundry account's network
configuration. Describe a passing result as runtime and capability-host
evidence, not as proof that the complete control-plane configuration is correct.
