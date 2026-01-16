# Foundry Agents VNet

Deploys AI Foundry with Agents Service in a separate VNet.

## Description

This deployment explores a scenario where:
- Foundry Agents Service is in one VNet
- All dependencies are in another VNet
- Private DNS resolver enables name resolution
- VNet peering connects the networks

This setup is useful for network isolation requirements where the Agents Service needs to be in a dedicated network segment.

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
