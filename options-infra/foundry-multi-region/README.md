# Foundry Multi Region

Deploys AI Foundry with dependencies in a different region.

## Description

This deployment creates a Foundry Standard setup where:
- Foundry is deployed to a VNet in the primary region
- All dependencies register their private endpoints in the PE subnet
- Dependencies can be in a different region

## Deployment

```bash
# Using Azure CLI
az deployment group create \
  --resource-group "rg-ai-foundry" \
  --template-file main.bicep \
  --parameters location=swedencentral dependencyLocation=eastus2

# Using Azure Developer CLI
azd up
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `location` | Azure region for Foundry deployment | Resource group location |
| `dependencyLocation` | Azure region for dependencies | eastus2 |
