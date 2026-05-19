param(
    [string]$ResourceGroup = "",
    [string]$Location = "eastus2",
    [string]$AcrName = "",
    [string]$ContainerAppEnvironmentName = "cae-kong-maf-demo",
    [string]$ContainerAppName = "kong-maf-gateway",
    [string]$LogAnalyticsWorkspaceName = "law-kong-maf-demo",
    [string]$HostedAgentName = "kong-maf-hosted-agent",
    [string]$ImageRepository = "kong-maf-gateway",
    [string]$ImageTag = (Get-Date -Format "yyyyMMddHHmmss")
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

function Set-EnvFileValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $escapedName = [regex]::Escape($Name)
    $lines = if (Test-Path $Path) { Get-Content $Path } else { @() }
    $updated = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "^$escapedName=") {
            $lines[$i] = "$Name=$Value"
            $updated = $true
        }
    }

    if (-not $updated) {
        $lines += "$Name=$Value"
    }

    Set-Content -Path $Path -Value $lines -Encoding ascii
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

if (-not $ResourceGroup) {
    throw "Resource group is required. Pass -ResourceGroup or set AZURE_RESOURCE_GROUP in agent/.env."
}

if (-not $env:FOUNDRY_PROJECT_ENDPOINT) {
    throw "FOUNDRY_PROJECT_ENDPOINT is required in agent/.env."
}

$foundryResourceName = $env:FOUNDRY_RESOURCE_NAME

if (-not $AcrName) {
    $suffix = (($foundryResourceName -replace '[^a-zA-Z0-9]', '').ToLower())
    if ($suffix.Length -gt 34) {
        $suffix = $suffix.Substring(0, 34)
    }
    $AcrName = "$($suffix)acr"
}

$acr = az acr show --name $AcrName --resource-group $ResourceGroup --output json 2>$null
if (-not $acr) {
    throw "ACR $AcrName was not found. Run infra/deploy_hosted_agent.ps1 first."
}

$acrJson = $acr | ConvertFrom-Json
$acrId = $acrJson.id
$acrLoginServer = $acrJson.loginServer
$imageRef = "$acrLoginServer/$ImageRepository`:$ImageTag"

Write-Host "============================================"
Write-Host "  Kong Gateway Azure Deployment"
Write-Host "============================================"
Write-Host "Resource group:            $ResourceGroup"
Write-Host "Location:                  $Location"
Write-Host "Container Apps env:        $ContainerAppEnvironmentName"
Write-Host "Container App:             $ContainerAppName"
Write-Host "Hosted agent name:         $HostedAgentName"
Write-Host "Kong image:                $imageRef"
Write-Host ""

Write-Host "[1/6] Building the Kong Azure image in ACR..."
$kongSourceDir = Join-Path $rootDir "kong"
Push-Location $kongSourceDir
try {
    az acr build `
        --registry $AcrName `
        --image "$ImageRepository`:$ImageTag" `
        --platform linux/amd64 `
        --no-logs `
        --file azure.Dockerfile `
        . | Out-Host
} finally {
    Pop-Location
}
if ($LASTEXITCODE -ne 0) {
    throw "az acr build failed for Kong gateway image."
}

$workspace = az monitor log-analytics workspace show `
    --resource-group $ResourceGroup `
    --workspace-name $LogAnalyticsWorkspaceName `
    --output json 2>$null

if (-not $workspace) {
    Write-Host "[2/6] Creating Log Analytics workspace..."
    az monitor log-analytics workspace create `
        --resource-group $ResourceGroup `
        --workspace-name $LogAnalyticsWorkspaceName `
        --location $Location `
        --output table | Out-Host
    $workspace = az monitor log-analytics workspace show `
        --resource-group $ResourceGroup `
        --workspace-name $LogAnalyticsWorkspaceName `
        --output json
}

$workspaceJson = $workspace | ConvertFrom-Json
$workspaceId = $workspaceJson.customerId
$workspaceKey = az monitor log-analytics workspace get-shared-keys `
    --resource-group $ResourceGroup `
    --workspace-name $LogAnalyticsWorkspaceName `
    --query primarySharedKey `
    --output tsv

