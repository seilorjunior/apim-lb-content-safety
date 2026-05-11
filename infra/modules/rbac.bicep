// =============================================================================
// Role assignments. All assignments are scoped to the smallest possible
// resource (account / vault / storage account, not the resource group).
// =============================================================================

param apimPrincipalId string
param functionPrincipalId string
param primaryContentSafetyName string
param secondaryContentSafetyName string
param storageAccountName string
param keyVaultName string
param principalId string

// Built-in role IDs
var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// Existing scopes
resource primaryCs 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: primaryContentSafetyName
}

resource secondaryCs 'Microsoft.CognitiveServices/accounts@2024-10-01' existing = {
  name: secondaryContentSafetyName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' existing = {
  name: storageAccountName
}

// Key Vault always exists - it holds the APIM subscription key secret
// regardless of the external-cache toggle.
resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' existing = {
  name: keyVaultName
}

// -----------------------------------------------------------------------------
// APIM MI -> Cognitive Services User on each Content Safety account
// -----------------------------------------------------------------------------
resource apimToPrimaryCs 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(primaryCs.id, apimPrincipalId, cognitiveServicesUserRoleId)
  scope: primaryCs
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource apimToSecondaryCs 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(secondaryCs.id, apimPrincipalId, cognitiveServicesUserRoleId)
  scope: secondaryCs
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// Function MI -> Storage data plane (blob/queue/table). Flex Consumption uses
// blob for the deployment package + host metadata, queue + table for internal
// scaling/locking; without queue & table roles workers fail to spawn.
// -----------------------------------------------------------------------------
resource functionToStorageBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionPrincipalId, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource functionToStorageQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionPrincipalId, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource functionToStorageTable 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionPrincipalId, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// Optional: developer principal -> Cognitive Services User on each CS account
// -----------------------------------------------------------------------------
resource devToPrimaryCs 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(primaryCs.id, principalId, cognitiveServicesUserRoleId)
  scope: primaryCs
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: principalId
    principalType: 'User'
  }
}

resource devToSecondaryCs 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(secondaryCs.id, principalId, cognitiveServicesUserRoleId)
  scope: secondaryCs
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: principalId
    principalType: 'User'
  }
}

// -----------------------------------------------------------------------------
// Function MI -> Key Vault Secrets User on the shared KV. Required so the
// `@Microsoft.KeyVault(SecretUri=...)` reference for APIM_SUBSCRIPTION_KEY
// resolves at App Service runtime.
// -----------------------------------------------------------------------------
resource functionToKeyVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, functionPrincipalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// -----------------------------------------------------------------------------
// Optional: developer principal -> KV Secrets User (lets a human inspect/rotate
// the APIM subscription key secret without leaving the portal). Gated on the
// presence of a principal so CI runs (no principalId) don't grab the role.
// -----------------------------------------------------------------------------
resource devToKeyVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: principalId
    principalType: 'User'
  }
}
