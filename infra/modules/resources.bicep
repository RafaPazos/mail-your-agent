targetScope = 'resourceGroup'

@minLength(1)
@description('Name of the azd environment.')
param environmentName string

@description('Azure region for all newly created resources.')
param location string = resourceGroup().location

@description('Service name used by azd to locate the workflow app.')
param serviceName string

@description('Tags applied to all resources.')
param tags object = {}

@description('Existing Microsoft Foundry project endpoint.')
param foundryProjectEndpoint string

@description('Existing Microsoft Foundry prompt agent name.')
param foundryAgentName string

@description('Subject-line phrase that triggers the workflow (case-insensitive).')
param mailTriggerPhrase string

@description('Existing Azure AI Content Understanding endpoint, used to extract text from PDF attachments.')
param contentUnderstandingEndpoint string

var suffix = take(uniqueString(subscription().id, resourceGroup().id, environmentName), 6)
var storageAccountName = 'stmail${suffix}'
var appServicePlanName = 'asp-${environmentName}-mail-${suffix}'
var logicAppName = 'lapp-${environmentName}-mail-${suffix}'
var logAnalyticsName = 'log-${environmentName}-mail-${suffix}'
var applicationInsightsName = 'appi-${environmentName}-mail-${suffix}'
var office365ConnectionName = 'office365v2-${environmentName}-${suffix}'

var storageBlobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var storageQueueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageTableDataContributorRoleId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  // SecurityControl=Ignore is the MCAPS-documented exemption tag; without it the
  // StorageAccount_PublicNetwork_Modify policy forces publicNetworkAccess to Disabled
  // and the Logic App host cannot reach its own storage.
  tags: union(tags, {
    SecurityControl: 'Ignore'
  })
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    sku: {
      name: 'PerGB2018'
    }
  }
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: applicationInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    Flow_Type: 'Bluefield'
    IngestionMode: 'LogAnalytics'
    Request_Source: 'rest'
    WorkspaceResourceId: logAnalyticsWorkspace.id
  }
}

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  kind: 'elastic'
  sku: {
    capacity: 1
    name: 'WS1'
    tier: 'WorkflowStandard'
  }
  properties: {
    maximumElasticWorkerCount: 20
    reserved: false
  }
}

resource office365Connection 'Microsoft.Web/connections@2016-06-01' = {
  name: office365ConnectionName
  location: location
  tags: tags
  #disable-next-line BCP187
  kind: 'V2'
  properties: {
    api: {
      id: subscriptionResourceId('Microsoft.Web/locations/managedApis', location, 'office365')
    }
    displayName: 'Mail receiver Outlook connection'
  }
}

resource hostStorageIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${environmentName}-host-${suffix}'
  location: location
  tags: tags
}

resource logicApp 'Microsoft.Web/sites@2023-12-01' = {
  name: logicAppName
  location: location
  tags: union(tags, {
    'azd-service-name': serviceName
  })
  kind: 'functionapp,workflowapp'
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${hostStorageIdentity.id}': {}
    }
  }
  properties: {
    clientAffinityEnabled: false
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    serverFarmId: appServicePlan.id
    siteConfig: {
      ftpsState: 'Disabled'
      functionAppScaleLimit: 20
      minTlsVersion: '1.2'
      use32BitWorkerProcess: false
      appSettings: [
        {
          name: 'APP_KIND'
          value: 'workflowApp'
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsights.properties.ConnectionString
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__id'
          value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__version'
          value: '[1.*, 2.0.0)'
        }
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          // Blob-based secret storage requires a storage key, which is disabled tenant-wide.
          name: 'AzureWebJobsSecretStorageType'
          value: 'Files'
        }
        {
          // Logic Apps Standard host storage supports user-assigned identity only.
          name: 'AzureWebJobsStorage__credentialType'
          value: 'managedIdentity'
        }
        {
          // The Functions/WebJobs secret provider uses the SDK naming convention instead.
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'AzureWebJobsStorage__managedIdentityResourceId'
          value: hostStorageIdentity.id
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: hostStorageIdentity.properties.clientId
        }
        {
          name: 'AzureWebJobsStorage__blobServiceUri'
          value: storageAccount.properties.primaryEndpoints.blob
        }
        {
          name: 'AzureWebJobsStorage__queueServiceUri'
          value: storageAccount.properties.primaryEndpoints.queue
        }
        {
          name: 'AzureWebJobsStorage__tableServiceUri'
          value: storageAccount.properties.primaryEndpoints.table
        }
        {
          name: 'FOUNDRY_AGENT_NAME'
          value: foundryAgentName
        }
        {
          name: 'FOUNDRY_PROJECT_ENDPOINT'
          value: foundryProjectEndpoint
        }
        {
          name: 'MAIL_TRIGGER_PHRASE'
          value: mailTriggerPhrase
        }
        {
          name: 'CONTENT_UNDERSTANDING_ENDPOINT'
          value: contentUnderstandingEndpoint
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'office365-ConnectionRuntimeUrl'
          value: any(office365Connection).properties.?connectionRuntimeUrl ?? ''
        }
        {
          name: 'office365-ConnectionName'
          value: office365Connection.name
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~18'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        {
          name: 'WORKFLOWS_LOCATION_NAME'
          value: location
        }
        {
          name: 'WORKFLOWS_MANAGEMENT_BASE_URI'
          value: environment().resourceManager
        }
        {
          name: 'WORKFLOWS_RESOURCE_GROUP_NAME'
          value: resourceGroup().name
        }
        {
          name: 'WORKFLOWS_SUBSCRIPTION_ID'
          value: subscription().subscriptionId
        }
      ]
    }
  }
}

#disable-next-line BCP081
resource office365ConnectionAccessPolicy 'Microsoft.Web/connections/accessPolicies@2016-06-01' = {
  parent: office365Connection
  name: guid(office365Connection.id, logicApp.id)
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        tenantId: subscription().tenantId
        objectId: logicApp.identity.principalId
      }
    }
  }
}

resource storageBlobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicApp.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataOwnerRoleId)
  }
}

resource storageQueueRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicApp.id, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleId)
  }
}

resource storageTableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, logicApp.id, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: logicApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleId)
  }
}

resource hostIdentityStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for roleId in [
    storageBlobDataOwnerRoleId
    storageQueueDataContributorRoleId
    storageTableDataContributorRoleId
  ]: {
    name: guid(storageAccount.id, hostStorageIdentity.id, roleId)
    scope: storageAccount
    properties: {
      principalId: hostStorageIdentity.properties.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleId)
    }
  }
]

output logicAppName string = logicApp.name
output logicAppPrincipalId string = logicApp.identity.principalId
output office365ConnectionName string = office365Connection.name
output applicationInsightsConnectionString string = applicationInsights.properties.ConnectionString
