// On-demand AVD session host: Win11 multi-session, TrustedLaunch, Azure AD-joined.
// The AVD agent is registered post-deploy via run-command (deploy.sh / portal) with a
// fresh host-pool token — so this template stays free of versioned DSC artifacts.
param location string
param shName string
param vmSize string
param adminUser string
@secure()
param adminPassword string
param subnetId string
param imagePublisher string = 'microsoftwindowsdesktop'
param imageOffer string = 'windows-11'
param imageSku string = 'win11-23h2-avd'
// When a registration token is supplied (portal deploy), a CustomScript installs +
// registers the AVD agent during provisioning — so the host self-registers, no
// post-deploy run-command needed. (deploy.sh leaves this empty and uses run-command.)
@secure()
param registrationToken string = ''
param agentUrl string = 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv'
param bootloaderUrl string = 'https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH'

var avdInstallCmd = 'powershell -ExecutionPolicy Unrestricted -NoProfile -Command "New-Item -ItemType Directory -Force -Path C:\\AVDAgent | Out-Null; Invoke-WebRequest -Uri \'${agentUrl}\' -OutFile C:\\AVDAgent\\agent.msi -UseBasicParsing; Invoke-WebRequest -Uri \'${bootloaderUrl}\' -OutFile C:\\AVDAgent\\boot.msi -UseBasicParsing; Start-Process msiexec.exe -Wait -ArgumentList \'/i C:\\AVDAgent\\agent.msi /quiet /norestart REGISTRATIONTOKEN=${registrationToken}\'; Start-Process msiexec.exe -Wait -ArgumentList \'/i C:\\AVDAgent\\boot.msi /quiet /norestart\'; Start-Sleep 8; Restart-Service RDAgentBootLoader -ErrorAction SilentlyContinue"'

resource nic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${shName}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: { id: subnetId }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: shName
  location: location
  identity: { type: 'SystemAssigned' }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: shName
      adminUsername: adminUser
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: imagePublisher
        offer: imageOffer
        sku: imageSku
        version: 'latest'
      }
      osDisk: {
        name: '${shName}-osdisk'
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    networkProfile: { networkInterfaces: [ { id: nic.id } ] }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
  }
}

// Azure AD join (lets users sign in with their AAD account; needs system identity).
resource aadJoin 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = {
  parent: vm
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.0'
    autoUpgradeMinorVersion: true
  }
}

// Install + register the AVD agent during provisioning (only when a token is given).
resource avdAgent 'Microsoft.Compute/virtualMachines/extensions@2023-09-01' = if (registrationToken != '') {
  parent: vm
  name: 'InstallAVDAgent'
  location: location
  dependsOn: [ aadJoin ]
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    protectedSettings: {
      commandToExecute: avdInstallCmd
    }
  }
}

output vmId string = vm.id
output principalId string = vm.identity.principalId
