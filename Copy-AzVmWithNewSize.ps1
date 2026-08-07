<#
.SYNOPSIS
Clones Azure VMs in a resource group at a different VM size.

.DESCRIPTION
Copies each selected VM's specialized OS disk, creates a new NIC in the source
subnet, and creates a running clone at the requested size. Source VMs are
not modified. Data disks, additional NICs, public IPs, extensions, identities,
zones, availability settings, and tags are not copied.

For selected Windows VMs, GeneralizeWindows creates and boots a temporary copy,
schedules Sysprep through Azure Run Command, captures a generalized managed
image, and deploys the final clone with new local administrator credentials.

Progress is reported against counted workflow steps. If a source VM fails, the
script displays the failure reason, skips its remaining clone plans, performs
best-effort cleanup, and continues with the next selected source VM.

.PARAMETER ResourceGroupName
Resource group containing the source VMs and receiving the cloned VMs.

.PARAMETER TargetVmSize
Azure VM size for each clone. The size must be available to the active
subscription in every selected source VM region.

.PARAMETER SourceVmSize
Optional source-size filter. All VMs in the resource group are selected when omitted.

.PARAMETER SourceVmName
Optional source VM name. SourceVM is an alias. When parameters are omitted in
interactive use, the script presents a numbered source VM menu that accepts
one or more selections.

.PARAMETER CloneCount
Number of clones to create for each selected source VM. Defaults to 1. Guided
VM selection prompts for a value when this parameter is omitted.

.PARAMETER SubscriptionId
Optional Azure subscription name or ID. The active Azure CLI subscription is
used when omitted.

.PARAMETER EnableAcceleratedNetworking
Enables accelerated networking on each new NIC. Use only when the target VM
size and operating system support it.

.PARAMETER GeneralizeWindows
Runs Sysprep on a temporary copy of each selected Windows VM, captures a
generalized image, and deploys the final clone from that image. Source VMs are
not modified. Linux VMs remain specialized clones.

.PARAMETER WindowsAdminCredential
Local administrator credentials provisioned on generalized Windows clones.
When omitted, Get-Credential prompts securely before resource creation.

.PARAMETER AcknowledgeSysprepPrerequisites
Confirms that installed applications, security agents, and server roles support
Sysprep, including any product-specific SQL Server or Microsoft Defender for
Endpoint preparation. Required for noninteractive Windows generalization.

.EXAMPLE
.\Copy-AzVmWithNewSize.ps1 -ResourceGroupName lab-rg -TargetVmSize Standard_D4s_v5

.EXAMPLE
.\Copy-AzVmWithNewSize.ps1

Prompts with numbered menus for the resource group, source VM, and target size.

.EXAMPLE
.\Copy-AzVmWithNewSize.ps1 -ResourceGroupName lab-rg -SourceVM server01 -TargetVmSize Standard_D4s_v5 -Confirm:$false

.EXAMPLE
.\Copy-AzVmWithNewSize.ps1 -ResourceGroupName lab-rg -SourceVM winserver01 -TargetVmSize Standard_D4s_v5 -GeneralizeWindows -AcknowledgeSysprepPrerequisites

Creates a generalized Windows clone through a temporary Sysprep VM and securely
prompts for the final clone's local administrator credentials.

.NOTES
Author: Henrique Rezende

.LINK
https://github.com/hrezenmsft/azure-vm-lifecycle-tools
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$ResourceGroupName,

    [string]$TargetVmSize,

    [Alias("SourceVM")]
    [string]$SourceVmName,

    [ValidateRange(1, 100)]
    [int]$CloneCount = 1,

    [string]$SourceVmSize,

    [string]$SubscriptionId,

    [switch]$EnableAcceleratedNetworking,

    [switch]$GeneralizeWindows,

    [PSCredential]$WindowsAdminCredential,

    [switch]$AcknowledgeSysprepPrerequisites
)

function Show-AzureMenuHeader {
    Write-Host ""
    Write-Host "Active Azure subscription" -ForegroundColor Yellow
    Write-Host "  $script:ActiveAzureSubscriptionLabel"
}

function Select-MenuItem {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [scriptblock]$LabelExpression,

        [switch]$Multiple
    )

    if ($Items.Count -eq 0) {
        throw "No choices are available for '$Title'."
    }

    Show-AzureMenuHeader
    Write-Host $Title -ForegroundColor Cyan
    for ($index = 0; $index -lt $Items.Count; $index++) {
        Write-Host ("[{0}] {1}" -f ($index + 1), (& $LabelExpression $Items[$index]))
    }
    Write-Host "[0] Cancel"
    if ($Multiple) {
        Write-Host "[A] Select all"
        Write-Host "Use commas and ranges for multiple choices, for example: 1,3-5"
    }

    while ($true) {
        $selectionText = Read-Host "Enter selection"
        if ($Multiple) {
            if ($selectionText -match "^(?i:a|all)$") {
                return $Items
            }
            if ($selectionText -eq "0") {
                throw "Selection cancelled."
            }

            $selectedIndexes = @()
            $validSelection = $true
            foreach ($selectionPart in @($selectionText -split ",")) {
                $selectionPart = $selectionPart.Trim()
                if ($selectionPart -match "^(\d+)$") {
                    $rangeStart = [int]$Matches[1]
                    $rangeEnd = $rangeStart
                }
                elseif ($selectionPart -match "^(\d+)\s*-\s*(\d+)$") {
                    $rangeStart = [int]$Matches[1]
                    $rangeEnd = [int]$Matches[2]
                }
                else {
                    $validSelection = $false
                    break
                }

                if ($rangeStart -lt 1 -or $rangeEnd -gt $Items.Count -or $rangeStart -gt $rangeEnd) {
                    $validSelection = $false
                    break
                }
                $selectedIndexes += $rangeStart..$rangeEnd
            }

            if ($validSelection -and $selectedIndexes.Count -gt 0) {
                $zeroBasedIndexes = @($selectedIndexes | Sort-Object -Unique | ForEach-Object { $_ - 1 })
                return $Items[$zeroBasedIndexes]
            }
            Write-Warning "Enter choices from 1 through $($Items.Count) using commas or ranges, A for all, or 0 to cancel."
            continue
        }

        $selection = 0
        if ([int]::TryParse($selectionText, [ref]$selection) -and $selection -ge 0 -and $selection -le $Items.Count) {
            if ($selection -eq 0) {
                throw "Selection cancelled."
            }
            return $Items[$selection - 1]
        }
        Write-Warning "Enter a number from 0 through $($Items.Count)."
    }
}

