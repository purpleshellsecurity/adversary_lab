targetScope = 'resourceGroup'

@description('Location for all resources')
param location string = resourceGroup().location

@description('Admin username for the VM')
param adminUsername string

@description('Admin password for the VM')
@secure()
param adminPassword string

@description('Base name prefix for resources')
param namePrefix string = 'adversarylab'

@description('VM size')
param vmSize string = 'Standard_D2s_v3'

@description('Your Public IP address to allow RDP access')
param myIP string = '' // Your Public IP address

@description('Log Analytics workspace retention in days')
param retentionInDays int = 30

@description('Enable automatic shutdown schedule')
param enableAutoShutdown bool = true

@description('Time to shutdown the VM daily (24-hour format, e.g., 2330 for 11:30 PM)')
param shutdownTime string = '2330'

@description('Timezone for the shutdown schedule')
param shutdownTimeZone string = 'Eastern Standard Time'

@description('Enable shutdown notifications')
param enableShutdownNotificationEmails bool = false

@description('Email for shutdown notifications')
param notificationEmail string = ''

@description('Minutes before shutdown to send notification')
param notificationMinutesBefore int = 15

@description('Start date for the budget (defaults to first day of current month)')
param budgetStartDate string = format('{0}-{1:D2}-01', utcNow('yyyy'), int(utcNow('MM')))

// Generate unique suffix for resource names
var resourceSuffix = substring(uniqueString(resourceGroup().id, deployment().name), 0, 3)
var uniqueNamePrefix = '${namePrefix}${resourceSuffix}'

// ===== INFRASTRUCTURE LAYER =====

// Deploy networking infrastructure
module networking 'modules/networking.bicep' = {
  name: 'networking-deployment-${resourceSuffix}'
  params: {
    location: location
    namePrefix: uniqueNamePrefix
    myIP: myIP
  }
}

// Deploy storage account for flow logs
module storage 'modules/storage.bicep' = {
  name: 'storage-deployment-${resourceSuffix}'
  params: {
    location: location
    namePrefix: uniqueNamePrefix
  }
}

// Deploy the VM with AMA
module vm 'modules/vm_ama.bicep' = {
  name: 'vm-deployment-${resourceSuffix}'
  params: {
    location: location
    namePrefix: uniqueNamePrefix
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
    subnetId: networking.outputs.subnetId
    publicIpId: networking.outputs.publicIpId
    
    // Auto-shutdown parameters
    enableAutoShutdown: enableAutoShutdown
    shutdownTime: shutdownTime
    shutdownTimeZone: shutdownTimeZone
    enableShutdownNotifications: enableShutdownNotificationEmails
    notificationEmail: notificationEmail
    notificationMinutesBefore: notificationMinutesBefore
  }
}

// ===== MONITORING LAYER =====

// Layer 1: Log Analytics Workspace
module logAnalytics 'modules/log_analytics.bicep' = {
  name: 'log-analytics-deployment-${resourceSuffix}'
  params: {
    location: location
    namePrefix: uniqueNamePrefix
    retentionInDays: retentionInDays
  }
}

// Layer 2: Sentinel Deployment
module sentinelDeployment 'modules/sentinel_deployment.bicep' = {
  name: 'sentinel-deployment-${resourceSuffix}'
  params: {
    workspaceName: logAnalytics.outputs.workspaceName
  }
}

// Layer 3: Data Collection from VM
module dataCollection 'modules/vm_data_collection.bicep' = {
  name: 'data-collection-deployment-${resourceSuffix}'
  params: {
    location: location
    namePrefix: uniqueNamePrefix
    workspaceResourceId: logAnalytics.outputs.workspaceResourceId
    vmResourceId: vm.outputs.vmResourceId
  }
}

// Layer 4: Cost Management
resource budgetAlert 'Microsoft.Consumption/budgets@2023-05-01' = if (!empty(notificationEmail)) {
  name: '${uniqueNamePrefix}-dev-budget'
  scope: resourceGroup()
  properties: {
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
    }
    amount: 50  // $50/month budget for dev environment
    category: 'Cost'
    notifications: {
      Actual: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        contactEmails: [
          notificationEmail // Email for budget alerts
        ]
      }  
    }
  }
}

// ===== OUTPUTS =====

// Infrastructure Outputs
output vmName string = vm.outputs.vmName
output vmPublicIP string = networking.outputs.publicIpAddress
output vmResourceId string = vm.outputs.vmResourceId
output uniqueNamePrefix string = uniqueNamePrefix

// Monitoring Outputs
output workspaceName string = logAnalytics.outputs.workspaceName
output workspaceId string = logAnalytics.outputs.workspaceId
output workspaceResourceId string = logAnalytics.outputs.workspaceResourceId
output dcrId string = dataCollection.outputs.dcrId

// Storage Outputs
output storageAccountName string = storage.outputs.storageAccountName
output storageAccountResourceId string = storage.outputs.storageAccountResourceId

// Resource Group Info
output resourceGroupName string = resourceGroup().name

// Helpful URLs
output sentinelUrl string = 'https://portal.azure.com/#@${subscription().tenantId}/resource${logAnalytics.outputs.workspaceResourceId}/overview'
output vmConnectCommand string = 'mstsc /v:${networking.outputs.publicIpAddress}'

// Cost Management Output
output budgetCreated bool = !empty(notificationEmail)


// Networking Outputs
output vnetId string = networking.outputs.vnetId
output vnetResourceId string = networking.outputs.vnetResourceId
output vnetName string = networking.outputs.vnetName
