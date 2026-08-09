<#
.SYNOPSIS
Converts a zonal Azure VM to a regional VM in-place.

.DESCRIPTION
This script snapshots the source VM OS and data disks, creates new regional
managed disks from those snapshots, deletes the source VM while preserving
NICs/disks, and creates a replacement regional VM using the same NICs and
configuration where possible.

The source VM object is deleted and replaced using the same VM name.

An active Azure CLI session is required. The script does not run az login.

.PARAMETER ResourceGroupName
Resource group containing the source VM.

.PARAMETER VmName
Name of the source zonal VM to convert.

.PARAMETER TargetVmName
Reserved parameter. The script always recreates the VM with the same source VM
name.

.PARAMETER TargetVmSize
Optional target VM size. Defaults to the source VM size.

.PARAMETER SubscriptionId
Optional Azure subscription name or ID.

.PARAMETER TenantId
Optional Microsoft Entra tenant ID used in the az login guidance message.

.PARAMETER TargetDiskSkuName
Optional disk SKU used for new regional OS/data disks. Defaults to each source
 disk's current SKU.

.PARAMETER KeepSnapshots
Keeps the temporary snapshots after successful conversion.

.EXAMPLE
.\Convert-AzZonalVmToRegional.ps1 -ResourceGroupName rg-prod -VmName app01

.EXAMPLE
.\Convert-AzZonalVmToRegional.ps1 -ResourceGroupName rg-prod -VmName app01 -Confirm:$false

.EXAMPLE
.\Convert-AzZonalVmToRegional.ps1

Prompts with menus to select resource group and VM, with manual entry options.

.NOTES
Author: Henrique Rezende
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$ResourceGroupName,

    [Alias("SourceVmName")]
    [string]$VmName,

    [string]$TargetVmName,

    [string]$TargetVmSize,

    [string]$SubscriptionId,

    [string]$TenantId,

    [ValidateSet("Standard_LRS", "Premium_LRS", "StandardSSD_LRS", "PremiumV2_LRS", "UltraSSD_LRS")]
    [string]$TargetDiskSkuName,

    [switch]$KeepSnapshots
)

function Get-ResourceGroupFromResourceId {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceId
    )

    if ($ResourceId -match "/resourceGroups/([^/]+)/") {
        return $Matches[1]
    }

    throw "Could not parse resource group from resource ID '$ResourceId'."
}

function Show-AzureMenuHeader {
    Write-Host ""
    Write-Host "Active Azure subscription" -ForegroundColor Yellow
    Write-Host "  $script:ActiveAzureSubscriptionLabel"
}

function Select-AzResourceGroupName {
    param(
        [string]$CurrentValue
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue
    }

    $resourceGroups = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName)
    if ($resourceGroups.Count -eq 0) {
        throw "No resource groups were found in the active subscription."
    }
    $visibleResourceGroups = @($resourceGroups | Select-Object -First 10)

    while ($true) {
        Show-AzureMenuHeader
        Write-Host "Choose source resource group" -ForegroundColor Cyan
        for ($index = 0; $index -lt $visibleResourceGroups.Count; $index++) {
            $resourceGroup = $visibleResourceGroups[$index]
            Write-Host ("[{0}] {1} ({2})" -f ($index + 1), $resourceGroup.ResourceGroupName, $resourceGroup.Location)
        }
        if ($resourceGroups.Count -gt $visibleResourceGroups.Count) {
            Write-Host ("Showing first {0} of {1}. Use manual entry to target another resource group." -f $visibleResourceGroups.Count, $resourceGroups.Count) -ForegroundColor Yellow
        }
        Write-Host "[M] Manually type resource group name"
        Write-Host "[0] Cancel"

        $selectionText = (Read-Host "Enter selection").Trim()
        if ($selectionText -eq "0") {
            throw "Selection cancelled."
        }

        if ($selectionText -match "^(?i:m|manual)$") {
            $manualValue = (Read-Host "Enter resource group name").Trim()
            if (-not [string]::IsNullOrWhiteSpace($manualValue)) {
                return $manualValue
            }

            Write-Warning "Resource group name cannot be empty."
            continue
        }

        $selection = 0
        if ([int]::TryParse($selectionText, [ref]$selection) -and $selection -ge 1 -and $selection -le $visibleResourceGroups.Count) {
            return $visibleResourceGroups[$selection - 1].ResourceGroupName
        }

        Write-Warning "Enter a number from 1 to $($visibleResourceGroups.Count), M for manual entry, or 0 to cancel."
    }
}

