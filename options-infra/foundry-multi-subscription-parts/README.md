# Foundry Multi Subscription Parts

Deploys AI Foundry across multiple subscriptions using a multi-part deployment approach.

## Description

This is a multi-part deployment for complex cross-subscription scenarios:

**Subscription Layout:**
- **Sub 1 (AI)**: Foundry with models, Private endpoints
- **Sub 2 (App)**: Foundry dependencies
- **Sub 3 (DNS)**: Private DNS zones

**Deployment Parts:**
- `part0.bicep` - Infrastructure foundation (VNets, resource groups)
- `part1.bicep` - Foundry and dependencies
- `part2.bicep` - DNS and final configuration

## Prerequisites

Create local parameter files based on the provided templates:
- `part0.local.bicepparam`
- `part1.local.bicepparam`
- `part2.local.bicepparam`

## Deployment

Deploy in order:

```bash
# Part 0 - Foundation
az deployment mg create \
  --management-group-id <name>-management-group \
  --template-file part0.bicep \
  --parameters part0.local.bicepparam \
  --location westus

# Part 1 - Foundry
az deployment mg create \
  --management-group-id <name>-management-group \
  --template-file part1.bicep \
  --parameters part1.local.bicepparam \
  --location westus

# Part 2 - DNS
az deployment mg create \
  --management-group-id <name>-management-group \
  --template-file part2.bicep \
  --parameters part2.local.bicepparam \
  --location westus
```
