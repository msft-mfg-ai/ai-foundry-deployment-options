using 'main-option-2.bicep'

// Parameters for the main Bicep template
param location = 'westus'
// Option 2 doesn't use VNETs or private endpoints, so AI services have to be public
param existingAiResourceId = 'TBD'

