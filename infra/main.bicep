// =============================================================================
// Subscription-scope entry point. Creates the resource group then delegates to
// main-resources.bicep for the actual workload.
// =============================================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment. Used to derive resource names.')
param environmentName string

@minLength(1)
@description('Primary region (Function App + APIM + primary Content Safety account + storage + monitoring).')
param location string

@description('Secondary region for the second Content Safety account.')
param secondaryContentSafetyLocation string = 'eastus2'

@description('Object id of the principal to grant developer roles (Cognitive Services User on each Content Safety account, Key Vault Secrets User on the KV when external cache is on). Leave empty in CI.')
param principalId string = ''

@description('Provision Azure Managed Redis + Key Vault and bind AMR as the APIM external cache. Default false (APIM internal cache).')
param useExternalCache bool = false

@description('AMR SKU when useExternalCache=true. Default Balanced_B0 (~$80/mo, no SLA, fine for dev).')
param redisSku string = 'Balanced_B0'

@description('Region for Azure Managed Redis. Leave empty (default) to co-locate with the primary location; override (e.g. via AZURE_REDIS_LOCATION) when the primary region has capacity issues for the chosen Redis SKU. Cross-region traffic from APIM to Redis is TCP-only and adds a few ms of latency.')
param redisLocation string = ''

@description('Idempotency cache TTL in seconds for blocklist mutations. Range 60-604800. Default 3600.')
@minValue(60)
@maxValue(604800)
param idempotencyTtlSeconds int = 3600

@description('Enable irreversible Key Vault purge protection. Leave false in dev.')
param useProductionGuards bool = false

var resourceGroupName = 'rg-${environmentName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    'azd-env-name': environmentName
  }
}

module resources 'main-resources.bicep' = {
  name: 'main-resources'
  scope: rg
  params: {
    environmentName: environmentName
    location: location
    secondaryContentSafetyLocation: secondaryContentSafetyLocation
    principalId: principalId
    useExternalCache: useExternalCache
    redisSku: redisSku
    redisLocation: redisLocation
    idempotencyTtlSeconds: idempotencyTtlSeconds
    useProductionGuards: useProductionGuards
  }
}

// =============================================================================
// Outputs consumed by azd hooks and the test scripts.
// =============================================================================
output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output FUNCTION_APP_HOSTNAME string = resources.outputs.functionAppHostname
output APIM_GATEWAY_URL string = resources.outputs.apimGatewayUrl
output PRIMARY_CONTENT_SAFETY_NAME string = resources.outputs.primaryContentSafetyName
output SECONDARY_CONTENT_SAFETY_NAME string = resources.outputs.secondaryContentSafetyName
output APPLICATION_INSIGHTS_NAME string = resources.outputs.appInsightsName
output AZURE_USE_EXTERNAL_CACHE bool = useExternalCache
output AZURE_REDIS_SKU string = redisSku
output AZURE_REDIS_LOCATION string = empty(redisLocation) ? location : redisLocation
output AZURE_IDEMPOTENCY_TTL_SECONDS int = idempotencyTtlSeconds
