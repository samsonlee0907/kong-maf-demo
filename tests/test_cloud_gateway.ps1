$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

python (Join-Path $scriptDir "test_cloud_gateway.py")
