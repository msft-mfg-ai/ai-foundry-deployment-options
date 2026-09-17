# Add Private CA Trust to an Existing Foundry Account

This guide shows the minimum changes required for an existing Microsoft Foundry account to call an HTTPS endpoint whose certificate is signed by a private or self-signed CA.

## What Foundry needs

Foundry does not need the endpoint private key or PFX. It needs:

1. The public issuing CA certificate in PEM format, stored as a versioned Key Vault secret.
2. The Foundry account managed identity granted `Key Vault Secrets User` on that vault.
3. The Key Vault secret referenced by the Foundry account's `properties.trustedCertificates`.
4. Existing project capability hosts recreated after the trust configuration changes.

The endpoint certificate must:

- contain the endpoint DNS name in its Subject Alternative Name (SAN);
- be currently valid;
- chain to the CA certificate registered with Foundry;
- be reachable and resolvable from the Foundry agent network.

> Private CA support currently uses preview APIs and may require subscription allowlisting and a supported region. The reference implementation uses `canadacentral`.

## 1. Prepare the CA certificate

Export the public root CA, or the required root and intermediate CA certificates, as PEM files:

```text
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
```

Do not upload the endpoint private key, PFX password, or any other private key material.

Verify that the endpoint leaf certificate chains to the CA:

```bash
openssl verify -CAfile root-ca.pem endpoint-leaf.pem
```

## 2. Store the CA PEM in Key Vault

The Key Vault must use Azure RBAC authorization. Upload the PEM as a secret and retain its generated version:

The identity performing the upload must have a data-plane role such as `Key Vault Secrets Officer` on the vault. New role assignments can take several minutes to propagate; if the upload returns `Forbidden`, wait and retry.

```bash
CA_SECRET_ID=$(az keyvault secret set \
  --vault-name "<key-vault-name>" \
  --name "private-root-ca-pem" \
  --file root-ca.pem \
  --encoding utf-8 \
  --content-type "application/x-pem-file" \
  --query id \
  --output tsv)

CA_SECRET_VERSION=${CA_SECRET_ID##*/}
echo "$CA_SECRET_VERSION"
```

Foundry pins the certificate reference to this exact secret version. Uploading a new version does not automatically rotate the certificate used by Foundry.

If Foundry must trust multiple private CAs, upload each public root as a separate Key Vault secret:

```bash
az keyvault secret set \
  --vault-name "<key-vault-name>" \
  --name "private-root-ca-1-pem" \
  --file root-ca-1.pem \
  --encoding utf-8 \
  --content-type "application/x-pem-file"

az keyvault secret set \
  --vault-name "<key-vault-name>" \
  --name "private-root-ca-2-pem" \
  --file root-ca-2.pem \
  --encoding utf-8 \
  --content-type "application/x-pem-file"
```

Add one versioned `certificates` entry for each secret. Foundry loads one PEM certificate from each referenced secret; a concatenated multi-certificate PEM secret can result in only the first root being trusted.

## 3. Grant the Foundry identity access

Find the principal ID of the identity attached to the Foundry account. Use the system-assigned principal ID or the principal ID of the configured user-assigned identity:

```bash
FOUNDRY_PRINCIPAL_ID=$(az resource show \
  --ids "<foundry-account-resource-id>" \
  --api-version "2026-07-15-preview" \
  --query identity.principalId \
  --output tsv)
```

For a user-assigned identity, retrieve its principal ID directly:

```bash
FOUNDRY_PRINCIPAL_ID=$(az identity show \
  --ids "<foundry-user-assigned-identity-resource-id>" \
  --query principalId \
  --output tsv)
```

Grant the identity access at the Key Vault scope:

```bash
az role assignment create \
  --assignee-object-id "$FOUNDRY_PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "<key-vault-resource-id>"
```

The built-in role definition is:

```text
Key Vault Secrets User
4633458b-17de-408a-b874-0445c86b69e6
```

It grants these required data actions:

```text
Microsoft.KeyVault/vaults/secrets/getSecret/action
Microsoft.KeyVault/vaults/secrets/readMetadata/action
```

Allow several minutes for a new role assignment to propagate before creating or recreating capability hosts.

## 4. Bicep changes

Add `trustedCertificates` to the template that already owns the Foundry account. Do not redeclare an existing account with an incomplete resource body because Bicep deploys resources with PUT semantics.

Before changing the property, query and retain any existing certificate references:

```bash
az rest \
  --method get \
  --url "<foundry-account-resource-id>?api-version=2026-07-15-preview" \
  --query "properties.trustedCertificates"
```

Use the preview account API:

```bicep
param keyVaultResourceId string
param caSecretName string
param caSecretVersion string

resource foundry 'Microsoft.CognitiveServices/accounts@2026-07-15-preview' = {
  name: '<existing account name>'
  // Keep the account's existing kind, SKU, identity, location, tags, and properties.
  properties: union(existingAccountProperties, {
    trustedCertificates: [
      {
        keyVaultId: keyVaultResourceId
        certificates: [
          {
            name: caSecretName
            version: caSecretVersion
          }
        ]
      }
    ]
  })
}
```

If Bicep also creates the Key Vault secret, derive the version from its versioned URI:

