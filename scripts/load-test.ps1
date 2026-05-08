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
    [string] $FunctionHostname
)

$ErrorActionPreference = 'Stop'

if (-not $FunctionHostname) {
    $values = azd env get-values | Out-String
    # Match the value after FUNCTION_APP_HOSTNAME=, optionally quoted. Use \r\n
    # in the negated character class so we don't match across lines (the
    # previous backtick-escaped form was treated as literal characters inside a
    # single-quoted string and truncated hostnames containing 'r' or 'n').
    if ($values -match 'FUNCTION_APP_HOSTNAME="?([^"\r\n]+?)"?\s*$' -or $values -match 'FUNCTION_APP_HOSTNAME="?([^"\r\n]+?)"?(?:\r?\n|$)') {
        $FunctionHostname = $matches[1]
    } else {
        throw "Could not resolve FUNCTION_APP_HOSTNAME from `azd env get-values`. Pass -FunctionHostname explicitly."
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
