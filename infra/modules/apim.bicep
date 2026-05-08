// =============================================================================
// API Management Basic v2 + load-balanced backend pool over two Content Safety
// accounts. APIM authenticates to each backend with its system-assigned MI
// (Cognitive Services User role assigned by rbac.bicep). Round-robin pool with
// equal weight + circuit breaker per backend.
// =============================================================================

param location string
param apimName string
param publisherEmail string
param publisherName string
param primaryContentSafetyEndpoint string
param primaryContentSafetyName string
param secondaryContentSafetyEndpoint string
param secondaryContentSafetyName string
param appInsightsId string
@secure()
param appInsightsKey string
param useExternalCache bool
param redisConnectionStringSecretUri string
@secure()
param redisConnectionString string
param idempotencyTtlSeconds int
param tags object

// =============================================================================
// APIM service
// =============================================================================
resource apim 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: 'Enabled'
  }
}

// =============================================================================
// Application Insights logger (W3C correlation, 100 % sampling)
// =============================================================================
resource appInsightsLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'appinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for content-safety API'
    resourceId: appInsightsId
    credentials: {
      instrumentationKey: appInsightsKey
    }
  }
}

resource diagnostic 'Microsoft.ApiManagement/service/diagnostics@2024-05-01' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    alwaysLog: 'allErrors'
    httpCorrelationProtocol: 'W3C'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    loggerId: appInsightsLogger.id
    verbosity: 'information'
  }
}

// =============================================================================
// External cache (opt-in): bind AMR as APIM's external cache.
// =============================================================================
resource externalCache 'Microsoft.ApiManagement/service/caches@2024-05-01' = if (useExternalCache) {
  parent: apim
  name: 'default'
  properties: {
    description: 'AMR external cache (blocklist pinning + idempotency)'
    connectionString: redisConnectionString
    useFromLocation: location
    resourceId: redisConnectionStringSecretUri
  }
}

// =============================================================================
// Named values (parsed at policy compile time, so they substitute as literals).
// =============================================================================
resource idempotencyTtlNv 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'idempotency-ttl-seconds'
  properties: {
    displayName: 'idempotency-ttl-seconds'
    value: string(idempotencyTtlSeconds)
    secret: false
  }
}

// =============================================================================
// Backends: one per Content Safety account.
// Content Safety REST API lives under the /contentsafety/ path prefix on the
// Cognitive Services endpoint, so the backend URL must include it. Otherwise
// APIM forwards e.g. POST /text:analyze (instead of /contentsafety/text:analyze)
// and the upstream returns 404.
// =============================================================================
var primaryBackendUrl = '${primaryContentSafetyEndpoint}${endsWith(primaryContentSafetyEndpoint, '/') ? '' : '/'}contentsafety'
var secondaryBackendUrl = '${secondaryContentSafetyEndpoint}${endsWith(secondaryContentSafetyEndpoint, '/') ? '' : '/'}contentsafety'

