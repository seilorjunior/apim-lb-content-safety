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
