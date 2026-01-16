> **AI Foundry Deployment Options**
>
> This repository provides Bicep templates and deployment instructions for setting up Azure AI Foundry landing zones with various networking and resource sharing options. It is intended for Azure administrators and application teams deploying AI workloads with private networking, BYO resources, and cost management best practices.
>
> **Last updated:** July 31, 2025
>

# AI Foundry landing zone options

## Table of Contents

- [Overview](#ai-foundry-landing-zone-options)
- [Standard Network Setup](#ai-foundry-standard-network-standard-setup)
- [Cost Management](#cost-management)
- [Deployment Options](#deployment-options)
  - [Architecture Patterns](#architecture-patterns)
  - [All Deployment Templates](#all-deployment-templates)
- [Deployment Instructions](#deployment-instructions)
- [Troubleshooting](#troubleshooting)

## AI Foundry Standard Network Standard Setup

In this setup, AI Foundry is deployed with BYO resources and Network.

Network and BYO resources apply only to Agent Service, not to other features of Foundry.

>[!IMPORTANT]
> BYO Network requires BYO Storage and cannot be applied separately.

Bicep files in this repository, for Foundry Standard Setup were provided by the Product Team in [15 private network standard agent setup](https://github.com/azure-ai-foundry/foundry-samples/tree/main/samples/microsoft/infrastructure-setup/15-private-network-standard-agent-setup).

Agent Service uses:
 
* **Cosmos DB** for thread management
* **Azure OpenAI** for models
* **Storage** for file storage
* **AI Search** for agent indexes
* **Subnet** for certain Agent tool execution (OpenAPI, MCP, etc.) [(BYO) private virtual network](https://learn.microsoft.com/en-us/azure/ai-foundry/agents/how-to/virtual-networks).

> [!WARNING]
> Your existing Azure Cosmos DB for NoSQL account used in a standard setup must have a total throughput limit of at least 3000 RU/s. Both provisioned throughput and serverless are supported.
> Three containers will be provisioned in your existing Cosmos DB account, each requiring 1000 RU/s

> [!NOTE]
> Currently there's no way to manage cost of shared resources (Cosmos, Search) in order to execute chargeback to application teams.

## Cost management

### Cost of models

Currently AI Foundry does not offer cost metrics per project.
All models deployed on the foundry instance are shared with all the projects.

>[!INFORMATION]
> Agent Service is deployed and configured in each project. It supports BYO models through a connection to an external foundry resource.

### Cost of dependent resources

For Foundry Standard deployment (BYO network and storage), all dependent resources CAN be shared between projects or multiple foundries.

> [!WARNING]
> Deployed agents may serve varied use cases which utilize dependent resources (artifacts in storage, indexes in search, threads in Cosmos DB). It's important to monitor usage (especially for Cosmos DB), scale when needed.

### Key Information

**Limited Region Support for Class A Subnet IPs**
- Class A subnet support is only available in select regions and requires allowlisting of your subscription ID. Supported regions: West US, East US, East US 2, Central US, Japan East, France Central, [New] Spain Central, [New] UAE North

**Region and Resource Placement Requirements**
- **All Foundry workspace resources should be in the same region as the VNet**, including CosmosDB, Storage Account, AI Search, Foundry Account, Project, Managed Identity. The only exception is within the Foundry Account, you may choose to deploy your model to a different region, and any cross-region communication will be handled securely within our network infrastructure.
  - **Note:** Your dependent resources can be in a different resource group (including VNET) but have to be in the same region and subscription.

> [!NOTE]
> Shared AI resource has to be of kind `AIServices` in order to support all models not only OpenAI.

## Deployment Options

### Architecture Patterns

| Pattern | Description | Diagram | Sample |
|---------|-------------|---------|--------|
| **Nothing Shared** | Each application deploys its own AI Landing Zone | ![Nothing shared](./Resources/1-nothing_shared.png) | [foundry-basic](./options-infra/foundry-basic/) |
| **Nothing Shared (2 RGs)** | Separate internal resources (Cosmos DB, Storage, AI Search, VNET) into dedicated Resource Group | ![2 RGs](./Resources/1-nothing_shared-two-rgs.png) | [foundry-multi-rg](./options-infra/foundry-multi-rg/) |
| **Shared AI Dependencies** | Share Cosmos DB, Storage, AI Search between projects (same subscription/region) | ![Shared deps](./Resources/2-shared-dependencies.png) | [foundry-multi-rg](./options-infra/foundry-multi-rg/) |
| **Shared AI Foundry Models** | Share models via external AI Foundry connection (can be cross-subscription) | ![Shared models](./Resources/3-shared-models.png) | [foundry-external-ai](./options-infra/foundry-external-ai/) |
| **Shared Foundry, Multiple Projects** | Single Foundry with project per application team | ![Many projects](./Resources/4-shared-foundry-many-projects.png) | [foundry-two-projects](./options-infra/foundry-two-projects/) |
| **AI Gateway (APIM)** | Use Azure API Management as AI Gateway ⚠️ *Not yet supported* | ![AI Gateway](./Resources/5-shared-apim.png) | [ai-gateway](./options-infra/ai-gateway/) |

### All Deployment Templates

| Directory | Description | Scope | azd |
|-----------|-------------|-------|-----|
| [foundry-basic](./options-infra/foundry-basic/) | Basic AI Foundry with self-contained resources | Resource Group | ✅ |
| [foundry-external-ai](./options-infra/foundry-external-ai/) | Foundry with external AI resource connection | Resource Group | ✅ |
| [foundry-multi-rg](./options-infra/foundry-multi-rg/) | Resources split across multiple resource groups | Subscription | ✅ |
| [foundry-two-projects](./options-infra/foundry-two-projects/) | One Foundry with two AI projects | Resource Group | ✅ |
| [foundry-multi-vnet](./options-infra/foundry-multi-vnet/) | Foundry and dependencies in separate VNets with DNS resolver | Resource Group | ✅ |
| [foundry-multi-region](./options-infra/foundry-multi-region/) | Dependencies in different region | Resource Group | ✅ |
| [foundry-agents-vnet](./options-infra/foundry-agents-vnet/) | Agents Service in dedicated VNet | Resource Group | ✅ |
| [foundry-avm](./options-infra/foundry-avm/) | Using official Azure Verified Modules (AVM) | Resource Group | ✅ |
| [foundry-multi-subscription](./options-infra/foundry-multi-subscription/) | Cross-subscription deployment (3 subs) | Management Group | ✅ |
| [foundry-multi-subscription-parts](./options-infra/foundry-multi-subscription-parts/) | Multi-part cross-subscription deployment | Management Group | ✅ |
| [azure-ml](./options-infra/azure-ml/) | Azure Machine Learning workspace | Resource Group | ✅ |
| [foundry-search](./options-infra/foundry-search/) | Foundry with AI Search integration | Resource Group | ✅ |
| [ai-gateway](./options-infra/ai-gateway/) | API Management as AI Gateway | Resource Group | ✅ |
| [ai-gateway-basic](./options-infra/ai-gateway-basic/) | Basic AI Gateway configuration | Resource Group | ✅ |
| [ai-gateway-premium](./options-infra/ai-gateway-premium/) | Premium tier AI Gateway | Resource Group | ✅ |
| [ai-gateway-internal](./options-infra/ai-gateway-internal/) | Internal AI Gateway (private) | Resource Group | ✅ |
| [ai-gateway-pe](./options-infra/ai-gateway-pe/) | AI Gateway with private endpoints | Resource Group | ✅ |
| [ai-gateway-openrouter](./options-infra/ai-gateway-openrouter/) | AI Gateway with OpenRouter | Resource Group | ✅ |
| [litellm](./options-infra/litellm/) | LiteLLM proxy deployment | Resource Group | ✅ |
| [deploy-vm](./options-infra/deploy-vm/) | Deploy VM for testing | Resource Group | ✅ |
| [separate-dns](./options-infra/separate-dns/) | Separate DNS configuration | Resource Group | ✅ |
| [create-projects](./options-infra/create-projects/) | Create additional projects | Resource Group | ✅ |
| [destroy-caphost](./options-infra/destroy-caphost/) | Destroy capability hosts | Resource Group | ✅ |

### Additional Resources

- **Mini Landing Zone**: Simple infrastructure for testing - [landing-zone.bicep](./options-infra/landing-zone.bicep)
- **AI Landing Zone Reference**: [Azure AI Landing Zones](https://github.com/Azure/AI-Landing-Zones)
- **AI Gateway Workshop**: [azure-samples.github.io/AI-Gateway](https://azure-samples.github.io/AI-Gateway/)
- **OpenAI Spillover Feature**: [Spillover traffic management (preview)](https://learn.microsoft.com/en-us/azure/ai-services/openai/how-to/spillover-traffic-management)

## Deployment Instructions

### Prerequisites

* Azure CLI installed and configured
* Appropriate permissions (Contributor or Owner access) to your Azure subscription/resource group
* Azure subscription with quota for AI services

### Steps to Deploy

1. **Navigate to the infrastructure directory:**

   ```bash
   cd "options-infra"
   ```

2. **Login to Azure (if not already logged in):**

   ```bash
   az login
   ```

3. **Set your subscription (if you have multiple):**

   ```bash
   az account set --subscription "your-subscription-id-or-name"
   ```

4. **Create a resource group (if it doesn't exist):**

   ```bash
   az group create --name "rg-ai-foundry-config" --location "eastus2"
   ```

5. **Deploy the Bicep template using the parameters file:**

   **Option 1 - Just Foundry:**
   ```bash
   az deployment group create `
     --resource-group "rg-ai-foundry-config" `
     --template-file "foundry-basic/main.bicep" `
     --parameters "foundry-basic/main.bicepparam" `
     --verbose
   ```

   **Option 2 - AI Foundry with external AI resource**
   ```bash
   az deployment group create `
     --resource-group "rg-ai-foundry-config" `
     --template-file "foundry-external-ai/main.bicep" `
     --parameters "foundry-external-ai/main.bicepparam" `
     --verbose
   ```

   **Option 3 - two resource groups - one for app - one for AI dependencies:**
   ```bash
   az deployment sub create `
     --location westus `
     --template-file "foundry-multi-rg/main.bicep" `
     --parameters "foundry-multi-rg/main.bicepparam" `
     --verbose
   ```

   **Option 4 - AI Foundry with multiple projects:**
   ```bash
   az deployment group create `
     --resource-group "rg-ai-foundry-config" `
     --template-file "foundry-two-projects/main.bicep" `
     --parameters "foundry-two-projects/main.bicepparam" `
     --verbose
   ```


**Configuration Notes:**
Create your own configuration file: `foundry-multi-rg/main.local.bicepparam` and use in the deployment.

* **Location**: Set to `eastus2` - you can change this to your preferred Azure region that supports AI services
* **Existing AOAI Resource**: 
  - Provide the full resource ID of your existing Azure OpenAI resource

> [!IMPORTANT]
> When using an existing Azure OpenAI resource (Options 2-4), ensure that:
>
> * The Azure OpenAI resource and AI Foundry account are deployed in the same region
> * You have appropriate permissions to access the existing Azure OpenAI resource
> * The existing Azure OpenAI resource has the required model deployments

### Alternative Deployment Methods

**Deploy with inline parameters (example for Option 2):**

```bash
az deployment group create `
  --resource-group "rg-ai-foundry-config" `
  --template-file "foundry-external-ai/main.bicep" `
  --parameters location="eastus2" existingAoaiResourceId="/subscriptions/1c083bf3-30ac-4804-aa81-afddc58c78dc/resourceGroups/aoai-rgp-02/providers/Microsoft.CognitiveServices/accounts/aoai-02" `
  --verbose
```

### Troubleshooting

#### Troubleshooting Agents

The easiest way to test agents BYO network capabilities is by using OpenAPI tool for non public API.

[Agents Testing workbook](./agents/testing-agents.ipynb) offers scripts for creating, configuring and running agents in Foundry.

For Testing OpenAPI and MCP, you can use [weather-MCP-OpenAPI-server](https://github.com/karpikpl/weather-MCP-OpenAPI-server). Deploy it to Azure Container Apps without any additional configuration.

```bash
docker run -it --rm -p 3000:3000 -p 3001:3001 ghcr.io/karpikpl/weather-mcp-openapi-server:latest
```

For Troubleshooting OpenAPI and MCP, use [dev tunnels](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/).

```bash
devtunnel user login
devtunnel port create -p 3000
devtunnel port create -p 3001
devtunnel host
```
#### Troubleshooting Capability Hosts

The most common issue with Foundry Standard deployment is misconfiguration of capability hosts or temperary errors in it's creation.

Use tools available in [utils](./utils/) to view/modify/delete capability hosts.

#### Troubleshooting Bicep

* If you get permission errors, ensure your account has Owner access to the subscription/resource group
* If model deployments fail, check that your subscription has quota for the AI models
* For RBAC or role assignment problems, confirm your identity and permissions
* Use `--verbose` flag for more detailed output if needed
* Ensure Azure OpenAI resource and Azure AI Foundry account are in the same region
* For deployment failures, review error messages and consult [Azure documentation](https://learn.microsoft.com/en-us/azure/ai-foundry/agents/how-to/use-your-own-resources)