```bicep
@secure()
param rootCaPem string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: '<key-vault-name>'
}

resource rootCaSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'private-root-ca-pem'
  properties: {
    value: rootCaPem
    contentType: 'application/x-pem-file'
  }
}

var caSecretVersion = last(split(rootCaSecret.properties.secretUriWithVersion, '/'))
```

Create the role assignment at the Key Vault scope:

```bicep
param foundryPrincipalId string

var keyVaultSecretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, foundryPrincipalId, keyVaultSecretsUserRoleId)
  properties: {
    principalId: foundryPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}
```

If the existing Foundry account is not managed by your Bicep template, use an ARM PATCH operation rather than deploying a partial account definition:

```bash
az rest \
  --method patch \
  --url "<foundry-account-resource-id>?api-version=2026-07-15-preview" \
  --headers "Content-Type=application/json" \
  --body '{
    "properties": {
      "trustedCertificates": [
        {
          "keyVaultId": "<key-vault-resource-id>",
          "certificates": [
            {
              "name": "private-root-ca-pem",
              "version": "<secret-version>"
            }
          ]
        }
      ]
    }
  }'
```

Preserve all existing `trustedCertificates` entries when applying this property. The update replaces the list.

## 5. Terraform changes

The AzureRM provider may not expose the preview `trustedCertificates` property. Use AzureRM for the secret and role assignment, and AzAPI for the Foundry account PATCH.

```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "foundry_account_id" {
  type = string
}

variable "foundry_principal_id" {
  type = string
}

variable "key_vault_id" {
  type = string
}

variable "root_ca_pem_path" {
  type = string
}

data "azurerm_subscription" "current" {}

resource "azurerm_key_vault_secret" "private_root_ca" {
  name         = "private-root-ca-pem"
  value        = file(var.root_ca_pem_path)
  content_type = "application/x-pem-file"
  key_vault_id = var.key_vault_id
}

resource "azurerm_role_assignment" "foundry_key_vault_secrets_user" {
  scope              = var.key_vault_id
  principal_id       = var.foundry_principal_id
  role_definition_id = "${data.azurerm_subscription.current.id}/providers/Microsoft.Authorization/roleDefinitions/4633458b-17de-408a-b874-0445c86b69e6"
}

resource "azapi_update_resource" "foundry_private_ca_trust" {
  type        = "Microsoft.CognitiveServices/accounts@2026-07-15-preview"
  resource_id = var.foundry_account_id

  body = {
    properties = {
      trustedCertificates = [
        {
          keyVaultId = var.key_vault_id
          certificates = [
            {
              name    = azurerm_key_vault_secret.private_root_ca.name
              version = azurerm_key_vault_secret.private_root_ca.version
            }
          ]
        }
      ]
    }
  }

  depends_on = [
    azurerm_role_assignment.foundry_key_vault_secrets_user
  ]
}
```

As with Bicep, include any existing trusted certificate entries in the Terraform list so they are not removed.

## 6. Recreate existing capability hosts

Trusted certificates are resolved when a project capability host is provisioned. After adding or rotating a CA:

1. Record the capability host's existing properties, especially any BYO Storage, Cosmos DB, or AI Search configuration.
2. Delete the existing project capability host.
3. Recreate it with the same properties.

Example for a capability host without BYO resource settings:

```bash
CAPABILITY_HOST_ID="<foundry-account-resource-id>/projects/<project-name>/capabilityHosts/<host-name>"
CAPABILITY_HOST_API_VERSION="2026-05-15-preview"

az rest \
  --method delete \
  --url "$CAPABILITY_HOST_ID?api-version=$CAPABILITY_HOST_API_VERSION"

az rest \
  --method put \
  --url "$CAPABILITY_HOST_ID?api-version=$CAPABILITY_HOST_API_VERSION" \
  --headers "Content-Type=application/json" \
  --body '{"properties":{}}'

az rest \
  --method get \
  --url "$CAPABILITY_HOST_ID?api-version=$CAPABILITY_HOST_API_VERSION" \
  --query "{name:name,state:properties.provisioningState}"
```

Do not use the empty properties example if the existing capability host contains customer-provided resource settings.
Continue only after the returned provisioning state is `Succeeded`.

## 7. Verify the configuration

Confirm that the Foundry account references the expected vault, secret, and version:

```bash
az rest \
  --method get \
  --url "<foundry-account-resource-id>?api-version=2026-07-15-preview" \
  --query "properties.trustedCertificates"
```

Confirm the role assignment:

```bash
az role assignment list \
  --assignee-object-id "<foundry-principal-id>" \
  --scope "<key-vault-resource-id>" \
  --query "[?roleDefinitionName=='Key Vault Secrets User'].{role:roleDefinitionName,scope:scope}" \
  --output table
```

Finally, call the private HTTPS endpoint through a Foundry agent tool:

- success proves DNS, routing, endpoint TLS, Key Vault access, account trust, and capability-host refresh are working together;
- an unknown-authority error usually means the wrong CA or secret version is registered, the role assignment is missing, or the capability host was not recreated;
- a hostname mismatch means the endpoint certificate SAN does not contain the hostname used by the Foundry connection.

## Rotation checklist

When rotating the CA:

1. Upload the new CA PEM, creating a new Key Vault secret version.
2. Update `trustedCertificates` to reference the new version.
3. Wait for Key Vault RBAC propagation if the vault or identity changed.
4. Recreate each affected project capability host.
5. Test the endpoint through the Foundry agent.
