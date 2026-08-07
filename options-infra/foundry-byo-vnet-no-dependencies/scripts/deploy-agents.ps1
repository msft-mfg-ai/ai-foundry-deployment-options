$ErrorActionPreference = "Stop"

Set-Location (Split-Path -Parent $PSScriptRoot)

$environmentName = if ($env:AZURE_ENV_NAME) {
    $env:AZURE_ENV_NAME
}
else {
    azd env get-value AZURE_ENV_NAME
}

try {
    $subscriptionId = azd env get-value AZURE_SUBSCRIPTION_ID -e $environmentName
    $resourceGroup = azd env get-value AZURE_RESOURCE_GROUP -e $environmentName
    $deploymentName = azd env get-value AZURE_OPENAI_CHAT_DEPLOYMENT_NAME -e $environmentName
    $projectIdNoCap = azd env get-value AZURE_AI_PROJECT_ID_NO_CAP -e $environmentName
    $projectIdWithCap = azd env get-value AZURE_AI_PROJECT_ID_WITH_CAP -e $environmentName
    $projectEndpointNoCap = azd env get-value FOUNDRY_PROJECT_ENDPOINT_NO_CAP -e $environmentName
    $projectEndpointWithCap = azd env get-value FOUNDRY_PROJECT_ENDPOINT_WITH_CAP -e $environmentName
    $projectConnectionStrings = azd env get-value project_connection_strings -e $environmentName
    $projectNames = azd env get-value project_names -e $environmentName
    $originalProjectId = azd env get-value AZURE_AI_PROJECT_ID -e $environmentName 2>$null
    if (-not $originalProjectId) {
        $originalProjectId = $projectIdNoCap
    }
    $originalProjectEndpoint = azd env get-value FOUNDRY_PROJECT_ENDPOINT -e $environmentName 2>$null
    if (-not $originalProjectEndpoint) {
        $originalProjectEndpoint = $projectEndpointNoCap
    }

    function Deploy-HostedAgent {
        param(
            [Parameter(Mandatory)] [string] $ServiceName,
            [Parameter(Mandatory)] [string] $ProjectId,
            [Parameter(Mandatory)] [string] $ProjectEndpoint
        )

        azd env set AZURE_AI_PROJECT_ID $ProjectId -e $environmentName | Out-Null
        azd env set FOUNDRY_PROJECT_ENDPOINT $ProjectEndpoint -e $environmentName | Out-Null
        azd deploy $ServiceName -e $environmentName

        $agent = azd ai agent show $ServiceName -e $environmentName --output json | ConvertFrom-Json
        if (-not $agent.instance_identity.principal_id) {
            throw "Agent $ServiceName does not expose an instance identity."
        }

        $scope = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup"
        az role assignment create `
            --assignee-object-id $agent.instance_identity.principal_id `
            --assignee-principal-type ServicePrincipal `
            --role Reader `
            --scope $scope `
            --only-show-errors `
            --output none
    }

    Deploy-HostedAgent `
        -ServiceName "hosted-agent-no-cap" `
        -ProjectId $projectIdNoCap `
        -ProjectEndpoint $projectEndpointNoCap

    Deploy-HostedAgent `
        -ServiceName "hosted-agent-with-cap" `
        -ProjectId $projectIdWithCap `
        -ProjectEndpoint $projectEndpointWithCap

    $env:PROJECT_CONNECTION_STRINGS = $projectConnectionStrings
    $env:PROJECT_NAMES = $projectNames
    $env:AZURE_OPENAI_CHAT_DEPLOYMENT_NAME = $deploymentName
    uv run --project ../../agents_v2 python scripts/create_mcp_prompt_agents.py
}
finally {
    if ($originalProjectId) {
        azd env set AZURE_AI_PROJECT_ID $originalProjectId -e $environmentName | Out-Null
    }
    if ($originalProjectEndpoint) {
        azd env set FOUNDRY_PROJECT_ENDPOINT $originalProjectEndpoint -e $environmentName | Out-Null
    }
}
