param accountName string
param raiPolicyName string = 'Custom-Guardrail'
param tags object = {}

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: accountName
}

var promptCompletionSources = [
  'Prompt'
  'Completion'
]

var agentSources = [
  'Prompt'
  'PreToolCall'
  'PostToolCall'
  'Completion'
]

var harmFilters = [
  'Hate'
  'Sexual'
  'Selfharm'
  'Violence'
]

var piiFilters = [
  'ABA routing number Protection'
  'Address Protection'
  'Age Protection'
  'Australia bank account number Protection'
  'Australia Company Number Protection'
  'Australia driver\'s license Protection'
  'Australia medical account number Protection'
  'Australia passport number Protection'
  'Australia tax file number Protection'
  'Australian business number Protection'
  'Azure DocumentDB Auth Key Protection'
  'Azure IAAS Database Connection String and Azure SQL Connection String Protection'
  'Azure IoT Connection String Protection'
  'Azure Publish Setting Password Protection'
  'Azure Redis Cache Connection String Protection'
  'Azure SAS Protection'
  'Azure Service Bus Connection String Protection'
  'Azure Storage Account Key Protection'
  'Azure Storage Account Key (Generic) Protection'
  'Canada bank account number Protection'
  'Canada driver\'s license number Protection'
  'Canada health service number Protection'
  'Canada passport number Protection'
  'Credit card Protection'
  'Email Protection'
  'EU debit card number Protection'
  'EU driver\'s license number Protection'
  'EU national identification number Protection'
  'EU passport number Protection'
  'International Banking Account Number (IBAN) Protection'
  'IP Address Protection'
  'Name Protection'
  'Phone Number Protection'
  'SQL Server Connection String Protection'
  'SWIFT code Protection'
  'U.K. Driver\'s License Number Protection'
  'U.K. Electoral Roll Number Protection'
  'U.K. National Health Service (NHS) Number Protection'
  'U.K. National Insurance Number (NINO) Protection'
  'U.K. Unique Taxpayer Reference Number Protection'
  'U.S. Bank Account Number Protection'
  'U.S. Driver\'s License Number Protection'
  'U.S. Drug Enforcement Agency (DEA) Number Protection'
  'U.S. Individual Taxpayer Identification Number (ITIN) Protection'
  'U.S. or U.K. Passport Number Protection'
  'U.S. Social Security Number (SSN) Protection'
]

var harmContentFilters = [
  for i in range(0, length(harmFilters) * length(promptCompletionSources)): {
    name: harmFilters[i / length(promptCompletionSources)]
    source: promptCompletionSources[i % length(promptCompletionSources)]
    severityThreshold: 'Medium'
    blocking: true
    enabled: true
  }
]

var profanityContentFilters = [
  for source in promptCompletionSources: {
    name: 'Profanity'
    source: source
    blocking: true
    enabled: true
  }
]

var piiContentFilters = [
  for i in range(0, length(piiFilters) * length(agentSources)): {
    name: piiFilters[i / length(agentSources)]
    source: agentSources[i % length(agentSources)]
    blocking: true
    enabled: true
  }
]

resource raiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2026-05-15-preview' = {
  parent: account
  name: raiPolicyName
  tags: tags
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Default'
    egressPolicy: {
      defaultAction: 'Deny'
      mode: 'Enforced'
      rules: []
    }
    contentFilters: concat(
      harmContentFilters,
      [
        {
          name: 'Jailbreak'
          source: 'Prompt'
          blocking: true
          enabled: true
        }
        {
          name: 'Protected Material Text'
          source: 'Completion'
          blocking: true
          enabled: true
        }
        {
          name: 'Protected Material Code'
          source: 'Completion'
          blocking: true
          enabled: true
        }
      ],
      profanityContentFilters,
      [
        {
          name: 'Indirect Attack Spotlighting'
          source: 'Prompt'
          blocking: true
          enabled: true
        }
        {
          name: 'Indirect Attack'
          source: 'Prompt'
          blocking: true
          enabled: true
        }
        {
          name: 'Indirect Attack'
          source: 'PostToolCall'
          blocking: true
          enabled: true
        }
        {
          name: 'Task Adherence'
          source: 'PreToolCall'
          blocking: true
          enabled: true
        }
      ],
      piiContentFilters
    )
  }
}
