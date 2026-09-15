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

.PARAMETER Reliability
  Also checks concurrent mutation exclusion, replay fidelity, conflicting bodies,
  and key scoping across resources. Creates disposable blocklists on both owners.

.PARAMETER FaultInjection
  DESTRUCTIVE: requires -Reliability -DisposableEnvironment. Temporarily changes
  one APIM backend URL to a nonexistent path on its SAME trusted origin and sets
  its circuit breaker to trip on one 404 for five minutes. Requires sustained
  stateless pool success while owned requests fail closed.
  Restores the URL and full circuit-breaker configuration in finally.
  Run only against an isolated disposable deployment;
  interruption or lost management-plane access can require manual restoration.

.PARAMETER DisposableEnvironment
  Explicit acknowledgement that fault injection can disrupt all deployment users.

.PARAMETER RestartFunction
  Requires -FaultInjection. Restarts the Function and checks durable replay and
  both owned reads. This exercises worker-state loss, NOT APIM/Redis cache loss.

.NOTES
  Requires PowerShell 7. No live fault or restart occurs without explicit switches.
  These are black-box checks: they cannot prove upstream dispatch counts, observe
  circuit-breaker state, or simulate a crash between dispatch and blob completion.
  The fault test observes a backend 404 and requires twelve consecutive stateless
  successes after convergence; internal breaker state still requires telemetry.
  No Redis cache is flushed or disconnected; a cache-free deployment may run the
  same suite, but that is not evidence of a live cache-loss experiment.
  Test idempotency records remain in blob storage; there is no global cleanup.
  Expired definitive records are reclaimed only when the same key is reused.
  Pending/uncertain records never expire and require reconciliation before any
  manual deletion; blocklist cleanup does not remove these records.

.EXAMPLE
  pwsh ./scripts/test-deployment.ps1
  pwsh ./scripts/test-deployment.ps1 -Blocklists
  pwsh ./scripts/test-deployment.ps1 -Reliability
  pwsh ./scripts/test-deployment.ps1 -Reliability -FaultInjection -DisposableEnvironment -RestartFunction
#>
[CmdletBinding()]
param (
    [Parameter()]
    [switch] $Blocklists,

    [switch] $Reliability,
    [switch] $FaultInjection,
    [switch] $DisposableEnvironment,
    [switch] $RestartFunction,
    [ValidateRange(2, 32)]
    [int] $Concurrency = 8,

    [Parameter()]
    [string] $FunctionHostname,

    [Parameter()]
    [string] $FunctionKey
)

$ErrorActionPreference = 'Stop'

if ($FaultInjection -and (-not $Reliability -or -not $DisposableEnvironment)) {
    throw '-FaultInjection requires -Reliability and -DisposableEnvironment.'
}
if ($RestartFunction -and -not $FaultInjection) {
    throw '-RestartFunction requires -FaultInjection.'
}
if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 or later is required.'
}

# Resolve azd env values once: the Function App is FUNCTION-auth so we need both
# the hostname and a host key (kept out of source via az CLI lookup).
$envValues = azd env get-values | Out-String
if ($LASTEXITCODE -ne 0) { throw 'azd env get-values failed.' }

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
        [int[]] $ExpectedStatus = @(200, 201, 204),
        [int] $TimeoutSeconds = 60
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
            TimeoutSec         = $TimeoutSeconds
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

function Get-HeaderValue {
    param ($Response, [string] $Name)
    return (@($Response.Headers[$Name]) -join ',')
}

function Assert-Replay {
    param ($Original, $Replay)
    if ((Get-HeaderValue $Replay 'X-Idempotent-Replay') -cne 'true') {
        throw 'Replay must return X-Idempotent-Replay: true.'
    }
    if ($Original.StatusCode -ne $Replay.StatusCode -or
        [string]$Original.Content -cne [string]$Replay.Content) {
        throw 'Replay changed the original status or response body.'
    }
    # Date, server and transport headers can legitimately change on each request.
    foreach ($header in @('content-type', 'location', 'etag', 'last-modified',
            'retry-after', 'x-ms-request-id', 'apim-request-id',
            'x-correlation-id', 'traceparent', 'tracestate')) {
        if ((Get-HeaderValue $Original $header) -cne (Get-HeaderValue $Replay $header)) {
            throw "Replay changed preserved response header '$header'."
        }
    }
    Write-Host '  Replay status, body, preserved headers and marker match.' -ForegroundColor Green
}

