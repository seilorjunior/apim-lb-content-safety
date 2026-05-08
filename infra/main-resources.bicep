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
// 2. Storage (Function App deployment storage, MI-only)
// -----------------------------------------------------------------------------
module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: 'st${prefix}'
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
// 4. (Opt-in) Key Vault + Azure Managed Redis for APIM external cache
// -----------------------------------------------------------------------------
module keyVault 'modules/keyvault.bicep' = if (useExternalCache) {
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
    keyVaultName: useExternalCache ? keyVault!.outputs.name : ''
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
    useExternalCache: useExternalCache
    redisConnectionStringSecretUri: useExternalCache ? redis!.outputs.connectionStringSecretUri : ''
    redisConnectionString: useExternalCache ? redis!.outputs.connectionString : ''
    idempotencyTtlSeconds: idempotencyTtlSeconds
    tags: tags
  }
}

// -----------------------------------------------------------------------------
// 6. Function App (Python, Flex Consumption, MI to storage and APIM)
// -----------------------------------------------------------------------------
module functionApp 'modules/function.bicep' = {
  name: 'function'
  params: {
    location: location
    functionAppName: 'func-${prefix}'
    appServicePlanName: 'plan-${prefix}'
    storageAccountName: storage.outputs.name
    apimName: apim.outputs.name
    apimGatewayUrl: apim.outputs.gatewayUrl
    apimSubscriptionName: apim.outputs.functionSubscriptionName
    corsAllowedOrigins: corsAllowedOrigins
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
    keyVaultName: useExternalCache ? keyVault!.outputs.name : ''
    useExternalCache: useExternalCache
    principalId: principalId
  }
}

// -----------------------------------------------------------------------------
// Outputs surfaced to azd
// -----------------------------------------------------------------------------
output functionAppName string = functionApp.outputs.name
output functionAppHostname string = functionApp.outputs.hostname
output apimGatewayUrl string = apim.outputs.gatewayUrl
output primaryContentSafetyName string = primaryCs.outputs.name
output secondaryContentSafetyName string = secondaryCs.outputs.name
output appInsightsName string = monitoring.outputs.appInsightsName
