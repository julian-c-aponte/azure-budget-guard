targetScope = 'subscription'

@description('Resource ID of the action group to notify.')
param actionGroupId string

@description('Monthly budget amount in the billing currency.')
param budgetAmount int = 50

@description('First day of the budget period, format yyyy-MM-01.')
param startDate string

param alertEmails array = []

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: 'budget-guard-monthly'
  properties: {
    category: 'Cost'
    amount: budgetAmount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      warning50: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 50
        thresholdType: 'Actual'
        contactEmails: alertEmails
        contactGroups: [ actionGroupId ]
      }
      forecast80: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 80
        thresholdType: 'Forecasted'
        contactEmails: alertEmails
        contactGroups: [ actionGroupId ]
      }
      critical100: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: alertEmails
        contactGroups: [ actionGroupId ]
      }
    }
  }
}
