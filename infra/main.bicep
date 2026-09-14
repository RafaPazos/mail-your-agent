targetScope = 'subscription'

@minLength(1)
@description('Name of the azd environment.')
param environmentName string

@description('Azure region for the deployment.')
param location string

@description('Existing Microsoft Foundry project endpoint.')
param foundryProjectEndpoint string

@description('Existing prompt agent name.')
param foundryAgentName string

@description('Subject-line phrase that triggers the workflow (case-insensitive).')
param mailTriggerPhrase string

@description('Existing Azure AI Content Understanding endpoint, used to extract text from PDF attachments.')
param contentUnderstandingEndpoint string

@description('Resource group of the existing Microsoft Foundry account.')
param foundryResourceGroupName string

@description('Name of the existing Microsoft Foundry account.')
param foundryResourceName string

var tags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}-mail-lapp'
  location: location
  tags: tags
}

module resources './modules/resources.bicep' = {
  name: 'mail-lapp-resources'
  scope: rg
  params: {
    environmentName: environmentName
    location: location
    serviceName: 'logic-app'
    tags: tags
    foundryProjectEndpoint: foundryProjectEndpoint
    foundryAgentName: foundryAgentName
    mailTriggerPhrase: mailTriggerPhrase
    contentUnderstandingEndpoint: contentUnderstandingEndpoint
  }
}

module foundryRbac './modules/foundry-rbac.bicep' = {
  name: 'mail-lapp-foundry-rbac'
  scope: resourceGroup(foundryResourceGroupName)
  params: {
    foundryResourceName: foundryResourceName
    principalId: resources.outputs.logicAppPrincipalId
  }
}

output AZURE_RESOURCE_GROUP string = rg.name
output LOGIC_APP_NAME string = resources.outputs.logicAppName
output OFFICE365_CONNECTION_NAME string = resources.outputs.office365ConnectionName
output APPLICATIONINSIGHTS_CONNECTION_STRING string = resources.outputs.applicationInsightsConnectionString