$vmAvailableSizeCache = @{}
function Get-AzVmAvailableSize {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [Parameter(Mandatory)]
        [string]$Location,

        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    $cacheKey = "$SubscriptionId|$ResourceGroupName|$VmName"
    if ($vmAvailableSizeCache.ContainsKey($cacheKey)) {
        return $vmAvailableSizeCache[$cacheKey]
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "Checking sizes available to '$VmName' in '$Location' for the active subscription..." -ForegroundColor Cyan
    try {
        $sizeJson = az vm list-vm-resize-options --resource-group $ResourceGroupName --name $VmName --subscription $SubscriptionId --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Azure CLI could not check VM sizes available to '$VmName'."
        }
        $availableSizes = @($sizeJson | ConvertFrom-Json -ErrorAction Stop)
        $vmAvailableSizeCache[$cacheKey] = $availableSizes
        Write-Host ("Availability check completed in {0:N1} seconds." -f $stopwatch.Elapsed.TotalSeconds) -ForegroundColor Green
        $availableSizes
    }
    finally {
        $stopwatch.Stop()
    }
}

function Find-MicrosoftLearnVmSku {
    param(
        [Parameter(Mandatory)]
        [string]$SearchText
    )

    $normalizedSearchText = ($SearchText -replace "^(?i:Standard_)", "").Trim()
    $query = [uri]::EscapeDataString("$normalizedSearchText size series")
    $searchUri = "https://learn.microsoft.com/api/search?search=$query&locale=en-us&scope=Azure&%24top=30"
    Write-Host "Searching Microsoft Learn VM size documentation for '$SearchText'..." -ForegroundColor Cyan
    $searchResponse = Invoke-RestMethod -Uri $searchUri -Method Get -ErrorAction Stop
    $documentationResults = @(
        $searchResponse.results | Where-Object {
            $_.url -like "https://learn.microsoft.com/*/azure/virtual-machines/sizes/*"
        } | Select-Object -First 8
    )

    $documentationText = [System.Collections.Generic.List[string]]::new()
    $documentationText.Add(($searchResponse | ConvertTo-Json -Depth 8))
    $pageNumber = 0
    foreach ($documentationResult in $documentationResults) {
        $pageNumber++
        Write-Progress -Id 2 -Activity "Searching Microsoft Learn VM size documentation" -Status $documentationResult.title -PercentComplete (($pageNumber / $documentationResults.Count) * 100)
        $documentationUrl = ([string]$documentationResult.url -split "#")[0]
        $separator = if ($documentationUrl.Contains("?")) { "&" } else { "?" }
        try {
            $documentationPage = Invoke-WebRequest -Uri "$documentationUrl${separator}accept=text/markdown" -UseBasicParsing -ErrorAction Stop
            $documentationText.Add([string]$documentationPage.Content)
        }
        catch {
            Write-Verbose "Could not read Microsoft Learn page '$documentationUrl': $($_.Exception.Message)"
        }
    }
    Write-Progress -Id 2 -Activity "Searching Microsoft Learn VM size documentation" -Completed

    $skuNames = [System.Collections.Generic.List[string]]::new()
    $normalizedPattern = $normalizedSearchText -replace "[_-]", ""
    $isSeriesSearch = $normalizedPattern -match "^(?i:[A-Z]+V\d+)$"
    foreach ($skuMatch in [regex]::Matches(($documentationText -join "`n"), "(?i)Standard(?:\\)?_[A-Z0-9_\\-]+")) {
        $skuName = $skuMatch.Groups[0].Value -replace "\\", ""
        $normalizedSkuName = ($skuName -replace "^(?i:Standard_)", "") -replace "[_-]", ""
        $normalizedSeriesName = $normalizedSkuName -replace "^(?<family>[A-Z]+)\d+", '${family}'
        if (($isSeriesSearch -and $normalizedSeriesName -eq $normalizedPattern) -or (-not $isSeriesSearch -and $normalizedSkuName -like "*$normalizedPattern*")) {
            $skuNames.Add($skuName)
        }
    }
    @($skuNames | Sort-Object -Unique)
}

