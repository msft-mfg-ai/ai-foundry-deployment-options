# Foundry Multi VNet

Deploys AI Foundry with resources in separate VNets with Private DNS resolver.

## Description

This deployment creates a Foundry Standard setup where:
- Foundry is deployed to one VNet
- All dependencies are in another VNet
- Private DNS resolver enables name resolution
- VNet peering connects the networks

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
