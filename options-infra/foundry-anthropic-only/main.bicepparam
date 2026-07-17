using 'main.bicep'

param claudeOrganizationName = readEnvironmentVariable('CLAUDE_ORGANIZATION_NAME', 'Contoso')
param claudeCountryCode = readEnvironmentVariable('CLAUDE_COUNTRY_CODE', 'US')
param claudeIndustry = readEnvironmentVariable('CLAUDE_INDUSTRY', 'technology')
param principalId = readEnvironmentVariable('AZURE_PRINCIPAL_ID', '')
