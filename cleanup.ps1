param(
    [string]$ResourceGroup = "rg-kong-maf-demo"
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Stop-DemoProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$Patterns
    )

    $processes = Get-CimInstance Win32_Process | Where-Object {
        $commandLine = $_.CommandLine
        if (-not $commandLine) {
            return $false
        }

        foreach ($pattern in $Patterns) {
            if ($commandLine -match $pattern) {
                return $true
            }
        }

        return $false
    }

    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "============================================"
Write-Host "  Kong + MAF Demo -- Cleanup"
Write-Host "============================================"

Write-Host "[1/3] Stopping Kong..."
if (Get-Command docker -ErrorAction SilentlyContinue) {
    Push-Location (Join-Path $rootDir "kong")
    try {
        docker compose down
    } finally {
        Pop-Location
    }
} else {
    Write-Host "  Docker not installed; skipping Kong shutdown."
}

Write-Host "[2/3] Stopping MAF server..."
Stop-DemoProcess -Patterns @(
    'server\.py',
    'hosted_main\.py',
    'uvicorn(\.exe)? .*server:app'
)

Write-Host "[3/3] Deleting Azure resource group $ResourceGroup..."
az group delete --name $ResourceGroup --yes --no-wait

Write-Host "Cleanup initiated."