function Select-AzVmName {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [string]$CurrentValue
    )

    if (-not [string]::IsNullOrWhiteSpace($CurrentValue)) {
        return $CurrentValue
    }

    while ($true) {
        $resourceGroupVms = @(
            Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue |
            Where-Object { $_.Zones -and $_.Zones.Count -gt 0 } |
            Sort-Object Name
        )

        $visibleResourceGroupVms = @($resourceGroupVms | Select-Object -First 10)

        Show-AzureMenuHeader
        Write-Host "Choose source zonal VM in resource group '$ResourceGroupName'" -ForegroundColor Cyan
        if ($visibleResourceGroupVms.Count -gt 0) {
            for ($index = 0; $index -lt $visibleResourceGroupVms.Count; $index++) {
                $vm = $visibleResourceGroupVms[$index]
                $zoneLabel = if ($vm.Zones -and $vm.Zones.Count -gt 0) { $vm.Zones -join "," } else { "regional" }
                Write-Host ("[{0}] {1} ({2}, zone: {3}, {4})" -f ($index + 1), $vm.Name, $vm.Location, $zoneLabel, $vm.HardwareProfile.VmSize)
            }
            if ($resourceGroupVms.Count -gt $visibleResourceGroupVms.Count) {
                Write-Host ("Showing first {0} of {1}. Use manual entry to target another VM." -f $visibleResourceGroupVms.Count, $resourceGroupVms.Count) -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "No zonal VMs were found in this resource group." -ForegroundColor Yellow
        }
        Write-Host "[M] Manually type VM name"
        Write-Host "[0] Cancel"

        $selectionText = (Read-Host "Enter selection").Trim()
        if ($selectionText -eq "0") {
            throw "Selection cancelled."
        }

        if ($selectionText -match "^(?i:m|manual)$") {
            $manualValue = (Read-Host "Enter VM name").Trim()
            if (-not [string]::IsNullOrWhiteSpace($manualValue)) {
                return $manualValue
            }

            Write-Warning "VM name cannot be empty."
            continue
        }

        if ($visibleResourceGroupVms.Count -eq 0) {
            Write-Warning "No indexed selection is available. Use M for manual VM name entry."
            continue
        }

        $selection = 0
        if ([int]::TryParse($selectionText, [ref]$selection) -and $selection -ge 1 -and $selection -le $visibleResourceGroupVms.Count) {
            return $visibleResourceGroupVms[$selection - 1].Name
        }

        Write-Warning "Enter a number from 1 to $($visibleResourceGroupVms.Count), M for manual entry, or 0 to cancel."
    }
}

function Wait-AzVmPowerState {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [Parameter(Mandatory)]
        [string[]]$ExpectedState,

        [int]$TimeoutMinutes = 20
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction Stop
        $powerState = ($vmStatus.Statuses | Where-Object Code -like "PowerState/*" | Select-Object -First 1).Code -replace "^PowerState/", ""
        if ($powerState -in $ExpectedState) {
            return $powerState
        }

        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "VM '$VmName' did not reach power state '$($ExpectedState -join "' or '")' within $TimeoutMinutes minutes."
}

function Wait-AzVmDeletion {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [int]$TimeoutMinutes = 10
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            return
        }

        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "VM '$VmName' was not deleted within $TimeoutMinutes minutes."
}

