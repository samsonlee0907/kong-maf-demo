param(
    [int]$AgentPort = 8080
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$templatePath = Join-Path $scriptDir "kong.template.yaml"
$outputPath = Join-Path $scriptDir "kong.yaml"

if (-not (Test-Path $templatePath)) {
    throw "Missing local Kong template at $templatePath"
}

if ($AgentPort -lt 1 -or $AgentPort -gt 65535) {
    throw "AgentPort must be between 1 and 65535."
}

$template = Get-Content -Path $templatePath -Raw
$rendered = $template.Replace("__AGENT_UPSTREAM_PORT__", [string]$AgentPort)
Set-Content -Path $outputPath -Value $rendered -Encoding ascii

Write-Host "Rendered kong.yaml with FastAPI upstream port $AgentPort"
Write-Host "Output: $outputPath"
