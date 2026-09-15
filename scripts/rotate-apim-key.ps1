<#
.SYNOPSIS
  Rotate the APIM "function-app" subscription primary key end-to-end.

.DESCRIPTION
  Exercises the Tier 1 KV-reference flow:

    1. Read current key fingerprint from Key Vault (last 4 chars only).
    2. POST .../subscriptions/function-app/regeneratePrimaryKey on APIM.
    3. POST .../subscriptions/function-app/listSecrets to fetch the new primary.
    4. PUT the new value into Key Vault secret `apim-subscription-function-app-key`.
    5. Restart the Function App to force its KV reference cache to refresh
       (otherwise the reference is re-resolved on the ~24 h slot-setting timer).
    6. Smoke-test /api/analyze-text and confirm 200.

  Safe to re-run. Idempotent because each call generates a fresh key, the KV
  secret is set as a new version, and the Function App is restarted regardless.

.PARAMETER DryRun
  Print every step but do NOT regenerate, write, or restart anything.

.PARAMETER SkipSmokeTest
  Skip the post-rotation /api/analyze-text call (e.g. when rotating in a region
  with no Content Safety quota for live calls).

.NOTES
  Required RBAC for the caller:
    * Microsoft.ApiManagement/service/subscriptions/regeneratePrimaryKey/action
    * Microsoft.ApiManagement/service/subscriptions/listSecrets/action
      → covered by "API Management Service Contributor" on the APIM scope.
    * Key Vault Secrets Officer on the vault.
    * Website Contributor (or Owner) on the Function App for `az functionapp restart`.

  Why the restart: Function App KV references are resolved at app start AND on
  a periodic re-resolution timer (~24 h). Without a restart, the rotated value
  could take up to a day to propagate. Restart bounds propagation to ~10 s.
