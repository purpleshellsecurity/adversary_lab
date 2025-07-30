param location string
param namePrefix string
param workspaceResourceId string
param vmResourceId string

var dcrName = '${namePrefix}-dcr'
var vmName = last(split(vmResourceId, '/'))

// Reference the existing VM
resource vm 'Microsoft.Compute/virtualMachines@2023-03-01' existing = {
  name: vmName
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  properties: {
    dataSources: {
      windowsEventLogs: [
        {
          name: 'WindowsEventLogsDataSource'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'Security!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0)]]'
            'Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0)]]'
            'System!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0)]]'
            'Setup!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0)]]'
            'Microsoft-Windows-Windows Defender/Operational!*'
            'Microsoft-Windows-PowerShell/Operational!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0)]]'
            'Microsoft-Windows-AppLocker/EXE and DLL!*'
            'Microsoft-Windows-AppLocker/MSI and Script!*'
          ]
        }
        {
          name: 'SysmonDataSource'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'Microsoft-Windows-Sysmon/Operational!*'
          ]
        }
      ]
      performanceCounters: [
        {
          name: 'PerformanceCountersDataSource'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\Available Bytes'
            '\\Memory\\% Committed Bytes In Use'
            '\\LogicalDisk(_Total)\\Disk Reads/sec'
            '\\LogicalDisk(_Total)\\Disk Writes/sec'
            '\\LogicalDisk(_Total)\\% Free Space'
            '\\Network Interface(*)\\Bytes Total/sec'
            '\\Process(_Total)\\Handle Count'
            '\\Process(_Total)\\Thread Count'
            '\\System\\Processor Queue Length'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: workspaceResourceId
          name: 'la-workspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Event'
        ]
        destinations: [
          'la-workspace'
        ]
        transformKql: 'source'
        outputStream: 'Microsoft-Event'
      }
      {
        streams: [
          'Microsoft-Perf'
        ]
        destinations: [
          'la-workspace'
        ]
        transformKql: 'source'
        outputStream: 'Microsoft-Perf'
      }
    ]
  }
}

// Data Collection Rule Association
resource dcrAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: '${dcrName}-association'
  scope: vm
  properties: {
    dataCollectionRuleId: dcr.id
    description: 'Association between DCR and VM for security monitoring'
  }
}

output dcrId string = dcr.id
output dcrName string = dcr.name
output dcrAssociationId string = dcrAssociation.id


