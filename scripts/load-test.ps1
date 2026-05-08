<#
.SYNOPSIS
  Concurrent load test that validates round-robin behaviour across both
  Content Safety backends.

.DESCRIPTION
  Fires N text-analyze requests in parallel and checks the response
  distribution. We can't observe the upstream backend directly from outside
  APIM, but Application Insights' "Backend service hostname" dimension shows
  the split — this script just asserts that all requests succeed.

  PASS criteria:
    - Zero failed requests.
    - For meaningful round-robin verification, query App Insights afterwards:

      requests
      | where timestamp > ago(10m) and operation_Name contains "content-safety"
      | summarize count() by tostring(customDimensions["Backend service URL"])

.PARAMETER Count
  Total number of requests to send. Default 50.

.PARAMETER Concurrency
  Max simultaneous in-flight requests. Default 10.

.PARAMETER FunctionHostname
  Override the Function hostname. Default: read from `azd env get-values`.

.PARAMETER FunctionKey
  Override the Function host key. Default: read from `az functionapp keys list`.

.EXAMPLE
  pwsh ./scripts/load-test.ps1
  pwsh ./scripts/load-test.ps1 -Count 200 -Concurrency 25
#>
[CmdletBinding()]
param (
    [Parameter()]
    [int] $Count = 50,

    [Parameter()]
    [int] $Concurrency = 10,

    [Parameter()]
    [string] $FunctionHostname,

    [Parameter()]
    [string] $FunctionKey
)

$ErrorActionPreference = 'Stop'

$envValues = azd env get-values | Out-String

function Get-AzdEnvValue {
    param ([string] $Name)
    if ($envValues -match "^${Name}=`"?([^`"`r`n]+?)`"?\s*$") {
        return $matches[1]
    }
    return $null
}

if (-not $FunctionHostname) {
    $FunctionHostname = Get-AzdEnvValue 'FUNCTION_APP_HOSTNAME'
    if (-not $FunctionHostname) {
        throw "Could not resolve FUNCTION_APP_HOSTNAME from ``azd env get-values``. Pass -FunctionHostname explicitly."
    }
}

if (-not $FunctionKey) {
    $functionAppName = Get-AzdEnvValue 'FUNCTION_APP_NAME'
    $resourceGroup   = Get-AzdEnvValue 'AZURE_RESOURCE_GROUP'
    if (-not $functionAppName -or -not $resourceGroup) {
        throw "Could not resolve FUNCTION_APP_NAME / AZURE_RESOURCE_GROUP from ``azd env get-values``. Pass -FunctionKey explicitly."
    }
    Write-Host "Fetching function key for $functionAppName..." -ForegroundColor DarkGray
    $keysJson = az functionapp keys list --name $functionAppName --resource-group $resourceGroup 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az functionapp keys list failed: $keysJson"
    }
    $FunctionKey = ($keysJson | Out-String | ConvertFrom-Json).functionKeys.default
    if (-not $FunctionKey) {
        throw "default function key was empty. Verify the Function App exists and has a default host key."
    }
}

$url = "https://${FunctionHostname}/api/analyze-text"
$body = @{ text = 'Have a wonderful day!' } | ConvertTo-Json -Compress

Write-Host "Firing $Count requests, concurrency=$Concurrency..." -ForegroundColor Cyan

$start = Get-Date
$results = @(1..$Count) | ForEach-Object -Parallel {
    try {
        $r = Invoke-WebRequest `
            -Uri                $using:url `
            -Method             POST `
            -Body               $using:body `
            -ContentType        'application/json' `
            -Headers            @{ 'x-functions-key' = $using:FunctionKey } `
            -SkipHttpErrorCheck `
            -TimeoutSec         60
        [pscustomobject]@{
            Index      = $_
            Status     = $r.StatusCode
            Correlation = $r.Headers['x-correlation-id']
        }
    } catch {
        [pscustomobject]@{
            Index      = $_
            Status     = -1
            Correlation = ''
            Error      = $_.Exception.Message
        }
    }
} -ThrottleLimit $Concurrency

$elapsed = (Get-Date) - $start
$ok      = ($results | Where-Object Status -in 200, 201).Count
$failed  = $Count - $ok

Write-Host ''
Write-Host 'Results' -ForegroundColor Cyan
Write-Host '-------'
Write-Host ('  Sent      : {0}' -f $Count)
Write-Host ('  OK        : {0}' -f $ok)
Write-Host ('  Failed    : {0}' -f $failed)
Write-Host ('  Elapsed   : {0:N1} s' -f $elapsed.TotalSeconds)
Write-Host ('  Throughput: {0:N1} req/s' -f ($Count / $elapsed.TotalSeconds))

if ($failed -gt 0) {
    Write-Host ''
    Write-Host 'FAILED requests:' -ForegroundColor Red
    $results | Where-Object Status -ne 200 | Format-Table -AutoSize
    exit 1
}

Write-Host ''
Write-Host 'Load test PASSED' -ForegroundColor Green
Write-Host ''
Write-Host 'To verify round-robin split, run this KQL against App Insights:' -ForegroundColor Yellow
Write-Host 'requests'
Write-Host '| where timestamp > ago(10m) and operation_Name contains "analyze-text"'
Write-Host '| summarize count() by tostring(customDimensions["Backend service URL"])'
