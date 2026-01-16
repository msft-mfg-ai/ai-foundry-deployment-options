using 'main.bicep'

var subnetIdValue = readEnvironmentVariable('SUBNET_ID', '')
param subnetId = empty(subnetIdValue) ? null : subnetIdValue
