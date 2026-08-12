@description('Resource ID of the Automation Account.')
param automationAccountId string

@description('Webhook URI for the emergency stop runbook. Created out of band.')
@secure()
param emergencyStopWebhookUri string

@description('Email address to notify on budget alerts.')
param alertEmail string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-budgetguard'
  location: 'Global'
  properties: {
    groupShortName: 'BudgetGuard'
    enabled: true
    emailReceivers: [
      {
        name: 'email-me'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
    automationRunbookReceivers: [
      {
        name: 'run-emergency-stop'
        automationAccountId: automationAccountId
        runbookName: 'Invoke-EmergencyStop'
        webhookResourceId: '${automationAccountId}/webhooks/wh-emergency-stop'
        isGlobalRunbook: false
        serviceUri: emergencyStopWebhookUri
        useCommonAlertSchema: true
      }
    ]
  }
}

output actionGroupId string = actionGroup.id
