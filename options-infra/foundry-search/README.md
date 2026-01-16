# Foundry Search

Deploys AI Foundry with AI Search integration and multiple projects.

## Description

This deployment creates a comprehensive AI Foundry setup with:
- AI Foundry with VNet integration
- AI Search services:
  - public without private endpoint
  - public with private endpoint
  - private with private endpoint
- Multiple AI Projects with capability hosts (Foundry Standard mode)
- AI dependencies with DNS configuration
- Private endpoints for Azure Storage and Cosmos DB

This is useful for scenarios where you need AI Search capabilities integrated with your Foundry projects.

## Features

- **Multiple Projects**: Configurable number of AI projects (default: 3)
- **AI Search Integration**: Public AI Search service with role assignments
- **Network Isolation**: VNet with dedicated subnets for agents and private endpoints
- **Identity Management**: Managed identities with proper role assignments

## Deployment

```bash
# Using Azure CLI
az deployment group create \
  --resource-group "rg-foundry-search" \
  --template-file main.bicep \
  --parameters main.bicepparam

# Using Azure Developer CLI
azd up
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `location` | Azure region for deployment | Resource group location |
| `principalId` | User principal ID for role assignments | - |
| `projectsCount` | Number of AI projects to create | 3 |

## Post-Deployment

After deployment, you can use the scripts in the `scripts/` directory for testing and configuration.
