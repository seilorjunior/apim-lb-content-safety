<#
.SYNOPSIS
  One-shot helper: restart the function app, wait for cold-start, probe
  /api/health, then invoke the load test.
.NOTES
  Used as a workaround for a hung Python worker on the Flex Consumption
  Function App. Not meant for general use — kept under scripts/ only as a
  convenience runner.
#>
[CmdletBinding()]
param (
    [int] $WaitSeconds = 45,
    [int] $Count       = 50,
    [int] $Concurrency = 10
)

$ErrorActionPreference = 'Stop'

$envBlob = azd env get-values | Out-String
function Get-AzdValue {
    param ([string] $Name)
    if ($envBlob -match "(?m)^${Name}=`"?([^`"`r`n]+?)`"?\s*$") {
        return $matches[1]
    }
    return $null
}

$hostname = Get-AzdValue 'FUNCTION_APP_HOSTNAME'
$appName  = Get-AzdValue 'FUNCTION_APP_NAME'
$rg       = Get-AzdValue 'AZURE_RESOURCE_GROUP'
if (-not $hostname -or -not $appName -or -not $rg) {
    throw "Missing env values (hostname=$hostname appName=$appName rg=$rg)."
}

Write-Host "Restarting $appName..." -ForegroundColor Cyan
az functionapp restart --name $appName --resource-group $rg 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "az functionapp restart failed (exit=$LASTEXITCODE)"
}

Write-Host "Restart issued. Waiting ${WaitSeconds}s for cold-start..." -ForegroundColor DarkGray
Start-Sleep -Seconds $WaitSeconds

$keysJson = az functionapp keys list --name $appName --resource-group $rg 2>&1
if ($LASTEXITCODE -ne 0) { throw "az functionapp keys list failed: $keysJson" }
$key = ($keysJson | Out-String | ConvertFrom-Json).functionKeys.default
if (-not $key) { throw "default function key empty." }

$sw = [Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-WebRequest -Uri "https://$hostname/api/health" `
        -Headers @{ 'x-functions-key' = $key } -TimeoutSec 60 -SkipHttpErrorCheck
    $sw.Stop()
    Write-Host ('/api/health => {0} in {1:N1}s' -f $r.StatusCode, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host $r.Content
    if ($r.StatusCode -ge 400) {
        throw "/api/health returned non-success status $($r.StatusCode); aborting load test."
    }
} catch {
    $sw.Stop()
    Write-Host ('/api/health FAILED in {0:N1}s: {1}' -f $sw.Elapsed.TotalSeconds, $_.Exception.Message) -ForegroundColor Red
    throw
}

Write-Host ''
Write-Host "Health OK — running load test (Count=$Count Concurrency=$Concurrency)..." -ForegroundColor Cyan
& "$PSScriptRoot/load-test.ps1" -Count $Count -Concurrency $Concurrency -FunctionHostname $hostname -FunctionKey $key
exit $LASTEXITCODE
