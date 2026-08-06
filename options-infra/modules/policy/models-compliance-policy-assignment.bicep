@description('The name of the model compliance policy assignment')
param cognitiveServicesPolicyAssignmentName string = 'audit-cognitive-services-models-assignment'

@description('Resource ID of the model compliance policy definition')
param cognitiveServicesPolicyDefinitionId string

@description('List of approved models in "modelName,version" format. An empty list reports every model deployment as non-compliant.')
@metadata({
  example: ['gpt-4,0613', 'gpt-35-turbo,0613', 'gpt-4o,2024-05-13']
})
param approvedCognitiveServicesModels array = []

resource cognitiveServicesPolicyAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: cognitiveServicesPolicyAssignmentName
  properties: {
    policyDefinitionId: cognitiveServicesPolicyDefinitionId
    parameters: {
      approvedModels: {
        value: approvedCognitiveServicesModels
      }
    }
    displayName: 'Audit Cognitive Services Model Deployments'
    description: 'Reports Azure OpenAI / AI Foundry model deployments as non-compliant unless they are in the approved list. Deployments are not blocked.'
  }
}

output cognitiveServicesPolicyAssignmentId string = cognitiveServicesPolicyAssignment.id
