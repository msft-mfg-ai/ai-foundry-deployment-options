// nginx reverse proxy that fronts the LiteLLM container app for Foundry.
//
// Foundry cannot validate the self-signed cert that LiteLLM serves on its
// custom domain, so this proxy sits in the middle:
//   Foundry ──https (MS-trusted *.azurecontainerapps.io cert)──▶ nginx
//   nginx   ──https (self-signed cert, validated against the root CA)──▶ LiteLLM
//
// The nginx container is unmodified `nginx:1.27-alpine`; two init containers
// materialise (a) the trusted root CA on a shared volume and (b) the rendered
// nginx config. nginx then proxies all paths to https://<liteLlmDomain> with
// `proxy_ssl_verify on` and explicit SNI.
//
// Streaming responses (SSE) are preserved via `proxy_buffering off` +
// `proxy_http_version 1.1`.

param location string
param resourceToken string
param tags object = {}

param appInsightsConnectionString string

@description('User-assigned managed identity used by the proxy container app (KV access not required — root CA + nginx config are injected as Container Apps secrets / env).')
param identityResourceId string

@description('Resource id of the existing Container Apps managed environment (reuses the one created by lite-llm.bicep).')
param containerAppsEnvironmentResourceId string

@description('Workload profile name on the managed environment.')
param workloadProfileName string

@description('The custom domain LiteLLM serves TLS on (e.g. litellm.contoso.internal). The proxy uses this for both proxy_pass and SNI.')
param liteLlmDomain string

@secure()
@description('Base64-encoded root CA in PEM. The init container decodes this to /ca-trust/rootCA.crt; nginx references it via proxy_ssl_trusted_certificate.')
param liteLlmRootCaPemBase64 string

var identityResourceParts = split(identityResourceId, '/')
var identityResourceName = last(identityResourceParts)
var identityResourceRgName = identityResourceParts[length(identityResourceParts) - 5]
var identityResourceSubId = identityResourceParts[2]

resource userAssignedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2018-11-30' existing = {
  name: identityResourceName
  scope: resourceGroup(identityResourceSubId, identityResourceRgName)
}

// nginx config template — $LITELLM_DOMAIN is substituted by envsubst at init
// time; all `$other` variables are nginx-native and are escaped via a quoted
// envsubst whitelist so nginx keeps seeing them as `$other`.
//
// `set $upstream ...` forces nginx to do DNS resolution at request time
// rather than at startup — required because the Azure DNS server only
// resolves the LiteLLM ACA hostname after the LiteLLM container app is up.
var nginxConfTemplate = '''
server {
    listen 8080;
    server_name _;

    location = /healthz {
        return 200 "ok\n";
        add_header Content-Type text/plain;
    }

    location / {
        # Streaming-friendly defaults (LiteLLM model inference uses SSE).
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;

        proxy_set_header Host                $LITELLM_DOMAIN;
        proxy_set_header X-Real-IP           $remote_addr;
        proxy_set_header X-Forwarded-For     $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto   $scheme;
        proxy_set_header Connection          "";

        # Runtime DNS via Azure-provided resolver. The variable indirection
        # forces nginx to re-resolve on every request rather than at startup.
        resolver 168.63.129.16 valid=30s;
        set $upstream https://$LITELLM_DOMAIN:443;
        proxy_pass $upstream;

        proxy_ssl_trusted_certificate /ca-trust/rootCA.crt;
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 2;
        proxy_ssl_name $LITELLM_DOMAIN;
        proxy_ssl_server_name on;
        proxy_ssl_session_reuse on;
    }
}
'''

