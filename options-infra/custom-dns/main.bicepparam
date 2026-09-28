using 'main.bicep'

param targetSubscriptionId = readEnvironmentVariable('CUSTOM_DNS_TARGET_SUBSCRIPTION_ID', '')
param vnetResourceGroupName = readEnvironmentVariable('CUSTOM_DNS_VNET_RESOURCE_GROUP', '')
param vnetName = readEnvironmentVariable('CUSTOM_DNS_VNET_NAME', '')
param dnsResourceGroupName = readEnvironmentVariable('CUSTOM_DNS_RESOURCE_GROUP', '')
param location = readEnvironmentVariable('CUSTOM_DNS_LOCATION', '')
param deploymentMode = readEnvironmentVariable('CUSTOM_DNS_DEPLOYMENT_MODE', 'Public')
param dnsSubnetName = readEnvironmentVariable('CUSTOM_DNS_SUBNET_NAME', 'custom-dns-aci-subnet')
param dnsSubnetPrefix = readEnvironmentVariable('CUSTOM_DNS_SUBNET_CIDR', '')
param adminPassword = readEnvironmentVariable('CUSTOM_DNS_ADMIN_PASSWORD', '')
param technitiumImage = readEnvironmentVariable('CUSTOM_DNS_IMAGE', 'docker.io/technitium/dns-server:latest')
param ownershipId = readEnvironmentVariable('CUSTOM_DNS_OWNERSHIP_ID', '')
