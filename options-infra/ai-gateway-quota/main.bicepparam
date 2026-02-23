using 'main.bicep'

// Azure OpenAI backend configuration
param openAiApiBase = readEnvironmentVariable('OPENAI_API_BASE', '')
param openAiResourceId = readEnvironmentVariable('OPENAI_RESOURCE_ID', '')

var openAiLocationValue = readEnvironmentVariable('OPENAI_LOCATION', '')
param openAiLocation = empty(openAiLocationValue) ? null : openAiLocationValue
