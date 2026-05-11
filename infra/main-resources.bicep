// =============================================================================
// Resource-group-scope orchestrator. Wires:
//   monitoring -> storage -> two Content Safety accounts -> APIM -> Function -> RBAC
// Optional: redis + key vault when useExternalCache=true.
// =============================================================================
targetScope = 'resourceGroup'

param environmentName string
param location string
param secondaryContentSafetyLocation string
param principalId string
param useExternalCache bool
param redisSku string
param redisLocation string
param idempotencyTtlSeconds int
param useProductionGuards bool
param corsAllowedOrigins array
param maxRequestBodyBytes int

var effectiveRedisLocation = empty(redisLocation) ? location : redisLocation

// ------------------------------------------------------------
// CORS wildcard guard (ADR 0001 "secure by default")
// The Function App is meant for server-to-server traffic. A wildcard CORS
// origin would silently grant any browser on the public internet permission
// to invoke the API (subject to the APIM subscription key, but still a major
// foot-gun). We strip '*' here, pass only the safe origins to the function
// module, and surface a deployment output so operators can spot the silent
// rewrite in azd's post-deploy summary.
// ------------------------------------------------------------
var corsHasWildcard = contains(corsAllowedOrigins, '*')
var effectiveCorsAllowedOrigins = filter(corsAllowedOrigins, o => o != '*')

// Resource naming uses a short hash of the resource group id to keep names
// globally-unique while staying readable.
var token = uniqueString(resourceGroup().id, environmentName)
var prefix = 'cs${token}'

var tags = {
  'azd-env-name': environmentName
  workload: 'apim-lb-content-safety'
}

// -----------------------------------------------------------------------------
// 1. Monitoring (Log Analytics + App Insights)
// -----------------------------------------------------------------------------
module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    workspaceName: 'log-${prefix}'
    appInsightsName: 'appi-${prefix}'
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// 2. Network (VNet + subnets + private DNS for blob private endpoint)
//    Must deploy before storage because storage now binds a private endpoint
//    into snet-pe and registers it under the blob private DNS zone.
// -----------------------------------------------------------------------------
module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    vnetName: 'vnet-${prefix}'
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// 3. Storage (Function App deployment storage, MI-only, private endpoint)
// -----------------------------------------------------------------------------
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: 'st${prefix}'
    privateEndpointSubnetId: network.outputs.privateEndpointsSubnetId
    blobPrivateDnsZoneId: network.outputs.blobPrivateDnsZoneId
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// 3. Two Content Safety accounts (primary + secondary region)
// -----------------------------------------------------------------------------
module primaryCs 'modules/contentsafety.bicep' = {
  name: 'cs-primary'
  params: {
    location: location
    accountName: 'cs-${prefix}-pri'
    customSubdomainName: '${prefix}-pri'
    tags: tags
  }
}

module secondaryCs 'modules/contentsafety.bicep' = {
  name: 'cs-secondary'
  params: {
    location: secondaryContentSafetyLocation
    accountName: 'cs-${prefix}-sec'
    customSubdomainName: '${prefix}-sec'
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// 4. Key Vault (always-on; stores the APIM "function-app" subscription key as
//    a secret so the Function references it via @Microsoft.KeyVault(SecretUri=...)
//    instead of receiving the cleartext value through appSettings).
//    Azure Managed Redis remains opt-in.
// -----------------------------------------------------------------------------
module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    keyVaultName: 'kv-${prefix}'
    tenantId: subscription().tenantId
    enablePurgeProtection: useProductionGuards
    tags: tags
  }
}

module redis 'modules/redis.bicep' = if (useExternalCache) {
  name: 'redis'
  params: {
    location: effectiveRedisLocation
    clusterName: 'amr-${prefix}'
    skuName: redisSku
    keyVaultName: keyVault.outputs.name
    secretName: 'redis-connection-string'
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// 5. APIM (with backend pool, policies, and named values)
// -----------------------------------------------------------------------------
module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    location: location
    apimName: 'apim-${prefix}'
    publisherEmail: 'admin@${environmentName}.local'
    publisherName: environmentName
    primaryContentSafetyEndpoint: primaryCs.outputs.endpoint
    primaryContentSafetyName: primaryCs.outputs.name
    secondaryContentSafetyEndpoint: secondaryCs.outputs.endpoint
    secondaryContentSafetyName: secondaryCs.outputs.name
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsKey: monitoring.outputs.appInsightsInstrumentationKey
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    keyVaultName: keyVault.outputs.name
    useExternalCache: useExternalCache
    redisConnectionStringSecretUri: useExternalCache ? redis!.outputs.connectionStringSecretUri : ''
    redisConnectionString: useExternalCache ? redis!.outputs.connectionString : ''
    idempotencyTtlSeconds: idempotencyTtlSeconds
    maxRequestBodyBytes: maxRequestBodyBytes
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// 6. Function App (Python, Flex Consumption, MI to storage and APIM,
//    VNet-integrated to reach storage privately)
// -----------------------------------------------------------------------------
module functionApp 'modules/function.bicep' = {
  name: 'function'
  params: {
    location: location
    functionAppName: 'func-${prefix}'
    appServicePlanName: 'plan-${prefix}'
    storageAccountName: storage.outputs.name
    apimGatewayUrl: apim.outputs.gatewayUrl
    apimSubscriptionKeySecretUri: apim.outputs.apimSubscriptionKeySecretUri
    virtualNetworkSubnetId: network.outputs.functionsSubnetId
    storageBlobPrivateEndpointId: storage.outputs.blobPrivateEndpointId
    logAnalyticsWorkspaceId: monitoring.outputs.workspaceId
    corsAllowedOrigins: effectiveCorsAllowedOrigins
    maxRequestBodyBytes: maxRequestBodyBytes
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// 7. RBAC role assignments
// -----------------------------------------------------------------------------
module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    apimPrincipalId: apim.outputs.principalId
    functionPrincipalId: functionApp.outputs.principalId
    primaryContentSafetyName: primaryCs.outputs.name
    secondaryContentSafetyName: secondaryCs.outputs.name
    storageAccountName: storage.outputs.name
    keyVaultName: keyVault.outputs.name
    principalId: principalId
  }
}

// -----------------------------------------------------------------------------
// Outputs surfaced to azd
// -----------------------------------------------------------------------------
output functionAppName string = functionApp.outputs.name
output functionAppHostname string = functionApp.outputs.hostname
output apimGatewayUrl string = apim.outputs.gatewayUrl
output apimName string = apim.outputs.name
output keyVaultName string = keyVault.outputs.name
output primaryContentSafetyName string = primaryCs.outputs.name
output secondaryContentSafetyName string = secondaryCs.outputs.name
output appInsightsName string = monitoring.outputs.appInsightsName
output storageAccountName string = storage.outputs.name
output vnetName string = network.outputs.vnetName
@description('True if AZURE_CORS_ALLOWED_ORIGINS contained the wildcard ("*") and it was silently stripped before reaching the Function App. Treat as a misconfiguration to fix at the caller.')
output corsWildcardSilentlyStripped bool = corsHasWildcard
