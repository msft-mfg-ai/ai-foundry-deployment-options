# Azure Machine Learning

Deploys Azure Machine Learning workspace and related resources.

## Description

This deployment creates an Azure Machine Learning workspace with:
- User-assigned managed identity
- Role assignments for ML operations
- ML workspace configuration

## Deployment

```bash
# Using Azure CLI
az deployment group create \
  --resource-group "rg-azure-ml" \
  --template-file main.bicep \
  --parameters location=eastus2

# Using Azure Developer CLI
azd up
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `location` | Azure region for deployment | Resource group location |
