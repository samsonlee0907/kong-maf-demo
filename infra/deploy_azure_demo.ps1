param(
    [string]$HostedAgentName = "kong-maf-hosted-agent",
    [string]$GatewayAppName = "kong-maf-gateway",
    [string]$Location = "eastus2"
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent $PSScriptRoot
$hostedScript = Join-Path $PSScriptRoot "deploy_hosted_agent.ps1"
$kongScript = Join-Path $PSScriptRoot "deploy_kong_azure.ps1"

& $hostedScript -AgentName $HostedAgentName
& $kongScript -HostedAgentName $HostedAgentName -ContainerAppName $GatewayAppName -Location $Location
