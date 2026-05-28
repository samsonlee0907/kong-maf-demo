param(
    [ValidateSet("bootstrap", "local", "cloud", "all")]
    [string]$Mode = "bootstrap"
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $rootDir "agent/.env"

$failures = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

function Write-Pass {
    param([string]$Message)
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    $warnings.Add($Message) | Out-Null
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    $failures.Add($Message) | Out-Null
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Get-EnvMap {
    param([string]$Path)

    $map = @{}
    if (-not (Test-Path $Path)) {
        return $map
    }

    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*#' -or $line -notmatch '=') {
            continue
        }

        $name, $value = $line -split '=', 2
        $map[$name.Trim()] = $value.Trim()
    }

    return $map
}

function Require-Command {
    param(
        [string]$Name,
        [string]$Label
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        Write-Fail "$Label is not installed or not on PATH."
        return $false
    }

    Write-Pass "$Label detected."
    return $true
}

function Require-EnvValue {
    param(
        [hashtable]$Values,
        [string]$Name,
        [string]$Hint
    )

    if (-not $Values.ContainsKey($Name) -or [string]::IsNullOrWhiteSpace($Values[$Name])) {
        Write-Fail "$Name is not configured. $Hint"
        return $false
    }

    Write-Pass "$Name is configured."
    return $true
}

Write-Host "============================================"
Write-Host "  Kong + MAF Demo -- Preflight"
Write-Host "============================================"
Write-Host "Mode: $Mode"
Write-Host ""

$hasPython = Require-Command -Name "python" -Label "Python"
if ($hasPython) {
    $pythonVersionText = (& python --version 2>&1).Trim()
    if ($pythonVersionText -match 'Python\s+(\d+)\.(\d+)\.(\d+)') {
        $major = [int]$Matches[1]
        $minor = [int]$Matches[2]
        if ($major -gt 3 -or ($major -eq 3 -and $minor -ge 10)) {
            Write-Pass "Python version is $pythonVersionText."
        } else {
            Write-Fail "Python 3.10+ is required. Found $pythonVersionText."
        }
    } else {
        Write-Warn "Unable to parse Python version output: $pythonVersionText"
    }
}

$hasAz = Require-Command -Name "az" -Label "Azure CLI"
if ($hasAz) {
    try {
        $account = az account show --output json | ConvertFrom-Json
        Write-Pass "Azure CLI is logged in to subscription '$($account.name)' ($($account.id))."
    } catch {
        Write-Fail "Azure CLI is installed but not logged in. Run 'az login'."
    }
}

if ($Mode -in @("local", "all")) {
    $hasDocker = Require-Command -Name "docker" -Label "Docker"
    if ($hasDocker) {
        try {
            $dockerVersion = (& docker --version 2>&1).Trim()
            Write-Pass $dockerVersion
        } catch {
            Write-Warn "Docker is installed but version output could not be read."
        }

        try {
            $composeVersion = (& docker compose version 2>&1).Trim()
            Write-Pass $composeVersion
        } catch {
            Write-Fail "Docker Compose is not available. Install Docker Desktop or Docker Compose."
        }
    }
}

$envValues = Get-EnvMap -Path $envFile

if ($Mode -eq "bootstrap") {
    if (Test-Path $envFile) {
        Write-Pass "Existing environment file found at $envFile."
    } else {
        Write-Warn "agent/.env is not present yet. Run '.\\infra\\provision.ps1' after bootstrap checks pass."
    }
} else {
    if (-not (Test-Path $envFile)) {
        Write-Fail "Missing $envFile. Run '.\\infra\\provision.ps1' first."
    } else {
        Write-Pass "Found environment file at $envFile."
        $null = Require-EnvValue -Values $envValues -Name "FOUNDRY_PROJECT_ENDPOINT" -Hint "Run '.\\infra\\provision.ps1' to generate agent/.env."
        $null = Require-EnvValue -Values $envValues -Name "FOUNDRY_MODEL" -Hint "Run '.\\infra\\provision.ps1' to create the model deployment."
    }
}

if ($Mode -in @("cloud", "all") -and (Test-Path $envFile)) {
    $null = Require-EnvValue -Values $envValues -Name "AZURE_RESOURCE_GROUP" -Hint "Run '.\\infra\\provision.ps1' before cloud deployment."
    $null = Require-EnvValue -Values $envValues -Name "FOUNDRY_RESOURCE_NAME" -Hint "Run '.\\infra\\provision.ps1' before cloud deployment."

    if (-not $envValues.ContainsKey("AZURE_KONG_GATEWAY_URL") -or [string]::IsNullOrWhiteSpace($envValues["AZURE_KONG_GATEWAY_URL"])) {
        Write-Warn "AZURE_KONG_GATEWAY_URL is not set yet. Run '.\\infra\\deploy_azure_demo.ps1' after provisioning."
    } else {
        Write-Pass "AZURE_KONG_GATEWAY_URL is configured."
    }
}

Write-Host ""
if ($warnings.Count -gt 0) {
    Write-Host "Warnings:" -ForegroundColor Yellow
    foreach ($warning in $warnings) {
        Write-Host "  - $warning" -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($failures.Count -gt 0) {
    Write-Host "Preflight failed with $($failures.Count) issue(s)." -ForegroundColor Red
    throw "Resolve the failures above and rerun infra/preflight.ps1."
}

Write-Host "Preflight passed." -ForegroundColor Green
Write-Host ""
switch ($Mode) {
    "bootstrap" {
        Write-Host "Next steps:"
        Write-Host "  1. If agent/.env is missing, run '.\\infra\\provision.ps1'"
        Write-Host "  2. Run '.\\infra\\deploy_azure_demo.ps1' for the cloud path"
        Write-Host "  3. Start '.\\agent\\server.py' for the local portal"
    }
    "local" {
        Write-Host "Next steps:"
        Write-Host "  1. Start the FastAPI host from '.\\agent'"
        Write-Host "  2. Start Docker Compose from '.\\kong'"
        Write-Host "  3. Run '.\\tests\\test_both.ps1'"
    }
    "cloud" {
        Write-Host "Next steps:"
        Write-Host "  1. Run '.\\infra\\deploy_azure_demo.ps1' if cloud resources are not deployed"
        Write-Host "  2. Run 'python .\\tests\\test_cloud_gateway.py'"
        Write-Host "  3. Open the local portal and choose 'Cloud Gateway'"
    }
    default {
        Write-Host "Next steps:"
        Write-Host "  1. Validate the cloud path with 'python .\\tests\\test_cloud_gateway.py'"
        Write-Host "  2. Validate the local path with '.\\tests\\test_both.ps1'"
    }
}
