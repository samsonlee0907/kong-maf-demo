param(
    [string]$ResourceGroup = "",
    [string]$AcrName = "",
    [string]$ImageRepository = "kong-maf-hosted-agent",
    [string]$AgentName = "kong-maf-hosted-agent",
    [string]$ImageTag = (Get-Date -Format "yyyyMMddHHmmss"),
    [string]$ModelDeploymentName = "",
    [switch]$SkipImageBuild
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $rootDir "agent/.env"

function Ensure-FoundryUserRole {
    param(
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$AssigneeObjectId
    )

    foreach ($roleName in @("Foundry User", "Azure AI User")) {
        $existingRole = az role assignment list `
            --scope $Scope `
            --assignee $AssigneeObjectId `
            --role $roleName `
            --query "[0].id" `
            --output tsv 2>$null

        if ($existingRole) {
            return $roleName
        }

        az role assignment create `
            --assignee-object-id $AssigneeObjectId `
            --assignee-principal-type ServicePrincipal `
            --role $roleName `
            --scope $Scope `
            --output none 2>$null

        if ($LASTEXITCODE -eq 0) {
            return $roleName
        }
    }

    throw "Unable to assign Foundry access at scope $Scope for principal $AssigneeObjectId."
}

if (-not (Test-Path $envFile)) {
    throw "Missing environment file at $envFile. Run infra/provision.ps1 first."
}

Get-Content $envFile | ForEach-Object {
    if ($_ -match '^\s*#' -or $_ -notmatch '=') {
        return
    }
    $name, $value = $_ -split '=', 2
    Set-Item -Path "Env:$name" -Value $value
}

if (-not $ResourceGroup) {
    $ResourceGroup = $env:AZURE_RESOURCE_GROUP
}

if (-not $ModelDeploymentName) {
    $ModelDeploymentName = $env:FOUNDRY_MODEL_DEPLOYMENT_NAME
}

if (-not $ResourceGroup) {
    throw "Resource group is required. Pass -ResourceGroup or set AZURE_RESOURCE_GROUP in agent/.env."
}

if (-not $env:FOUNDRY_PROJECT_ENDPOINT) {
    throw "FOUNDRY_PROJECT_ENDPOINT is required in agent/.env."
}

if (-not $ModelDeploymentName) {
    throw "Model deployment name is required. Pass -ModelDeploymentName or set FOUNDRY_MODEL_DEPLOYMENT_NAME."
}

$subscription = az account show --output json | ConvertFrom-Json
$projectEndpoint = $env:FOUNDRY_PROJECT_ENDPOINT.TrimEnd('/')
$foundryResourceName = $env:FOUNDRY_RESOURCE_NAME
$projectName = $env:FOUNDRY_PROJECT_NAME

if (-not $AcrName) {
    $suffix = (($foundryResourceName -replace '[^a-zA-Z0-9]', '').ToLower())
    if ($suffix.Length -gt 34) {
        $suffix = $suffix.Substring(0, 34)
    }
    $AcrName = "$($suffix)acr"
}

Write-Host "============================================"
Write-Host "  Hosted Agent Deployment"
Write-Host "============================================"
Write-Host "Resource group:         $ResourceGroup"
Write-Host "Foundry resource:       $foundryResourceName"
Write-Host "Foundry project:        $projectName"
Write-Host "ACR:                    $AcrName"
Write-Host "Hosted agent name:      $AgentName"
Write-Host "Image tag:              $ImageTag"
Write-Host "Model deployment:       $ModelDeploymentName"
Write-Host ""

$acr = az acr show --name $AcrName --resource-group $ResourceGroup --output json 2>$null
if (-not $acr) {
    Write-Host "[1/5] Creating Azure Container Registry..."
    az acr create `
        --name $AcrName `
        --resource-group $ResourceGroup `
        --sku Basic `
        --admin-enabled false `
        --output table | Out-Host
    $acr = az acr show --name $AcrName --resource-group $ResourceGroup --output json
}

$acrJson = $acr | ConvertFrom-Json
$acrId = $acrJson.id
$acrLoginServer = $acrJson.loginServer
$imageRef = "$acrLoginServer/$ImageRepository`:$ImageTag"

$projectIdentityPrincipalId = az resource list `
    --resource-group $ResourceGroup `
    --query "[?type=='Microsoft.CognitiveServices/accounts/projects' && name=='$foundryResourceName/$projectName'].identity.principalId | [0]" `
    --output tsv

if (-not $projectIdentityPrincipalId) {
    throw "Unable to resolve the Foundry project managed identity principalId."
}

Write-Host "[2/5] Ensuring the Foundry project identity can pull from ACR..."
$existingAcrPull = az role assignment list `
    --scope $acrId `
    --assignee $projectIdentityPrincipalId `
    --role "AcrPull" `
    --query "[0].id" `
    --output tsv

if (-not $existingAcrPull) {
    az role assignment create `
        --assignee-object-id $projectIdentityPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role "AcrPull" `
        --scope $acrId `
        --output none
}

if (-not $SkipImageBuild) {
    Write-Host "[3/5] Building the hosted-agent image in ACR..."
    $agentSourceDir = Join-Path $rootDir "agent"
    Push-Location $agentSourceDir
    try {
        az acr build `
            --registry $AcrName `
            --image "$ImageRepository`:$ImageTag" `
            --platform linux/amd64 `
            --no-logs `
            --file Dockerfile `
            . | Out-Host
    } finally {
        Pop-Location
    }
    if ($LASTEXITCODE -ne 0) {
        throw "az acr build failed for hosted-agent image."
    }
} else {
    Write-Host "[3/5] Skipping image build."
}

Write-Host "[4/5] Creating or updating the Hosted Agent version..."
$deployScript = Join-Path $rootDir "agent/deploy_hosted_agent.py"
$pythonExe = Join-Path $rootDir "agent/.venv/Scripts/python.exe"

if (-not (Test-Path $pythonExe)) {
    throw "Missing Python virtual environment at $pythonExe. Install agent dependencies first."
}

& $pythonExe $deployScript `
    --agent-name $AgentName `
    --image $imageRef `
    --model-deployment $ModelDeploymentName
if ($LASTEXITCODE -ne 0) {
    throw "Hosted agent create/update failed."
}

$accountId = az cognitiveservices account show `
    --name $foundryResourceName `
    --resource-group $ResourceGroup `
    --query "id" `
    --output tsv

Write-Host "[5/5] Collecting hosted-agent details..."
$env:HOSTED_AGENT_NAME = $AgentName
$agentSummary = @'
from __future__ import annotations

import json
import os

from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential

client = AIProjectClient(
    endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    credential=DefaultAzureCredential(),
    allow_preview=True,
)
agent = client.agents.get(os.environ["HOSTED_AGENT_NAME"])
payload = {
    "name": agent.name,
    "id": agent.id,
    "instance_identity": agent.instance_identity.as_dict() if agent.instance_identity else None,
    "blueprint": agent.blueprint.as_dict() if agent.blueprint else None,
    "versions": agent.versions.as_dict() if agent.versions else None,
}
print(json.dumps(payload))
'@

$agentJson = $agentSummary | & $pythonExe -
$agent = $agentJson | ConvertFrom-Json
$instancePrincipalId = $agent.instance_identity.principal_id
$blueprintPrincipalId = $agent.blueprint.principal_id

if ($instancePrincipalId) {
    $assignedRoleName = Ensure-FoundryUserRole -Scope $accountId -AssigneeObjectId $instancePrincipalId
}

if ($blueprintPrincipalId) {
    $blueprintRoleName = Ensure-FoundryUserRole -Scope $accountId -AssigneeObjectId $blueprintPrincipalId
}

@"
Hosted agent deployment complete.
Agent name:               $($agent.name)
Agent id:                 $($agent.id)
Agent principal id:       $instancePrincipalId
Foundry access role:      $assignedRoleName
Blueprint principal id:   $blueprintPrincipalId
Blueprint access role:    $blueprintRoleName
Image:                    $imageRef
Project endpoint:         $projectEndpoint
Cognitive Services scope: $accountId
"@ | Write-Host
