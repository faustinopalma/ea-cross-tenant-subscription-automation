targetScope = 'resourceGroup'

type tenantConfiguration = {
  eaTenantId: string
  targetTenantId: string
  sourceApplicationId: string
  targetApplicationId: string
  targetOwnerObjectId: string
  billingAccountId: string
  enrollmentAccountId: string
}

@description('Approved identities and EA billing scope. Contains no credentials.')
param configuration tenantConfiguration

@description('Region supporting Azure Automation PowerShell 7.4 runtime environments.')
param location string = resourceGroup().location

@minLength(6)
@maxLength(50)
param automationAccountName string = 'ea-subscription-automation'

@minLength(3)
@maxLength(24)
param storageAccountName string = 'earequests${uniqueString(resourceGroup().id)}'

param runbookName string = 'New-EASubscription'
param sourceCertificateAssetName string = 'ea-source-certificate'
param targetCertificateAssetName string = 'ea-target-certificate'

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
])
param storageSku string = 'Standard_LRS'

module automationAccount 'br/public:avm/res/automation/automation-account:0.16.0' = {
  params: {
    name: automationAccountName
    location: location
    skuName: 'Basic'
    managedIdentities: {
      systemAssigned: true
    }
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    enableTelemetry: false
  }
}

resource automation 'Microsoft.Automation/automationAccounts@2024-10-23' existing = {
  name: automationAccountName
}

resource runtime 'Microsoft.Automation/automationAccounts/runtimeEnvironments@2024-10-23' = {
  parent: automation
  name: 'ea-powershell74'
  location: location
  properties: {
    description: 'EA subscription execution runtime'
    runtime: {
      language: 'PowerShell'
      version: '7.4'
    }
  }
  dependsOn: [
    automationAccount
  ]
}

resource accountsPackage 'Microsoft.Automation/automationAccounts/runtimeEnvironments/packages@2024-10-23' = {
  parent: runtime
  name: 'Az.Accounts'
  properties: {
    contentLink: {
      uri: 'https://www.powershellgallery.com/api/v2/package/Az.Accounts/5.3.1'
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: storageAccountName
  location: location
  kind: 'StorageV2'
  sku: {
    name: storageSku
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    allowCrossTenantReplication: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Allow'
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: true
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    isVersioningEnabled: true
    deleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
  }
}

resource requests 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobs
  name: 'requests'
  properties: {
    publicAccess: 'None'
  }
}

var blobContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource requestAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(requests.id, automationAccountName, blobContributorRoleId)
  scope: requests
  properties: {
    roleDefinitionId: blobContributorRoleId
    principalId: automationAccount.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
  }
}

resource settings 'Microsoft.Automation/automationAccounts/variables@2024-10-23' = {
  parent: automation
  name: 'EA-Configuration'
  properties: {
    description: 'Administrator-controlled identities, billing scope and asset names'
    isEncrypted: false
    value: string(union(configuration, {
      sourceCertificateAssetName: sourceCertificateAssetName
      targetCertificateAssetName: targetCertificateAssetName
      requestContainerUri: '${storage.properties.primaryEndpoints.blob}requests'
    }))
  }
  dependsOn: [
    automationAccount
  ]
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  parent: automation
  name: runbookName
  location: location
  properties: {
    description: 'Creates and accepts a new EA subscription in the destination tenant'
    runbookType: 'PowerShell'
    runtimeEnvironment: runtime.name
    draft: {}
    logVerbose: false
    logProgress: false
  }
  dependsOn: [
    accountsPackage
  ]
}

output automationAccountResourceId string = automation.id
output runbookResourceId string = runbook.id
output requestContainerResourceId string = requests.id
output runtimeEnvironmentName string = runtime.name
output sourceCertificateName string = sourceCertificateAssetName
output targetCertificateName string = targetCertificateAssetName