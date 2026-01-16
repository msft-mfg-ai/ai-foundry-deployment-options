using 'main-option-10.bicep'

param appSubscriptionId = readEnvironmentVariable('APP_SUBSCRIPTION_ID', guid(''))
param foundrySubscriptionId = readEnvironmentVariable('FOUNDRY_SUBSCRIPTION_ID', guid(''))
param dnsSubscriptionId = readEnvironmentVariable('DNS_SUBSCRIPTION_ID', guid(''))

