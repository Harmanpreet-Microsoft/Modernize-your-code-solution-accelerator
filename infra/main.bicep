@minLength(3)
@description('Prefix for all resources created by this template. This should be 3-20 characters long. If your provide a prefix longer than 20 characters, it will be truncated to 20 characters.')
param Prefix string
var abbrs = loadJsonContent('./abbreviations.json')
var safePrefix = length(Prefix) > 20 ? substring(Prefix, 0, 20) : Prefix

@description('Required. Location for all Resources except AI Foundry.')
param solutionLocation string = resourceGroup().location

@allowed([
  'australiaeast'
  'eastus'
  'eastus2'
  'francecentral'
  'japaneast'
  'norwayeast'
  'southindia'
  'swedencentral'
  'uksouth'
  'westus'
  'westus3'
])
@description('Location for all Ai services resources. This location can be different from the resource group location.')
param AzureAiServiceLocation string  // The location used for all deployed resources.  This location must be in the same region as the resource group.

@minValue(5)
@description('Capacity of the GPT deployment:')
param capacity int = 5

param existingLogAnalyticsWorkspaceId string = ''

@minLength(1)
@description('GPT model deployment type:')
param deploymentType string = 'GlobalStandard'

@minLength(1)
@description('Name of the GPT model to deploy:')
param llmModel string = 'gpt-4o'

@minLength(1)
@description('Set the Image tag:')
param imageVersion string = 'latest'

@minLength(1)
@description('Version of the GPT model to deploy:')
param gptModelVersion string = '2024-08-06'



var uniqueId = toLower(uniqueString(subscription().id, safePrefix, resourceGroup().location))
var UniquePrefix = 'cm${padLeft(take(uniqueId, 12), 12, '0')}'
var ResourcePrefix = take('cm${safePrefix}${UniquePrefix}', 15)
var cosmosdbDatabase  = 'cmsadb'
var cosmosdbBatchContainer  = 'cmsabatch'
var cosmosdbFileContainer  = 'cmsafile'
var cosmosdbLogContainer  = 'cmsalog'
var containerName  = 'appstorage'
var storageSkuName = 'Standard_LRS'
var storageContainerName = replace(replace(replace(replace('${ResourcePrefix}cast', '-', ''), '_', ''), '.', ''),'/', '')
var azureAiServicesName = '${abbrs.ai.aiServices}${ResourcePrefix}'



var aiModelDeployments = [
  {
    name: llmModel
    model: llmModel
    version: gptModelVersion
    sku: {
      name: deploymentType
      capacity: capacity
    }
    raiPolicyName: 'Microsoft.Default'
  }
]

resource azureAiServices 'Microsoft.CognitiveServices/accounts@2024-04-01-preview' = {
  name: azureAiServicesName
  location: AzureAiServiceLocation
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  properties: {
    customSubDomainName: azureAiServicesName
    publicNetworkAccess: 'Enabled'
  }
}

@batchSize(1)
resource azureAiServicesDeployments 'Microsoft.CognitiveServices/accounts/deployments@2023-05-01' = [for aiModeldeployment in aiModelDeployments: {
  parent: azureAiServices //aiServices_m
  name: aiModeldeployment.name
  properties: {
    model: {
      format: 'OpenAI'
      name: aiModeldeployment.model
      version: aiModeldeployment.version
    }
    raiPolicyName: aiModeldeployment.raiPolicyName
  }
  sku:{
    name: aiModeldeployment.sku.name
    capacity: aiModeldeployment.sku.capacity
  }
}]



//param storageAccountId string = 'storageAccountId'
module managedIdentityModule 'deploy_managed_identity.bicep' = {
  name: 'deploy_managed_identity'
  params: {
    miName:'${abbrs.security.managedIdentity}${ResourcePrefix}'
    solutionName: ResourcePrefix
    solutionLocation: solutionLocation 
  }
  scope: resourceGroup(resourceGroup().name)
}


// ==========Key Vault Module ========== //
module kvault 'deploy_keyvault.bicep' = {
  name: 'deploy_keyvault'
  params: {
    keyvaultName: '${abbrs.security.keyVault}${ResourcePrefix}'
    solutionName: ResourcePrefix
    solutionLocation: solutionLocation
    managedIdentityObjectId:managedIdentityModule.outputs.managedIdentityOutput.objectId
  }
  scope: resourceGroup(resourceGroup().name)
}


