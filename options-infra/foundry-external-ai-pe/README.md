# Foundry External AI

Creates AI Foundry and project with an external AI resource connection using Private Endpoint.

> [!Warning]
> This setup is currently (1/22/2026) not supported by Foundry.
> External AI resource needs to be public.

## Description

This deployment creates an AI Foundry Standard setup that connects to an external AI resource (another Foundry). This is useful when you want to share AI models across multiple Foundry instances.

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
