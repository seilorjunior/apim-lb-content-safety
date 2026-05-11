// Storage account for Function Flex Consumption deployment package.
// MI-only (allowSharedKeyAccess: false) and TLS 1.2.
//
// Network model: publicNetworkAccess: Disabled. The FC1 worker reaches blob
// via a private endpoint in the integration VNet. DNS resolves through the
// private DNS zone (privatelink.blob.<suffix>) linked to the same VNet.
//
// `bypass: AzureServices` is retained so Azure Monitor metrics and a few
// internal control-plane flows still work; it does NOT re-open the data
// plane to the public internet (publicNetworkAccess: Disabled is the gate).
param location string
param storageAccountName string
param privateEndpointSubnetId string
param blobPrivateDnsZoneId string
param tags object

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobServices
  name: 'app-package-deployments'
  properties: {
    publicAccess: 'None'
  }
}

// Private endpoint for blob sub-resource. The FC1 worker pulls
// released-package.zip via this PE; without it the function cannot start.
resource blobPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${storageAccountName}-blob'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
    customNetworkInterfaceName: 'nic-pe-${storageAccountName}-blob'
  }
}

// Registers the PE's private IP under the linked private DNS zone so that
// <storage>.blob.<suffix> resolves to the private IP from inside the VNet.
// Cleaner than managing A records by hand — the platform refreshes the
// record set whenever the PE NIC moves.
resource blobPrivateEndpointDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: blobPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob-core-windows-net'
        properties: {
          privateDnsZoneId: blobPrivateDnsZoneId
        }
      }
    ]
  }
}

output id string = storageAccount.id
output name string = storageAccount.name
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output deploymentContainerName string = deploymentContainer.name
output blobPrivateEndpointId string = blobPrivateEndpoint.id
