$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$kongUrl = if ($env:KONG_URL) { $env:KONG_URL.TrimEnd("/") } else { "http://localhost:8000" }
$agentUrl = if ($env:AGENT_URL) { $env:AGENT_URL.TrimEnd("/") } else { "http://localhost:8080" }

Write-Host "============================================"
Write-Host "  Kong + MAF Demo -- Full Test Suite"
Write-Host "============================================"
Write-Host ""

Write-Host "[Pre-check] Verifying services..."
try {
    Invoke-WebRequest -UseBasicParsing "$kongUrl/health" | Out-Null
    Write-Host "  Kong is reachable"
} catch {
    throw "Kong not reachable at $kongUrl"
}

try {
    Invoke-WebRequest -UseBasicParsing "$agentUrl/health" | Out-Null
    Write-Host "  MAF server is reachable"
} catch {
    throw "MAF server not reachable at $agentUrl"
}

Write-Host ""
python (Join-Path $scriptDir "test_non_sse.py")
Write-Host ""
python (Join-Path $scriptDir "test_sse.py")