function Select-AzVmTargetSize {
    param(
        [Parameter(Mandatory)]
        [object[]]$SourceVms,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    $locationLabel = @($SourceVms.Location | Sort-Object -Unique) -join ", "

    while ($true) {
        Show-AzureMenuHeader
        $sizeInput = (Read-Host "Enter the target VM size or part of its name for region(s) '$locationLabel' (example: Standard_D4s_v5 or D4s_v5)").Trim()
        if ([string]::IsNullOrWhiteSpace($sizeInput)) {
            Write-Warning "Enter a VM size name or partial name."
            continue
        }

        $availableSizes = @(Get-AzVmAvailableSize -ResourceGroupName $ResourceGroupName -VmName $SourceVms[0].Name -Location $SourceVms[0].Location -SubscriptionId $SubscriptionId)
        foreach ($sourceVm in @($SourceVms | Select-Object -Skip 1)) {
            $vmSizeNames = @(Get-AzVmAvailableSize -ResourceGroupName $ResourceGroupName -VmName $sourceVm.Name -Location $sourceVm.Location -SubscriptionId $SubscriptionId | Select-Object -ExpandProperty Name)
            $availableSizes = @($availableSizes | Where-Object { $_.Name -in $vmSizeNames })
        }

        $exactSizeName = if ($sizeInput -match "^(?i:Standard_)") { $sizeInput } else { "Standard_$sizeInput" }
        $exactSize = $availableSizes | Where-Object Name -eq $exactSizeName | Select-Object -First 1
        if ($exactSize) {
            Write-Host "VM size '$($exactSize.Name)' is available to this subscription across all selected regions." -ForegroundColor Green
            return $exactSize.Name
        }

        try {
            $documentedSkuNames = @(Find-MicrosoftLearnVmSku -SearchText $sizeInput)
        }
        catch {
            Write-Warning "Microsoft Learn search failed: $($_.Exception.Message)"
            continue
        }
        $matchingSizes = @($availableSizes | Where-Object { $_.Name -in $documentedSkuNames } | Sort-Object Name)
        if ($matchingSizes.Count -eq 0) {
            Write-Warning "Microsoft Learn returned no matching VM sizes available to this subscription across region(s) '$locationLabel'."
            continue
        }
        if ($matchingSizes.Count -gt 50) {
            Write-Warning "$($matchingSizes.Count) documented VM sizes matched. Enter a more specific name."
            continue
        }

        return (Select-MenuItem -Title "Choose a Microsoft Learn match available in all selected regions" -Items $matchingSizes -LabelExpression {
            param($size)
            "{0} ({1} vCPU, {2:N1} GiB memory)" -f $size.Name, $size.NumberOfCores, ($size.MemoryInMB / 1024)
        }).Name
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

function Write-StepProgress {
    param(
        [Parameter(Mandatory)]
        [int]$Id,

        [Parameter(Mandatory)]
        [int]$ParentId,

        [Parameter(Mandatory)]
        [string]$Activity,

        [Parameter(Mandatory)]
        [string]$Status,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$Step,

        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TotalSteps
    )

    if ($Step -gt $TotalSteps) {
        throw "Progress step $Step cannot exceed total steps $TotalSteps."
    }

    $percentComplete = [math]::Floor(($Step / $TotalSteps) * 100)
    Write-Progress -Id $Id -ParentId $ParentId -Activity $Activity -Status "$Status (step $Step of $TotalSteps)" -PercentComplete $percentComplete
}

function Wait-AzVmDeletion {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [int]$TimeoutMinutes = 5
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
        if (-not $vm) {
            return
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    throw "Temporary VM '$VmName' was not deleted within $TimeoutMinutes minutes."
}

function Wait-AzVmSysprepShutdown {
    param(
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$VmName,

        [int]$TimeoutMinutes = 30
    )

    $startedAt = Get-Date
    $deadline = $startedAt.AddMinutes($TimeoutMinutes)
    $nextDiagnosticAt = $startedAt.AddMinutes(3)
    do {
        $vmStatus = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status -ErrorAction Stop
        $powerState = ($vmStatus.Statuses | Where-Object Code -like "PowerState/*" | Select-Object -First 1).Code -replace "^PowerState/", ""
        if ($powerState -in @("stopped", "deallocated")) {
            return $powerState
        }

        if ((Get-Date) -ge $nextDiagnosticAt) {
            $diagnosticScript = @'
$task = Get-ScheduledTask -TaskName 'AzureCloneSysprep' -ErrorAction SilentlyContinue
$taskInfo = if ($task) { Get-ScheduledTaskInfo -TaskName 'AzureCloneSysprep' } else { $null }
$sysprepRunning = @(Get-Process -Name sysprep -ErrorAction SilentlyContinue).Count -gt 0
$succeeded = Test-Path 'C:\Windows\System32\Sysprep\Sysprep_succeeded.tag'
$errorLogPath = 'C:\Windows\System32\Sysprep\Panther\setuperr.log'
$errorText = if (Test-Path $errorLogPath) { (Get-Content $errorLogPath -Tail 40) -join "`n" } else { '' }
$activityLogPath = 'C:\Windows\System32\Sysprep\Panther\setupact.log'
$activityText = if (Test-Path $activityLogPath) { (Get-Content $activityLogPath -Tail 40) -join "`n" } else { '' }
if ($sysprepRunning -and $activityText -match 'Displaying dialog box for user to choose sysprep mode') {
    "SYSPREP_FAILED:`nSysprep opened an interactive mode-selection dialog in the noninteractive SYSTEM session."
}
elseif ($taskInfo -and $taskInfo.LastRunTime -gt [datetime]::MinValue -and -not $sysprepRunning -and -not $succeeded -and -not [string]::IsNullOrWhiteSpace($errorText)) {
    "SYSPREP_FAILED:`n$errorText"
}
else {
    'SYSPREP_PENDING'
}
'@
            $diagnosticResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VmName -CommandId "RunPowerShellScript" -ScriptString $diagnosticScript -ErrorAction Stop
            $diagnosticOutput = @($diagnosticResult.Value.Message) -join [Environment]::NewLine
            if ($diagnosticOutput -match "(?s)SYSPREP_FAILED:\s*(.+)") {
                throw "Sysprep failed on temporary VM '$VmName':`n$($Matches[1].Trim())"
            }
            $nextDiagnosticAt = (Get-Date).AddMinutes(2)
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)

    throw "Temporary VM '$VmName' did not shut down after Sysprep within $TimeoutMinutes minutes."
}

foreach ($commandName in @("az", "Connect-AzAccount", "Get-AzResourceGroup", "Get-AzVM", "Get-AzDisk", "New-AzSnapshot", "New-AzDisk", "New-AzVM", "Invoke-AzVMRunCommand", "Set-AzVM", "New-AzImageConfig", "New-AzImage", "Remove-AzImage", "Remove-AzVM", "Remove-AzDisk", "Set-AzVMOperatingSystem", "Set-AzVMSourceImage")) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found. Review the README requirements and try again."
    }
}

$null = az account get-access-token --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "No valid Azure CLI session was found. Starting az login..." -ForegroundColor Yellow
    az login
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI login failed."
    }
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
$subscriptionId = [string]$azAccount.id
$script:ActiveAzureSubscriptionLabel = "$($azAccount.name) [$subscriptionId]"

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $resourceGroups = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName)
    $selectedResourceGroup = Select-MenuItem -Title "Choose source resource group" -Items $resourceGroups -LabelExpression {
        param($resourceGroup)
        "{0} ({1})" -f $resourceGroup.ResourceGroupName, $resourceGroup.Location
    }
    $ResourceGroupName = $selectedResourceGroup.ResourceGroupName
}

$resourceGroupVms = @(Get-AzVM -ResourceGroupName $ResourceGroupName -ErrorAction Stop | Sort-Object Name)
if ($resourceGroupVms.Count -eq 0) {
    throw "No VMs were found in resource group '$ResourceGroupName'."
}