resource primaryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'cs-primary'
  properties: {
    url: primaryBackendUrl
    protocol: 'http'
    description: 'Content Safety primary (${primaryContentSafetyName})'
    circuitBreaker: {
      rules: [
        {
          name: 'cb-rule'
          failureCondition: {
            count: 5
            interval: 'PT1M'
            statusCodeRanges: [
              {
                min: 429
                max: 429
              }
              {
                min: 500
                max: 599
              }
            ]
          }
          tripDuration: 'PT30S'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

resource secondaryBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'cs-secondary'
  properties: {
    url: secondaryBackendUrl
    protocol: 'http'
    description: 'Content Safety secondary (${secondaryContentSafetyName})'
    circuitBreaker: {
      rules: [
        {
          name: 'cb-rule'
          failureCondition: {
            count: 5
            interval: 'PT1M'
            statusCodeRanges: [
              {
                min: 429
                max: 429
              }
              {
                min: 500
                max: 599
              }
            ]
          }
          tripDuration: 'PT30S'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

// Backend pool: round-robin with equal weight.
resource pool 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'cs-pool'
  properties: {
    description: 'Round-robin pool over both Content Safety accounts'
    type: 'Pool'
    pool: {
      services: [
        {
          id: primaryBackend.id
          priority: 1
          weight: 1
        }
        {
          id: secondaryBackend.id
          priority: 1
          weight: 1
        }
      ]
    }
  }
}

// =============================================================================
// API: contentsafety. Single API hosting all 14 operations.
// =============================================================================
resource api 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'content-safety'
  properties: {
    displayName: 'Content Safety'
    description: 'Load-balanced facade over two Azure AI Content Safety accounts'
    path: 'contentsafety'
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    apiType: 'http'
  }
}

// API-level base policy (retry + circuit breaker behaviour + correlation).
resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: api
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: replace(
      loadTextContent('policies/api-base.xml'),
      '__POOL_BACKEND_ID__',
      pool.name
    )
  }
}

// =============================================================================
// Operations
// =============================================================================

// --- Stateless analyze operations (round-robin, no pin) ---------------------

// 1. POST /text:analyze
resource opAnalyzeText 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'analyze-text'
  properties: {
    displayName: 'Analyze Text'
    method: 'POST'
    urlTemplate: '/text:analyze'
  }
}

// 2. POST /image:analyze
resource opAnalyzeImage 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'analyze-image'
  properties: {
    displayName: 'Analyze Image'
    method: 'POST'
    urlTemplate: '/image:analyze'
  }
}

// 3. POST /text:detectGroundedness
resource opGroundedness 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'detect-groundedness'
  properties: {
    displayName: 'Detect Groundedness'
    method: 'POST'
    urlTemplate: '/text:detectGroundedness'
  }
}

// 4. POST /text:detectProtectedMaterial
resource opProtectedMaterial 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'detect-protected-material'
  properties: {
    displayName: 'Detect Protected Material'
    method: 'POST'
    urlTemplate: '/text:detectProtectedMaterial'
  }
}

// 5. POST /text:shieldPrompt
resource opShieldPrompt 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'shield-prompt'
  properties: {
    displayName: 'Shield Prompt (Prompt Shields)'
    method: 'POST'
    urlTemplate: '/text:shieldPrompt'
  }
}

// 6. GET /text/blocklists  (list — round-robin; documented limitation)
resource opListBlocklists 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'list-blocklists'
  properties: {
    displayName: 'List Blocklists'
    method: 'GET'
    urlTemplate: '/text/blocklists'
  }
}

// --- Blocklist mutations (pin write + idempotency) --------------------------

// 7. PATCH /text/blocklists/{blocklistName}  — create-or-update (pin write)
resource opUpsertBlocklist 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'upsert-blocklist'
  properties: {
    displayName: 'Create or Update Blocklist'
    method: 'PATCH'
    urlTemplate: '/text/blocklists/{blocklistName}'
    templateParameters: [
      {
        name: 'blocklistName'
        type: 'string'
        required: true
      }
    ]
  }
}

// 8. POST /text/blocklists/{blocklistName}:addOrUpdateBlocklistItems
resource opAddItems 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'add-blocklist-items'
  properties: {
    displayName: 'Add or Update Blocklist Items'
    method: 'POST'
    urlTemplate: '/text/blocklists/{blocklistName}:addOrUpdateBlocklistItems'
    templateParameters: [
      {
        name: 'blocklistName'
        type: 'string'
        required: true
      }
    ]
  }
}

// 9. POST /text/blocklists/{blocklistName}:removeBlocklistItems
resource opRemoveItems 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'remove-blocklist-items'
  properties: {
    displayName: 'Remove Blocklist Items'
    method: 'POST'
    urlTemplate: '/text/blocklists/{blocklistName}:removeBlocklistItems'
    templateParameters: [
      {
        name: 'blocklistName'
        type: 'string'
        required: true
      }
    ]
  }
}

// --- Blocklist reads/deletes (pin read) -------------------------------------

