<#
.SYNOPSIS
Generates an Azure VM placement inventory.

.DESCRIPTION
Builds an inventory of Azure virtual machines and reports each VM name,
region, whether it is regional or zonal, and zone values when present.

You can target a single resource group or all resource groups in the active
subscription. When scope parameters are omitted, the script shows interactive
menus.

An active Azure CLI session is required. The script does not run az login.

.PARAMETER ResourceGroupName
Optional resource group to inventory.

.PARAMETER AllResourceGroups
Inventories VMs across all resource groups in the active subscription.

.PARAMETER SubscriptionId
Optional Azure subscription name or ID.

.PARAMETER TenantId
Optional Microsoft Entra tenant ID used in az login guidance.

.EXAMPLE
.\Get-AzVmPlacementInventory.ps1

Prompts with a menu to choose one resource group or all resource groups.

.EXAMPLE
.\Get-AzVmPlacementInventory.ps1 -ResourceGroupName rg-prod

Inventories only resource group rg-prod.

.EXAMPLE
.\Get-AzVmPlacementInventory.ps1 -AllResourceGroups

Inventories VMs across all resource groups in the active subscription.

.NOTES
Author: Henrique Rezende
#>

[CmdletBinding()]
param(
    [string]$ResourceGroupName,

    [switch]$AllResourceGroups,

    [string]$SubscriptionId,

    [string]$TenantId
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
        [scriptblock]$LabelExpression
    )

    if ($Items.Count -eq 0) {
        throw "No choices are available for '$Title'."
    }

    while ($true) {
        Show-AzureMenuHeader
        Write-Host $Title -ForegroundColor Cyan
        for ($index = 0; $index -lt $Items.Count; $index++) {
            Write-Host ("[{0}] {1}" -f ($index + 1), (& $LabelExpression $Items[$index]))
        }
        Write-Host "[0] Cancel"

        $selectionText = (Read-Host "Enter selection").Trim()
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

    $visibleResourceGroups = @($resourceGroups | Select-Object -First 20)

    while ($true) {
        Show-AzureMenuHeader
        Write-Host "Choose resource group" -ForegroundColor Cyan
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

function Get-VmPlacementInventoryRow {
    param(
        [Parameter(Mandatory)]
        [object]$Vm,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName
    )

    $isZonal = $Vm.Zones -and $Vm.Zones.Count -gt 0
    $zone = if ($isZonal) { $Vm.Zones -join "," } else { "" }

    [PSCustomObject]@{
        Name = $Vm.Name
        ResourceGroupName = $ResourceGroupName
        Region = $Vm.Location
        Placement = if ($isZonal) { "Zonal" } else { "Regional" }
        Zone = $zone
    }
}

foreach ($commandName in @(
    "az",
    "Connect-AzAccount",
    "Get-AzResourceGroup",
    "Get-AzVM"
)) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found. Install requirements and try again."
    }
}

if (-not [string]::IsNullOrWhiteSpace($ResourceGroupName) -and $AllResourceGroups.IsPresent) {
    throw "Specify either -ResourceGroupName or -AllResourceGroups, not both."
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

if ([string]::IsNullOrWhiteSpace($ResourceGroupName) -and -not $AllResourceGroups.IsPresent) {
    $scopeChoice = Select-MenuItem -Title "Choose inventory scope" -Items @(
        [PSCustomObject]@{ Label = "One resource group"; Value = "Single" }
        [PSCustomObject]@{ Label = "All resource groups"; Value = "All" }
    ) -LabelExpression { param($item) $item.Label }

    if ($scopeChoice.Value -eq "All") {
        $AllResourceGroups = $true
    }
    else {
        $ResourceGroupName = Select-AzResourceGroupName
    }
}

$targetResourceGroups = @()
if ($AllResourceGroups.IsPresent) {
    $targetResourceGroups = @(Get-AzResourceGroup -ErrorAction Stop | Sort-Object ResourceGroupName | Select-Object -ExpandProperty ResourceGroupName)
}
else {
    $ResourceGroupName = Select-AzResourceGroupName -CurrentValue $ResourceGroupName
    $targetResourceGroups = @($ResourceGroupName)
}

if ($targetResourceGroups.Count -eq 0) {
    throw "No resource groups were found in the active subscription."
}

$inventory = [System.Collections.Generic.List[object]]::new()

for ($index = 0; $index -lt $targetResourceGroups.Count; $index++) {
    $rgName = $targetResourceGroups[$index]
    $percent = [math]::Floor((($index + 1) / $targetResourceGroups.Count) * 100)
    Write-Progress -Id 1 -Activity "Collecting VM inventory" -Status "$rgName ($($index + 1) of $($targetResourceGroups.Count))" -PercentComplete $percent

    try {
        $resourceGroupVms = @(Get-AzVM -ResourceGroupName $rgName -ErrorAction Stop)
    }
    catch {
        Write-Warning "Skipping resource group '$rgName': $($_.Exception.Message)"
        continue
    }

    foreach ($vm in $resourceGroupVms) {
        $inventory.Add((Get-VmPlacementInventoryRow -Vm $vm -ResourceGroupName $rgName))
    }
}

Write-Progress -Id 1 -Activity "Collecting VM inventory" -Completed

$sortedInventory = @($inventory | Sort-Object ResourceGroupName, Name)

if ($sortedInventory.Count -eq 0) {
    Write-Warning "No virtual machines were found for the selected scope."
    return @()
}

Write-Host ""
Write-Host "VM placement inventory" -ForegroundColor Green
Write-Host "Subscription: $script:ActiveAzureSubscriptionLabel"
if ($AllResourceGroups.IsPresent) {
    Write-Host "Scope: All resource groups"
}
else {
    Write-Host "Scope: Resource group '$ResourceGroupName'"
}
Write-Host "VM count: $($sortedInventory.Count)"
Write-Host ""

$sortedInventory |
Format-Table -Property Name, ResourceGroupName, Region, Placement, Zone -AutoSize

return