$sourceVmMenuUsed = $false
if (-not [string]::IsNullOrWhiteSpace($SourceVmName)) {
    $sourceVms = @($resourceGroupVms | Where-Object { $_.Name -eq $SourceVmName })
}
elseif (-not [string]::IsNullOrWhiteSpace($SourceVmSize)) {
    $sourceVms = @($resourceGroupVms | Where-Object { $_.HardwareProfile.VmSize -eq $SourceVmSize })
}
elseif ($PSBoundParameters.ContainsKey("ResourceGroupName") -and $PSBoundParameters.ContainsKey("TargetVmSize")) {
    # Preserve the original noninteractive behavior: process every VM when only RG and target size are supplied.
    $sourceVms = $resourceGroupVms
}
else {
    $sourceVmMenuUsed = $true
    $selectedVms = @(Select-MenuItem -Title "Choose source VMs" -Items $resourceGroupVms -Multiple -LabelExpression {
        param($vm)
        "{0} ({1}, {2})" -f $vm.Name, $vm.HardwareProfile.VmSize, $vm.Location
    })
    $sourceVms = $selectedVms
}

if ($sourceVms.Count -eq 0) {
    throw "No source VMs matched the requested resource group and size filter."
}

if ($sourceVmMenuUsed -and -not $PSBoundParameters.ContainsKey("CloneCount")) {
    while ($true) {
        $cloneCountText = Read-Host "Enter the number of clones to create per selected VM (1-100)"
        $selectedCloneCount = 0
        if ([int]::TryParse($cloneCountText, [ref]$selectedCloneCount) -and $selectedCloneCount -ge 1 -and $selectedCloneCount -le 100) {
            $CloneCount = $selectedCloneCount
            break
        }
        Write-Warning "Enter a whole number from 1 through 100."
    }
}

$windowsSourceVms = @($sourceVms | Where-Object { $_.StorageProfile.OsDisk.OsType -eq "Windows" })
if ($sourceVmMenuUsed -and $windowsSourceVms.Count -gt 0 -and -not $PSBoundParameters.ContainsKey("GeneralizeWindows")) {
    $windowsCloneMode = Select-MenuItem -Title "Choose how selected Windows VMs are cloned" -Items @(
        [PSCustomObject]@{ Name = "Specialized"; Description = "Copy as-is; preserves machine-specific identity"; Generalize = $false }
        [PSCustomObject]@{ Name = "Generalized"; Description = "Sysprep a temporary copy and deploy from a generalized image"; Generalize = $true }
    ) -LabelExpression {
        param($mode)
        "{0} - {1}" -f $mode.Name, $mode.Description
    }
    $GeneralizeWindows = $windowsCloneMode.Generalize
}

if ($GeneralizeWindows -and $windowsSourceVms.Count -gt 0) {
    $trustedLaunchVms = @($windowsSourceVms | Where-Object { $_.SecurityProfile.SecurityType -eq "TrustedLaunch" })
    if ($trustedLaunchVms.Count -gt 0) {
        throw "Windows generalization through a managed image is not supported for Trusted Launch VM(s): $($trustedLaunchVms.Name -join ', ')."
    }
}

if ([string]::IsNullOrWhiteSpace($TargetVmSize)) {
    $TargetVmSize = Select-AzVmTargetSize -SourceVms $sourceVms -ResourceGroupName $ResourceGroupName -SubscriptionId $subscriptionId
}

foreach ($sourceVm in $sourceVms) {
    $validTargetSize = Get-AzVmAvailableSize -ResourceGroupName $ResourceGroupName -VmName $sourceVm.Name -Location $sourceVm.Location -SubscriptionId $subscriptionId | Where-Object Name -eq $TargetVmSize | Select-Object -First 1
    if (-not $validTargetSize) {
        throw "Target VM size '$TargetVmSize' is not available to source VM '$($sourceVm.Name)' in region '$($sourceVm.Location)' for subscription '$subscriptionId'."
    }
}

$clonePlans = @($sourceVms | ForEach-Object {
    $sourceVm = $_
    foreach ($cloneNumber in 1..$CloneCount) {
        $suffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
        $newVmName = "$($sourceVm.Name)-$suffix"
        [PSCustomObject]@{
            SourceVm = $sourceVm
            CloneNumber = $cloneNumber
            Suffix = $suffix
            NewVmName = $newVmName
            Generalize = $GeneralizeWindows -and $sourceVm.StorageProfile.OsDisk.OsType -eq "Windows"
            BootDiagnosticsEnabled = $sourceVm.DiagnosticsProfile.BootDiagnostics.Enabled -eq $true
        }
    }
})

$confirmationLines = @(
    "Subscription: $script:ActiveAzureSubscriptionLabel"
    "Resource group: $ResourceGroupName"
    "Target VM size: $TargetVmSize"
    "Selected source VMs: $($sourceVms.Count)"
    "Clones per source VM: $CloneCount"
    "Total clones: $($clonePlans.Count)"
    foreach ($clonePlan in $clonePlans) {
        $cloneType = if ($clonePlan.Generalize) { "generalized via Sysprep" } else { "specialized" }
        $bootDiagnostics = if ($clonePlan.BootDiagnosticsEnabled) { "boot diagnostics enabled" } else { "boot diagnostics disabled" }
        "- $($clonePlan.SourceVm.Name) [$($clonePlan.CloneNumber)/$CloneCount] -> $($clonePlan.NewVmName) [$($clonePlan.SourceVm.Location), $cloneType, $bootDiagnostics]"
    }
)
$confirmationSummary = $confirmationLines -join [Environment]::NewLine
$generalizedCloneCount = @($clonePlans | Where-Object Generalize).Count
$operationDescription = if ($generalizedCloneCount -gt 0) {
    "Create $($clonePlans.Count) VM clone(s), including $generalizedCloneCount generalized Windows clone(s)"
}
else {
    "Create $($clonePlans.Count) specialized VM clone(s)"
}
if (-not $PSCmdlet.ShouldProcess($confirmationSummary, $operationDescription)) {
    return
}
if ($generalizedCloneCount -gt 0 -and -not $AcknowledgeSysprepPrerequisites) {
    $sysprepDocumentationUrl = "https://learn.microsoft.com/en-us/azure/virtual-machines/generalize#generalizing-a-windows-vm-before-creating-an-image"
    if (-not $sourceVmMenuUsed) {
        throw "Use -AcknowledgeSysprepPrerequisites after reviewing the official guidance at $sysprepDocumentationUrl and confirming that installed applications, security agents, and server roles support Sysprep."
    }
    $null = Select-MenuItem -Title "Confirm Windows Sysprep prerequisites`nOfficial Microsoft Learn guidance: $sysprepDocumentationUrl" -Items @(
        "I confirmed application, server-role, SQL Server, security-agent, and MDE Sysprep requirements"
    ) -LabelExpression { param($item) $item }
    $AcknowledgeSysprepPrerequisites = $true
}
if ($generalizedCloneCount -gt 0 -and -not $WindowsAdminCredential) {
    $WindowsAdminCredential = Get-Credential -Message "Enter local administrator credentials for the generalized Windows clone(s)."
    if (-not $WindowsAdminCredential) {
        throw "Windows administrator credentials are required for generalized clones."
    }
}

