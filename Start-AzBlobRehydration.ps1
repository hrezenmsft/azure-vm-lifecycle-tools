<#
.SYNOPSIS
Rehydrates archived Azure blobs to an online access tier.

.DESCRIPTION
Finds base blobs in the Archive access tier across selected containers and
submits tier changes for blobs that do not already have a pending rehydration
operation. Blob enumeration uses Microsoft Entra ID authentication and resets
the continuation token for each container. The script never enables shared-key
access or retrieves storage account keys.

Rehydration can incur data retrieval, transaction, online storage, and early
deletion charges. High-priority retrieval costs more than Standard priority.
The operation cannot be canceled after Azure accepts the tier change.

.PARAMETER ResourceGroupName
Resource group containing the storage account. When omitted, the script lists
storage accounts in the selected subscription and derives the resource group
from the selected account.

.PARAMETER StorageAccountName
Storage account containing the archived blobs. When omitted, the script
displays a numbered menu of storage accounts in the selected scope.

.PARAMETER ContainerName
One or more container names to scan. When omitted, all containers in the
storage account are scanned.

.PARAMETER TargetTier
Online access tier to request: Hot or Cool. The default is Hot.

.PARAMETER RehydratePriority
Retrieval priority: Standard or High. The default is Standard. High priority
can complete sooner but costs more.

.PARAMETER BatchSize
Maximum blobs requested per enumeration page. The default is 5000.

.PARAMETER MaxBlobCount
Maximum eligible archived blobs to include in this run. Zero means no limit.
The default is zero.

.PARAMETER SubscriptionId
Optional Azure subscription name or ID. The active Azure CLI subscription is
used when omitted.

.PARAMETER TenantId
Optional Microsoft Entra tenant ID used for Azure CLI and Az PowerShell login.
Specify this for accounts that can access multiple tenants to avoid
cross-tenant discovery.

.EXAMPLE
.\Start-AzBlobRehydration.ps1 -WhatIf

Selects a storage account, scans every container, and previews the rehydration
request without changing blob tiers.

.EXAMPLE
.\Start-AzBlobRehydration.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -TenantId 11111111-1111-1111-1111-111111111111 -WhatIf

Uses tenant-scoped device-code authentication when an Azure session is invalid,
then previews eligible blobs in the selected subscription.

.EXAMPLE
.\Start-AzBlobRehydration.ps1 -ResourceGroupName archive-rg -StorageAccountName archivestore01 -ContainerName backups -TargetTier Cool -RehydratePriority Standard

Rehydrates eligible blobs in the backups container to the Cool tier.

.EXAMPLE
.\Start-AzBlobRehydration.ps1 -StorageAccountName archivestore01 -MaxBlobCount 100 -RehydratePriority High -Confirm:$false

Submits at most 100 eligible blobs with High priority without an interactive
confirmation. High priority has additional cost.

.NOTES
Author: Henrique Rezende

.LINK
https://github.com/hrezenmsft/azure-vm-lifecycle-tools

.LINK
https://learn.microsoft.com/azure/storage/blobs/archive-rehydrate-overview
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$ResourceGroupName,

    [string]$StorageAccountName,

    [string[]]$ContainerName,

    [ValidateSet("Hot", "Cool")]
    [string]$TargetTier = "Hot",

    [ValidateSet("Standard", "High")]
    [string]$RehydratePriority = "Standard",

    [ValidateRange(1, 5000)]
    [int]$BatchSize = 5000,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxBlobCount = 0,

    [string]$SubscriptionId,

    [string]$TenantId
)

