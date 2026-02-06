<div align="center">

# 🤖 Microsoft Foundry Deployment Options

<img src="https://raw.githubusercontent.com/microsoft/Azure-AI-Foundry-Accelerators/main/assets/ai-foundry-logo.png" alt="Microsoft Foundry" width="200"/>

### 🚀 Bicep Templates for Azure AI Infrastructure

[![Bicep](https://img.shields.io/badge/Bicep-✓-blue.svg)](https://learn.microsoft.com/azure/azure-resource-manager/bicep/)
[![Azure](https://img.shields.io/badge/Azure-Foundry-0089D6.svg)](https://azure.microsoft.com/en-us/products/ai-foundry/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

📦 **29 Deployment Options** | 🔐 **Private Networking** | 💰 **Cost Optimized** | 🏗️ **Enterprise Ready**

</div>

---

## 📋 Table of Contents

- [Overview](#-overview)
- [Standard Network Setup](#-standard-network-setup)
- [Cost Management](#-cost-management)
- [Deployment Options](#-deployment-options)
  - [Architecture Patterns](#-architecture-patterns)
  - [Foundry Deployments](#-foundry-deployments)
  - [AI Gateway Options](#-ai-gateway-options)
  - [Utility & Support](#-utility--support)
- [Quick Start](#-quick-start)
- [Troubleshooting](#-troubleshooting)

---

## 🌟 Overview

This repository provides **development-ready Bicep templates** for deploying Microsoft Foundry with various configurations including:

✅ **Private networking** with VNet integration
✅ **BYO (Bring Your Own) resources** - Storage, Cosmos DB, AI Search
✅ **Multi-region & multi-subscription** support
✅ **Cost management** with shared resources
✅ **AI Gateway** patterns with Azure API Management
✅ **Azure Verified Modules (AVM)** compliance

> **Last updated:** January 2026
> For production use-cases, some modifications are recommended - like subnet sizes etc.
---

## 🔧 Standard Network Setup

Microsoft Foundry can be deployed with **BYO resources and networking** for enhanced security and control.

### 🎯 Key Capabilities

Network and BYO resources apply to **Agent Service** specifically, enabling:

- 🔒 **Private virtual networks** for agent execution
- 📦 **Custom storage accounts** for file management
- 🔍 **Azure AI Search** for agent indexes
- 🗄️ **Cosmos DB** for thread management
- 🤖 **Azure OpenAI** for model access

> [!IMPORTANT]
> **BYO Network requires BYO Storage** and cannot be applied separately.

> [!NOTE]
> Bicep templates in this repository are based on best practices from the Product Team's [private network standard agent setup](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/15-private-network-standard-agent-setup).

### 🧱 Agent Service Dependencies

| Resource | Purpose | Configuration |
|----------|---------|---------------|
| **🗄️ Cosmos DB** | Thread management | Min 3000 RU/s total throughput |
| **🤖 Azure OpenAI** | LLM models | Supports spillover & cross-region |
| **📦 Storage Account** | File storage & artifacts | Private endpoint enabled |
| **🔍 AI Search** | Vector indexes | Shared or dedicated |
| **🌐 Subnet** | Tool execution (OpenAPI, MCP) | Delegated to Agent Service |

> [!WARNING]
> **Cosmos DB Requirements:**
> - Minimum **3000 RU/s** total throughput limit
> - Three containers provisioned (1000 RU/s each)
> - Both **provisioned throughput** and **serverless** modes supported

> [!NOTE]
> Currently there's no native way to manage cost of shared resources (Cosmos, Search) for executing chargeback to application teams.

---

## 💰 Cost Management

### 💵 Model Costs

Microsoft Foundry currently **does not offer per-project cost metrics**. All models deployed on a Foundry instance are **shared across all projects**.

> [!TIP]
> **Agent Service** is configured per project and supports **BYO models** through connections to external Foundry resources, enabling cost isolation.

### 📊 Dependent Resources

For Foundry Standard deployments, dependent resources **can be shared** between:
- Multiple projects within one Foundry
- Multiple Foundry instances (same subscription/region)

> [!WARNING]
> **Monitor resource usage carefully:**
> - Agents may serve varied use cases with different resource patterns
> - **Storage:** Artifacts and file uploads
> - **AI Search:** Vector indexes per agent
> - **Cosmos DB:** Thread storage (scale when needed)

### 🌍 Regional Considerations

**✅ Supported Regions for Private Network Setup**
Agent Service with BYO VNet is available in the following regions:
- `Australia East`, `Brazil South`, `Canada East`, `East US`, `East US 2`, `France Central`
- `Germany West Central`, `Italy North`, `Japan East`, `South Africa North`, `South Central US`
- `South India`, `Spain Central`, `Sweden Central`, `UAE North`, `UK South`
- `West Europe`, `West US`, `West US 3`

**📍 Resource Placement Requirements**
- ✅ **All Foundry workspace resources** (Cosmos, Storage, Search, Managed Identity) → **Same region as VNet (Recommended but not required)**
- ✅ **Model deployments** → Can be in different regions (handled by Azure's secure network)
- ⚠️ **Dependent resources** → Can be in different resource groups **but must be same subscription. Regional placement is recommeded.**

**🔧 Subnet Requirements**
- **Two subnets required**: Agent Subnet and Private Endpoint Subnet
- **Agent Subnet** (e.g., 192.168.0.0/24): Recommended `/24` size, must be delegated to `Microsoft.App/environments` at least `/27`
- **Private Endpoint Subnet** (e.g., 192.168.1.0/24): Hosts private endpoints
- **Subnet Exclusivity**: Agent subnet must be exclusive to the Foundry account (cannot be shared)
- **Avoid reserved ranges**: Do not use the following Azure-reserved ranges:
  `169.254.0.0/16`, `172.30.0.0/16`, `172.31.0.0/16`, `192.0.2.0/24`, `0.0.0.0/8`, `127.0.0.0/8`, `100.100.0.0/17`, `100.100.192.0/19`, `100.100.224.0/19`, `100.64.0.0/11`
  This includes all address spaces in your VNet (if you have more than one) and peered VNets.

> [!IMPORTANT]
> Shared AI resources must be of kind **`AIServices`** (not just `OpenAI`) to support all models including multimodal and embedding services.

### 🔒 Private DNS Zones

| Private Link Resource Type | Sub Resource | Private DNS Zone Name | Public DNS Zone Forwarders |
|---------------------------|--------------|------------------------|-----------------------------|
| **Azure AI Foundry** | account | `privatelink.cognitiveservices.azure.com`<br>`privatelink.openai.azure.com`<br>`privatelink.services.ai.azure.com` | `cognitiveservices.azure.com`<br>`openai.azure.com`<br>`services.ai.azure.com` |
| **Azure AI Search** | searchService | `privatelink.search.windows.net` | `search.windows.net` |
| **Azure Cosmos DB** | Sql | `privatelink.documents.azure.com` | `documents.azure.com` |
| **Azure Storage** | blob | `privatelink.blob.core.windows.net` | `blob.core.windows.net` |

---

## 🚀 Deployment Options

### 🏗️ Architecture Patterns

| Pattern | Description | Diagram | Sample |
|---------|-------------|---------|--------|
| **🎯 Nothing Shared** | Each application deploys its own complete infrastructure | <TBD> | <TBD> |
| **📁 Nothing Shared (2 RGs)** | Separate internal resources (Cosmos, Storage, Search, VNet) into dedicated Resource Group | <TBD> | <TBD> |
| **🔗 Shared AI Dependencies** | Share Cosmos DB, Storage, AI Search between projects (same subscription/region) | <TDB> | <TBD> |
| **🤖 Shared Foundry Models** | Share models via external Foundry connection (cross-subscription capable) | <TBD> | <TBD> |
| **🏢 Shared Foundry, Multiple Projects** | Single Foundry with project per application team | | <TBD> | <TBD> |
| **🌐 AI Gateway (APIM)** | Use Azure API Management as AI Gateway for unified access | <TBD> | <TBD> |

---

### 🤖 Foundry Deployments

> Piotr Review: Please verify the descriptions match each template's actual purpose

| Directory | Description | Scope | Features |
|-----------|-------------|-------|----------|
| [**foundry-basic**](./options-infra/foundry-basic/) | 🎯 Self-contained Foundry with no BYO resources (Log Analytics, App Insights, GPT-4.1-mini) | Resource Group | Single project, managed identity, capability host |
| [**foundry-external-ai**](./options-infra/foundry-external-ai/) | 🔌 Foundry with external AI resource connection to share models across instances | Resource Group | Cross-subscription model sharing |
| [**foundry-external-ai-pe**](./options-infra/foundry-external-ai-pe/) | 🔐 Foundry with external AI + Private Endpoints (⚠️ not supported as of 1/22/2026) | Resource Group | External AI with private networking |
| [**foundry-multi-rg**](./options-infra/foundry-multi-rg/) | 📁 AI Foundry in main RG, dependencies (VNet, PE, Search, Storage, Cosmos) in separate RG | Subscription | Separate infra & app RGs |
| [**foundry-two-projects**](./options-infra/foundry-two-projects/) | 🏢 One Foundry with two Foundry Projects | Resource Group | Multiple projects, shared models |
| [**foundry-multi-vnet**](./options-infra/foundry-multi-vnet/) | 🌐 Foundry in one VNet, dependencies in another with VNet peering and DNS resolver | Resource Group | DNS resolver, VNet peering |
| [**foundry-multi-region**](./options-infra/foundry-multi-region/) | 🌍 Foundry in primary region, dependencies in a different region with private endpoints | Resource Group | Cross-region dependencies |
| [**foundry-agents-vnet**](./options-infra/foundry-agents-vnet/) | 🔒 Agents Service in a separate VNet connected via VNet peering and DNS resolver | Resource Group | Isolated agent execution |
| [**foundry-avm**](./options-infra/foundry-avm/) | ✅ Using official Azure Verified Modules (AVM) | Resource Group | Using AVM foundry module |
| [**foundry-multi-subscription**](./options-infra/foundry-multi-subscription/) | 🔀 3 subscriptions: Sub 1 Foundry/deps, Sub 2 private endpoints, Sub 3 DNS | Management Group | Hub, shared services, workload subs |
| [**foundry-multi-subscription-parts**](./options-infra/foundry-multi-subscription-parts/) | 🧩 Multi-part deployment: part0 infra, part1 Foundry/deps, part2 DNS/config | Management Group | Deploy in sequence: part0, part1, part2 |
| [**foundry-search**](./options-infra/foundry-search/) | 🔍 Foundry with public/private AI Search, multiple projects, and capability hosts | Resource Group | AI Search for agent indexes |
| [**foundry-rag-search**](./options-infra/foundry-rag-search/) | 📚 RAG with Document Intelligence, GPT-4o, Cohere embed-v4, semantic/vector search | Resource Group | RAG with AI Search & embeddings |
| [**foundry-sk-agents**](./options-infra/foundry-sk-agents/) | 🧠 Containerized SK Agents App + File Processor API with OpenTelemetry | Resource Group | Semantic Kernel integration |

---

### 🌐 AI Gateway Options

| Directory | Description | Scope | Features |
|-----------|-------------|-------|----------|
| [**ai-gateway**](./options-infra/ai-gateway/) | 🌐 Azure API Management as AI Gateway | Resource Group | Basic v2 SKU APIM, Public Networking |
| [**ai-gateway-basic**](./options-infra/ai-gateway-basic/) | 🚀 Foundry Basic + APIM Basic v2 (no capability hosts, no agent subnet, public) | Resource Group | Minimal config, quick start |
| [**ai-gateway-premium**](./options-infra/ai-gateway-premium/) | 💎 APIM v2 Premium with VNet injection (internal mode) as AI Gateway | Resource Group | Premium APIM, VNet injection |
| [**ai-gateway-internal**](./options-infra/ai-gateway-internal/) | 🔒 Internal APIM (VNet injected) proxying to external Azure OpenAI | Resource Group | Internal VNet mode |
| [**ai-gateway-pe**](./options-infra/ai-gateway-pe/) | 🔐 APIM Standard v2 with private endpoint to Foundry Agent Service | Resource Group | Private endpoints to backends |
| [**ai-gateway-openrouter**](./options-infra/ai-gateway-openrouter/) | 🌍 Public Foundry (no agent subnet) with OpenRouter as external model gateway | Resource Group | OpenRouter backend support |
| [**ai-gateway-litellm**](./options-infra/ai-gateway-litellm/) | ⚡ LiteLLM on ACA + PostgreSQL with Application Gateway and private endpoints | Resource Group | LiteLLM Container Apps deployment |

> [!NOTE]
> AI Gateway (APIM) integration with Azure AI Foundry is expected to enter **public preview on February 13, 2026**.

---

### 🛠️ Utility & Support

| Directory | Description | Scope | Purpose |
|-----------|-------------|-------|---------|
| [**azure-ml**](./options-infra/azure-ml/) | 🧪 Azure ML workspace with managed identity and role assignments | Resource Group | Classic Azure ML setup |
| [**shared-infra**](./options-infra/shared-infra/) | 🔗 Shared infrastructure for multiple deployments | Resource Group | Cosmos, Storage, Search to share |
| [**create-projects**](./options-infra/create-projects/) | ➕ Create additional projects in existing Foundry | Resource Group | Add projects post-deployment |
| [**deploy-vm**](./options-infra/deploy-vm/) | 💻 Deploy VM for testing/troubleshooting | Resource Group | Jumpbox for private endpoints |
| [**separate-dns**](./options-infra/separate-dns/) | 🌐 Separate DNS configuration | Resource Group | Custom DNS setup |
| [**destroy-caphost**](./options-infra/destroy-caphost/) | 🗑️ Destroy capability hosts | Resource Group | Cleanup utility |
| [**fix-cosmos-permissions**](./options-infra/fix-cosmos-permissions/) | 🔧 Fix Cosmos DB RBAC permissions | Resource Group | Permission troubleshooting |
| [**testing-permissions**](./options-infra/testing-permissions/) | ✅ Step-by-step RBAC role combination testing (AI User, Reader, Contributor, etc.) | Resource Group | Permission validation |

---

## 🚀 Quick Start

### 📋 Prerequisites

- ✅ **Azure CLI** installed and configured
- ✅ **Azure AI Account Owner**: Needed to create a cognitive services account and project
- ✅ **Owner or Role Based Access Administrator**: Needed to assign RBAC to the required resources (Cosmos DB, Azure AI Search, Storage)
- ✅ **Azure AI User**: Needed to create and edit agents
- ✅ **Azure subscription** with quota for AI services
- ✅ Sufficient quota for all resources in your target Azure region
- ✅ Supported **Azure region** (East US 2, West US, etc.)
- ✅ Network administrator permissions (if operating in a restricted or enterprise environment)

#### 📦 Register Resource Providers

Make sure the following resource providers are registered in your subscription:

```bash
az provider register --namespace 'Microsoft.KeyVault'
az provider register --namespace 'Microsoft.CognitiveServices'
az provider register --namespace 'Microsoft.Storage'
az provider register --namespace 'Microsoft.Search'
az provider register --namespace 'Microsoft.Network'
az provider register --namespace 'Microsoft.App'
az provider register --namespace 'Microsoft.ContainerService'
```

### 🎬 Deployment Steps

#### 1️⃣ Login to Azure

```bash
az login
azd auth login
```

#### 2️⃣ Navigate to the desired deployment option

```bash
cd options-infra/foundry-basic  # or any other option
```

#### 3️⃣ Deploy

```bash
azd up
```

You will be prompted to select a subscription, region, and provide any required parameters.

> [!TIP]
> Each deployment option directory contains an `azure.yaml` file that defines the infrastructure. Browse the [Deployment Options](#-deployment-options) section to find the right template for your scenario.

### ⚙️ Configuration

**💡 Create Local Configuration:**

```bash
cp foundry-basic/main.bicepparam foundry-basic/main.local.bicepparam
# Edit main.local.bicepparam with your values
```

**🔑 Key Parameters:**

- **`location`** - Azure region (e.g., `eastus2`, `westus`)
- **`principalId`** - Your Azure AD user/service principal ID
- **`existingAoaiResourceId`** - (Optional) Existing Azure OpenAI resource ID

> [!IMPORTANT]
> **When using existing Azure OpenAI resources:**
> - The Azure OpenAI and Foundry must be in the **same region**
> - You need appropriate **RBAC permissions** on the OpenAI resource
> - The OpenAI resource should have required **model deployments**

**🎯 Inline Parameters Example:**

```bash
az deployment group create \
  --resource-group "rg-ai-foundry-demo" \
  --template-file "foundry-external-ai/main.bicep" \
  --parameters location="eastus2" \
    existingAoaiResourceId="/subscriptions/.../providers/Microsoft.CognitiveServices/accounts/my-aoai" \
  --verbose
```

---

## �️ Account Deletion & Cleanup

Before deleting an **Account** resource, you **must** first delete the associated **Account Capability Host**. Failure to do so may result in residual dependencies (subnets, ACA applications) remaining linked, leading to **"Subnet already in use"** errors when reusing the subnet.

**Option 1: Full Account Removal**
- Delete **and purge** the account. Simply deleting is not sufficient — you must purge so that deletion of the associated capability host is triggered.
- Use the Azure portal: [Purge a deleted resource](https://learn.microsoft.com/en-us/azure/ai-services/recover-purge-resources?tabs=azure-portal#purge-a-deleted-resource)
- Allow approximately **20 minutes** for all resources to be fully unlinked.

**Option 2: Retain Account, Remove Capability Host**
- Delete the capability host using the [`destroy-caphost`](./options-infra/destroy-caphost/) utility.
- After deletion, allow approximately **20 minutes** for all resources to be fully unlinked.
- To recreate the capability host, redeploy the project capability host Bicep.

> [!IMPORTANT]
> Before deleting the **account** capability host, ensure that the **project** capability host is deleted first.

---

## �🐛 Troubleshooting

### 🤖 Testing Agents

The easiest way to test **Agents BYO network** capabilities is using the OpenAPI tool with a non-public API.

**📓 Agents Testing Workbook:**
- [Agents Testing Notebook](./agents/testing-agents.ipynb) - Scripts for creating, configuring and running agents

**🌐 Test Server:**

Use [weather-MCP-OpenAPI-server](https://github.com/karpikpl/weather-MCP-OpenAPI-server) for testing OpenAPI and MCP:

```bash
# Run locally
docker run -it --rm -p 3000:3000 -p 3001:3001 \
  ghcr.io/karpikpl/weather-mcp-openapi-server:latest
```

**🔌 Dev Tunnels for Local Testing:**

```bash
devtunnel user login
devtunnel port create -p 3000
devtunnel port create -p 3001
devtunnel host
```

> 📚 Learn more: [Dev Tunnels Documentation](https://learn.microsoft.com/azure/developer/dev-tunnels/)

---

### 🔧 Capability Hosts Issues

The most common issue with Foundry Standard deployments is **misconfiguration or transient errors** during capability host creation.

**🛠️ Utilities:**

Use tools in [`utils/`](./utils/) directory to:
- 👀 View capability host status
- ✏️ Modify configuration
- 🗑️ Delete and recreate hosts

---

### 🩺 Bicep Deployment Issues

| Issue | Solution |
|-------|----------|
| ❌ **Permission errors** | Ensure account has **Owner** or **Contributor + User Access Administrator** roles |
| ❌ **Model deployment fails** | Check subscription **quota** for AI models in target region |
| ❌ **RBAC assignment errors** | Verify identity permissions and wait for AD replication (can take 5-10 min) |
| ❌ **VNet/Subnet errors** | Ensure subnet is **delegated** to `Microsoft.App/environments` |
| ❌ **Cosmos DB provisioning** | Verify **3000 RU/s minimum** throughput available |
| ❌ **Region mismatch** | All resources must be in **same region** (except OpenAI spillover) |

**🔍 Debugging Tips:**

```bash
# Use verbose flag for detailed logs
--verbose

# Check deployment status
az deployment group show \
  --resource-group "rg-name" \
  --name "deployment-name"

# View deployment operations
az deployment operation group list \
  --resource-group "rg-name" \
  --name "deployment-name"
```

---

## 📚 Additional Resources

- 📖 **[Microsoft Foundry Documentation](https://learn.microsoft.com/azure/ai-foundry/)**
- 🏗️ **[Azure AI Architecture Reference](https://github.com/Azure/AI-Landing-Zones)**
- 🌐 **[AI Gateway Workshop](https://azure-samples.github.io/AI-Gateway/)**
- 🔄 **[OpenAI Spillover Feature](https://learn.microsoft.com/azure/ai-services/openai/how-to/spillover-traffic-management)**
- 🏛️ **[Azure Verified Modules (AVM)](https://aka.ms/avm)**

---

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<div align="center">

**Built with ❤️ for Azure AI**

🌟 Star this repo if you find it helpful!

</div>
