<#
.SYNOPSIS
  End-to-end smoke test. Calls /api/health, /api/analyze-text and
  /api/analyze-image against the deployed Function App.

.PARAMETER Blocklists
  If set, also exercises the blocklist CRUD endpoints (create, add items,
  list, get item, remove items, delete) end-to-end.

.PARAMETER FunctionHostname
  Override the Function hostname. Default: read from `azd env get-values`.

.PARAMETER FunctionKey
  Override the Function host key. Default: read from `az functionapp keys list`.
  The deployed Function App requires `x-functions-key` (FUNCTION auth level).

.EXAMPLE
  pwsh ./scripts/test-deployment.ps1
  pwsh ./scripts/test-deployment.ps1 -Blocklists
#>
[CmdletBinding()]
param (
    [Parameter()]
    [switch] $Blocklists,

    [Parameter()]
    [string] $FunctionHostname,

    [Parameter()]
    [string] $FunctionKey
)

$ErrorActionPreference = 'Stop'

# Resolve azd env values once: the Function App is FUNCTION-auth so we need both
# the hostname and a host key (kept out of source via az CLI lookup).
$envValues = azd env get-values | Out-String

function Get-AzdEnvValue {
    param ([string] $Name)
    # (?m) so ^ and $ anchor on each line, not the whole envValues blob.
    if ($envValues -match "(?m)^${Name}=`"?([^`"`r`n]+?)`"?\s*$") {
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
    $functionAppName  = Get-AzdEnvValue 'FUNCTION_APP_NAME'
    $resourceGroup    = Get-AzdEnvValue 'AZURE_RESOURCE_GROUP'
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

    # Inject the Function host key on every call. Caller-supplied Headers win
    # only if they explicitly set x-functions-key.
    if (-not $Headers.ContainsKey('x-functions-key')) {
        $Headers = $Headers.Clone()
        $Headers['x-functions-key'] = $FunctionKey
    }

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
# 3. Analyze Image (64x64 white PNG — Content Safety rejects images <50px)
# ---------------------------------------------------------------------------
$pngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAACFSURBVHhe7dAhAQAADITA719681SAk0h2cmOwaQCDTQMYbBrAYNMABpsGMNg0gMGmAQw2DWCwaQCDTQMYbBrAYNMABpsGMNg0gMGmAQw2DWCwaQCDTQMYbBrAYNMABpsGMNg0gMGmAQw2DWCwaQCDTQMYbBrAYNMABpsGMNg0gMGmAQw2D0bQw7Koj1gSAAAAAElFTkSuQmCC'
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