function Select-MenuItem {
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [object[]]$Items,

        [Parameter(Mandatory)]
        [scriptblock]$LabelExpression
    )

    if ($Items.Count -eq 0) {
        throw "No choices are available for '$Title'."
    }

    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($index = 0; $index -lt $Items.Count; $index++) {
        Write-Host ("[{0}] {1}" -f ($index + 1), (& $LabelExpression $Items[$index]))
    }
    Write-Host "[0] Cancel"

    while ($true) {
        $selection = 0
        $selectionText = Read-Host "Enter selection"
        if ([int]::TryParse($selectionText, [ref]$selection) -and $selection -ge 0 -and $selection -le $Items.Count) {
            if ($selection -eq 0) {
                throw "Selection canceled."
            }
            return $Items[$selection - 1]
        }
        Write-Warning "Enter a number from 0 through $($Items.Count)."
    }
}

function Format-ByteSize {
    param(
        [Parameter(Mandatory)]
        [long]$Bytes
    )

    if ($Bytes -ge 1TB) {
        return "{0:N2} TiB" -f ($Bytes / 1TB)
    }
    if ($Bytes -ge 1GB) {
        return "{0:N2} GiB" -f ($Bytes / 1GB)
    }
    if ($Bytes -ge 1MB) {
        return "{0:N2} MiB" -f ($Bytes / 1MB)
    }
    if ($Bytes -ge 1KB) {
        return "{0:N2} KiB" -f ($Bytes / 1KB)
    }
    return "$Bytes bytes"
}

$requiredCommands = @(
    "az",
    "Connect-AzAccount",
    "Get-AzContext",
    "Set-AzContext",
    "Get-AzStorageAccount",
    "New-AzStorageContext",
    "Get-AzStorageContainer",
    "Get-AzStorageBlob"
)
foreach ($commandName in $requiredCommands) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found. Review the README requirements and try again."
    }
}

$tokenCheckArguments = @("account", "get-access-token", "--output", "none")
if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $tokenCheckArguments += @("--subscription", $SubscriptionId)
}
$null = & az @tokenCheckArguments 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "No valid Azure CLI session was found. Starting device-code login..." -ForegroundColor Yellow
    $loginArguments = @("login", "--use-device-code")
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $loginArguments += @("--tenant", $TenantId)
    }
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId) -and -not [string]::IsNullOrWhiteSpace($TenantId)) {
        $loginArguments += @("--subscription", $SubscriptionId)
    }
    & az @loginArguments
    if ($LASTEXITCODE -ne 0) {
        $tenantGuidance = if ([string]::IsNullOrWhiteSpace($TenantId)) { " Specify -TenantId to limit login to the tenant containing the subscription." } else { "" }
        throw "Azure CLI device-code login failed.$tenantGuidance"
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
$subscriptionId = [string]$azAccount.id
$subscriptionLabel = "$($azAccount.name) ($subscriptionId)"
$activeTenantId = [string]$azAccount.tenantId

$azPowerShellContext = Get-AzContext -ErrorAction SilentlyContinue
if ($null -eq $azPowerShellContext -or $null -eq $azPowerShellContext.Account -or [string]$azPowerShellContext.Tenant.Id -ine $activeTenantId) {
    Write-Host "No matching Az PowerShell session was found. Starting device-code login..." -ForegroundColor Yellow
    Connect-AzAccount -Tenant $activeTenantId -Subscription $subscriptionId -UseDeviceAuthentication -ErrorAction Stop | Out-Null
}
else {
    try {
        Set-AzContext -Subscription $subscriptionId -Tenant $activeTenantId -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "The Az PowerShell session could not select the subscription. Starting device-code login..." -ForegroundColor Yellow
        Connect-AzAccount -Tenant $activeTenantId -Subscription $subscriptionId -UseDeviceAuthentication -ErrorAction Stop | Out-Null
    }
}

$storageAccounts = @(Get-AzStorageAccount -ErrorAction Stop)
if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $storageAccounts = @($storageAccounts | Where-Object ResourceGroupName -IEQ $ResourceGroupName)
    if ($storageAccounts.Count -eq 0) {
        throw "No storage accounts were found in resource group '$ResourceGroupName' for subscription '$subscriptionLabel'."
    }
}