$containerEnv = az containerapp env show `
    --resource-group $ResourceGroup `
    --name $ContainerAppEnvironmentName `
    --output json 2>$null

if (-not $containerEnv) {
    Write-Host "[3/6] Creating Container Apps environment..."
    az containerapp env create `
        --name $ContainerAppEnvironmentName `
        --resource-group $ResourceGroup `
        --location $Location `
        --logs-workspace-id $workspaceId `
        --logs-workspace-key $workspaceKey `
        --output table | Out-Host
}

$existingApp = az containerapp show `
    --resource-group $ResourceGroup `
    --name $ContainerAppName `
    --output json 2>$null

if (-not $existingApp) {
    Write-Host "[4/6] Creating Kong Container App..."
    az containerapp create `
        --name $ContainerAppName `
        --resource-group $ResourceGroup `
        --environment $ContainerAppEnvironmentName `
        --image $imageRef `
        --target-port 8000 `
        --ingress external `
        --transport auto `
        --system-assigned `
        --registry-server $acrLoginServer `
        --registry-identity system `
        --cpu 1.0 `
        --memory 2Gi `
        --min-replicas 1 `
        --max-replicas 1 `
        --env-vars `
            "FOUNDRY_PROJECT_ENDPOINT=$($env:FOUNDRY_PROJECT_ENDPOINT)" `
            "FOUNDRY_HOSTED_AGENT_NAME=$HostedAgentName" `
            "FOUNDRY_AGENT_API_VERSION=v1" `
            "AZURE_AUTH_SCOPE=https://ai.azure.com/.default" `
        --query properties.configuration.ingress.fqdn `
        --output tsv | Out-Host
} else {
    Write-Host "[4/6] Updating Kong Container App..."
    az containerapp update `
        --name $ContainerAppName `
        --resource-group $ResourceGroup `
        --image $imageRef `
        --set-env-vars `
            "FOUNDRY_PROJECT_ENDPOINT=$($env:FOUNDRY_PROJECT_ENDPOINT)" `
            "FOUNDRY_HOSTED_AGENT_NAME=$HostedAgentName" `
            "FOUNDRY_AGENT_API_VERSION=v1" `
            "AZURE_AUTH_SCOPE=https://ai.azure.com/.default" `
        --output table | Out-Host
}

$appIdentityPrincipalId = az containerapp show `
    --resource-group $ResourceGroup `
    --name $ContainerAppName `
    --query identity.principalId `
    --output tsv

if (-not $appIdentityPrincipalId) {
    throw "Unable to resolve the Kong Container App managed identity."
}

Write-Host "[5/6] Granting ACR pull permission to Kong..."
$existingAcrPull = az role assignment list `
    --scope $acrId `
    --assignee $appIdentityPrincipalId `
    --role "AcrPull" `
    --query "[0].id" `
    --output tsv

if (-not $existingAcrPull) {
    az role assignment create `
        --assignee-object-id $appIdentityPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role "AcrPull" `
        --scope $acrId `
        --output none
}

$accountId = az cognitiveservices account show `
    --name $foundryResourceName `
    --resource-group $ResourceGroup `
    --query "id" `
    --output tsv

Write-Host "[6/6] Granting Foundry access to Kong..."
$assignedRoleName = Ensure-FoundryUserRole -Scope $accountId -AssigneeObjectId $appIdentityPrincipalId

$fqdn = az containerapp show `
    --resource-group $ResourceGroup `
    --name $ContainerAppName `
    --query properties.configuration.ingress.fqdn `
    --output tsv

$gatewayUrl = "https://$fqdn"
Set-EnvFileValue -Path $envFile -Name "AZURE_KONG_GATEWAY_URL" -Value $gatewayUrl
Set-EnvFileValue -Path $envFile -Name "AZURE_HOSTED_AGENT_NAME" -Value $HostedAgentName
Set-EnvFileValue -Path $envFile -Name "DEFAULT_GATEWAY_PROFILE" -Value "azure-hosted"

@"
Kong Azure deployment complete.
Gateway FQDN:           $gatewayUrl
Health endpoint:        $gatewayUrl/health
Responses endpoint:     $gatewayUrl/responses
Container App identity: $appIdentityPrincipalId
Foundry access role:    $assignedRoleName
"@ | Write-Host
