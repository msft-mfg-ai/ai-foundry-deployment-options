# Foundry Basic

Creates AI Foundry and project - all self-contained with no BYO resources.

## Description

This deployment creates a basic AI Foundry setup with:
- Log Analytics Workspace and Application Insights
- Managed Identity
- AI Foundry with GPT-4.1-mini model deployment
- AI Project with capability host

## Deployment

```bash
# Using Azure CLI
az deployment group create \
  --resource-group "rg-ai-foundry" \
  --template-file main.bicep \
  --parameters main.bicepparam

# Using Azure Developer CLI
azd up
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `location` | Azure region for deployment | Resource group location |
