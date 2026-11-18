using './main.bicep'

// Sample parameter values. Replace the image names with images you have
// pushed to your own container registry, and supply the SQL password at
// deploy time instead of storing it here:
//
//   az deployment group create \
//     --resource-group <resource-group> \
//     --template-file infra/main.bicep \
//     --parameters infra/main.bicepparam \
//     --parameters sqlAdminPassword='<strong-password>'

param environmentName = 'dev'
param catalogImage = 'myregistry.azurecr.io/catalog-api:latest'
param ordersImage = 'myregistry.azurecr.io/orders-api:latest'
param sqlAdminLogin = 'ecomadmin'
param sqlAdminPassword = ''
