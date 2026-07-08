using 'main.bicep'

// Existing APIM in foundry-sbd environment
param apimResourceId = '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/rg-foundry-sbd/providers/Microsoft.ApiManagement/service/apim-26xvo6gnq5edo'
param apimApiName = 'inference-api'
param apimAuthType = 'ProjectManagedIdentity'

// Agent subnet (delegated to Microsoft.App/environments)
param agentSubnetResourceId = '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/rg-foundry-sbd/providers/Microsoft.Network/virtualNetworks/project-vnet-26xvo6gnq5edo/subnets/agent-subnet-1'

// Existing dependent resources from foundry-sbd deployment
param existingAppInsightsResourceId = '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/rg-foundry-sbd/providers/Microsoft.Insights/components/app-insights'
param existingCosmosDBResourceId = '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/rg-foundry-sbd/providers/Microsoft.DocumentDB/databaseAccounts/project-cosmosdb-26xvo6gnq5edo'
param existingStorageAccountResourceId = '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/rg-foundry-sbd/providers/Microsoft.Storage/storageAccounts/projstorage26xvo6gnq5edo'
param existingAiSearchResourceId = '/subscriptions/0721e282-2773-4021-af16-e00641ed5e36/resourceGroups/rg-foundry-sbd/providers/Microsoft.Search/searchServices/project-search-26xvo6gnq5edo'

// Static models available through APIM are discovered from existing Foundry
// accounts by the preprovision hook.
param staticModels = []
param foundryInstances = json(readEnvironmentVariable('FOUNDRY_INSTANCES_JSON', '[]'))
