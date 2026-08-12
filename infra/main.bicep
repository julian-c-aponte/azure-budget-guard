// ---------------------------------------------------------------
// Azure Budget Guard — core resources
// Deploy at resource group scope.
// ---------------------------------------------------------------

@description('Location for the Automation Account. Must be in the Automation-supported region list.')
param location string = 'eastus2'

// Hardcoded rather than resourceGroup().location: Azure Automation maintains a
// separate region allowlist from the general subscription policy. eastus2 is the
// only region in both sets for this subscription. The RG itself is in westus2.

@description('Name of the Automation Account.')
param automationAccountName string = 'aa-budgetguard'

@description('Base URL for runbook content, e.g. the raw GitHub URL of this repo.')
param runbookBaseUri string

@description('Time zone for the nightly schedule, IANA or Windows format.')
param scheduleTimeZone string = 'America/New_York'

@description('UTC datetime the nightly schedule first fires. Must be in the future.')
param scheduleStartTime string

// Built-in role: Virtual Machine Contributor
var vmContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'

// ---------------------------------------------------------------
// Automation Account with a system-assigned managed identity
// ---------------------------------------------------------------
resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
  }
  tags: {
    project: 'budget-guard'
    managedBy: 'bicep'
  }
}

// ---------------------------------------------------------------
// Least-privilege RBAC: VM Contributor on THIS resource group only
// ---------------------------------------------------------------
resource vmContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, automationAccount.id, vmContributorRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmContributorRoleId)
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------
// Runbooks — content pulled from the public raw URLs in this repo
// ---------------------------------------------------------------
resource stopTaggedVMs 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Stop-TaggedVMs'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logProgress: true
    logVerbose: false
    description: 'Deallocates VMs carrying the AutoShutdown tag.'
    publishContentLink: {
      uri: '${runbookBaseUri}/runbooks/Stop-TaggedVMs.ps1'
    }
  }
}

resource emergencyStop 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Invoke-EmergencyStop'
  location: location
  properties: {
    runbookType: 'PowerShell72'
    logProgress: true
    logVerbose: false
    description: 'Budget-triggered emergency deallocation of all non-exempt VMs.'
    publishContentLink: {
      uri: '${runbookBaseUri}/runbooks/Invoke-EmergencyStop.ps1'
    }
  }
}

// ---------------------------------------------------------------
// Nightly schedule + job link
// ---------------------------------------------------------------
resource nightlySchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'nightly-2200'
  properties: {
    description: 'Nightly cost-hygiene shutdown.'
    startTime: scheduleStartTime
    frequency: 'Day'
    interval: 1
    timeZone: scheduleTimeZone
  }
}


output automationAccountId string = automationAccount.id
output automationAccountName string = automationAccount.name
output managedIdentityPrincipalId string = automationAccount.identity.principalId
