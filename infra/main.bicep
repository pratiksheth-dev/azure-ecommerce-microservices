// ============================================================================
// Azure production target for the e-commerce microservices sample.
// Built by Pratik Sheth — sample portfolio project.
//
// Deploys:
//   * Azure Container Apps environment + Log Analytics workspace
//   * Catalog API and Orders API as container apps
//   * Azure SQL Database (serverless) for durable order/product storage
//   * Azure Service Bus namespace with an "order-events" queue for
//     asynchronous order events
//
// The two APIs run from container images you publish to your own registry
// (e.g. Azure Container Registry). Locally they use in-memory stores; the
// connection strings and queue name are injected here as configuration and
// secrets so the same images can be promoted to durable storage.
// ============================================================================

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short environment name used in resource names (for example: dev, prod).')
param environmentName string = 'dev'

@description('Container image for the Catalog API (for example: myregistry.azurecr.io/catalog-api:latest).')
param catalogImage string

@description('Container image for the Orders API (for example: myregistry.azurecr.io/orders-api:latest).')
param ordersImage string

@description('Administrator login for the Azure SQL server.')
param sqlAdminLogin string

@description('Administrator password for the Azure SQL server.')
@secure()
param sqlAdminPassword string

var prefix = 'ecom-${environmentName}'
var uniqueSuffix = uniqueString(resourceGroup().id)

// ---------------------------------------------------------------------------
// Observability
// ---------------------------------------------------------------------------

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: '${prefix}-logs'
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource containerEnv 'Microsoft.App/managedEnvironments@2023-05-01' = {
  name: '${prefix}-env'
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

// ---------------------------------------------------------------------------
// Data: Azure SQL (serverless) — durable store for products and orders
// ---------------------------------------------------------------------------

resource sqlServer 'Microsoft.Sql/servers@2022-05-01-preview' = {
  name: '${prefix}-sql-${uniqueSuffix}'
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    version: '12.0'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2022-05-01-preview' = {
  parent: sqlServer
  name: 'ecommerce'
  location: location
  sku: {
    name: 'GP_S_Gen5_1'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1
  }
  properties: {
    autoPauseDelay: 60
    minCapacity: json('0.5')
  }
}

// Allow other Azure services (including Container Apps) to reach the server.
// In production, prefer private endpoints / VNet integration over this rule.
resource sqlFirewallAzureServices 'Microsoft.Sql/servers/firewallRules@2022-05-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ---------------------------------------------------------------------------
// Messaging: Service Bus — asynchronous order events
// ---------------------------------------------------------------------------

resource serviceBus 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: '${prefix}-sb-${uniqueSuffix}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {}
}

resource orderEventsQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: serviceBus
  name: 'order-events'
  properties: {
    lockDuration: 'PT1M'
    maxDeliveryCount: 10
    defaultMessageTimeToLive: 'P14D'
  }
}

// Least-privilege rule used by the Orders API to publish and listen.
resource serviceBusAuthRule 'Microsoft.ServiceBus/namespaces/AuthorizationRules@2022-10-01-preview' = {
  parent: serviceBus
  name: 'orders-app'
  properties: {
    rights: [
      'Send'
      'Listen'
    ]
  }
}

// ---------------------------------------------------------------------------
// Compute: the two microservices on Azure Container Apps
// ---------------------------------------------------------------------------

resource catalogApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${prefix}-catalog'
  location: location
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
      }
      secrets: [
        {
          name: 'sql-connection'
          value: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=ecommerce;User ID=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;'
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'catalog-api'
          image: catalogImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'ConnectionStrings__DefaultConnection'
              secretRef: 'sql-connection'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

resource ordersApp 'Microsoft.App/containerApps@2023-05-01' = {
  name: '${prefix}-orders'
  location: location
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
      }
      secrets: [
        {
          name: 'sql-connection'
          value: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=ecommerce;User ID=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;'
        }
        {
          name: 'servicebus-connection'
          value: serviceBusAuthRule.listKeys().primaryConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'orders-api'
          image: ordersImage
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              // Service-to-service call target: the catalog app's public FQDN.
              name: 'CatalogApi__BaseUrl'
              value: 'https://${catalogApp.properties.configuration.ingress.fqdn}'
            }
            {
              name: 'ConnectionStrings__DefaultConnection'
              secretRef: 'sql-connection'
            }
            {
              name: 'ServiceBus__ConnectionString'
              secretRef: 'servicebus-connection'
            }
            {
              name: 'ServiceBus__QueueName'
              value: orderEventsQueue.name
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output catalogUrl string = 'https://${catalogApp.properties.configuration.ingress.fqdn}'
output ordersUrl string = 'https://${ordersApp.properties.configuration.ingress.fqdn}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output serviceBusNamespace string = serviceBus.name
output orderEventsQueueName string = orderEventsQueue.name
