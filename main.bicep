@description('Location for all resources.')
param location string = resourceGroup().location

@description('Name of the Container Apps Environment.')
param environmentName string = 'openclaw-workspace-env'

@description('Name of the OpenClaw Container App.')
param containerAppName string = 'openclaw-gateway'

@description('The full image tag from GitHub Actions (e.g., myacr.azurecr.io/my-openclaw:abc1234).')
param containerImage string

@description('The ACR login server (e.g., myacr.azurecr.io).')
param registryServer string

@description('The ACR username (usually the registry name).')
param registryUsername string

@description('The ACR password.')
@secure()
param registryPassword string

@description('Your static token to lock down the OpenClaw dashboard.')
@secure()
param openclawStaticToken string

// 1. Log Analytics Workspace
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${environmentName}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// 2. Storage Account for Persistent Memory (Must be globally unique)
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = {
  name: 'ocdata${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
}

// 3. Azure File Share (The "Trailer")
resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2022-09-01' = {
  name: '${storageAccount.name}/default/openclaw-workspace'
}

// 4. Container Apps Environment (Now linked to the File Share)
resource containerAppEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: environmentName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }

  // Register the File Share to the Environment so apps can use it
  resource storage 'storages@2023-05-01' = {
    name: 'openclaw-mount'

    // NEW DEPENDENCY: Wait for the actual File Share to be created before registering it
    dependsOn: [
      fileShare
    ]

    properties: {
      azureFile: {
        accountName: storageAccount.name
        accountKey: storageAccount.listKeys().keys[0].value
        shareName: 'openclaw-workspace'
        accessMode: 'ReadWrite'
      }
    }
  }
}

// 5. The OpenClaw Gateway Container App
resource openclawApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location

  // Existing dependency: Wait for the environment storage registration
  dependsOn: [
    containerAppEnv::storage
  ]

  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 18789
      }
      secrets: [
        {
          name: 'acr-password'
          value: registryPassword
        }
        {
          name: 'gateway-token'
          value: openclawStaticToken
        }
      ]
      registries: [
        {
          server: registryServer
          username: registryUsername
          passwordSecretRef: 'acr-password'
        }
      ]
    }
    template: {
      // Define the volume using the environment's storage link
      volumes: [
        {
          name: 'openclaw-volume'
          storageType: 'AzureFile'
          storageName: 'openclaw-mount'
        }
      ]
      containers: [
        {
          name: 'openclaw-core'
          image: containerImage
          // Correct Node.js command override to prevent crashing and bind to Azure's network
          command: [
            'node'
            'openclaw.mjs'
            'gateway'
            '--allow-unconfigured'
            '--bind'
            'lan'
          ]
          env: [
            {
              name: 'OPENCLAW_GATEWAY_AUTH_TOKEN'
              secretRef: 'gateway-token'
            }
            {
              name: 'OPENCLAW_GATEWAY_TRUSTED_PROXIES'
              value: '*'
            }
          ]
          // Physically plug the File Share into the container's memory folder
          volumeMounts: [
            {
              volumeName: 'openclaw-volume'
              mountPath: '/home/node/.openclaw'
            }
          ]
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}
