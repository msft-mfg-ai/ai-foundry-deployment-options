# Foundry with Azure Databricks Genie One

Deploys:

- One Microsoft Foundry account and one Standard agent project
- Foundry Agent Service injected into a dedicated delegated subnet
- Azure Storage, Cosmos DB, and AI Search dependencies with private endpoints
- One Premium-by-default Azure Databricks workspace injected into two dedicated subnets
- Secure Cluster Connectivity (`enableNoPublicIp`) and NAT Gateway egress
- A `gpt-5.2` model deployment
- An optional prompt agent connected to the Databricks Genie One managed MCP server
- An Entra application/service principal for Databricks automation
- A SQL warehouse, Unity Catalog sample dataset, and a configured Genie Agent
- An ADLS Gen2 managed-storage account and Databricks Access Connector

The Foundry and Databricks control-plane endpoints remain public. Compute and Agent Service data-plane resources are VNet injected.

## Prerequisites

- Azure CLI, Azure Developer CLI 1.29 or newer (`azd`, including `azd ai`), and `uv`
- Access to deploy Foundry and Azure Databricks resources
- Owner or User Access Administrator on the resource group so the deployment can grant the Databricks Access Connector access to ADLS Gen2
- Azure Databricks account admin access for the OAuth application
- Workspace admin access to enable the **Managed MCP Servers** preview
- Databricks users who can be granted the required Unity Catalog permissions

Genie One and its Foundry integration are preview features.

## Configure the Databricks account ID

Account-level automation requires the Azure Databricks account ID:

1. Open the [Azure Databricks account console](https://accounts.azuredatabricks.net/).
2. Sign in with the Microsoft Entra account associated with the Azure Databricks workspace.
3. Click your profile icon in the upper-right corner.
4. Copy **Account ID** from the menu. The account ID is a UUID; do not use the numeric workspace ID or OpenSharing ID shown in the workspace UI.

From this sample directory, save the copied value in the active azd environment:

```bash
azd env set DATABRICKS_ACCOUNT_ID "<databricks-account-id>"
```

Without it, deployment still creates the Entra service principal and workspace, but skips Databricks account registration and OAuth application creation.

To try the workspace trial SKU:

```bash
azd env set DATABRICKS_PRICING_TIER trial
```

Premium remains the default because Genie, Unity Catalog, serverless SQL, and previews can be restricted in trial workspaces.

## Deploy and configure

```bash
AZD_DISABLE_AGENT_DETECT=1 azd up
```

The azd hooks automate:

- Entra application, service principal, and client credential
- Databricks account service-principal registration and workspace assignment
- Confidential Databricks OAuth application with `genie offline_access`
- Classic Pro SQL warehouse running in the injected Databricks subnets
- Unity Catalog storage credential and external managed location
- `genie_demo.sales.orders` Delta table with synthetic data
- Unity Catalog grants for the automation service principal
- A Genie Agent configured with sample questions and SQL instructions
- Project connection: `databricks-genie-one`
- Prompt agent: `agent-databricks-genie-one` (override with `GENIE_AGENT_NAME`)

Generated credentials are stored only in the local azd environment. Do not commit `.azure/`.

## Remaining manual steps

1. Open the Databricks account **Previews** page and enable **Managed MCP Servers** for the workspace. Databricks does not expose a supported API for this preview toggle. Postprovision prints the account-specific URL.
2. Open the OAuth connection in Foundry and copy its generated redirect URL.
3. Save the callback and rerun postprovision. The hook registers it on the `foundry-genie-mcp` Databricks OAuth application:

   ```bash
   azd env set DATABRICKS_OAUTH_REDIRECT_URL "https://global.consent.azure-apim.net/redirect/<connection-id>"
   azd hooks run postprovision
   ```

4. Complete the first-user OAuth consent flow.

The connection uses:

```text
https://<workspace-hostname>/api/2.0/mcp/genie
```

Postprovision prints and saves direct links as `DATABRICKS_PREVIEWS_URL` and `FOUNDRY_PROJECT_URL` in the azd environment.

The first user request returns an OAuth consent link. Complete consent with a Databricks user that has access to Genie One and the relevant Unity Catalog data.

## Notes

- Databricks requires two dedicated subnets; they cannot be shared with Foundry Agent Service.
- The Databricks subnets use explicit NAT Gateway egress because new VNets no longer receive default outbound access.
- The sample uses explicit ADLS Gen2 managed storage with blob and DFS private endpoints because VNet-injected Hybrid workspaces cannot create this catalog on Databricks Default Storage.
- The SQL warehouse uses classic VNet-injected compute so it can reach the private-only ADLS account. Serverless SQL requires separate serverless network connectivity configuration.
- Genie One answers across workspace data. To target one Genie Agent instead, change the MCP URL to `/api/2.0/mcp/genie/<genie-space-id>`.
- The created Genie Agent ID and per-agent MCP URL are saved as `DATABRICKS_GENIE_SPACE_ID` and `DATABRICKS_GENIE_AGENT_MCP_URL`.
- Genie Ontology is enriched indirectly by the documented table metadata and Genie Agent instructions; direct ontology configuration has no public API.