// ==========AI Foundry and related resources ========== //
module azureAifoundry 'deploy_ai_foundry.bicep' = {
  name: 'deploy_ai_foundry'
  params: {
    solutionName: ResourcePrefix
    solutionLocation: AzureAiServiceLocation
    keyVaultName: kvault.outputs.keyvaultName
    gptModelName: llmModel
    gptModelVersion: gptModelVersion
    managedIdentityObjectId:managedIdentityModule.outputs.managedIdentityOutput.objectId
    aiServicesEndpoint: azureAiServices.properties.endpoint
    aiServicesKey: azureAiServices.listKeys().key1
    aiServicesId: azureAiServices.id
    existingLogAnalyticsWorkspaceId: existingLogAnalyticsWorkspaceId
  }
  scope: resourceGroup(resourceGroup().name)
}

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.9.1' = {
  name: toLower('${ResourcePrefix}conAppsEnv')
  params: {
    logAnalyticsWorkspaceResourceId: azureAifoundry.outputs.logAnalyticsId
    name: toLower('${ResourcePrefix}manenv')
    location: solutionLocation
    zoneRedundant: false
    managedIdentities: managedIdentityModule
  }
}

module databaseAccount 'br/public:avm/res/document-db/database-account:0.9.0' = {
  name: toLower('${abbrs.databases.cosmosDBDatabase}${ResourcePrefix}databaseAccount')
  params: {
    // Required parameters
    name: toLower('${abbrs.databases.cosmosDBDatabase}${ResourcePrefix}databaseAccount')
    // Non-required parameters
    enableAnalyticalStorage: true
    location: solutionLocation
    managedIdentities: {
      systemAssigned: true
      userAssignedResourceIds: [
        managedIdentityModule.outputs.managedIdentityOutput.resourceId
      ]
    }
    networkRestrictions: {
      networkAclBypass: 'AzureServices'
      publicNetworkAccess: 'Enabled'
      ipRules: []  // Adding ipRules as an empty array
      virtualNetworkRules: [] // Adding virtualNetworkRules as an empty array
    }
    disableKeyBasedMetadataWriteAccess: false
    locations: [
      {
        failoverPriority: 0
        isZoneRedundant: false
        locationName: solutionLocation
      }
    ]
    sqlDatabases: [
      {
        containers: [
          {
          indexingPolicy: {
            automatic: true
          }
          name: cosmosdbBatchContainer
          paths:[
            '/batch_id'
          ]
        }
        {
          indexingPolicy: {
            automatic: true
          }
          name: cosmosdbFileContainer
          paths:[
            '/file_id'
          ]
        }
        {
          indexingPolicy: {
            automatic: true
          }
          name: cosmosdbLogContainer
          paths:[
            '/log_id'
          ]
        }
        ]
        name: cosmosdbDatabase
      }
    ]
  
  }

}

module containerAppFrontend 'br/public:avm/res/app/container-app:0.13.0' = {
  name: toLower('${abbrs.containers.containerApp}${ResourcePrefix}containerAppFrontend')
  params: {
    managedIdentities: {
      systemAssigned: true
      userAssignedResourceIds: [
        managedIdentityModule.outputs.managedIdentityOutput.resourceId
      ]
    }
    // Required parameters
    containers: [
      {
        env: [
          {
            name: 'API_URL'
            value: 'https://${containerAppBackend.properties.configuration.ingress.fqdn}'
          }
        ]
        image: 'cmsacontainerreg.azurecr.io/cmsafrontend:${imageVersion}'
        name: 'cmsafrontend'
        resources: {
          cpu: '1'
          memory: '2.0Gi'
        }
      }
    ]
    ingressTargetPort: 3000
    ingressExternal: true
    scaleMinReplicas: 1
    scaleMaxReplicas: 1
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    name: toLower('${abbrs.containers.containerApp}${ResourcePrefix}Frontend')
    // Non-required parameters
    location: solutionLocation
  }
}


