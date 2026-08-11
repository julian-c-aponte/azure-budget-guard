<#
.SYNOPSIS
    Emergency cost circuit breaker. Deallocates all non-exempt VMs when an
    Azure budget threshold is breached.

.DESCRIPTION
    Triggered by an Azure Monitor action group calling this runbook's webhook.
    Parses the incoming budget alert payload, logs it in full, and deallocates
    every running VM in scope except those explicitly tagged as exempt.

    The payload shape from budget alerts has varied over time and differs
    between the legacy 'AIP Budget Notification' schema and the common alert
    schema, so parsing here is deliberately defensive: we log the raw body,
    try several known field paths, and never fail the shutdown just because
    we couldn't pretty-print the alert metadata.

.NOTES
    Runtime: PowerShell 7.2
    Auth:    System-assigned managed identity
#>

param(
    [Parameter(Mandatory = $false)]
    [object] $WebhookData,

    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName = 'rg-budgetguard-lab',

    [Parameter(Mandatory = $false)]
    [string] $ExemptTagName = 'AutoShutdown',

    [Parameter(Mandatory = $false)]
    [string] $ExemptTagValue = 'exempt',

    [Parameter(Mandatory = $false)]
    [bool] $DryRun = $false
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

Write-Output "=========================================="
Write-Output " Budget Guard :: EMERGENCY STOP"
Write-Output " Started : $($startTime.ToString('o'))"
Write-Output "=========================================="

# ---------------------------------------------------------------
# 1. Parse the incoming alert payload (defensively)
# ---------------------------------------------------------------
$alert = [ordered]@{
    BudgetName = 'unknown'
    Threshold  = 'unknown'
    Spend      = 'unknown'
    Budget     = 'unknown'
    Source     = 'manual'
}

if ($null -ne $WebhookData) {
    $alert.Source = 'webhook'

    # Gotcha: depending on how the runbook is invoked, WebhookData can arrive
    # as a proper object OR as a JSON string that merely looks like one.
    if ($WebhookData -is [string]) {
        Write-Output "[PARSE] WebhookData arrived as a string; converting."
        try   { $WebhookData = $WebhookData | ConvertFrom-Json }
        catch { Write-Warning "[PARSE] Could not convert WebhookData string: $($_.Exception.Message)" }
    }

    $rawBody = $WebhookData.RequestBody
    Write-Output "[PARSE] --- RAW REQUEST BODY START ---"
    Write-Output $rawBody
    Write-Output "[PARSE] --- RAW REQUEST BODY END ---"

    try {
        $payload = $rawBody | ConvertFrom-Json

        # Legacy budget schema: { schemaId: "AIP Budget Notification", data: { ... } }
        # Common alert schema:  { data: { essentials: {...}, alertContext: {...} } }
        $d = $payload.data

        if ($null -ne $d) {
            if ($d.PSObject.Properties.Name -contains 'BudgetName') {
                $alert.BudgetName = $d.BudgetName
                $alert.Threshold  = $d.NotificationThresholdAmount
                $alert.Spend      = $d.SpendingAmount
                $alert.Budget     = $d.BudgetAmount
            }
            elseif ($null -ne $d.alertContext) {
                $alert.BudgetName = $d.essentials.alertRule
                $alert.Threshold  = $d.alertContext.NotificationThresholdAmount
                $alert.Spend      = $d.alertContext.SpendingAmount
                $alert.Budget     = $d.alertContext.BudgetAmount
            }
        }
    }
    catch {
        Write-Warning "[PARSE] Payload parse failed, continuing anyway: $($_.Exception.Message)"
    }
}
else {
    Write-Output "[PARSE] No WebhookData — treating as a manual invocation."
}

Write-Output "[ALERT] Source     : $($alert.Source)"
Write-Output "[ALERT] Budget     : $($alert.BudgetName)"
Write-Output "[ALERT] Threshold  : $($alert.Threshold)"
Write-Output "[ALERT] Spend      : $($alert.Spend) / $($alert.Budget)"

# ---------------------------------------------------------------
# 2. Authenticate
# ---------------------------------------------------------------
try {
    Disable-AzContextAutosave -Scope Process | Out-Null
    $azContext = (Connect-AzAccount -Identity).Context
    $azContext = Set-AzContext -SubscriptionId $azContext.Subscription.Id -DefaultProfile $azContext
    Write-Output "[AUTH] Connected to: $($azContext.Subscription.Name)"
}
catch {
    Write-Error "[AUTH] Managed identity authentication failed: $($_.Exception.Message)"
    throw
}

# ---------------------------------------------------------------
# 3. Find every running VM that is NOT exempt
# ---------------------------------------------------------------
$queryParams = @{ Status = $true; DefaultProfile = $azContext }
if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $queryParams['ResourceGroupName'] = $ResourceGroupName
}

$allVMs = Get-AzVM @queryParams

$targets = $allVMs | Where-Object {
    $_.PowerState -eq 'VM running' -and
    -not ($_.Tags -and
          $_.Tags.ContainsKey($ExemptTagName) -and
          $_.Tags[$ExemptTagName] -eq $ExemptTagValue)
}

Write-Output "[SCAN] $($allVMs.Count) VM(s) in scope, $($targets.Count) targeted for emergency stop."

# ---------------------------------------------------------------
# 4. Deallocate
# ---------------------------------------------------------------
$stopped = @(); $failed = @()

foreach ($vm in $targets) {
    if ($DryRun) {
        Write-Output "[DRYRUN] Would deallocate: $($vm.Name)"
        $stopped += $vm.Name
        continue
    }
    try {
        Write-Output "[ACTION] EMERGENCY deallocating $($vm.Name) ..."
        Stop-AzVM -ResourceGroupName $vm.ResourceGroupName `
                  -Name $vm.Name -Force -DefaultProfile $azContext | Out-Null
        $stopped += $vm.Name
    }
    catch {
        Write-Warning "[ACTION] FAILED on $($vm.Name): $($_.Exception.Message)"
        $failed += $vm.Name
    }
}

$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

Write-Output "=========================================="
Write-Output " EMERGENCY STOP COMPLETE"
Write-Output " Trigger   : $($alert.BudgetName) @ $($alert.Threshold)"
Write-Output " Stopped   : $($stopped.Count) [$($stopped -join ', ')]"
Write-Output " Failed    : $($failed.Count) [$($failed -join ', ')]"
Write-Output " Duration  : ${duration}s"
Write-Output "=========================================="

if ($failed.Count -gt 0) { throw "Emergency stop incomplete: $($failed.Count) failure(s)." }