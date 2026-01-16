# Foundry AVM

Deploys AI Foundry using the official Azure Verified Modules (AVM).

## Description

This deployment uses the official AVM module for AI Foundry from:
https://github.com/Azure/bicep-avm-ptn-aiml-landing-zone

This approach leverages Microsoft's verified and tested modules for consistent, production-ready deployments.

## Deployment

```bash
# Using Azure CLI
az deployment group create \
  --resource-group "rg-ai-foundry" \
  --template-file main.bicep \
  --parameters location=eastus2

# Using Azure Developer CLI
azd up
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `location` | Azure region for deployment | Resource group location |
| `user_principal_id` | User principal ID for role assignments | - |