function Get-BlocklistOwner {
    param ([string] $Name)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Name))
        if (($digest[0] % 2) -eq 0) { return 'cs-primary' }
        return 'cs-secondary'
    } finally {
        $sha.Dispose()
    }
}

function New-OwnedBlocklistName {
    param ([string] $Owner)
    do { $candidate = "reliability-$([guid]::NewGuid().ToString('N'))" }
    while ((Get-BlocklistOwner $candidate) -ne $Owner)
    return $candidate
}

function Wait-OwnedRead {
    param ([string] $Name, [int] $TimeoutSeconds = 180)
    $wait = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            return Invoke-Test -Name "wait for owned read ($Name)" -Method GET `
                -Url "${base}/api/blocklists/${Name}" -ExpectedStatus 200 -TimeoutSeconds 30
        } catch {
            if ($wait.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw }
            Start-Sleep -Seconds 5
        }
    } while ($true)
}

function Set-BackendConfiguration {
    param ([string] $ResourceUrl, [string] $BackendUrl, $CircuitBreaker)
    $body = @{
        properties = @{ url = $BackendUrl; circuitBreaker = $CircuitBreaker }
    } | ConvertTo-Json -Depth 20 -Compress
    $result = az rest --method patch --url $ResourceUrl --headers 'If-Match=*' --body $body --output none 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Backend configuration update failed: $result" }
}

function Invoke-OwnerFaultTest {
    param ([string] $OwnerName, [string] $SurvivorName)
    $rg = Get-AzdEnvValue 'AZURE_RESOURCE_GROUP'
    $apim = Get-AzdEnvValue 'APIM_SERVICE_NAME'
    if (-not $rg -or -not $apim) { throw 'Fault injection requires AZURE_RESOURCE_GROUP and APIM_SERVICE_NAME.' }
    if ($FunctionHostname -ne (Get-AzdEnvValue 'FUNCTION_APP_HOSTNAME')) {
        throw 'Fault injection requires FunctionHostname to match the current azd environment.'
    }
    $serviceId = az apim show --name $apim --resource-group $rg --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $serviceId) { throw 'Could not resolve APIM resource ID.' }
    $owner = Get-BlocklistOwner $OwnerName
    $resourceUrl = "${serviceId}/backends/${owner}?api-version=2024-05-01"
    $backendJson = az rest --method get --url $resourceUrl --output json
    if ($LASTEXITCODE -ne 0) { throw 'Could not read original APIM backend.' }
    $original = ($backendJson | Out-String | ConvertFrom-Json).properties
    $originalUrl = $original.url
    if (-not $originalUrl) { throw 'Original backend URL was empty; refusing fault injection.' }
    $faultUri = [UriBuilder]::new($originalUrl)
    $faultUri.Path = $faultUri.Path.TrimEnd('/') + "/copilot-fault-$([guid]::NewGuid().ToString('N'))"
    $faultUrl = $faultUri.Uri.AbsoluteUri
    if ($faultUri.Uri.Authority -ne ([Uri]$originalUrl).Authority -or $faultUri.Scheme -ne 'https') {
        throw 'Fault URL must remain on the original trusted HTTPS origin.'
    }
    $faultBreaker = @{
        rules = @(@{
            name = 'deployment-test-404'
            failureCondition = @{
                count = 1
                interval = 'PT1M'
                statusCodeRanges = @(@{ min = 404; max = 404 })
            }
            tripDuration = 'PT5M'
            acceptRetryAfter = $false
        })
    }
    $breakerBackup = $original.circuitBreaker | ConvertTo-Json -Depth 20 -Compress
    Write-Warning "Changing $owner temporarily. Manual recovery if interrupted: URL=$originalUrl; circuitBreaker=$breakerBackup"
    $beforeFault = Invoke-Test -Name 'owner baseline before fault' -Method GET `
        -Url "${base}/api/blocklists/${OwnerName}" -ExpectedStatus 200
    try {
        Set-BackendConfiguration $resourceUrl $faultUrl $faultBreaker
        $convergence = [System.Diagnostics.Stopwatch]::StartNew()
        $observed404 = $false
        do {
            $prime = Invoke-Test -Name 'prime owner 404 circuit breaker' -Method GET `
                -Url "${base}/api/blocklists/${OwnerName}" `
                -ExpectedStatus (@(200, 404) + (500..599)) -TimeoutSeconds 30
            if ($prime.StatusCode -eq 404) { $observed404 = $true; break }
            Start-Sleep -Seconds 5
        } while ($convergence.Elapsed.TotalSeconds -lt 180)
        if (-not $observed404) { throw 'Did not observe the injected backend 404 within the convergence window.' }

        Invoke-Test -Name 'unavailable owner read must not reroute' -Method GET `
            -Url "${base}/api/blocklists/${OwnerName}" -ExpectedStatus (@(404) + (500..599)) | Out-Null
        Invoke-Test -Name 'other owner remains readable' -Method GET `
            -Url "${base}/api/blocklists/${SurvivorName}" -ExpectedStatus 200 | Out-Null
        Invoke-Test -Name 'unavailable owner mutation must not reroute' -Method PATCH `
            -Url "${base}/api/blocklists/${OwnerName}" `
            -Body '{"description":"must not reach the other owner"}' `
            -Headers @{ 'Idempotency-Key' = [guid]::NewGuid().ToString('N') } `
            -ExpectedStatus (@(404) + (500..599)) | Out-Null

        # Separate POSTs, never retries of an individual request. Allow propagation
        # failures, but require a sustained healthy streak rather than one survivor hit.
        $poolWait = [System.Diagnostics.Stopwatch]::StartNew()
        $consecutiveSuccesses = 0
        $probes = 0
        do {
            $probes++
            $probe = Invoke-Test -Name "stateless failover probe $probes" -Method POST `
                -Url "${base}/api/analyze-text" -Body $textBody `
                -ExpectedStatus (@(200, 404) + (500..599)) -TimeoutSeconds 15
            if ($probe.StatusCode -eq 200) { $consecutiveSuccesses++ }
            else { $consecutiveSuccesses = 0 }
            if ($consecutiveSuccesses -eq 12) { break }
            Start-Sleep -Seconds 1
        } while ($poolWait.Elapsed.TotalSeconds -lt 120)
        if ($consecutiveSuccesses -ne 12) {
            throw 'Pool did not converge to twelve consecutive 200 responses while one backend was faulted.'
        }
        Invoke-Test -Name 'owner still fails closed after pool convergence' -Method GET `
            -Url "${base}/api/blocklists/${OwnerName}" -ExpectedStatus (@(404) + (500..599)) | Out-Null
        Write-Host "Stateless failover: twelve consecutive 200 responses after $probes probes; owner remains unavailable."
        Write-Warning 'This is black-box failover coverage; exact breaker state and dispatch counts still require APIM telemetry.'
    } finally {
        $restored = $false
        for ($attempt = 0; $attempt -lt 3 -and -not $restored; $attempt++) {
            try {
                Set-BackendConfiguration $resourceUrl $originalUrl $original.circuitBreaker
                $restored = $true
            } catch {
                Write-Warning "Backend restoration attempt failed: $_"
                if ($attempt -lt 2) { Start-Sleep -Seconds 5 }
            }
        }
        if (-not $restored) {
            throw "CRITICAL: restore $owner manually: URL=$originalUrl; circuitBreaker=$breakerBackup"
        }
        # Gateway propagation and the injected five-minute trip may outlive PATCH.
        $afterFault = Wait-OwnedRead $OwnerName -TimeoutSeconds 360
        if (($beforeFault.Content | ConvertFrom-Json).description -cne
            ($afterFault.Content | ConvertFrom-Json).description) {
            throw 'Owned blocklist changed during the unavailable-owner mutation.'
        }
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
if ($Blocklists -or $Reliability) {
    $name = "smoke-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    if ($Reliability) { $name = New-OwnedBlocklistName 'cs-primary' }
    $idemKey = [guid]::NewGuid().ToString('N')
    $cleanupNames = [System.Collections.Generic.List[string]]::new()
    $cleanupNames.Add($name)
    $testsCompleted = $false

    try {
    $createBody = @{ description = 'smoke-test blocklist' } | ConvertTo-Json -Compress
    $created = Invoke-Test -Name 'upsert-blocklist' -Method PATCH `
        -Url     "${base}/api/blocklists/${name}" `
        -Body    $createBody `
        -Headers @{ 'Idempotency-Key' = $idemKey } `
        -ExpectedStatus 201, 200

    $replay = Invoke-Test -Name 'upsert-blocklist (replay)' -Method PATCH `
        -Url     "${base}/api/blocklists/${name}" `
        -Body    $createBody `
        -Headers @{ 'Idempotency-Key' = $idemKey } `
        -ExpectedStatus 201, 200
    Assert-Replay $created $replay

    $addBody = @{ blocklistItems = @(@{ description = 'foo'; text = 'foobar' }) } | ConvertTo-Json -Compress
    $added = Invoke-Test -Name 'add-items' -Method POST `
        -Url  "${base}/api/blocklists/${name}/items:add" `
        -Body $addBody -ExpectedStatus 200, 201

    Invoke-Test -Name 'list-items' -Method GET `
        -Url "${base}/api/blocklists/${name}/items" | Out-Null

    if ($Reliability) {
        Invoke-Test -Name 'same key conflicting body' -Method PATCH `
            -Url "${base}/api/blocklists/${name}" `
            -Body '{"description":"conflicting description"}' `
            -Headers @{ 'Idempotency-Key' = $idemKey } -ExpectedStatus 422 | Out-Null

        $otherName = New-OwnedBlocklistName 'cs-secondary'
        $cleanupNames.Add($otherName)
        $otherCreated = Invoke-Test -Name 'same key different resource' -Method PATCH `
            -Url "${base}/api/blocklists/${otherName}" -Body $createBody `
            -Headers @{ 'Idempotency-Key' = $idemKey } -ExpectedStatus 200, 201
        if ((Get-HeaderValue $otherCreated 'X-Idempotent-Replay') -eq 'true') {
            throw 'Same key on a different resource incorrectly replayed.'
        }
        foreach ($ownedName in @($name, $otherName)) {
            Invoke-Test -Name "owned read ($ownedName)" -Method GET `
                -Url "${base}/api/blocklists/${ownedName}" -ExpectedStatus 200 | Out-Null
        }
        $ownedAnalyzeBody = @{
            text = 'foobar'
            blocklistNames = @($name)
        } | ConvertTo-Json -Compress
        # Item matching can lag writes; this checks owned routing, not index freshness.
        Invoke-Test -Name 'analyze-text using primary-owned blocklist' -Method POST `
            -Url "${base}/api/analyze-text" -Body $ownedAnalyzeBody -ExpectedStatus 200 | Out-Null
        $secondaryAnalyzeBody = @{
            text = 'Have a wonderful day!'
            blocklistNames = @($otherName)
        } | ConvertTo-Json -Compress
        Invoke-Test -Name 'analyze-text using secondary-owned blocklist' -Method POST `
            -Url "${base}/api/analyze-text" -Body $secondaryAnalyzeBody -ExpectedStatus 200 | Out-Null
        $mixedAnalyzeBody = @{
            text = 'foobar'
            blocklistNames = @($name, $otherName)
        } | ConvertTo-Json -Compress
        Invoke-Test -Name 'analyze-text rejects mixed blocklist owners' -Method POST `
            -Url "${base}/api/analyze-text" -Body $mixedAnalyzeBody -ExpectedStatus 400 | Out-Null

        $updateKey = [guid]::NewGuid().ToString('N')
        $updateBody = '{"description":"updated reliability blocklist"}'
        $updated = Invoke-Test -Name 'update existing blocklist' -Method PATCH `
            -Url "${base}/api/blocklists/${name}" -Body $updateBody `
            -Headers @{ 'Idempotency-Key' = $updateKey } -ExpectedStatus 200, 201
        $updateReplay = Invoke-Test -Name 'update replay' -Method PATCH `
            -Url "${base}/api/blocklists/${name}" -Body $updateBody `
            -Headers @{ 'Idempotency-Key' = $updateKey } -ExpectedStatus $updated.StatusCode
        Assert-Replay $updated $updateReplay
        if ($updated.StatusCode -ne 200) {
            Write-Warning "200 update replay case not exercised: service returned $($updated.StatusCode)."
        }

        $url = "${base}/api/blocklists/${name}/items:add"
        $concurrentKey = [guid]::NewGuid().ToString('N')
        $itemText = "concurrent-$([guid]::NewGuid().ToString('N'))"
        $concurrentBody = @{ blocklistItems = @(@{ text = $itemText }) } | ConvertTo-Json -Compress
        # Shared gate releases requests only after all runspaces are ready.
        $gate = [System.Threading.CountdownEvent]::new($Concurrency)
        try {
            $results = @(1..$Concurrency | ForEach-Object -Parallel {
                $sharedGate = $using:gate
                try {
                    $null = $sharedGate.Signal()
                    if (-not $sharedGate.Wait([TimeSpan]::FromSeconds(30))) {
                        throw 'Concurrent start gate timed out.'
                    }
                    $response = Invoke-WebRequest -Uri $using:url -Method POST `
                        -Body $using:concurrentBody -ContentType 'application/json' `
                        -Headers @{ 'x-functions-key' = $using:FunctionKey; 'Idempotency-Key' = $using:concurrentKey } `
                        -SkipHttpErrorCheck -TimeoutSec 60
                    [pscustomobject]@{
                        StatusCode = [int]$response.StatusCode
                        Content = $response.Content
                        Headers = $response.Headers
                        Error = $null
                    }
                } catch {
                    [pscustomobject]@{ StatusCode = -1; Content = ''; Headers = @{}; Error = "$_" }
                }
            } -ThrottleLimit $Concurrency)
        } finally {
            $gate.Dispose()
        }
        $fresh = @($results | Where-Object {
            $_.StatusCode -in 200, 201 -and (Get-HeaderValue $_ 'X-Idempotent-Replay') -ne 'true'
        })
        if ($results.Count -ne $Concurrency -or $fresh.Count -ne 1) {
            throw "Expected exactly one fresh concurrent success; got $($fresh.Count). Statuses: $($results.StatusCode -join ','). Errors: $($results.Error -join ';')"
        }
        foreach ($result in $results) {
            if ($result.StatusCode -eq 409) { continue }
            if ($result.StatusCode -notin 200, 201) {
                throw "Concurrent call failed unexpectedly: status $($result.StatusCode); $($result.Error)"
            }
            if ((Get-HeaderValue $result 'X-Idempotent-Replay') -eq 'true') {
                Assert-Replay $fresh[0] $result
            }
        }
        $completedReplay = Invoke-Test -Name 'concurrent operation completed replay' -Method POST `
            -Url $url -Body $concurrentBody -Headers @{ 'Idempotency-Key' = $concurrentKey } `
            -ExpectedStatus $fresh[0].StatusCode
        Assert-Replay $fresh[0] $completedReplay
        $itemsResponse = Invoke-Test -Name 'verify single concurrent item' -Method GET `
            -Url "${base}/api/blocklists/${name}/items" -ExpectedStatus 200
        $matchingItems = @(($itemsResponse.Content | ConvertFrom-Json).value | Where-Object text -CEQ $itemText)
        if ($matchingItems.Count -ne 1) { throw "Expected one matching item; got $($matchingItems.Count)." }

        $itemIds = @((($added.Content | ConvertFrom-Json).blocklistItems).blocklistItemId)
        if ($itemIds.Count -ne 1 -or -not $itemIds[0]) { throw 'Add-items did not return a blocklistItemId.' }
        $removeBody = @{ blocklistItemIds = $itemIds } | ConvertTo-Json -Compress
        $removeKey = [guid]::NewGuid().ToString('N')
        $removed = Invoke-Test -Name 'remove-items' -Method POST `
            -Url "${base}/api/blocklists/${name}/items:remove" -Body $removeBody `
            -Headers @{ 'Idempotency-Key' = $removeKey } -ExpectedStatus 200, 204
        $removeReplay = Invoke-Test -Name 'remove-items replay' -Method POST `
            -Url "${base}/api/blocklists/${name}/items:remove" -Body $removeBody `
            -Headers @{ 'Idempotency-Key' = $removeKey } -ExpectedStatus $removed.StatusCode
        Assert-Replay $removed $removeReplay
        if ($removed.StatusCode -ne 204) {
            Write-Warning "204 remove-items replay case not exercised: service returned $($removed.StatusCode)."
        }

        if ($RestartFunction) {
            if ($FunctionHostname -ne (Get-AzdEnvValue 'FUNCTION_APP_HOSTNAME')) {
                throw 'Restart requires FunctionHostname to match the current azd environment.'
            }
            $app = Get-AzdEnvValue 'FUNCTION_APP_NAME'
            $rg = Get-AzdEnvValue 'AZURE_RESOURCE_GROUP'
            if (-not $app -or -not $rg) { throw 'Restart requires FUNCTION_APP_NAME and AZURE_RESOURCE_GROUP.' }
            az functionapp restart --name $app --resource-group $rg
            if ($LASTEXITCODE -ne 0) { throw 'Function restart failed.' }
            Start-Sleep -Seconds 45
            foreach ($ownedName in @($name, $otherName)) { Wait-OwnedRead $ownedName | Out-Null }
            $afterRestart = Invoke-Test -Name 'durable replay after worker restart' -Method POST `
                -Url $url -Body $concurrentBody -Headers @{ 'Idempotency-Key' = $concurrentKey } `
                -ExpectedStatus $fresh[0].StatusCode
            Assert-Replay $fresh[0] $afterRestart
            Write-Host 'Worker restart replay and both owned reads passed; APIM/Redis cache loss was not injected.'
        } else {
            Write-Host 'SKIPPED worker-state-loss test (requires -RestartFunction with fault-injection acknowledgement).'
        }
        if ($FaultInjection) {
            Invoke-OwnerFaultTest $name $otherName
        } else {
            Write-Host 'SKIPPED backend outage and survivor probes (requires -FaultInjection -DisposableEnvironment).'
        }
        Write-Host 'Not covered: dispatch counts, interrupted in-flight recovery, live APIM/Redis cache loss, observed breaker state.'
    }
    $testsCompleted = $true
    } finally {
        $cleanupFailed = $false
        foreach ($cleanupName in $cleanupNames) {
            try {
                Invoke-Test -Name "cleanup ($cleanupName)" -Method DELETE `
                    -Url "${base}/api/blocklists/${cleanupName}" `
                    -Headers @{ 'Idempotency-Key' = [guid]::NewGuid().ToString('N') } `
                    -ExpectedStatus 200, 204, 404 | Out-Null
            } catch {
                $cleanupFailed = $true
                Write-Warning "Could not clean up blocklist ${cleanupName}: $_"
            }
        }
        if ($cleanupFailed -and $testsCompleted) { throw 'Tests passed but blocklist cleanup failed.' }
    }
}

Write-Host ''
Write-Host 'Requested deployment tests PASSED' -ForegroundColor Green
