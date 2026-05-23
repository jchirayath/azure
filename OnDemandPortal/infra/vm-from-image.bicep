// =============================================================================
// vm-from-image.bicep — deploy the on-demand VM from the golden (specialized)
// Compute Gallery image: public IP (+DNS label), NSG, NIC, TrustedLaunch VM.
// Deployed into the target resource group (rg-axa) by the portal's Function.
// =============================================================================

@description('Azure region')
param location string = resourceGroup().location

@description('VM / resource name prefix and public DNS label')
param vmName string = 'axa'

@description('VM size')
param vmSize string = 'Standard_D4s_v3'

@description('Full resource ID of the gallery image version to deploy from')
param imageId string

@description('Resource ID of the user-assigned identity the VM uses to deallocate itself when idle (optional)')
param vmIdentityId string = ''

@description('Inbound TCP ports to open')
param openPorts array = [
  22
  80
  443
  8080
  8118
  10000
  5601
  9090
  3000
  8000
  25
  587
  465
  143
  993
]

resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: '${vmName}-ip'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    // reverseFqdn sets the PTR -> cloudapp FQDN (forward A already resolves there)
    // = valid FCrDNS, required for the mail relay's deliverability.
    dnsSettings: {
      domainNameLabel: vmName
      reverseFqdn: '${vmName}.${location}.cloudapp.azure.com'
    }
  }
}

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-09-01' = {
  name: '${vmName}-nsg'
  location: location
  properties: {
    securityRules: [for (port, i) in openPorts: {
      name: 'Allow-${port}'
      properties: {
        priority: 1000 + i * 10
        direction: 'Inbound'
        access: 'Allow'
        protocol: 'Tcp'
        sourcePortRange: '*'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
        destinationPortRange: string(port)
      }
    }]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name: '${vmName}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.20.0.0/24'] }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.20.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: { id: pip.id }
          subnet: { id: vnet.properties.subnets[0].id }
        }
      }
    ]
  }
}

// Specialized image -> NO osProfile (identity/credentials come from the image).
resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: vmName
  location: location
  identity: empty(vmIdentityId) ? null : {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${vmIdentityId}': {}
    }
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: { id: imageId }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
  }
}

output publicIp string = pip.properties.ipAddress
output fqdn string = pip.properties.dnsSettings.fqdn
output vmId string = vm.id
