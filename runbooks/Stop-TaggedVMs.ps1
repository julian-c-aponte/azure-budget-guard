<#
.SYNOPSIS
    Deallocates Azure VMs carrying a specified shutdown tag.

.DESCRIPTION
    Part of the Azure Budget Guard project. Authenticates using the Automation
    account's system-assigned managed identity, finds running VMs matching a
    tag key/value pair, and deallocates them to stop compute billing.

    Supports a dry-run mode so the filter logic can be validated before any
    VM is actually touched.

.NOTES
    Runtime: PowerShell 7.2
    Auth:    System-assigned managed identity
    RBAC:    Virtual Machine Contributor on the target scope
#>

param(
    # Leave empty to scan the whole subscription (requires broader RBAC)
    [Parameter(Mandatory = $false)]
    [string] $ResourceGroupName = 'rg-budgetguard-lab',

    [Parameter(Mandatory = $false)]
    [string] $TagName = 'AutoShutdown',

    [Parameter(Mandatory = $false)]
    [string] $TagValue = 'true',

    # Defaults to TRUE on purpose. A cost-control bot that deletes capacity
    # by accident is worse than no bot at all.
    [Parameter(Mandatory = $false)]
    [bool] $DryRun = $true
)

$ErrorActionPreference = 'Stop'
$startTime = Get-Date

Write-Output "=========================================="
Write-Output " Budget Guard :: Stop-TaggedVMs"
Write-Output " Started : $($startTime.ToString('o'))"
Write-Output " Scope   : $(if ($ResourceGroupName) { $ResourceGroupName } else { 'ENTIRE SUBSCRIPTION' })"
Write-Output " Filter  : $TagName = $TagValue"
Write-Output " DryRun  : $DryRun"
Write-Output "=========================================="

# ---------------------------------------------------------------
# 1. Authenticate with the system-assigned managed identity
# ---------------------------------------------------------------
try {
    # Prevent context bleeding between concurrent runbook jobs in the sandbox
    Disable-AzContextAutosave -Scope Process | Out-Null

    $azContext = (Connect-AzAccount -Identity).Context
    $azContext = Set-AzContext -SubscriptionId $azContext.Subscription.Id -DefaultProfile $azContext

    Write-Output "[AUTH] Connected to subscription: $($azContext.Subscription.Name)"
}
catch {
    Write-Error "[AUTH] Managed identity authentication failed: $($_.Exception.Message)"
    throw
}

# ---------------------------------------------------------------
# 2. Discover VMs
# ---------------------------------------------------------------
$queryParams = @{ Status = $true; DefaultProfile = $azContext }
if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $queryParams['ResourceGroupName'] = $ResourceGroupName
}

$allVMs = Get-AzVM @queryParams
Write-Output "[SCAN] Found $($allVMs.Count) VM(s) in scope."

# ---------------------------------------------------------------
# 3. Filter by tag AND running state
# ---------------------------------------------------------------
$targets = $allVMs | Where-Object {
    $_.Tags -and
    $_.Tags.ContainsKey($TagName) -and
    $_.Tags[$TagName] -eq $TagValue -and
    $_.PowerState -eq 'VM running'
}

foreach ($vm in $allVMs) {
    $tagVal = if ($vm.Tags -and $vm.Tags.ContainsKey($TagName)) { $vm.Tags[$TagName] } else { '<none>' }
    $verdict = if ($targets.Name -contains $vm.Name) { 'TARGET' } else { 'skip' }
    Write-Output ("[SCAN]   {0,-14} power={1,-14} {2}={3,-8} => {4}" -f $vm.Name, $vm.PowerState, $TagName, $tagVal, $verdict)
}

if ($targets.Count -eq 0) {
    Write-Output "[DONE] Nothing to do. No running VMs matched the filter."
    return
}

# ---------------------------------------------------------------
# 4. Act
# ---------------------------------------------------------------
$stopped = @()
$failed  = @()

foreach ($vm in $targets) {
    if ($DryRun) {
        Write-Output "[DRYRUN] Would deallocate: $($vm.ResourceGroupName)/$($vm.Name)"
        $stopped += $vm.Name
        continue
    }

    try {
        Write-Output "[ACTION] Deallocating $($vm.Name) ..."
        # Stop-AzVM deallocates by default, which is what actually stops
        # compute billing. -StayProvisioned would stop the OS but keep
        # charging you, which defeats the whole purpose.
        Stop-AzVM -ResourceGroupName $vm.ResourceGroupName `
                  -Name $vm.Name `
                  -Force `
                  -DefaultProfile $azContext | Out-Null

        Write-Output "[ACTION] Deallocated $($vm.Name)"
        $stopped += $vm.Name
    }
    catch {
        Write-Warning "[ACTION] FAILED on $($vm.Name): $($_.Exception.Message)"
        $failed += $vm.Name
    }
}

# ---------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------
$duration = [math]::Round(((Get-Date) - $startTime).TotalSeconds, 1)

Write-Output "=========================================="
Write-Output " SUMMARY"
Write-Output " Mode      : $(if ($DryRun) { 'DRY RUN' } else { 'LIVE' })"
Write-Output " Succeeded : $($stopped.Count) [$($stopped -join ', ')]"
Write-Output " Failed    : $($failed.Count) [$($failed -join ', ')]"
Write-Output " Duration  : ${duration}s"
Write-Output "=========================================="

if ($failed.Count -gt 0) {
    throw "Deallocation failed for $($failed.Count) VM(s)."
}