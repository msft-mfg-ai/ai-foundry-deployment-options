using 'main.bicep'

param genieAgentName = readEnvironmentVariable('GENIE_AGENT_NAME', 'agent-databricks-genie-one')
param databricksPricingTier = readEnvironmentVariable('DATABRICKS_PRICING_TIER', 'premium')
