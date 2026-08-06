targetScope = 'subscription'

@description('The name of the custom model compliance policy definition')
param cognitiveServicesPolicyName string = 'audit-cognitive-services-model-deployments'

@description('The category of the policy')
param policyCategory string = 'AI model governance'

resource cognitiveServicesPolicyDefinition 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: cognitiveServicesPolicyName
  properties: {
    displayName: 'Audit Cognitive Services Model Deployments'
    policyType: 'Custom'
    mode: 'All'
    description: 'Reports Cognitive Services (Azure OpenAI / AI Foundry) model deployments as non-compliant unless they are in the approved list. Deployments are not blocked.'
    metadata: {
      category: policyCategory
      version: '1.0.0'
    }
    parameters: {
      approvedModels: {
        type: 'Array'
        metadata: {
          displayName: 'Approved AI models'
          description: 'The list of approved models in "modelName,version" format.'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.CognitiveServices/accounts/deployments'
          }
          {
            not: {
              value: '[concat(field(\'Microsoft.CognitiveServices/accounts/deployments/model.name\'), \',\', field(\'Microsoft.CognitiveServices/accounts/deployments/model.version\'))]'
              in: '[parameters(\'approvedModels\')]'
            }
          }
        ]
      }
      then: {
        effect: 'audit'
      }
    }
  }
}

output cognitiveServicesPolicyDefinitionId string = cognitiveServicesPolicyDefinition.id
