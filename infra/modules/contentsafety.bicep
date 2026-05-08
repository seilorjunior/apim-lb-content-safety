// One Azure AI Content Safety account.
//
// kind 'ContentSafety' is the dedicated SKU; cheaper than multi-service if you
// only need text/image moderation. customSubDomainName is mandatory for AAD/MI
// auth.
param location string
param accountName string
param customSubdomainName string
param tags object

@allowed([
  'F0'
  'S0'
])
@description('F0 = free (limited TPS); S0 = standard. Default S0 to support batch + groundedness.')
param skuName string = 'S0'

resource account 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: accountName
  location: location
  tags: tags
  kind: 'ContentSafety'
  sku: {
    name: skuName
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: customSubdomainName
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Allow'
    }
    apiProperties: {}
  }
}

output id string = account.id
output name string = account.name
output endpoint string = account.properties.endpoint
output principalId string = account.identity.principalId
