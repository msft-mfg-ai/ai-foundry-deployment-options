using 'main.bicep'

// Parameters for the main Bicep template
var principalIdValue = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
param principalId = empty(principalIdValue) ? null : principalIdValue