if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
    if ($storageAccounts.Count -eq 0) {
        throw "No storage accounts were found in subscription '$subscriptionLabel'."
    }
    $selectedStorageAccount = Select-MenuItem -Title "Select a storage account in $subscriptionLabel" -Items ($storageAccounts | Sort-Object StorageAccountName) -LabelExpression {
        param($storageAccount)
        "$($storageAccount.StorageAccountName) ($($storageAccount.ResourceGroupName), $($storageAccount.Location))"
    }
}
else {
    $selectedStorageAccount = $storageAccounts | Where-Object StorageAccountName -IEQ $StorageAccountName | Select-Object -First 1
    if ($null -eq $selectedStorageAccount) {
        $scopeDescription = if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) { "subscription '$subscriptionLabel'" } else { "resource group '$ResourceGroupName'" }
        throw "Storage account '$StorageAccountName' was not found in $scopeDescription."
    }
}

$StorageAccountName = [string]$selectedStorageAccount.StorageAccountName
$ResourceGroupName = [string]$selectedStorageAccount.ResourceGroupName
$storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount -ErrorAction Stop

$availableContainers = @(Get-AzStorageContainer -Context $storageContext -ErrorAction Stop | Sort-Object Name)
if ($availableContainers.Count -eq 0) {
    Write-Host "No blob containers were found in storage account '$StorageAccountName'." -ForegroundColor Yellow
    return
}

if ($null -eq $ContainerName -or $ContainerName.Count -eq 0) {
    $selectedContainers = $availableContainers
}
else {
    $selectedContainers = @()
    foreach ($requestedContainerName in $ContainerName) {
        $matchingContainer = $availableContainers | Where-Object Name -CEQ $requestedContainerName | Select-Object -First 1
        if ($null -eq $matchingContainer) {
            throw "Container '$requestedContainerName' was not found in storage account '$StorageAccountName'."
        }
        $selectedContainers += $matchingContainer
    }
}

$eligibleBlobs = [System.Collections.Generic.List[object]]::new()
$scannedBlobCount = 0L
$limitReached = $false

foreach ($container in $selectedContainers) {
    $continuationToken = $null
    Write-Host "Scanning container '$($container.Name)'..." -ForegroundColor Cyan
    do {
        $blobs = @(Get-AzStorageBlob -Container $container.Name -MaxCount $BatchSize -ContinuationToken $continuationToken -Context $storageContext -ErrorAction Stop)
        if ($blobs.Count -eq 0) {
            break
        }

        foreach ($blob in $blobs) {
            $scannedBlobCount++
            $archiveStatus = [string]$blob.BlobProperties.ArchiveStatus
            if ([string]$blob.AccessTier -ieq "Archive" -and $archiveStatus -notmatch "(?i)rehydrate-pending") {
                $blobUri = if ($null -ne $blob.BlobClient -and $null -ne $blob.BlobClient.Uri) {
                    [string]$blob.BlobClient.Uri.AbsoluteUri
                }
                else {
                    [string]$blob.ICloudBlob.Uri.AbsoluteUri
                }
                $eligibleBlobs.Add([PSCustomObject]@{
                    Container = [string]$container.Name
                    BlobName = [string]$blob.Name
                    BlobUri = $blobUri
                    SizeBytes = [long]$blob.Length
                    AccessTier = [string]$blob.AccessTier
                    ArchiveStatus = $archiveStatus
                })

                if ($MaxBlobCount -gt 0 -and $eligibleBlobs.Count -ge $MaxBlobCount) {
                    $limitReached = $true
                    break
                }
            }
        }

        Write-Progress -Activity "Scanning archived blobs" -Status "$scannedBlobCount blobs scanned; $($eligibleBlobs.Count) eligible" -PercentComplete -1
        $continuationToken = $blobs[$blobs.Count - 1].ContinuationToken
    } while ($null -ne $continuationToken -and -not $limitReached)

    if ($limitReached) {
        break
    }
}
Write-Progress -Activity "Scanning archived blobs" -Completed

