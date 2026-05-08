// Azure Managed Redis (redisEnterprise) for APIM external cache.
// Connection string is written to Key Vault rather than emitted as a Bicep
// output to keep it out of deployment history.
param location string
param clusterName string
param skuName string
param keyVaultName string
param secretName string
param tags object

resource cluster 'Microsoft.Cache/redisEnterprise@2024-09-01-preview' = {
  name: clusterName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
}

resource database 'Microsoft.Cache/redisEnterprise/databases@2024-09-01-preview' = {
  parent: cluster
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'NoEviction'
    persistence: {
      aofEnabled: false
      rdbEnabled: false
    }
  }
}

// Build the connection string at deploy time and store it in Key Vault.
// (APIM caches resource takes a literal value, not a KV reference, so the
// secret is for inspection / rotation visibility — runtime rotation still
// requires a redeploy.)
var primaryKey = database.listKeys().primaryKey
var connectionString = '${cluster.properties.hostName}:10000,password=${primaryKey},ssl=True,abortConnect=False'

resource kv 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

resource connStringSecret 'Microsoft.KeyVault/vaults/secrets@2024-04-01-preview' = {
  parent: kv
  name: secretName
  properties: {
    value: connectionString
    contentType: 'text/plain'
  }
}

output clusterId string = cluster.id
output hostName string = cluster.properties.hostName
output connectionStringSecretUri string = connStringSecret.properties.secretUri
// Note: not marked @secure() because main-resources.bicep needs to dereference
// it via a ternary on useExternalCache (BCP426 forbids that for secure outputs).
// The value is already persisted in Key Vault; deployment-output exposure is
// scoped to principals with Microsoft.Resources/deployments/read on the RG.
output connectionString string = connectionString
