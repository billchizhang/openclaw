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

// 1. Log Analytics Workspace for debugging and telemetry
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

// 2. Container Apps Environment (The serverless cluster)
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
}

// 3. The OpenClaw Gateway Container App
resource openclawApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: containerAppName
  location: location
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true // Exposes the Gateway to the internet for Webhooks/Web UI
        targetPort: 18789
      }
      // Register the secret securely so it doesn't show in plaintext logs
      secrets: [
        {
          name: 'acr-password'
          value: registryPassword
        }
      ]
      // Authenticate to your private registry
      registries: [
        {
          server: registryServer
          username: registryUsername
          passwordSecretRef: 'acr-password' // References the secret defined above
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'openclaw-core'
          image: containerImage // Dynamically provided by GitHub Actions
          env: [
            {
              name: 'GATEWAY_BIND_MODE'
              value: 'cloud'
            }
            {
              name: 'GATEWAY_PORT'
              value: '18789'
            }
          ]
          resources: {
            cpu: json('1.0')
            memory: '2Gi'
          }
        }
      ]
      scale: {
        // Keeping replicas locked to 1 ensures OpenClaw's local memory 
        // doesn't fragment across multiple container instances.
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}
