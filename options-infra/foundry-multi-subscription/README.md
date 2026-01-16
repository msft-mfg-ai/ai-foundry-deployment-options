# Foundry Multi Subscription

Deploys AI Foundry with resources across multiple subscriptions.

## Description

This deployment creates a Foundry Standard setup across 3 subscriptions:
- **Subscription 1**: Foundry and dependencies
- **Subscription 2**: Private endpoints
- **Subscription 3**: DNS

Features:
- App VNet with peering to Foundry VNet
- Cross-subscription resource management

## Prerequisites

Create `main.local.bicepparam` based on `main.bicepparam` with your subscription IDs.

## Deployment

```bash
# Using Azure CLI (management group scope)
az deployment mg create \
  --management-group-id <name>-management-group \
  --template-file main.bicep \
  --parameters main.local.bicepparam \
  --location westus
```

## Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `foundryLocation` | Azure region for Foundry | swedencentral |
| `foundrySubscriptionId` | Subscription ID for Foundry | - |
| `foundryResourceGroupName` | Resource group name for Foundry | rg-ai-foundry |
| `appLocation` | Azure region for App | westeurope |
| `appSubscriptionId` | Subscription ID for App | - |
| `appResourceGroupName` | Resource group name for App | rg-ai-apps |
| `dnsLocation` | Azure region for DNS | appLocation |
| `dnsSubscriptionId` | Subscription ID for DNS | appSubscriptionId |
| `dnsResourceGroupName` | Resource group name for DNS | rg-private-dns |