// 10. GET /text/blocklists/{blocklistName}
resource opGetBlocklist 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'get-blocklist'
  properties: {
    displayName: 'Get Blocklist'
    method: 'GET'
    urlTemplate: '/text/blocklists/{blocklistName}'
    templateParameters: [
      {
        name: 'blocklistName'
        type: 'string'
        required: true
      }
    ]
  }
}

// 11. DELETE /text/blocklists/{blocklistName}
resource opDeleteBlocklist 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'delete-blocklist'
  properties: {
    displayName: 'Delete Blocklist'
    method: 'DELETE'
    urlTemplate: '/text/blocklists/{blocklistName}'
    templateParameters: [
      {
        name: 'blocklistName'
        type: 'string'
        required: true
      }
    ]
  }
}

// 12. GET /text/blocklists/{blocklistName}/blocklistItems
resource opListItems 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'list-blocklist-items'
  properties: {
    displayName: 'List Blocklist Items'
    method: 'GET'
    urlTemplate: '/text/blocklists/{blocklistName}/blocklistItems'
    templateParameters: [
      {
        name: 'blocklistName'
        type: 'string'
        required: true
      }
    ]
  }
}

// 13. GET /text/blocklists/{blocklistName}/blocklistItems/{blocklistItemId}
resource opGetItem 'Microsoft.ApiManagement/service/apis/operations@2024-05-01' = {
  parent: api
  name: 'get-blocklist-item'
  properties: {
    displayName: 'Get Blocklist Item'
    method: 'GET'
    urlTemplate: '/text/blocklists/{blocklistName}/blocklistItems/{blocklistItemId}'
    templateParameters: [
      {
        name: 'blocklistName'
        type: 'string'
        required: true
      }
      {
        name: 'blocklistItemId'
        type: 'string'
        required: true
      }
    ]
  }
}

// =============================================================================
// Operation policies — load XML files from policies/ and substitute tokens.
// =============================================================================
var statelessPolicy = loadTextContent('policies/stateless.xml')
var pinReadPolicy = loadTextContent('policies/blocklist-pin-read.xml')
// Note: blocklist-pin-write.xml is reserved for future use (e.g., a non-idempotent
// mutation flow). It is not loaded here to avoid an unused-vars linter warning.
var pinWriteIdempotentPolicy = loadTextContent('policies/idempotent-mutation.xml')

resource policyAnalyzeText 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opAnalyzeText
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: statelessPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource policyAnalyzeImage 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opAnalyzeImage
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: statelessPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource policyGroundedness 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opGroundedness
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: statelessPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource policyProtectedMaterial 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opProtectedMaterial
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: statelessPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource policyShieldPrompt 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opShieldPrompt
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: statelessPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource policyListBlocklists 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opListBlocklists
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: statelessPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource policyUpsertBlocklist 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opUpsertBlocklist
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: pinWriteIdempotentPolicy
  }
  dependsOn: [
    apiPolicy
    idempotencyTtlNv
  ]
}

resource policyAddItems 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opAddItems
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: pinWriteIdempotentPolicy
  }
  dependsOn: [
    apiPolicy
    idempotencyTtlNv
  ]
}

resource policyRemoveItems 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opRemoveItems
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: pinWriteIdempotentPolicy
  }
  dependsOn: [
    apiPolicy
    idempotencyTtlNv
  ]
}

resource policyGetBlocklist 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opGetBlocklist
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: pinReadPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource policyDeleteBlocklist 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opDeleteBlocklist
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: pinReadPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource policyListItems 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opListItems
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: pinReadPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

resource policyGetItem 'Microsoft.ApiManagement/service/apis/operations/policies@2024-05-01' = {
  parent: opGetItem
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: pinReadPolicy
  }
  dependsOn: [
    apiPolicy
  ]
}

// =============================================================================
// Outputs
// =============================================================================
output id string = apim.id
output name string = apim.name
output gatewayUrl string = apim.properties.gatewayUrl
output principalId string = apim.identity.principalId
