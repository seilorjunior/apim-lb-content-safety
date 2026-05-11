// Virtual network for Function App VNet integration + storage private endpoint.
//
// Two subnets:
//   - snet-functions (/27): delegated to Microsoft.App/environments — required
//     by FC1 (Flex Consumption). Minimum /27 per Microsoft docs; up to 40 IPs
//     per app even when scaled past 40 instances.
//   - snet-pe (/28): private endpoints. No delegation. privateEndpointNetworkPolicies
//     disabled so PEs can be created without an NSG/UDR carve-out.
//
// One private DNS zone (privatelink.blob.<storage suffix>) linked to the VNet
// so the function's outbound DNS for <storage>.blob.<suffix> resolves to the
// PE's private IP.
param location string
param vnetName string
param functionsSubnetName string = 'snet-functions'
param privateEndpointsSubnetName string = 'snet-pe'
param tags object

// /24 leaves headroom for additional PEs later (key vault, content safety, etc.)
var vnetAddressPrefix = '10.50.0.0/24'
// /27 → 27 usable IPs after Azure's reserved-5, FC1 minimum per docs.
var functionsSubnetPrefix = '10.50.0.0/27'
// /28 → 11 usable IPs, plenty for a handful of PEs.
var privateEndpointsSubnetPrefix = '10.50.0.32/28'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: functionsSubnetName
        properties: {
          addressPrefix: functionsSubnetPrefix
          delegations: [
            {
              // FC1 requires this exact delegation. The .NET / App Service
              // delegation (Microsoft.Web/serverFarms) is for Elastic Premium
              // and Dedicated plans, NOT Flex Consumption.
              name: 'Microsoft.App.environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: privateEndpointsSubnetName
        properties: {
          addressPrefix: privateEndpointsSubnetPrefix
          // Required for PE NIC injection without explicit NSG exception.
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// Private DNS zone for storage blob private endpoint. Name is fixed by Azure
// and depends on the cloud (public vs Gov vs China).
resource blobPrivateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

// Link the zone to the VNet so the function's outbound DNS resolves
// <storage>.blob.<suffix> → CNAME → <storage>.privatelink.blob.<suffix> →
// A → <PE private IP>.
resource blobPrivateDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: blobPrivateDnsZone
  name: '${vnetName}-blob-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output functionsSubnetId string = '${vnet.id}/subnets/${functionsSubnetName}'
output privateEndpointsSubnetId string = '${vnet.id}/subnets/${privateEndpointsSubnetName}'
output blobPrivateDnsZoneId string = blobPrivateDnsZone.id
