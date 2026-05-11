<#
.SYNOPSIS
  azd post-provision hook. Prints the deployed Function App + APIM URLs and a
  copy-paste-ready smoke-test snippet.

.NOTES
  Invoked automatically by `azd up` / `azd provision` (see azure.yaml).
#>
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ' Deployment complete' -ForegroundColor Cyan
Write-Host '================================================================' -ForegroundColor Cyan

$values = azd env get-values | Out-String
$kv = @{}
foreach ($line in $values -split "`n") {
    if ($line -match '^([A-Z_]+)="?(.*?)"?$') {
        $kv[$matches[1]] = $matches[2]
    }
}

$func = $kv['FUNCTION_APP_HOSTNAME']
$funcName = $kv['FUNCTION_APP_NAME']
$rg   = $kv['AZURE_RESOURCE_GROUP']
$apim = $kv['APIM_GATEWAY_URL']
$pri  = $kv['PRIMARY_CONTENT_SAFETY_NAME']
$sec  = $kv['SECONDARY_CONTENT_SAFETY_NAME']
$storage = $kv['STORAGE_ACCOUNT_NAME']

# Drift check: the desired steady state is publicNetworkAccess=Disabled
# (storage is private-endpoint-only; the FC1 worker reaches blob through the
# VNet-integrated subnet). If something flipped it back to Enabled, warn so
# the operator can re-deploy or manually re-disable. We intentionally do NOT
# self-heal here — fixing it without verifying that the PE / DNS path is
# healthy could leave a misconfigured private-only account unreachable.
if ($storage -and $rg) {
    $pna = (az storage account show --name $storage --resource-group $rg --query publicNetworkAccess -o tsv 2>$null)
    if ($pna -eq 'Enabled') {
        Write-Host "WARN: storage $storage publicNetworkAccess=Enabled (expected Disabled with PE+VNet)." -ForegroundColor Yellow
        Write-Host "      Re-run 'azd provision' or manually set it back to Disabled once the PE is verified." -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host "Function App     : https://$func"
Write-Host "APIM gateway     : $apim"
Write-Host "Primary CS acct  : $pri"
Write-Host "Secondary CS acct: $sec"
Write-Host ''
Write-Host 'The Function App requires `x-functions-key` (FUNCTION auth).' -ForegroundColor Yellow
Write-Host 'Fetch the default host key with:' -ForegroundColor Yellow
Write-Host "  az functionapp keys list --name $funcName --resource-group $rg --query functionKeys.default -o tsv"
Write-Host ''
Write-Host 'Quick smoke test (test-deployment.ps1 fetches the key automatically):' -ForegroundColor Yellow
Write-Host '  pwsh ./scripts/test-deployment.ps1'
Write-Host '  pwsh ./scripts/load-test.ps1 -Count 10'
Write-Host ''
