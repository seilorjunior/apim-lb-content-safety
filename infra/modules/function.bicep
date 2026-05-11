// Function App on Flex Consumption (FC1). Python 3.11. Managed identity for
// storage and APIM gateway calls.
param location string
param functionAppName string
param appServicePlanName string
param storageAccountName string
param apimName string
param apimGatewayUrl string
param apimSubscriptionName string
@description('Resource ID of the VNet subnet used for regional VNet integration. Must be delegated to Microsoft.App/environments for FC1.')
param virtualNetworkSubnetId string
@description('Resource ID of the storage blob private endpoint. Only used to force the function module to wait for the PE to finish provisioning before the platform restarts the app.')
param storageBlobPrivateEndpointId string
@description('Browser CORS allow-list. Defaults to [] (no browser origins). The Function is meant for server-to-server traffic; only widen this if you fully trust the listed origins.')
param corsAllowedOrigins array = []
@description('Maximum request body in bytes (mirrored to MAX_REQUEST_BODY_BYTES). Default 10 MiB matches Content Safety upstream limits.')
param maxRequestBodyBytes int = 10 * 1024 * 1024
@secure()
param appInsightsConnectionString string
param tags object

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

// Read the APIM subscription primary key inline so the function can authenticate
// to the APIM API. listSecrets() resolves at deployment time and the value is
// only emitted into appSettings (which are KV-encrypted at rest by App Service).
resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource apimSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' existing = {
  parent: apim
  name: apimSubscriptionName
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true
  }
}

// Reference the storage PE only to materialise a module-level dependency.
// Without this, ARM may try to restart the function before the PE is fully
// wired, which would cause the cold-start package fetch to time out against
// a private-only storage account.
var _storagePeDependency = storageBlobPrivateEndpointId

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  tags: union(tags, {
    'azd-service-name': 'api'
  })
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    // Regional VNet integration. Outbound traffic to private endpoints
    // (currently just storage blob) flows through this subnet. Public
    // destinations (APIM gateway, Content Safety, App Insights ingestion)
    // continue to use the FC1 outbound public IP pool because
    // vnetRouteAllEnabled is left at its default (false).
    virtualNetworkSubnetId: virtualNetworkSubnetId
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      cors: {
        allowedOrigins: corsAllowedOrigins
      }
      appSettings: [
        // Storage via managed identity. On FC1, setting only __accountName
        // (no connection string, no __credential override) makes the host
        // default to the system-assigned MI for blob/queue/table data plane.
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        // Application Insights via instrumentation-key connection string
        // (default ingestion path). AAD-only ingestion is intentionally NOT
        // enabled here — it can silently drop Python worker stdout/stderr
        // if the MI role assignment hasn't propagated yet, which masks
        // indexing errors.
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'APIM_GATEWAY_URL'
          value: apimGatewayUrl
        }
        {
          name: 'APIM_SUBSCRIPTION_KEY'
          value: apimSubscription.listSecrets().primaryKey
        }
        {
          name: 'MAX_REQUEST_BODY_BYTES'
          value: string(maxRequestBodyBytes)
        }
        {
          name: 'CONTENT_SAFETY_API_VERSION'
          value: '2024-09-01'
        }
        {
          name: 'CONTENT_SAFETY_PREVIEW_API_VERSION'
          value: '2024-09-15-preview'
        }
        // Surfacing the dependency value in appSettings is a no-op runtime
        // hint but keeps the unused-var lint quiet and helps trace which
        // PE this function is wired to.
        {
          name: 'STORAGE_BLOB_PE_ID'
          value: _storagePeDependency
        }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}app-package-deployments'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 100
      }
    }
  }
}

output id string = functionApp.id
output name string = functionApp.name
output hostname string = functionApp.properties.defaultHostName
output principalId string = functionApp.identity.principalId
