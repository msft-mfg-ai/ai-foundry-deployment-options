using 'main.bicep'

// Parameters for the main Bicep template
param openAiApiBase = readEnvironmentVariable('OPENAI_API_BASE', '')
param openAiResourceId = readEnvironmentVariable('OPENAI_RESOURCE_ID', '')

var projectsCountValue = readEnvironmentVariable('PROJECTS_COUNT', '')
param projectsCount = empty(projectsCountValue) ? null : int(projectsCountValue)

// LiteLLM custom domain + self-signed cert — populated by the `preprovision`
// hook. The root CA PEM is stored in Key Vault and registered with Foundry.
param liteLlmDomain = readEnvironmentVariable('LITELLM_DOMAIN', '')
param liteLlmCertPfxBase64 = readEnvironmentVariable('LITELLM_CERT_PFX_BASE64', '')
param liteLlmCertPfxPassword = readEnvironmentVariable('LITELLM_CERT_PFX_PASSWORD', '')
param liteLlmRootCaPemBase64 = readEnvironmentVariable('LITELLM_ROOT_CA_PEM_BASE64', '')

// Optional second private CA + leaf certificate for the sample MCP ACA.
// Each public root is stored in its own Key Vault secret and trustedCertificates
// entry. The hook also emits a combined bundle for inspection/export only.
param mcpDomain = readEnvironmentVariable('MCP_DOMAIN', '')
param mcpCertPfxBase64 = readEnvironmentVariable('MCP_CERT_PFX_BASE64', '')
param mcpCertPfxPassword = readEnvironmentVariable('MCP_CERT_PFX_PASSWORD', '')
param mcpRootCaPemBase64 = readEnvironmentVariable('MCP_ROOT_CA_PEM_BASE64', '')
