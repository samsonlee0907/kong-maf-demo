param(
    [int]$AgentPort = 8080
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw "Docker is not installed or not on PATH. Install Docker Desktop, start it, and retry."
}

try {
    docker info | Out-Null
} catch {
    throw "Docker Desktop is installed but the Docker daemon is not ready. Start Docker Desktop and retry."
}

$existingKong = $false
Push-Location $scriptDir
try {
    $runningServices = docker compose ps --services --status running 2>$null
    $existingKong = $runningServices -contains "kong"
} finally {
    Pop-Location
}

if (-not $existingKong) {
    $port8000Listener = Get-NetTCPConnection -LocalPort 8000 -State Listen -ErrorAction SilentlyContinue
    if ($port8000Listener) {
        $ownerProcess = Get-Process -Id $port8000Listener.OwningProcess -ErrorAction SilentlyContinue
        $ownerLabel = if ($ownerProcess) {
            "$($ownerProcess.ProcessName) (PID $($ownerProcess.Id))"
        } else {
            "PID $($port8000Listener.OwningProcess)"
        }

        throw "Port 8000 is already in use by $ownerLabel. Stop that process or free the port before starting local Kong."
    }
}

$agentListener = Get-NetTCPConnection -LocalPort $AgentPort -State Listen -ErrorAction SilentlyContinue
if (-not $agentListener) {
    Write-Warning "No process is currently listening on port $AgentPort. Kong will start, but requests will fail until the FastAPI server is running on that port."
}

& (Join-Path $scriptDir "render-local-config.ps1") -AgentPort $AgentPort

Push-Location $scriptDir
try {
    docker compose up -d
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Local Kong started on http://127.0.0.1:8000"
Write-Host "Upstream FastAPI port: $AgentPort"
