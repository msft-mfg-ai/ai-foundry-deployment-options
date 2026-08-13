# Diagnostic report interpretation

## Read order

1. `summary.status`
2. `summary.targets_failed`
3. `summary.top_findings`
4. Matching `results[]` entries and their `metrics`/`evidence`

## High-signal finding codes

| Code | Meaning |
|---|---|
| `GAI_FAIL_RAW_OK` | OS `getaddrinfo` fails although wire-level DNS succeeds; investigate resolver behavior rather than the destination route. |
| `GAI_INTERMITTENT` | Application-visible DNS resolution is intermittent. |
| `DNS_OK_PRIVATE_INTERMITTENT` / `DNS_INTERMITTENT` | DNS records exist, but some requests time out. |
| `DNS_UDP_DROP_TCP_OK` | UDP/53 fails while TCP/53 works; investigate EDNS, MTU, fragments, or UDP loss. |
| `DNS_OK_PUBLIC_FOR_PRIVATE` | A Private Link hostname resolved publicly; check zone links and conditional forwarding. |
| `DNS_SERVFAIL` | Resolver or conditional forwarder failed. |
| `DNS_REFUSED` | Resolver ACL/view likely excludes the agent subnet. |
| `DNS_TIMEOUT` | DNS server/path is unreachable or dropping packets. |
| `DNS_NXDOMAIN` / `DNS_NODATA` | Record is absent from the zone served to this runtime. |
| `RESOLVER_DISAGREE` | Different resolvers return different private/public answers. |
| `PARALLEL_DUAL_LOSS` | Parallel A/AAAA requests lose replies despite sequential success. |
| `DNS_INITIAL_INSTABILITY` | DNS fails at sandbox start but recovers quickly. |
| `DNS_PROPAGATION_DELAY` | DNS recovers only after the configured threshold. |
| `DNS_FAILURE_PERSISTED` | DNS remains unavailable for the entire observation window. |
| `LOCAL_UDP_CLEAN` | No local sandbox UDP/NIC drops; loss is upstream. |
| `LOCAL_UDP_DROPS` | Local socket or interface drops occurred. |
| `TCP_FAIL` timeout | Likely NSG, UDR, NVA, firewall, or disconnected route. |
| `TCP_FAIL` refused | Destination or intermediary actively rejected the connection. |
| `TLS_FAIL` verification | Certificate interception or unexpected endpoint. |

If `conn.direct` succeeds for a private IP while the corresponding hostname
fails, classify the failure as DNS. If both fail, classify it as network path
or endpoint availability.

## Expected unauthenticated service responses

These prove network reachability even though they are not HTTP 200:

| Service | Host pattern | Healthy unauthenticated response |
|---|---|---|
| ACR registry | `<acr>.azurecr.io` | `401` on `/v2/` with `WWW-Authenticate` |
| ACR data | `<acr>.<region>.data.azurecr.io` | `403` on `/v2/` |
| Cosmos DB | `<account>.documents.azure.com` | `401` mentioning missing authorization |
| Blob Storage | `<account>.blob.core.windows.net` | `400` for malformed root request |
| AI Search | `<service>.search.windows.net` | `401` with Search resource challenge |
| AI Services | `<account>.cognitiveservices.azure.com` | Usually `200 Service Operational` |
| Azure OpenAI | `<account>.openai.azure.com` | Usually `200 Service Operational` |
| Foundry | `<account>.services.ai.azure.com` | Usually `200` at the service root |
| APIM | `<service>.azure-api.net` | API-specific `200`, `401`, `403`, or `404` after successful TLS |
| Container Apps | `<app>.<environment>.<region>.azurecontainerapps.io` | Application-specific response after successful TLS |

For private endpoints, verify the resolved address is private and the
certificate SAN remains the public service hostname. Private Link changes DNS
and routing, not the hostname used for TLS.

## Evidence standards

Record:

- UTC start/end time;
- project and agent identifiers;
- runtime resolver and `/etc/resolv.conf` details;
- every resolved IP and CNAME chain;
- direct-IP comparison targets;
- TCP/TLS latency and failure type;
- HTTP status and non-secret response metadata;
- stable finding codes;
- raw report path.

Do not attach access tokens, client secrets, authorization headers, or
unreviewed environment dumps to incidents.