module proxyApp '../aca/container-app.bicep' = {
  name: 'app-litellm-proxy'
  params: {
    tags: union(tags, {
      'hidden-title': 'LiteLLM proxy (nginx, trusts self-signed root CA)'
    })
    location: location
    name: 'aca-litellm-proxy-${resourceToken}'
    workloadProfileName: workloadProfileName
    applicationInsightsConnectionString: appInsightsConnectionString
    definition: {
      // Inline Container-Apps secrets (no KV required — the root CA is the
      // public half of a self-signed cert; the nginx config has no secrets).
      // The init containers consume both via secretRef.
      settings: [
        {
          name: 'LITELLM_ROOT_CA_PEM_B64'
          secret: true
          secretValue: liteLlmRootCaPemBase64
        }
        {
          name: 'NGINX_CONF_TEMPLATE'
          secret: true
          secretValue: nginxConfTemplate
        }
      ]
    }
    volumes: [
      {
        name: 'ca-trust'
        storageType: 'EmptyDir'
      }
      {
        name: 'nginx-conf'
        storageType: 'EmptyDir'
      }
    ]
    volumeMounts: [
      {
        volumeName: 'ca-trust'
        mountPath: '/ca-trust'
      }
      {
        volumeName: 'nginx-conf'
        mountPath: '/etc/nginx/conf.d'
      }
    ]
    initContainersTemplate: [
      {
        name: 'ca-installer'
        image: 'alpine:latest'
        resources: {
          cpu: json('0.25')
          memory: '0.25Gi'
        }
        command: ['/bin/sh']
        args: [
          '-c'
          'set -e; printf "%s" "$LITELLM_ROOT_CA_PEM_B64" | base64 -d > /ca-trust/rootCA.crt && chmod 644 /ca-trust/rootCA.crt && echo "Root CA installed:" && openssl x509 -in /ca-trust/rootCA.crt -noout -subject -issuer 2>/dev/null || cat /ca-trust/rootCA.crt | head -5'
        ]
        env: [
          {
            name: 'LITELLM_ROOT_CA_PEM_B64'
            secretRef: 'litellm-root-ca-pem-b64'
          }
        ]
        volumeMounts: [
          {
            volumeName: 'ca-trust'
            mountPath: '/ca-trust'
          }
        ]
      }
      {
        name: 'nginx-conf-renderer'
        image: 'alpine:latest'
        resources: {
          cpu: json('0.25')
          memory: '0.25Gi'
        }
        command: ['/bin/sh']
        args: [
          '-c'
          // envsubst with an explicit whitelist so only $LITELLM_DOMAIN is
          // substituted — nginx variables ($remote_addr, $scheme, $upstream)
          // stay literal.
          'set -e; apk add --no-cache gettext >/dev/null && printf "%s" "$NGINX_CONF_TEMPLATE" > /tmp/default.conf.tmpl && envsubst \'$LITELLM_DOMAIN\' < /tmp/default.conf.tmpl > /etc/nginx/conf.d/default.conf && echo "nginx config rendered:" && cat /etc/nginx/conf.d/default.conf'
        ]
        env: [
          {
            name: 'NGINX_CONF_TEMPLATE'
            secretRef: 'nginx-conf-template'
          }
          {
            name: 'LITELLM_DOMAIN'
            value: liteLlmDomain
          }
        ]
        volumeMounts: [
          {
            volumeName: 'nginx-conf'
            mountPath: '/etc/nginx/conf.d'
          }
        ]
      }
    ]
    ingressTargetPort: 8080
    existingImage: 'nginx:1.27-alpine'
    userAssignedManagedIdentityClientId: userAssignedIdentity.properties.clientId
    userAssignedManagedIdentityResourceId: userAssignedIdentity.id
    // Matches LiteLLM (also external). The hosting ACA environment has
    // publicNetworkAccess: 'Disabled' + a private endpoint, so "external"
    // here exposes the proxy on the env's external FQDN (still reachable
    // only through the PE / VNet, not the public internet).
    ingressExternal: true
    cpu: '0.5'
    memory: '1.0Gi'
    scaleMaxReplicas: 2
    scaleMinReplicas: 1
    containerAppsEnvironmentResourceId: containerAppsEnvironmentResourceId
    keyVaultName: null
    probes: [
      {
        type: 'Readiness'
        initialDelaySeconds: 5
        httpGet: {
          path: '/healthz'
          port: 8080
        }
      }
      {
        type: 'Liveness'
        initialDelaySeconds: 10
        httpGet: {
          path: '/healthz'
          port: 8080
        }
      }
    ]
  }
}

@description('Proxy FQDN, including https:// — pass this as targetUrl to Foundry ModelGateway connections.')
output proxyFqdn string = proxyApp.outputs.CONTAINER_APP_FQDN
output proxyName string = proxyApp.outputs.CONTAINER_APP_NAME