function New-RegionalDiskFromSnapshot {
    param(
        [Parameter(Mandatory)]
        [Microsoft.Azure.Commands.Compute.Automation.Models.PSDisk]$SourceDisk,

        [Parameter(Mandatory)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory)]
        [string]$NameSuffix,

        [string]$DiskSkuName,

        [switch]$IsOsDisk
    )

    $snapshotName = "{0}-regional-snap-{1}" -f $SourceDisk.Name, $NameSuffix
    $newDiskName = "{0}-regional-{1}" -f $SourceDisk.Name, $NameSuffix

    $snapshotConfig = New-AzSnapshotConfig -SourceUri $SourceDisk.Id -CreateOption Copy -Location $SourceDisk.Location -ErrorAction Stop
    $snapshot = New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $TargetResourceGroupName -ErrorAction Stop

    $effectiveSku = if ([string]::IsNullOrWhiteSpace($DiskSkuName)) { $SourceDisk.Sku.Name } else { $DiskSkuName }
    $diskConfig = New-AzDiskConfig -SourceResourceId $snapshot.Id -CreateOption Copy -Location $SourceDisk.Location -SkuName $effectiveSku -ErrorAction Stop

    # Do not set zone on purpose. Omitting zone creates a regional disk.
    if ($IsOsDisk) {
        if ($SourceDisk.OsType -eq "Windows") {
            $diskConfig.OsType = "Windows"
        }
        elseif ($SourceDisk.OsType -eq "Linux") {
            $diskConfig.OsType = "Linux"
        }
    }

    $newDisk = New-AzDisk -Disk $diskConfig -DiskName $newDiskName -ResourceGroupName $TargetResourceGroupName -ErrorAction Stop

    [PSCustomObject]@{
        Snapshot = $snapshot
        Disk = $newDisk
    }
}

function Write-MigrationStepProgress {
    param(
        [Parameter(Mandatory)]
        [string]$Activity,

        [Parameter(Mandatory)]
        [ValidateRange(1, 5)]
        [int]$Step,

        [Parameter(Mandatory)]
        [string]$Status
    )

    $percentComplete = [math]::Floor(($Step / 5) * 100)
    Write-Progress -Id 1 -Activity $Activity -Status ("$Status (step $Step of 5)") -PercentComplete $percentComplete
}

foreach ($commandName in @(
    "az",
    "Connect-AzAccount",
    "Get-AzResourceGroup",
    "Get-AzVM",
    "Update-AzVM",
    "Stop-AzVM",
    "Remove-AzVM",
    "Get-AzDisk",
    "New-AzSnapshotConfig",
    "New-AzSnapshot",
    "Remove-AzSnapshot",
    "New-AzDiskConfig",
    "New-AzDisk",
    "New-AzVM",
    "New-AzVMConfig",
    "Set-AzVMBootDiagnostic",
    "Set-AzVMOSDisk",
    "Set-AzVMPlan",
    "Set-AzVMSecurityProfile",
    "Add-AzVMDataDisk",
    "Add-AzVMNetworkInterface"
)) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found. Install requirements and try again."
    }
}

