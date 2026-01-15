@description('The name of the policy assignment for Cognitive Services')
param cognitiveServicesPolicyAssignmentName string = 'block-cognitive-services-models-assignment'

@description('Resource ID of the Cognitive Services Policy Definition (Custom)')
param cognitiveServicesPolicyDefinitionId string


@description('List of allowed models in format "modelName,version". Leave empty to block all deployments.')
@metadata({
  example: ['gpt-4,0613', 'gpt-35-turbo,0613', 'gpt-4o,2024-05-13']
})
param allowedCognitiveServicesModels array = []

// ============================================================================
// Cognitive Services Model Deployments Policy Assignment
// ============================================================================
resource cognitiveServicesPolicyAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: cognitiveServicesPolicyAssignmentName
  properties: {
    policyDefinitionId: cognitiveServicesPolicyDefinitionId
    parameters: {
      allowedModels: {
        value: allowedCognitiveServicesModels
      }
    }
    displayName: 'Block Cognitive Services Model Deployments'
    description: 'This policy blocks Azure OpenAI / AI Foundry model deployments unless they are in the allowed list.'
  }
}

// ============================================================================
// Outputs
// ============================================================================
// output amlPolicyAssignmentId string = amlPolicyAssignment.id
output cognitiveServicesPolicyAssignmentId string = cognitiveServicesPolicyAssignment.id
