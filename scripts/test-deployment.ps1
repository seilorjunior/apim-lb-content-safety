<#
.SYNOPSIS
  End-to-end smoke test. Calls /api/health, /api/analyze-text and
  /api/analyze-image against the deployed Function App.

.PARAMETER Blocklists
  If set, also exercises the blocklist CRUD endpoints (create, add items,
  list, get item, remove items, delete) end-to-end.

.PARAMETER FunctionHostname
  Override the Function hostname. Default: read from `azd env get-values`.

.EXAMPLE
  pwsh ./scripts/test-deployment.ps1
  pwsh ./scripts/test-deployment.ps1 -Blocklists
#>
[CmdletBinding()]
param (
    [Parameter()]
    [switch] $Blocklists,

    [Parameter()]
    [string] $FunctionHostname
)

$ErrorActionPreference = 'Stop'

if (-not $FunctionHostname) {
    $values = azd env get-values | Out-String
    if ($values -match 'FUNCTION_APP_HOSTNAME="?([^"\r\n]+?)"?\s*$' -or $values -match 'FUNCTION_APP_HOSTNAME="([^"]+)"') {
        $FunctionHostname = $matches[1]
    } else {
        throw "Could not resolve FUNCTION_APP_HOSTNAME from ``azd env get-values``. Pass -FunctionHostname explicitly."
    }
}

$base = "https://${FunctionHostname}"

function Invoke-Test {
    param (
        [string] $Name,
        [string] $Method,
        [string] $Url,
        [string] $Body,
        [hashtable] $Headers = @{},
        [int[]] $ExpectedStatus = @(200, 201, 204)
    )

    Write-Host "[$Name] $Method $Url" -NoNewline
    try {
        $params = @{
            Uri                = $Url
            Method             = $Method
            Headers            = $Headers
            SkipHttpErrorCheck = $true
            TimeoutSec         = 60
        }
        if ($Body) {
            $params.Body = $Body
            $params.ContentType = 'application/json'
        }
        $resp = Invoke-WebRequest @params

        if ($ExpectedStatus -contains $resp.StatusCode) {
            Write-Host " -> $($resp.StatusCode) OK" -ForegroundColor Green
        } else {
            Write-Host " -> $($resp.StatusCode) UNEXPECTED" -ForegroundColor Red
            Write-Host $resp.Content
            throw "[$Name] expected status $($ExpectedStatus -join ',') but got $($resp.StatusCode)"
        }
        return $resp
    } catch {
        Write-Host " -> ERROR: $_" -ForegroundColor Red
        throw
    }
}

# ---------------------------------------------------------------------------
# 1. Health
# ---------------------------------------------------------------------------
Invoke-Test -Name 'health' -Method GET -Url "${base}/api/health" -ExpectedStatus 200 | Out-Null

# ---------------------------------------------------------------------------
# 2. Analyze Text
# ---------------------------------------------------------------------------
$textBody = @{
    text = 'Have a wonderful day!'
} | ConvertTo-Json -Compress

Invoke-Test -Name 'analyze-text' -Method POST `
    -Url  "${base}/api/analyze-text" `
    -Body $textBody | Out-Null

# ---------------------------------------------------------------------------
# 3. Analyze Image (1x1 transparent PNG)
# ---------------------------------------------------------------------------
$pngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='
$imageBody = @{
    image = @{ content = $pngBase64 }
} | ConvertTo-Json -Compress

Invoke-Test -Name 'analyze-image' -Method POST `
    -Url  "${base}/api/analyze-image" `
    -Body $imageBody | Out-Null

# ---------------------------------------------------------------------------
# 4. Optional: blocklist CRUD
# ---------------------------------------------------------------------------
if ($Blocklists) {
    $name = "smoke-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $idemKey = [guid]::NewGuid().ToString('N')

    # Upsert
    $createBody = @{ description = 'smoke-test blocklist' } | ConvertTo-Json -Compress
    Invoke-Test -Name 'upsert-blocklist' -Method PATCH `
        -Url     "${base}/api/blocklists/${name}" `
        -Body    $createBody `
        -Headers @{ 'Idempotency-Key' = $idemKey } `
        -ExpectedStatus 201, 200 | Out-Null

    # Idempotency replay
    $replay = Invoke-Test -Name 'upsert-blocklist (replay)' -Method PATCH `
        -Url     "${base}/api/blocklists/${name}" `
        -Body    $createBody `
        -Headers @{ 'Idempotency-Key' = $idemKey } `
        -ExpectedStatus 201, 200
    if ($replay.Headers['X-Idempotent-Replay'] -ne 'true') {
        Write-Warning 'X-Idempotent-Replay header was NOT returned on second call.'
    } else {
        Write-Host '  X-Idempotent-Replay: true (idempotency works)' -ForegroundColor Green
    }

    # Add items
    $addBody = @{ blocklistItems = @(@{ description = 'foo'; text = 'foobar' }) } | ConvertTo-Json -Compress
    Invoke-Test -Name 'add-items' -Method POST `
        -Url  "${base}/api/blocklists/${name}/items:add" `
        -Body $addBody | Out-Null

    # List
    Invoke-Test -Name 'list-items' -Method GET `
        -Url "${base}/api/blocklists/${name}/items" | Out-Null

    # Delete
    Invoke-Test -Name 'delete-blocklist' -Method DELETE `
        -Url "${base}/api/blocklists/${name}" `
        -ExpectedStatus 204, 200 | Out-Null
}

Write-Host ''
Write-Host 'Smoke test PASSED' -ForegroundColor Green