#>
[CmdletBinding()]
param (
    [Parameter()]
    [switch] $DryRun,

    [Parameter()]
    [switch] $SkipSmokeTest
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve everything from `azd env get-values`.
# Multi-line `-match` needs (?m) — see ~/.memory/powershell-gotchas.md.
# ---------------------------------------------------------------------------
$envValues = azd env get-values | Out-String

function Get-AzdEnvValue {
    param (
        [string] $Name,
        [switch] $Optional
    )
    if ($envValues -match "(?m)^$([regex]::Escape($Name))=`"?(.*?)`"?\s*$") {
        # .NET regex (?m) treats `$` as before `\n` only — the preceding `\r`
        # (from CRLF on Windows) can sneak into the capture along with the
        # trailing `"`. Trim defensively.
        return $matches[1].Trim().Trim('"')
    }
    if ($Optional) { return $null }
    throw "azd env value '$Name' not found. Run 'azd env refresh' first."
}

$subId   = Get-AzdEnvValue 'AZURE_SUBSCRIPTION_ID'
$rg      = Get-AzdEnvValue 'AZURE_RESOURCE_GROUP'
$funcName = Get-AzdEnvValue 'FUNCTION_APP_NAME'
$funcHost = Get-AzdEnvValue 'FUNCTION_APP_HOSTNAME'

# APIM_SERVICE_NAME and KEY_VAULT_NAME were added as Bicep outputs after the
# initial provision; older `azd env` may not have them. Fall back to discovery.
$apimName = Get-AzdEnvValue 'APIM_SERVICE_NAME' -Optional
if (-not $apimName) {
    $gateway = Get-AzdEnvValue 'APIM_GATEWAY_URL'
    if ($gateway -match '^https://([^./]+)\.azure-api\.net/?$') {
        $apimName = $matches[1]
        Write-Verbose "APIM_SERVICE_NAME not in azd env — derived '$apimName' from APIM_GATEWAY_URL."
    } else {
        throw "Could not derive APIM service name from APIM_GATEWAY_URL ('$gateway')."
    }
}

$kvName = Get-AzdEnvValue 'KEY_VAULT_NAME' -Optional
if (-not $kvName) {
    Write-Verbose "KEY_VAULT_NAME not in azd env — discovering via 'az keyvault list -g $rg'."
    $kvList = az keyvault list --resource-group $rg --query "[].name" -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az keyvault list failed: $kvList" }
    $kvCandidates = @($kvList -split "\r?\n" | Where-Object { $_ })
    if ($kvCandidates.Count -eq 0) { throw "No Key Vaults found in resource group '$rg'." }
    if ($kvCandidates.Count -gt 1) {
        throw "Multiple Key Vaults in '$rg' ($($kvCandidates -join ', ')) — set KEY_VAULT_NAME explicitly via 'azd env set'."
    }
    $kvName = $kvCandidates[0]
}

$subscriptionId = 'function-app'
$secretName     = 'apim-subscription-function-app-key'

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' APIM subscription key rotation' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host "APIM service     : $apimName"
Write-Host "Subscription SID : $subscriptionId"
Write-Host "Key Vault        : $kvName"
Write-Host "KV secret name   : $secretName"
Write-Host "Function App     : $funcName"
Write-Host "Dry-run          : $($DryRun.IsPresent)"
Write-Host ''

# ---------------------------------------------------------------------------
# Step 1: capture current key fingerprint (last 4 chars only — never log full).
# ---------------------------------------------------------------------------
Write-Host '[1/6] Fingerprinting current key in Key Vault...' -ForegroundColor Yellow
$currentValue = az keyvault secret show `
    --vault-name $kvName `
    --name $secretName `
    --query value `
    -o tsv 2>&1
if ($LASTEXITCODE -ne 0) { throw "az keyvault secret show failed: $currentValue" }

$currentFp = if ($currentValue.Length -ge 4) { $currentValue.Substring($currentValue.Length - 4) } else { '????' }
Write-Host "       Current fingerprint: ...$currentFp"

# ---------------------------------------------------------------------------
# Step 2: regenerate the APIM subscription primary key.
# The az CLI has no `az apim subscription regenerate` verb; use ARM REST.
# ---------------------------------------------------------------------------
$regenUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apimName/subscriptions/$subscriptionId/regeneratePrimaryKey?api-version=2024-05-01"

if ($DryRun) {
    Write-Host '[2/6] [DRY-RUN] Would POST regeneratePrimaryKey:' -ForegroundColor DarkYellow
    Write-Host "       $regenUrl"
} else {
    Write-Host '[2/6] Regenerating APIM subscription primary key...' -ForegroundColor Yellow
    $regenOut = az rest --method post --url $regenUrl 2>&1
    if ($LASTEXITCODE -ne 0) { throw "regeneratePrimaryKey failed: $regenOut" }
    Write-Host '       OK'
}

# ---------------------------------------------------------------------------
# Step 3: fetch the new primary key via listSecrets.
# ---------------------------------------------------------------------------
$listSecretsUrl = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apimName/subscriptions/$subscriptionId/listSecrets?api-version=2024-05-01"

if ($DryRun) {
    Write-Host '[3/6] [DRY-RUN] Would POST listSecrets to read new primary key.' -ForegroundColor DarkYellow
    $newKey = $currentValue  # reuse so downstream dry-run steps have a value
} else {
    Write-Host '[3/6] Fetching new primary key...' -ForegroundColor Yellow
    $secretsOut = az rest --method post --url $listSecretsUrl 2>&1
    if ($LASTEXITCODE -ne 0) { throw "listSecrets failed: $secretsOut" }
    $secrets = $secretsOut | Out-String | ConvertFrom-Json
    $newKey = $secrets.primaryKey
    if (-not $newKey) { throw 'listSecrets returned no primaryKey.' }
    $newFp = $newKey.Substring($newKey.Length - 4)
    Write-Host "       New fingerprint: ...$newFp"
    if ($newFp -eq $currentFp) {
        Write-Host '       WARN: new fingerprint matches old — regeneration may have been a no-op.' -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Step 4: write new value to Key Vault (new secret version).
# ---------------------------------------------------------------------------
if ($DryRun) {
    Write-Host '[4/6] [DRY-RUN] Would az keyvault secret set (new version).' -ForegroundColor DarkYellow
} else {
    Write-Host '[4/6] Writing new key to Key Vault...' -ForegroundColor Yellow
    $setOut = az keyvault secret set `
        --vault-name $kvName `
        --name $secretName `
        --value $newKey `
        --query id `
        -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az keyvault secret set failed: $setOut" }
    Write-Host "       New secret version: $setOut"
}

# ---------------------------------------------------------------------------
# Step 5: restart the Function App to force KV reference cache invalidation.
# ---------------------------------------------------------------------------
if ($DryRun) {
    Write-Host '[5/6] [DRY-RUN] Would az functionapp restart.' -ForegroundColor DarkYellow
} else {
    Write-Host '[5/6] Restarting Function App (forces KV reference refresh)...' -ForegroundColor Yellow
    $restartOut = az functionapp restart --name $funcName --resource-group $rg 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az functionapp restart failed: $restartOut" }
    Write-Host '       Restart issued. Waiting 15 s for cold start...'
    Start-Sleep -Seconds 15
}

# ---------------------------------------------------------------------------
# Step 6: smoke test /api/analyze-text. Validates that the Function resolved
# the new KV reference value and APIM accepts the new subscription key.
# ---------------------------------------------------------------------------
if ($SkipSmokeTest) {
    Write-Host '[6/6] -SkipSmokeTest set — skipping post-rotation smoke test.' -ForegroundColor DarkYellow
} elseif ($DryRun) {
    Write-Host '[6/6] [DRY-RUN] Would call /api/analyze-text via the Function App.' -ForegroundColor DarkYellow
} else {
    Write-Host '[6/6] Smoke-testing /api/analyze-text...' -ForegroundColor Yellow
    $funcKey = az functionapp keys list `
        --name $funcName `
        --resource-group $rg `
        --query functionKeys.default `
        -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az functionapp keys list failed: $funcKey" }

    $body = @{ text = 'hello world' } | ConvertTo-Json -Compress
    $url = "https://${funcHost}/api/analyze-text?code=$funcKey"
    try {
        $resp = Invoke-WebRequest `
            -Method POST `
            -Uri $url `
            -Headers @{ 'content-type' = 'application/json' } `
            -Body $body `
            -SkipHttpErrorCheck
    } catch {
        throw "Smoke test request raised: $_"
    }
    if ($resp.StatusCode -ne 200) {
        Write-Host "       FAIL: status=$($resp.StatusCode)" -ForegroundColor Red
        Write-Host $resp.Content
        throw 'Post-rotation smoke test failed. Investigate APIM subscription state + KV reference resolution.'
    }
    Write-Host "       OK: status=200"
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Green
Write-Host ' Rotation complete' -ForegroundColor Green
Write-Host '================================================================' -ForegroundColor Green
