using 'main-option-11-part1.bicep'

// From AI Foundry Subscription
param existingAiResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai-foundry/providers/Microsoft.CognitiveServices/accounts/ai-foundry-models-ckop2nnk2do3i'
param existingAiResourceKind = 'AIServices'
param existingFoundryAgentSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai-foundry/providers/Microsoft.Network/virtualNetworks/foundry-vnet-ckop2nnk2do3i/subnets/agent-subnet'
param existingApplicationInsightsName = 'app-insights'

// From App Subscription
param existingCosmosDBId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai-apps/providers/Microsoft.DocumentDB/databaseAccounts/project-cosmosdb-ckop2nnk2do3i'
param existingStorageId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai-apps/providers/Microsoft.Storage/storageAccounts/projstorageckop2nnk2do3i'
param existingFoundryAISearchId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai-apps/providers/Microsoft.Search/searchServices/project-search-ckop2nnk2do3i'