resource containerAppBackend 'Microsoft.App/containerApps@2023-05-01' = {
  name: toLower('${abbrs.containers.containerApp}${ResourcePrefix}Backend')
  location: solutionLocation
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.outputs.resourceId
    configuration: {
      ingress: {
        external: true
        targetPort: 8000
      }
    }
    template: {
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
      containers: [
        {
          name: 'cmsabackend'
          image: 'cmsacontainerreg.azurecr.io/cmsabackend:${imageVersion}'
          env: [
            {
              name: 'COSMOSDB_ENDPOINT'
              value: databaseAccount.outputs.endpoint
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: azureAifoundry.outputs.applicationInsightsConnectionString
            }
            {
              name: 'COSMOSDB_DATABASE'
              value: cosmosdbDatabase
            }
            {
              name: 'COSMOSDB_BATCH_CONTAINER'
              value: cosmosdbBatchContainer
            }
            {
              name: 'COSMOSDB_FILE_CONTAINER'
              value: cosmosdbFileContainer
            }
            {
              name: 'COSMOSDB_LOG_CONTAINER'
              value: cosmosdbLogContainer
            }
            {
              name: 'AZURE_BLOB_ACCOUNT_NAME'
              value: storageContianerApp.name
            }
            {
              name: 'AZURE_BLOB_CONTAINER_NAME'
              value: containerName
            }
            {
              name: 'AZURE_OPENAI_ENDPOINT'
              value: 'https://${azureAifoundry.outputs.aiServicesName}.openai.azure.com/'
            }
            {
              name: 'MIGRATOR_AGENT_MODEL_DEPLOY'
              value: llmModel
            }
            {
              name: 'PICKER_AGENT_MODEL_DEPLOY'
              value: llmModel
            }
            {
              name: 'FIXER_AGENT_MODEL_DEPLOY'
              value: llmModel
            }
            {
              name: 'SEMANTIC_VERIFIER_AGENT_MODEL_DEPLOY'
              value: llmModel
            }
            {
              name: 'SYNTAX_CHECKER_AGENT_MODEL_DEPLOY'
              value: llmModel
            }
            {
              name: 'SELECTION_MODEL_DEPLOY'
              value: llmModel
            }
            {
              name: 'TERMINATION_MODEL_DEPLOY'
              value: llmModel
            }
            {
              name: 'AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME'
              value: llmModel
            }
            {
              name: 'AZURE_AI_AGENT_PROJECT_NAME'
              value: azureAifoundry.outputs.aiProjectName
            }
            {
              name: 'AZURE_AI_AGENT_RESOURCE_GROUP_NAME'
              value: resourceGroup().name
            }
            {
              name: 'AZURE_AI_AGENT_SUBSCRIPTION_ID'
              value: subscription().subscriptionId
            }
            {
              name: 'AZURE_AI_AGENT_PROJECT_CONNECTION_STRING'
              value: azureAifoundry.outputs.projectConnectionString
            }
          ]
          resources: {
            cpu: 1
            memory: '2.0Gi'
          }
        }
      ]
    }
  }
}
resource storageContianerApp 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: storageContainerName
  location: solutionLocation
  sku: {
    name: storageSkuName
  }
  kind: 'StorageV2'
  identity: {
    type: 'SystemAssigned'  // Enables Managed Identity
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: false
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
        queue: {
          enabled: true
          keyType: 'Service'
        }
        table: {
          enabled: true
          keyType: 'Service'
        }
      }
    }
    isHnsEnabled: false
    isNfsV3Enabled: false
    keyPolicy: {
      keyExpirationPeriodInDays: 7
    }
    largeFileSharesState: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    supportsHttpsTrafficOnly: true
  }
}
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerAppBackend.id, 'Storage Blob Data Contributor')
  scope: storageContianerApp
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') // Storage Blob Data Contributor
    principalId: containerAppBackend.identity.principalId
  }
}
var openAiContributorRoleId = 'a001fd3d-188f-4b5d-821b-7da978bf7442'  // Fixed Role ID for OpenAI Contributor

resource openAiRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerAppBackend.id, openAiContributorRoleId)
  scope: azureAiServices
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', openAiContributorRoleId) // OpenAI Service Contributor
    principalId: containerAppBackend.identity.principalId
  }
}

var containerNames = [
  containerName
]

// Create a blob container resource for each container name.
resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-08-01' = [for containerName in containerNames: {
  name: '${storageContainerName}/default/${containerName}'
  properties: {
    publicAccess: 'None'
  }
  dependsOn: [azureAifoundry]
}]

resource aiHubProject 'Microsoft.MachineLearningServices/workspaces@2024-01-01-preview' existing = {
  name: '${abbrs.ai.aiHubProject}${ResourcePrefix}' // aiProjectName must be calculated - available at main start.
}

resource aiDeveloper 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  name: '64702f94-c441-49e6-a78b-ef80e0188fee'
}

resource aiDeveloperAccessProj 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerAppBackend.name, aiHubProject.id, aiDeveloper.id)
  scope: aiHubProject
  properties: {
    roleDefinitionId: aiDeveloper.id
    principalId: containerAppBackend.identity.principalId
  }
}

resource contributorRoleDefinition 'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions@2021-06-15' existing = {
  name: '${databaseAccount.name}/00000000-0000-0000-0000-000000000002'
}

var cosmosAssignCli  = 'az cosmosdb sql role assignment create --resource-group "${resourceGroup().name}" --account-name "${databaseAccount.outputs.name}" --role-definition-id "${contributorRoleDefinition.id}" --scope "${databaseAccount.outputs.resourceId}" --principal-id "${containerAppBackend.identity.principalId}"'

module deploymentScriptCLI 'br/public:avm/res/resources/deployment-script:0.5.1' = {
  name: 'deploymentScriptCLI'
  params: {
    // Required parameters
    kind: 'AzureCLI'
    name: 'rdsmin001'
    // Non-required parameters
    azCliVersion: '2.69.0'
    location: resourceGroup().location
    managedIdentities: {
      userAssignedResourceIds: [
        managedIdentityModule.outputs.managedIdentityId
      ]
    }
    scriptContent: cosmosAssignCli
  }
}