$results = @()
$progress = 0
$overallProgressId = 10
$vmProgressId = 11
try {
    foreach ($sourceVm in $sourceVms) {
        $sourceClonePlans = @($clonePlans | Where-Object { $_.SourceVm.Id -eq $sourceVm.Id } | Sort-Object CloneNumber)
        $generalizeSource = $sourceClonePlans[0].Generalize
        $sharedSuffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
        $snapshot = $null
        $temporaryVmName = $null
        $managedImage = $null
        $preparationDisk = $null
        $temporaryNicName = $null
        $temporaryVnetName = $null
        $preparationStepCount = if ($generalizeSource) { 12 } else { 3 }
        try {
            Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared source artifacts for $($sourceVm.Name)" -Status "Reading source OS disk" -Step 1 -TotalSteps $preparationStepCount
            $osDiskId = [string]$sourceVm.StorageProfile.OsDisk.ManagedDisk.Id
            if ([string]::IsNullOrWhiteSpace($osDiskId)) {
                throw "Source VM '$($sourceVm.Name)' does not use a managed OS disk."
            }

            $diskResourceGroup = if ($osDiskId -match "/resourceGroups/([^/]+)/") { $Matches[1] } else { $ResourceGroupName }
            $sourceDisk = Get-AzDisk -ResourceGroupName $diskResourceGroup -DiskName $sourceVm.StorageProfile.OsDisk.Name -ErrorAction Stop

            Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared source artifacts for $($sourceVm.Name)" -Status "Creating shared OS disk snapshot" -Step 2 -TotalSteps $preparationStepCount
            $snapshotName = "$($sourceDisk.Name)-snapshot-$sharedSuffix"
            $snapshotConfig = New-AzSnapshotConfig -SourceUri $sourceDisk.Id -CreateOption Copy -Location $sourceDisk.Location -ErrorAction Stop
            $snapshot = New-AzSnapshot -Snapshot $snapshotConfig -SnapshotName $snapshotName -ResourceGroupName $ResourceGroupName -ErrorAction Stop

            Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared source artifacts for $($sourceVm.Name)" -Status "Reading source network configuration" -Step 3 -TotalSteps $preparationStepCount
            $sourceNicId = [string]$sourceVm.NetworkProfile.NetworkInterfaces[0].Id
            if ([string]::IsNullOrWhiteSpace($sourceNicId)) {
                throw "Source VM '$($sourceVm.Name)' has no network interface."
            }
            $sourceNicJson = az network nic show --ids $sourceNicId --subscription $subscriptionId --output json --only-show-errors
            if ($LASTEXITCODE -ne 0) {
                throw "Azure CLI could not retrieve network interface '$sourceNicId'."
            }
            $sourceNic = $sourceNicJson | ConvertFrom-Json -ErrorAction Stop
            $sourceSubnetId = [string]$sourceNic.ipConfigurations[0].subnet.id
            if ([string]::IsNullOrWhiteSpace($sourceSubnetId)) {
                throw "Source VM '$($sourceVm.Name)' primary network interface has no subnet."
            }

            $sourceNetworkSecurityGroupId = [string]$sourceNic.networkSecurityGroup.id
            if ($generalizeSource) {
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared generalized image for $($sourceVm.Name)" -Status "Creating preparation OS disk" -Step 4 -TotalSteps $preparationStepCount
                $preparationDiskName = "$($sourceDisk.Name)-prep-$sharedSuffix"
                $preparationDiskConfig = New-AzDiskConfig -SourceResourceId $snapshot.Id -CreateOption Copy -Location $snapshot.Location -ErrorAction Stop
                $preparationDisk = New-AzDisk -Disk $preparationDiskConfig -DiskName $preparationDiskName -ResourceGroupName $ResourceGroupName -ErrorAction Stop

                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared generalized image for $($sourceVm.Name)" -Status "Creating isolated preparation network" -Step 5 -TotalSteps $preparationStepCount
                $temporaryVmName = "$($sourceVm.Name)-$sharedSuffix-prep"
                $temporaryVnetName = "$($sourceVm.Name)-$sharedSuffix-prep-vnet"
                $temporarySubnetName = "prep"
                $temporaryNicName = "$($sourceVm.Name)-$sharedSuffix-prep-nic"
                az network vnet create --name $temporaryVnetName --resource-group $ResourceGroupName --location $sourceVm.Location --address-prefixes "10.255.0.0/24" --subnet-name $temporarySubnetName --subnet-prefixes "10.255.0.0/24" --subscription $subscriptionId --output none --only-show-errors
                if ($LASTEXITCODE -ne 0) {
                    throw "Azure CLI could not create isolated preparation network '$temporaryVnetName'."
                }
                $temporaryNicJson = az network nic create --name $temporaryNicName --resource-group $ResourceGroupName --location $sourceVm.Location --vnet-name $temporaryVnetName --subnet $temporarySubnetName --subscription $subscriptionId --output json --only-show-errors
                if ($LASTEXITCODE -ne 0) {
                    throw "Azure CLI could not create isolated preparation network interface '$temporaryNicName'."
                }
                $temporaryNicResponse = $temporaryNicJson | ConvertFrom-Json -ErrorAction Stop
                $temporaryNic = if ($temporaryNicResponse.NewNIC) { $temporaryNicResponse.NewNIC } else { $temporaryNicResponse }
                $deploymentNicId = [string]$temporaryNic.id
                if ([string]::IsNullOrWhiteSpace($deploymentNicId)) {
                    throw "Azure CLI created preparation network interface '$temporaryNicName' but returned no resource ID."
                }
                $preparationVmConfig = New-AzVMConfig -VMName $temporaryVmName -VMSize $TargetVmSize -ErrorAction Stop
                $preparationVmConfig = if ($sourceClonePlans[0].BootDiagnosticsEnabled) {
                    Set-AzVMBootDiagnostic -VM $preparationVmConfig -Enable
                }
                else {
                    Set-AzVMBootDiagnostic -VM $preparationVmConfig -Disable
                }
                $preparationVmConfig = Set-AzVMOSDisk -VM $preparationVmConfig -ManagedDiskId $preparationDisk.Id -CreateOption Attach -Windows -DeleteOption Detach
                $preparationVmConfig = Add-AzVMNetworkInterface -VM $preparationVmConfig -Id $deploymentNicId -DeleteOption Detach
                $securityType = [string]$preparationDisk.SecurityProfile.SecurityType
                if (-not [string]::IsNullOrWhiteSpace($securityType)) {
                    $preparationVmConfig = Set-AzVMSecurityProfile -VM $preparationVmConfig -SecurityType $securityType
                }

                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared generalized image for $($sourceVm.Name)" -Status "Creating temporary Windows preparation VM" -Step 6 -TotalSteps $preparationStepCount
                $null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $sourceVm.Location -VM $preparationVmConfig -ErrorAction Stop

                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared generalized image for $($sourceVm.Name)" -Status "Scheduling Sysprep" -Step 7 -TotalSteps $preparationStepCount
                $sysprepScript = @'
$ntdsService = Get-Service -Name NTDS -ErrorAction SilentlyContinue
if ($ntdsService) {
    throw 'Sysprep generalization is not supported for an Active Directory domain controller.'
}
$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
if ($computerSystem.PartOfDomain) {
    'Domain-joined member detected. Sysprep will remove its machine-specific domain identity on the isolated preparation network.'
}
$encryptedVolumes = @()
if (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue) {
    $encryptedVolumes = @(Get-BitLockerVolume | Where-Object VolumeStatus -ne 'FullyDecrypted')
}
else {
    try {
        $encryptableVolumes = @(Get-CimInstance -Namespace 'root/CIMV2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -ErrorAction Stop)
        $encryptedVolumes = @($encryptableVolumes | Where-Object {
            (Invoke-CimMethod -InputObject $_ -MethodName GetConversionStatus -ErrorAction Stop).ConversionStatus -ne 0
        })
    }
    catch {
        throw "Unable to verify that every volume is fully decrypted: $($_.Exception.Message)"
    }
}
if ($encryptedVolumes.Count -gt 0) {
    throw 'Every Windows volume must be fully decrypted before Sysprep.'
}
$removableStoragePolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices'
if (Test-Path $removableStoragePolicyPath) {
    $policyKeys = @((Get-Item $removableStoragePolicyPath)) + @(Get-ChildItem $removableStoragePolicyPath -Recurse)
    $blockingPolicies = @($policyKeys | ForEach-Object {
        $policy = Get-ItemProperty $_.PSPath
        $policy.PSObject.Properties | Where-Object {
            $_.Name -match '^Deny_(All|Read|Write|Execute)$' -and [int]$_.Value -eq 1
        }
    })
    if ($blockingPolicies.Count -gt 0) {
        throw 'A removable-storage access policy is enabled. Remove the policy before Sysprep so Azure OOBE can mount its provisioning media.'
    }
}
$cdromStart = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\cdrom' -Name Start -ErrorAction Stop).Start
if ($cdromStart -ne 1) {
    throw 'The CD/DVD-ROM service must be enabled before Sysprep. Set HKLM:\SYSTEM\CurrentControlSet\Services\cdrom\Start to 1.'
}
Remove-Item -Path 'C:\Windows\Panther' -Recurse -Force -ErrorAction SilentlyContinue
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\Sysprep\Sysprep.exe" -Argument '/generalize /oobe /shutdown /quiet'
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2)
Register-ScheduledTask -TaskName 'AzureCloneSysprep' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
'Sysprep scheduled.'
'@
                $runCommandResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $temporaryVmName -CommandId "RunPowerShellScript" -ScriptString $sysprepScript -ErrorAction Stop
                $runCommandMessages = @($runCommandResult.Value | ForEach-Object {
                    if (-not [string]::IsNullOrWhiteSpace([string]$_.Message)) {
                        "[$($_.Code)] $($_.Message)"
                    }
                })
                $runCommandOutput = $runCommandMessages -join [Environment]::NewLine
                if ($runCommandOutput -notmatch "Sysprep scheduled\.") {
                    $runCommandDetails = if ([string]::IsNullOrWhiteSpace($runCommandOutput)) {
                        "Azure Run Command returned no guest output."
                    }
                    else {
                        $runCommandOutput
                    }
                    throw "Sysprep could not be scheduled on temporary VM '$temporaryVmName'. Run Command output:`n$runCommandDetails"
                }

                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared generalized image for $($sourceVm.Name)" -Status "Waiting for Sysprep shutdown" -Step 8 -TotalSteps $preparationStepCount
                $null = Wait-AzVmSysprepShutdown -ResourceGroupName $ResourceGroupName -VmName $temporaryVmName -TimeoutMinutes 30
                $null = Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $temporaryVmName -Force -ErrorAction Stop

                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared generalized image for $($sourceVm.Name)" -Status "Capturing shared generalized image" -Step 9 -TotalSteps $preparationStepCount
                $null = Set-AzVM -ResourceGroupName $ResourceGroupName -Name $temporaryVmName -Generalized -ErrorAction Stop
                $generalizedVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $temporaryVmName -ErrorAction Stop

                $imageName = "$($sourceVm.Name)-$sharedSuffix-image"
                $hyperVGeneration = [string]$sourceDisk.HyperVGeneration
                if ($hyperVGeneration -notin @("V1", "V2")) {
                    throw "Source OS disk '$($sourceDisk.Name)' has unsupported Hyper-V generation '$hyperVGeneration'."
                }
                $imageConfig = New-AzImageConfig -Location $sourceVm.Location -SourceVirtualMachineId $generalizedVm.Id -HyperVGeneration $hyperVGeneration -ErrorAction Stop
                $managedImage = New-AzImage -ResourceGroupName $ResourceGroupName -ImageName $imageName -Image $imageConfig -ErrorAction Stop

                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared generalized image for $($sourceVm.Name)" -Status "Removing preparation VM" -Step 10 -TotalSteps $preparationStepCount
                Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $temporaryVmName -Force -ErrorAction Stop | Out-Null
                Wait-AzVmDeletion -ResourceGroupName $ResourceGroupName -VmName $temporaryVmName
                $temporaryVmName = $null
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared generalized image for $($sourceVm.Name)" -Status "Removing preparation network" -Step 11 -TotalSteps $preparationStepCount
                az network nic delete --name $temporaryNicName --resource-group $ResourceGroupName --subscription $subscriptionId --only-show-errors
                if ($LASTEXITCODE -ne 0) {
                    throw "Azure CLI could not remove preparation network interface '$temporaryNicName'."
                }
                $temporaryNicName = $null
                az network vnet delete --name $temporaryVnetName --resource-group $ResourceGroupName --subscription $subscriptionId --only-show-errors
                if ($LASTEXITCODE -ne 0) {
                    throw "Azure CLI could not remove isolated preparation network '$temporaryVnetName'."
                }
                $temporaryVnetName = $null
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Preparing shared generalized image for $($sourceVm.Name)" -Status "Removing preparation OS disk" -Step 12 -TotalSteps $preparationStepCount
                Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $preparationDisk.Name -Force -ErrorAction Stop | Out-Null
                $preparationDisk = $null
            }

            foreach ($clonePlan in $sourceClonePlans) {
                $suffix = $clonePlan.Suffix
                $newVmName = $clonePlan.NewVmName
                $newDisk = $null
                $newNic = $null
                $currentCloneNumber = $progress + 1
                Write-Progress -Id $overallProgressId -Activity "Cloning Azure VMs" -Status "Creating $newVmName [$currentCloneNumber / $($clonePlans.Count)]" -PercentComplete (($progress / $clonePlans.Count) * 100)

                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "$($sourceVm.Name) -> $newVmName" -Status "Creating network interface" -Step 1 -TotalSteps 4
                $newNicName = "$($sourceNic.Name)-copy-$suffix"
                $nicCreateArguments = @(
                    "network", "nic", "create",
                    "--name", $newNicName,
                    "--resource-group", $ResourceGroupName,
                    "--location", $sourceNic.Location,
                    "--subnet", $sourceSubnetId,
                    "--subscription", $subscriptionId,
                    "--output", "json",
                    "--only-show-errors"
                )
                if (-not [string]::IsNullOrWhiteSpace($sourceNetworkSecurityGroupId)) {
                    $nicCreateArguments += @("--network-security-group", $sourceNetworkSecurityGroupId)
                }
                if ($EnableAcceleratedNetworking) {
                    $nicCreateArguments += @("--accelerated-networking", "true")
                }
                $newNicJson = az @nicCreateArguments
                if ($LASTEXITCODE -ne 0) {
                    throw "Azure CLI could not create network interface '$newNicName'."
                }
                $newNicResponse = $newNicJson | ConvertFrom-Json -ErrorAction Stop
                $newNic = if ($newNicResponse.NewNIC) { $newNicResponse.NewNIC } else { $newNicResponse }
                if ([string]::IsNullOrWhiteSpace([string]$newNic.id)) {
                    throw "Azure CLI created network interface '$newNicName' but returned no resource ID."
                }

                if ($generalizeSource) {
                    Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "$($sourceVm.Name) -> $newVmName" -Status "Configuring from shared generalized image" -Step 2 -TotalSteps 4
                    $computerName = if ($newVmName.Length -le 15) { $newVmName } else { $newVmName.Substring(0, 15).TrimEnd("-") }
                    $vmConfig = New-AzVMConfig -VMName $newVmName -VMSize $TargetVmSize -ErrorAction Stop
                    $vmConfig = if ($clonePlan.BootDiagnosticsEnabled) {
                        Set-AzVMBootDiagnostic -VM $vmConfig -Enable
                    }
                    else {
                        Set-AzVMBootDiagnostic -VM $vmConfig -Disable
                    }
                    $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $computerName -Credential $WindowsAdminCredential -ProvisionVMAgent -EnableAutoUpdate
                    $vmConfig = Set-AzVMSourceImage -VM $vmConfig -Id $managedImage.Id
                    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $newNic.id -DeleteOption Delete
                }
                else {
                    Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "$($sourceVm.Name) -> $newVmName" -Status "Creating OS disk from shared snapshot" -Step 2 -TotalSteps 4
                    $newDiskName = "$($sourceDisk.Name)-copy-$suffix"
                    $diskConfig = New-AzDiskConfig -SourceResourceId $snapshot.Id -CreateOption Copy -Location $snapshot.Location -ErrorAction Stop
                    $newDisk = New-AzDisk -Disk $diskConfig -DiskName $newDiskName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
                    $vmConfig = New-AzVMConfig -VMName $newVmName -VMSize $TargetVmSize -ErrorAction Stop
                    $vmConfig = if ($clonePlan.BootDiagnosticsEnabled) {
                        Set-AzVMBootDiagnostic -VM $vmConfig -Enable
                    }
                    else {
                        Set-AzVMBootDiagnostic -VM $vmConfig -Disable
                    }
                    if ($newDisk.OsType -eq "Linux") {
                        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newDisk.Id -CreateOption Attach -Linux -DeleteOption Delete
                    }
                    elseif ($newDisk.OsType -eq "Windows") {
                        $vmConfig = Set-AzVMOSDisk -VM $vmConfig -ManagedDiskId $newDisk.Id -CreateOption Attach -Windows -DeleteOption Delete
                    }
                    else {
                        throw "Copied OS disk '$newDiskName' has no recognized OS type."
                    }
                    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $newNic.id -DeleteOption Delete
                    $securityType = [string]$newDisk.SecurityProfile.SecurityType
                    if (-not [string]::IsNullOrWhiteSpace($securityType)) {
                        $vmConfig = Set-AzVMSecurityProfile -VM $vmConfig -SecurityType $securityType
                    }
                }

                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "$($sourceVm.Name) -> $newVmName" -Status "Creating virtual machine" -Step 3 -TotalSteps 4
                $null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $sourceVm.Location -VM $vmConfig -ErrorAction Stop
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "$($sourceVm.Name) -> $newVmName" -Status "Verifying cloned VM" -Step 4 -TotalSteps 4
                $newVm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $newVmName -Status -ErrorAction Stop
                $newVmPowerState = ($newVm.Statuses | Where-Object Code -like "PowerState/*" | Select-Object -First 1).DisplayStatus

                $results += [PSCustomObject]@{
                    SourceVmName = $sourceVm.Name
                    NewVmName = $newVm.Name
                    ResourceGroupName = $newVm.ResourceGroupName
                    TargetVmSize = $newVm.HardwareProfile.VmSize
                    PrivateIpAddress = $newNic.ipConfigurations[0].privateIPAddress
                    OsDiskName = $newVm.StorageProfile.OsDisk.Name
                    SubscriptionId = $subscriptionId
                    PowerState = $newVmPowerState
                    CloneType = if ($generalizeSource) { "Generalized" } else { "Specialized" }
                }
                $progress++
                Write-Progress -Id $vmProgressId -ParentId $overallProgressId -Activity "$($sourceVm.Name) -> $newVmName" -Completed
                Write-Progress -Id $overallProgressId -Activity "Cloning Azure VMs" -Status "Completed $newVmName [$progress / $($clonePlans.Count)]" -PercentComplete (($progress / $clonePlans.Count) * 100)
            }
        }
        catch {
            $remainingCloneCount = $sourceClonePlans.Count - @($results | Where-Object SourceVmName -eq $sourceVm.Name).Count
            $progress += $remainingCloneCount
            $errorDescription = $_.Exception.Message.Trim()
            Write-Progress -Id $vmProgressId -ParentId $overallProgressId -Activity "Source VM $($sourceVm.Name) failed" -Completed
            Write-Host ""
            Write-Host "ERROR: Source VM '$($sourceVm.Name)' was skipped." -ForegroundColor Red
            Write-Host "Reason: $errorDescription" -ForegroundColor Yellow
            Write-Host "Continuing with the next selected source VM." -ForegroundColor Cyan
            Write-Host ""
            Write-Progress -Id $overallProgressId -Activity "Cloning Azure VMs" -Status "Skipped $($sourceVm.Name) after an error [$progress / $($clonePlans.Count)]" -PercentComplete (($progress / $clonePlans.Count) * 100)
        }
        finally {
            $cleanupStepCount = @(
                if ($temporaryVmName) { "Preparation VM" }
                if ($temporaryNicName) { "Preparation NIC" }
                if ($temporaryVnetName) { "Preparation VNet" }
                if ($managedImage) { "Managed image" }
                if ($preparationDisk) { "Preparation disk" }
                if ($snapshot) { "Snapshot" }
            ).Count
            $cleanupStep = 0
            if ($temporaryVmName) {
                $cleanupStep++
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Cleaning shared source artifacts for $($sourceVm.Name)" -Status "Removing temporary preparation VM" -Step $cleanupStep -TotalSteps $cleanupStepCount
                Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $temporaryVmName -Force -ErrorAction SilentlyContinue | Out-Null
                try {
                    Wait-AzVmDeletion -ResourceGroupName $ResourceGroupName -VmName $temporaryVmName
                }
                catch {
                    Write-Verbose $_.Exception.Message
                }
            }
            if ($temporaryNicName) {
                $cleanupStep++
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Cleaning shared source artifacts for $($sourceVm.Name)" -Status "Removing preparation network interface" -Step $cleanupStep -TotalSteps $cleanupStepCount
                az network nic delete --name $temporaryNicName --resource-group $ResourceGroupName --subscription $subscriptionId --only-show-errors 2>$null
            }
            if ($temporaryVnetName) {
                $cleanupStep++
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Cleaning shared source artifacts for $($sourceVm.Name)" -Status "Removing isolated preparation network" -Step $cleanupStep -TotalSteps $cleanupStepCount
                az network vnet delete --name $temporaryVnetName --resource-group $ResourceGroupName --subscription $subscriptionId --only-show-errors 2>$null
            }
            if ($managedImage) {
                $cleanupStep++
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Cleaning shared source artifacts for $($sourceVm.Name)" -Status "Removing shared managed image" -Step $cleanupStep -TotalSteps $cleanupStepCount
                Remove-AzImage -ResourceGroupName $ResourceGroupName -ImageName $managedImage.Name -Force -ErrorAction SilentlyContinue | Out-Null
            }
            if ($preparationDisk) {
                $cleanupStep++
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Cleaning shared source artifacts for $($sourceVm.Name)" -Status "Removing preparation OS disk" -Step $cleanupStep -TotalSteps $cleanupStepCount
                Remove-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $preparationDisk.Name -Force -ErrorAction SilentlyContinue | Out-Null
            }
            if ($snapshot) {
                $cleanupStep++
                Write-StepProgress -Id $vmProgressId -ParentId $overallProgressId -Activity "Cleaning shared source artifacts for $($sourceVm.Name)" -Status "Removing shared snapshot" -Step $cleanupStep -TotalSteps $cleanupStepCount
                Remove-AzSnapshot -ResourceGroupName $snapshot.ResourceGroupName -SnapshotName $snapshot.Name -Force -ErrorAction SilentlyContinue
            }
            Write-Progress -Id $vmProgressId -ParentId $overallProgressId -Activity "Shared source artifacts for $($sourceVm.Name)" -Completed
        }
    }
}
finally {
    Write-Progress -Id $vmProgressId -Activity "VM clone subtasks" -Completed
    Write-Progress -Id $overallProgressId -Activity "Cloning Azure VMs" -Completed
}
$results