targetScope = 'subscription'

// ============================================================================
// Parameters for Cognitive Services Model Deployments Policy (Custom)
// ============================================================================
@description('The name of the custom policy definition for Cognitive Services')
param cognitiveServicesPolicyName string = 'deny-cognitive-services-model-deployments'

@description('The category of the policy')
param policyCategory string = 'AI model governance'

// ============================================================================
// Cognitive Services Model Deployments Policy Definition (Custom)
// ============================================================================
// This policy blocks model deployments in Azure OpenAI / AI Foundry unless 
// they are in the allowed list. Based on:
// https://learn.microsoft.com/en-us/azure/ai-foundry/foundry-models/how-to/configure-deployment-policies
resource cognitiveServicesPolicyDefinition 'Microsoft.Authorization/policyDefinitions@2021-06-01' = {
  name: cognitiveServicesPolicyName
  properties: {
    displayName: 'Deny Cognitive Services Model Deployments'
    policyType: 'Custom'
    mode: 'All'
    description: 'This policy denies model deployments in Cognitive Services (Azure OpenAI / AI Foundry) accounts unless they are in the allowed list.'
    metadata: {
      category: policyCategory
      version: '1.0.0'
    }
    parameters: {
      allowedModels: {
        type: 'Array'
        metadata: {
          displayName: 'Allowed AI models'
          description: 'The list of allowed models to be deployed.'
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
              in: '[parameters(\'allowedModels\')]'
            }
          }
        ]
      }
      then: {
        effect: 'deny'
      }
    }
  }
}


// ============================================================================
// Outputs
// ============================================================================
// output amlPolicyAssignmentId string = amlPolicyAssignment.id
output cognitiveServicesPolicyDefinitionId string = cognitiveServicesPolicyDefinition.id
