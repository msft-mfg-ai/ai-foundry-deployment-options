---
name: network-injection-diagnostics
description: Diagnose whether this hosted agent can resolve and reach its own Microsoft Foundry project through Azure networking and DNS.
---

# Network injection diagnostics

Use this skill when the user asks about VNet injection, Azure DNS, DNS
resolution, private networking, or connectivity from this hosted agent to
Microsoft Foundry.

## Procedure

1. Always call `validate_network_injection`; do not infer connectivity from the
   fact that the agent answered.
2. Report each check separately:
   - System DNS resolution of the Foundry project hostname returns PRIVATE IP addresses.
   - Direct DNS response from Azure's platform resolver at `168.63.129.16`.
   - HTTPS/TLS reachability to the exact `FOUNDRY_PROJECT_ENDPOINT`.
3. Include resolved addresses and state whether any are private.
4. Treat any HTTP status as proof that DNS, TCP, and TLS reached Foundry. The
   request is intentionally unauthenticated, so a 401, 403, or 404 is not a
   network failure.
5. If all checks pass, say the hosted runtime network path is operational.
6. If a check fails, identify the failed layer and return its error without
   claiming that another layer caused it.

## Interpretation limits

This tool validates connectivity from inside the hosted agent. It does not read
the Foundry account's ARM `networkInjections` property, subnet delegation, NSG,
or route table. Describe a passing result as runtime evidence that injection is
working, not as proof that the complete Azure control-plane configuration is
correct.
