# Foundry External AI

Creates AI Foundry and project with an external AI resource connection.

## Description

This deployment creates an AI Foundry setup that connects to an existing external AI resource (Azure OpenAI or AI Services). This is useful when you want to share AI models across multiple Foundry instances.

## Prerequisites

- An existing Azure OpenAI or AI Services resource (publicly accessible)
- The resource ID of the existing AI resource

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
| `existingAiResourceId` | Resource ID of existing AI resource | - |
| `existingAiResourceKind` | Type of AI resource (AzureOpenAI or AIServices) | AIServices |
