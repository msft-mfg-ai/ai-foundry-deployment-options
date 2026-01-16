using 'main-option-11-part2.bicep'

// From AI Foundry Subscription
param existingAiResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai-foundry/providers/Microsoft.CognitiveServices/accounts/ai-foundry-models-ckop2nnk2do3i'
param dnsResourceGroupName = 'rg-private-dns'
param dnsSubscriptionId = '00000000-0000-0000-0000-000000000000'

// From App Subscription
param peSubnetId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-ai-apps/providers/Microsoft.Network/virtualNetworks/app-vnet/subnets/pe-snet'

//00000000-0000-0000-0000-000000000000
