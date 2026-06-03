using 'main.bicep'

// Parameters for the main Bicep template
param openAiApiBase = readEnvironmentVariable('OPENAI_API_BASE', '')
param openAiApiKey = readEnvironmentVariable('OPENAI_API_KEY', '')
param openAiResourceId = readEnvironmentVariable('OPENAI_RESOURCE_ID', '')

// LiteLLM custom domain + self-signed cert — populated by the `preprovision`
// hook in azure.yaml (scripts/preprovision-litellm-cert.sh|.ps1).
param liteLlmDomain = readEnvironmentVariable('LITELLM_DOMAIN', '')
param liteLlmCertPfxBase64 = readEnvironmentVariable('LITELLM_CERT_PFX_BASE64', '')
param liteLlmCertPfxPassword = readEnvironmentVariable('LITELLM_CERT_PFX_PASSWORD', '')
param liteLlmRootCaPemBase64 = readEnvironmentVariable('LITELLM_ROOT_CA_PEM_BASE64', '')