$tokenCheckArguments = @("account", "get-access-token", "--output", "none")
if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $tokenCheckArguments += @("--subscription", $SubscriptionId)
}
$null = & az @tokenCheckArguments 2>$null
if ($LASTEXITCODE -ne 0) {
    $loginCommand = if ([string]::IsNullOrWhiteSpace($TenantId)) { "az login" } else { "az login --tenant `"$TenantId`"" }
    throw "No valid Azure CLI session was found. Run '$loginCommand', select the required subscription, and run this script again."
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    az account set --subscription $SubscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to select Azure subscription '$SubscriptionId'."
    }
}

$azAccount = az account show --output json --only-show-errors | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or -not $azAccount.id) {
    throw "Azure CLI has no active subscription."
}

$accessToken = az account get-access-token --subscription $azAccount.id --query accessToken --output tsv
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
    throw "Azure CLI could not acquire an access token for the active subscription."
}

Connect-AzAccount -AccessToken $accessToken -AccountId $azAccount.user.name -Tenant $azAccount.tenantId -Subscription $azAccount.id -ErrorAction Stop | Out-Null

$script:ActiveAzureSubscriptionLabel = "$($azAccount.name) [$($azAccount.id)]"

$ResourceGroupName = Select-AzResourceGroupName -CurrentValue $ResourceGroupName
$VmName = Select-AzVmName -ResourceGroupName $ResourceGroupName -CurrentValue $VmName

$sourceVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
$sourceVmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction Stop

if (-not [string]::IsNullOrWhiteSpace($TargetVmName) -and $TargetVmName -ne $VmName) {
    throw "This script recreates the VM using the original source name. Remove -TargetVmName or set it to '$VmName'."
}
$TargetVmName = $VmName

if (-not $TargetVmSize) {
    $TargetVmSize = $sourceVm.HardwareProfile.VmSize
}

$existingTargetVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $TargetVmName -ErrorAction SilentlyContinue
if ($existingTargetVm -and $TargetVmName -ne $VmName) {
    throw "Target VM '$TargetVmName' already exists in resource group '$ResourceGroupName'."
}

$vmZone = if ($sourceVm.Zones -and $sourceVm.Zones.Count -gt 0) { $sourceVm.Zones -join "," } else { "none" }
if (-not $sourceVm.Zones -or $sourceVm.Zones.Count -eq 0) {
    Write-Warning "Source VM '$VmName' is not marked as zonal at VM level. Continuing, but verify your disk zone configuration."
}

$osDiskResourceGroup = Get-ResourceGroupFromResourceId -ResourceId $sourceVm.StorageProfile.OsDisk.ManagedDisk.Id
$sourceOsDisk = Get-AzDisk -ResourceGroupName $osDiskResourceGroup -DiskName $sourceVm.StorageProfile.OsDisk.Name -ErrorAction Stop

$sourceDataDiskContexts = @()
foreach ($sourceDataDiskReference in @($sourceVm.StorageProfile.DataDisks | Sort-Object Lun)) {
    $dataDiskResourceGroup = Get-ResourceGroupFromResourceId -ResourceId $sourceDataDiskReference.ManagedDisk.Id
    $sourceDataDisk = Get-AzDisk -ResourceGroupName $dataDiskResourceGroup -DiskName $sourceDataDiskReference.Name -ErrorAction Stop

    $sourceDataDiskContexts += [PSCustomObject]@{
        Reference = $sourceDataDiskReference
        Disk = $sourceDataDisk
    }
}

$confirmationSummary = @(
    "Subscription: $($azAccount.name) [$($azAccount.id)]"
    "Resource group: $ResourceGroupName"
    "Source VM: $VmName"
    "Source VM zone: $vmZone"
    "Target VM: $TargetVmName"
    "Target VM size: $TargetVmSize"
    "OS disk: $($sourceOsDisk.Name) -> regional copy"
    "Data disks: $($sourceDataDiskContexts.Count)"
    "Reuse existing NICs: Yes (detach/re-attach where possible)"
) -join [Environment]::NewLine

if (-not $PSCmdlet.ShouldProcess($confirmationSummary, "Convert zonal VM '$VmName' to regional VM '$TargetVmName'")) {
    return
}

$createdSnapshots = [System.Collections.Generic.List[object]]::new()
$createdRegionalDataDisks = [System.Collections.Generic.List[object]]::new()
$createdRegionalOsDisk = $null

try {
    $progressActivity = "Converting zonal VM '$VmName' to regional"

    Write-MigrationStepProgress -Activity $progressActivity -Step 1 -Status "Snapshot source OS disk"
    Write-Host "Step 1/5: Snapshot source OS disk." -ForegroundColor Cyan
    $osConversion = New-RegionalDiskFromSnapshot -SourceDisk $sourceOsDisk -TargetResourceGroupName $ResourceGroupName -NameSuffix ([Guid]::NewGuid().ToString("N").Substring(0, 8)) -DiskSkuName $TargetDiskSkuName -IsOsDisk
    $createdSnapshots.Add($osConversion.Snapshot)
    $createdRegionalOsDisk = $osConversion.Disk

    Write-MigrationStepProgress -Activity $progressActivity -Step 2 -Status "Create regional disk copies"
    Write-Host "Step 2/5: Create regional OS disk copy." -ForegroundColor Cyan
    Write-Host "Created regional OS disk '$($createdRegionalOsDisk.Name)'." -ForegroundColor Green

    if ($sourceDataDiskContexts.Count -gt 0) {
        Write-Host "Step 2/5 (data disks): Snapshot and create regional copies for data disks." -ForegroundColor Cyan
        foreach ($dataDiskContext in $sourceDataDiskContexts) {
            $conversion = New-RegionalDiskFromSnapshot -SourceDisk $dataDiskContext.Disk -TargetResourceGroupName $ResourceGroupName -NameSuffix ([Guid]::NewGuid().ToString("N").Substring(0, 8)) -DiskSkuName $TargetDiskSkuName
            $createdSnapshots.Add($conversion.Snapshot)
            $createdRegionalDataDisks.Add([PSCustomObject]@{
                SourceReference = $dataDiskContext.Reference
                NewDisk = $conversion.Disk
            })
        }
    }

    Write-MigrationStepProgress -Activity $progressActivity -Step 3 -Status "Delete source VM and preserve resources"
    Write-Host "Step 3/5: Stop and delete source VM while preserving NICs and disks." -ForegroundColor Cyan
    $sourcePowerState = ($sourceVmStatus.Statuses | Where-Object Code -like "PowerState/*" | Select-Object -First 1).Code -replace "^PowerState/", ""
    if ($sourcePowerState -notin @("stopped", "deallocated")) {
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force -ErrorAction Stop | Out-Null
        $null = Wait-AzVmPowerState -ResourceGroupName $ResourceGroupName -VmName $VmName -ExpectedState @("stopped", "deallocated") -TimeoutMinutes 20
    }

    # Set delete options to Detach so VM delete does not remove NICs/disks.
    $sourceVmForDetach = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
    $sourceVmForDetach.StorageProfile.OsDisk.DeleteOption = "Detach"
    foreach ($attachedDataDisk in @($sourceVmForDetach.StorageProfile.DataDisks)) {
        $attachedDataDisk.DeleteOption = "Detach"
    }
    foreach ($attachedNic in @($sourceVmForDetach.NetworkProfile.NetworkInterfaces)) {
        $attachedNic.DeleteOption = "Detach"
    }
    Update-AzVM -ResourceGroupName $ResourceGroupName -VM $sourceVmForDetach -ErrorAction Stop | Out-Null

    Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force -ErrorAction Stop | Out-Null
    Wait-AzVmDeletion -ResourceGroupName $ResourceGroupName -VmName $VmName -TimeoutMinutes 10

    Write-MigrationStepProgress -Activity $progressActivity -Step 4 -Status "Create replacement regional VM"
    Write-Host "Step 4/5: Create replacement regional VM with source configuration." -ForegroundColor Cyan
    $newVmConfig = New-AzVMConfig -VMName $TargetVmName -VMSize $TargetVmSize -ErrorAction Stop

    if ($sourceVm.DiagnosticsProfile.BootDiagnostics.Enabled -eq $true) {
        if ($sourceVm.DiagnosticsProfile.BootDiagnostics.StorageUri) {
            $newVmConfig = Set-AzVMBootDiagnostic -VM $newVmConfig -Enable -ResourceGroupName $ResourceGroupName -StorageUri $sourceVm.DiagnosticsProfile.BootDiagnostics.StorageUri
        }
        else {
            $newVmConfig = Set-AzVMBootDiagnostic -VM $newVmConfig -Enable
        }
    }
    else {
        $newVmConfig = Set-AzVMBootDiagnostic -VM $newVmConfig -Disable
    }

    if ($createdRegionalOsDisk.OsType -eq "Windows") {
        $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig -ManagedDiskId $createdRegionalOsDisk.Id -CreateOption Attach -Windows -DeleteOption Detach
    }
    elseif ($createdRegionalOsDisk.OsType -eq "Linux") {
        $newVmConfig = Set-AzVMOSDisk -VM $newVmConfig -ManagedDiskId $createdRegionalOsDisk.Id -CreateOption Attach -Linux -DeleteOption Detach
    }
    else {
        throw "Regional OS disk '$($createdRegionalOsDisk.Name)' does not have a recognized OS type."
    }

    foreach ($sourceNicRef in @($sourceVm.NetworkProfile.NetworkInterfaces)) {
        if ($sourceNicRef.Primary -eq $true) {
            $newVmConfig = Add-AzVMNetworkInterface -VM $newVmConfig -Id $sourceNicRef.Id -Primary -DeleteOption Detach
        }
        else {
            $newVmConfig = Add-AzVMNetworkInterface -VM $newVmConfig -Id $sourceNicRef.Id -DeleteOption Detach
        }
    }

    foreach ($regionalDataDiskContext in @($createdRegionalDataDisks | Sort-Object { $_.SourceReference.Lun })) {
        $sourceReference = $regionalDataDiskContext.SourceReference
        $regionalDataDisk = $regionalDataDiskContext.NewDisk

        $newVmConfig = Add-AzVMDataDisk -VM $newVmConfig -Name $regionalDataDisk.Name -ManagedDiskId $regionalDataDisk.Id -Lun $sourceReference.Lun -Caching $sourceReference.Caching -CreateOption Attach -DeleteOption Detach
    }

    if (-not [string]::IsNullOrWhiteSpace($sourceVm.LicenseType)) {
        $newVmConfig.LicenseType = $sourceVm.LicenseType
    }

    if ($sourceVm.Plan) {
        $newVmConfig = Set-AzVMPlan -VM $newVmConfig -Publisher $sourceVm.Plan.Publisher -Product $sourceVm.Plan.Product -Name $sourceVm.Plan.Name
    }

    if ($sourceVm.SecurityProfile -and -not [string]::IsNullOrWhiteSpace($sourceVm.SecurityProfile.SecurityType)) {
        $newVmConfig = Set-AzVMSecurityProfile -VM $newVmConfig -SecurityType $sourceVm.SecurityProfile.SecurityType
    }

    Write-MigrationStepProgress -Activity $progressActivity -Step 5 -Status "Attach regional data disks and finalize"
    Write-Host "Step 5/5: Attach regional data disks and finalize." -ForegroundColor Cyan
    New-AzVM -ResourceGroupName $ResourceGroupName -Location $sourceVm.Location -VM $newVmConfig -Tag $sourceVm.Tags -ErrorAction Stop | Out-Null

    if (-not $KeepSnapshots) {
        foreach ($snapshot in $createdSnapshots) {
            Remove-AzSnapshot -ResourceGroupName $snapshot.ResourceGroupName -SnapshotName $snapshot.Name -Force -ErrorAction SilentlyContinue
        }
    }

    $cleanupCandidates = [System.Collections.Generic.List[object]]::new()
    $cleanupCandidates.Add([PSCustomObject]@{
        ResourceType = "ManagedDisk"
        ResourceGroupName = $sourceOsDisk.ResourceGroupName
        Name = $sourceOsDisk.Name
        Reason = "Original source OS disk retained after source VM deletion"
        RecommendedAction = "Delete after validating the replacement VM"
    })
    foreach ($sourceDataDiskContext in $sourceDataDiskContexts) {
        $cleanupCandidates.Add([PSCustomObject]@{
            ResourceType = "ManagedDisk"
            ResourceGroupName = $sourceDataDiskContext.Disk.ResourceGroupName
            Name = $sourceDataDiskContext.Disk.Name
            Reason = "Original source data disk retained after source VM deletion"
            RecommendedAction = "Delete after validating application/data integrity"
        })
    }
    if ($KeepSnapshots) {
        foreach ($snapshot in $createdSnapshots) {
            $cleanupCandidates.Add([PSCustomObject]@{
                ResourceType = "Snapshot"
                ResourceGroupName = $snapshot.ResourceGroupName
                Name = $snapshot.Name
                Reason = "Temporary migration snapshot retained by -KeepSnapshots"
                RecommendedAction = "Delete after rollback window expires"
            })
        }
    }

    Write-Host "" 
    Write-Host "Cleanup candidates after validation:" -ForegroundColor Yellow
    if ($cleanupCandidates.Count -eq 0) {
        Write-Host "  None." -ForegroundColor Green
    }
    else {
        foreach ($candidate in $cleanupCandidates) {
            Write-Host ("  - [{0}] {1}/{2} :: {3}" -f $candidate.ResourceType, $candidate.ResourceGroupName, $candidate.Name, $candidate.Reason)
        }
    }

    [PSCustomObject]@{
        SourceVmName = $VmName
        SourceVmZone = $vmZone
        TargetVmName = $TargetVmName
        Location = $sourceVm.Location
        VmSize = $TargetVmSize
        RegionalOsDisk = $createdRegionalOsDisk.Name
        RegionalDataDisks = @($createdRegionalDataDisks | ForEach-Object { $_.NewDisk.Name })
        ReusedNicCount = @($sourceVm.NetworkProfile.NetworkInterfaces).Count
        CleanupCandidates = $cleanupCandidates
        SubscriptionId = [string]$azAccount.id
        Status = "Completed"
    }
}
catch {
    throw
}
finally {
    Write-Progress -Id 1 -Activity "Converting zonal VM to regional" -Completed
}