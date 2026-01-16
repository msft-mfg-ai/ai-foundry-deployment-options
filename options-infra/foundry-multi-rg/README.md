# Foundry Multi Resource Group

Deploys AI Foundry with resources split across multiple resource groups.

## Description

This deployment creates two resource groups:
1. **Main resource group** - AI Project and Foundry
2. **Dependencies resource group** - VNet, private endpoints for AI Search, Azure Storage, and Cosmos DB

The AI Project uses dependencies from the second resource group and can optionally connect to an AI Foundry from a different subscription.

## Deployment

```bash
# Using Azure CLI (subscription scope)
az deployment sub create \
  --location westus \
  --template-file main.bicep \
  --parameters main.bicepparam

# Using Azure Developer CLI
azd up
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `location` | Azure region for deployment | - |
| `applicationName` | Base name for the application | my-app |
| `deployApp2` | Deploy second application | true |