if ($eligibleBlobs.Count -eq 0) {
    Write-Host "No eligible archived blobs were found. Blobs with pending rehydration were skipped." -ForegroundColor Yellow
    return
}

$totalBytes = [long](($eligibleBlobs | Measure-Object -Property SizeBytes -Sum).Sum)
Write-Host ""
Write-Host "Archived blob rehydration plan" -ForegroundColor Cyan
Write-Host "  Subscription: $subscriptionLabel"
Write-Host "  Storage account: $StorageAccountName"
Write-Host "  Containers scanned: $($selectedContainers.Count)"
Write-Host "  Blobs scanned: $scannedBlobCount"
Write-Host "  Eligible blobs: $($eligibleBlobs.Count)"
Write-Host "  Eligible data: $(Format-ByteSize -Bytes $totalBytes)"
Write-Host "  Target tier: $TargetTier"
Write-Host "  Priority: $RehydratePriority"
if ($limitReached) {
    Write-Host "  MaxBlobCount limit reached: $MaxBlobCount" -ForegroundColor Yellow
}
if ($RehydratePriority -eq "High") {
    Write-Warning "High-priority rehydration costs more than Standard priority."
}

$eligibleBlobs | Select-Object Container, BlobName, @{ Name = "Size"; Expression = { Format-ByteSize -Bytes $_.SizeBytes } }, ArchiveStatus | Format-Table -AutoSize | Out-Host

$targetDescription = "$($eligibleBlobs.Count) archived blobs ($((Format-ByteSize -Bytes $totalBytes))) in storage account '$StorageAccountName'"
$operationDescription = "Rehydrate to $TargetTier with $RehydratePriority priority"
if (-not $PSCmdlet.ShouldProcess($targetDescription, $operationDescription)) {
    return $eligibleBlobs
}

$operationResults = [System.Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $eligibleBlobs.Count; $index++) {
    $blob = $eligibleBlobs[$index]
    Write-Progress -Activity "Submitting blob rehydration" -Status "$($index + 1) of $($eligibleBlobs.Count): $($blob.Container)/$($blob.BlobName)" -PercentComplete ((($index + 1) / $eligibleBlobs.Count) * 100)

    $setTierArguments = @(
        "storage", "blob", "set-tier",
        "--account-name", $StorageAccountName,
        "--container-name", $blob.Container,
        "--name", $blob.BlobName,
        "--tier", $TargetTier,
        "--rehydrate-priority", $RehydratePriority,
        "--auth-mode", "login",
        "--subscription", $subscriptionId,
        "--only-show-errors",
        "--output", "none"
    )
    $commandOutput = & az @setTierArguments 2>&1
    $succeeded = $LASTEXITCODE -eq 0
    $operationResults.Add([PSCustomObject]@{
        Container = $blob.Container
        BlobName = $blob.BlobName
        BlobUri = $blob.BlobUri
        SizeBytes = $blob.SizeBytes
        TargetTier = $TargetTier
        RehydratePriority = $RehydratePriority
        Status = if ($succeeded) { "Submitted" } else { "Failed" }
        Error = if ($succeeded) { $null } else { ($commandOutput -join [Environment]::NewLine) }
    })
}
Write-Progress -Activity "Submitting blob rehydration" -Completed

$submittedCount = @($operationResults | Where-Object Status -EQ "Submitted").Count
$failedCount = @($operationResults | Where-Object Status -EQ "Failed").Count
Write-Host ""
Write-Host "Rehydration submission summary" -ForegroundColor Cyan
Write-Host "  Submitted: $submittedCount" -ForegroundColor Green
$failedColor = if ($failedCount -gt 0) { "Red" } else { "Green" }
Write-Host "  Failed: $failedCount" -ForegroundColor $failedColor
Write-Host "  Azure processes accepted requests asynchronously; archive status remains pending until rehydration completes."

$operationResults