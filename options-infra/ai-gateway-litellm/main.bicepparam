using 'main.bicep'

// Parameters for the main Bicep template
param openAiApiBase = readEnvironmentVariable('OPENAI_API_BASE', '')
param openAiApiKey = readEnvironmentVariable('OPENAI_API_KEY', '')
param openAiResourceId = readEnvironmentVariable('OPENAI_RESOURCE_ID', '')
