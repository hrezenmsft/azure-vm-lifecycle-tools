<#
.SYNOPSIS
Uploads a local fixed-size VHD or VHDX to a new Azure managed disk.

.DESCRIPTION
Creates an upload-enabled Azure managed disk, grants temporary write access,
uploads a local fixed-size VHD with AzCopy, and always revokes the temporary
SAS. VHDX inputs are converted to a temporary fixed VHD before upload. The
active Azure CLI subscription is used unless SubscriptionId is supplied. The
script must be run from an elevated PowerShell session.

.PARAMETER Path
Path to an existing local fixed-size .vhd or .vhdx file. Relative and absolute
paths are accepted. VHDX conversion requires the Hyper-V PowerShell module.

.PARAMETER ResourceGroupName
Name of the existing Azure resource group in which to create the managed disk.
When omitted, the script queries the selected subscription and displays a
numbered menu. Supplied names are validated against the same subscription.

.PARAMETER Location
Azure region name for the managed disk, for example eastus2 or westus3. Use the
region's CLI name rather than its display name. When omitted, the script lists
regions containing resource groups and provides an option to type another
physical Azure region.

.PARAMETER DiskName
Optional name for the managed disk. When omitted, the script generates a unique
name from the virtual disk filename.

.PARAMETER Sku
Managed disk storage SKU: Standard_LRS, StandardSSD_LRS, Premium_LRS, or
UltraSSD_LRS. The default is Standard_LRS.

.PARAMETER DiskType
Managed disk role: OS or Data. When omitted, supplying OsType implies OS;
otherwise, the script displays a numbered menu.

.PARAMETER OsType
Operating system type: Linux or Windows. Required when DiskType is OS and not
valid when DiskType is Data. When omitted for an OS disk, the script displays a
numbered menu.

.PARAMETER HyperVGeneration
Hyper-V generation for an OS disk: V1 or V2. The default is V1. This value is
used only for OS disks. When omitted for an interactively selected OS disk, the
script displays a numbered menu.

.PARAMETER SubscriptionId
Optional Azure subscription name or ID. The active Azure CLI subscription is
used when omitted.

.EXAMPLE
.\Import-AzVhdToManagedDisk.ps1 -Path .\server.vhd -ResourceGroupName lab-rg -Location eastus2

.EXAMPLE
.\Import-AzVhdToManagedDisk.ps1 -Path .\server.vhdx -ResourceGroupName lab-rg -Location eastus2 -DiskType OS -OsType Windows -HyperVGeneration V2

.EXAMPLE
.\Import-AzVhdToManagedDisk.ps1 -Path .\data.vhd -ResourceGroupName lab-rg -Location eastus2 -DiskType Data

.NOTES
Author: Henrique Rezende

.LINK
https://github.com/hrezenmsft/azure-vm-lifecycle-tools

.LINK
https://learn.microsoft.com/en-us/azure/virtual-machines/windows/prepare-for-upload-vhd-image
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = "High")]
param(
    [string]$Path,

    [string]$ResourceGroupName,

    [string]$Location,

    [string]$DiskName,

    [ValidateSet("Standard_LRS", "StandardSSD_LRS", "Premium_LRS", "UltraSSD_LRS")]
    [string]$Sku = "Standard_LRS",

    [ValidateSet("OS", "Data")]
    [string]$DiskType,

    [ValidateSet("Linux", "Windows")]
    [string]$OsType,

    [ValidateSet("V1", "V2")]
    [string]$HyperVGeneration = "V1",

    [string]$SubscriptionId
)

$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "This script must be run from an elevated PowerShell session. Start PowerShell as Administrator and try again."
}

function Read-RequiredInput {
    param(
        [Parameter(Mandatory)]
        [string]$Description,

        [Parameter(Mandatory)]
        [string]$Example
    )

    do {
        Write-Host ""
        Write-Host $Description -ForegroundColor Cyan
        Write-Host "Example: $Example" -ForegroundColor DarkGray
        $value = Read-Host "Enter value"
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Warning "A value is required."
        }
    } while ([string]::IsNullOrWhiteSpace($value))

    return $value.Trim()
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

function ConvertFrom-QuotedPathInput {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $normalizedValue = $Value.Trim()
    if ($normalizedValue.Length -ge 2) {
        $firstCharacter = $normalizedValue[0]
        $lastCharacter = $normalizedValue[$normalizedValue.Length - 1]
        if (($firstCharacter -eq '"' -and $lastCharacter -eq '"') -or ($firstCharacter -eq "'" -and $lastCharacter -eq "'")) {
            $normalizedValue = $normalizedValue.Substring(1, $normalizedValue.Length - 2).Trim()
        }
    }

    return $normalizedValue
}

function Assert-FixedVhd {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    $footerSize = 512
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($LiteralPath, "Open", "Read", "Read")
        if ($stream.Length -lt $footerSize) {
            throw "The file is too small to contain a valid VHD footer."
        }

        $null = $stream.Seek(-$footerSize, [System.IO.SeekOrigin]::End)
        $footer = [byte[]]::new($footerSize)
        if ($stream.Read($footer, 0, $footerSize) -ne $footerSize) {
            throw "The VHD footer could not be read."
        }

        $cookie = [System.Text.Encoding]::ASCII.GetString($footer, 0, 8)
        if ($cookie -ne "conectix") {
            throw "The file does not contain a valid VHD footer."
        }

        $storedChecksum = ([uint32]$footer[64] -shl 24) -bor
            ([uint32]$footer[65] -shl 16) -bor
            ([uint32]$footer[66] -shl 8) -bor
            [uint32]$footer[67]
        $checksumTotal = [uint32]0
        for ($index = 0; $index -lt $footerSize; $index++) {
            if ($index -lt 64 -or $index -gt 67) {
                $checksumTotal += $footer[$index]
            }
        }
        if ($storedChecksum -ne ([uint32]::MaxValue - $checksumTotal)) {
            throw "The file contains an invalid VHD footer checksum."
        }

        $diskType = ([uint32]$footer[60] -shl 24) -bor
            ([uint32]$footer[61] -shl 16) -bor
            ([uint32]$footer[62] -shl 8) -bor
            [uint32]$footer[63]
        if ($diskType -ne 2) {
            throw "Azure managed disk upload requires a fixed-size VHD. Convert '$LiteralPath' to fixed VHD format first."
        }
        if (($stream.Length - $footerSize) % 1MB -ne 0) {
            throw "Azure requires the VHD virtual size to be aligned to 1 MiB. Resize '$LiteralPath' before uploading it."
        }
    }
    catch {
        throw "Unable to validate VHD '$LiteralPath'. $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Assert-FixedVhdx {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath
    )

    if (-not (Get-Command "Get-VHD" -ErrorAction SilentlyContinue)) {
        Write-Host ""
        Write-Host "WARNING: The Hyper-V PowerShell module is unavailable, so '$LiteralPath' could not be validated." -ForegroundColor Red
        Write-Host "Ensure that the VHDX is fixed-size and its virtual size is aligned to 1 MiB before continuing." -ForegroundColor Red
        $confirmation = Read-Host "Type YES to continue without validation"
        if ($confirmation.Trim() -cne "YES") {
            throw "Upload canceled because the VHDX could not be validated."
        }

        return
    }

    try {
        $vhdx = Get-VHD -Path $LiteralPath -ErrorAction Stop
    }
    catch {
        Write-Host ""
        Write-Host "WARNING: VHDX validation failed for '$LiteralPath'. Continuing without validation." -ForegroundColor Red
        Write-Host "Ensure that the VHDX is fixed-size and its virtual size is aligned to 1 MiB." -ForegroundColor Red
        Write-Host "Validation error: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    if ([string]$vhdx.VhdFormat -ine "VHDX") {
        throw "The file does not contain a valid VHDX disk."
    }
    if ([string]$vhdx.VhdType -ine "Fixed") {
        throw "Azure managed disk upload requires a fixed-size VHDX. Convert '$LiteralPath' to fixed VHDX format first."
    }
    if ([int64]$vhdx.Size % 1MB -ne 0) {
        throw "Azure requires the VHDX virtual size to be aligned to 1 MiB. Resize '$LiteralPath' before uploading it."
    }
}

$diskRoleSelectedInteractively = $false
$osTypeSelectedInteractively = $false
if ([string]::IsNullOrWhiteSpace($DiskType)) {
    if ($PSBoundParameters.ContainsKey("OsType")) {
        $DiskType = "OS"
    }
    else {
        $diskRoleSelectedInteractively = $true
        $DiskType = [string](Select-MenuItem -Title "Select the managed disk role" -Items @("OS", "Data") -LabelExpression {
            param($role)
            "$role disk"
        })
    }
}
else {
    $DiskType = if ($DiskType -ieq "OS") { "OS" } else { "Data" }
}

if ($DiskType -eq "OS") {
    if ([string]::IsNullOrWhiteSpace($OsType)) {
        $osTypeSelectedInteractively = $true
        $OsType = [string](Select-MenuItem -Title "Select the operating system type" -Items @("Linux", "Windows") -LabelExpression {
            param($operatingSystem)
            $operatingSystem
        })
    }
    if (-not $PSBoundParameters.ContainsKey("HyperVGeneration") -and ($diskRoleSelectedInteractively -or $osTypeSelectedInteractively)) {
        $HyperVGeneration = [string](Select-MenuItem -Title "Select the Hyper-V generation" -Items @("V1", "V2") -LabelExpression {
            param($generation)
            $generation
        })
    }
}
else {
    if ($PSBoundParameters.ContainsKey("OsType")) {
        throw "-OsType cannot be used when -DiskType is Data."
    }
    if ($PSBoundParameters.ContainsKey("HyperVGeneration")) {
        throw "-HyperVGeneration cannot be used when -DiskType is Data."
    }
}

if ([string]::IsNullOrWhiteSpace($Path)) {
    $Path = Read-RequiredInput -Description "Enter the path to an existing local fixed-size VHD or VHDX file." -Example "C:\VMs\server01.vhdx"
}

$Path = ConvertFrom-QuotedPathInput -Value $Path
$resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
$sourceExtension = [System.IO.Path]::GetExtension($resolvedPath)
if ($sourceExtension -notin @(".vhd", ".vhdx")) {
    throw "Path must reference a .vhd or .vhdx file."
}

$requiredCommands = @("az", "azcopy")
foreach ($commandName in $requiredCommands) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$commandName' was not found. Review the README requirements and try again."
    }
}

if ($sourceExtension -ieq ".vhdx") {
    Assert-FixedVhdx -LiteralPath $resolvedPath
}
else {
    Assert-FixedVhd -LiteralPath $resolvedPath
}

$null = az account get-access-token --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "No valid Azure CLI session was found. Run 'az login', select the required subscription, and then run this script again."
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

$resourceGroupJson = & az group list --subscription $subscriptionId --only-show-errors --output json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve resource groups for subscription '$subscriptionLabel'."
}
$resourceGroups = @($resourceGroupJson | ConvertFrom-Json -ErrorAction Stop | Sort-Object name)
if ($resourceGroups.Count -eq 0) {
    throw "No resource groups were found in subscription '$subscriptionLabel'."
}
if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $selectedResourceGroup = Select-MenuItem -Title "Select the destination resource group in $subscriptionLabel" -Items $resourceGroups -LabelExpression {
        param($resourceGroup)
        "$($resourceGroup.name) ($($resourceGroup.location))"
    }
    $ResourceGroupName = [string]$selectedResourceGroup.name
}
else {
    $matchingResourceGroup = $resourceGroups | Where-Object name -IEQ $ResourceGroupName | Select-Object -First 1
    if ($null -eq $matchingResourceGroup) {
        throw "Resource group '$ResourceGroupName' was not found in subscription '$subscriptionLabel'."
    }
    $ResourceGroupName = [string]$matchingResourceGroup.name
}

$locationJson = & az account list-locations --query "[?metadata.regionType=='Physical'].{name:name,displayName:displayName}" --only-show-errors --output json
if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve Azure regions for subscription '$subscriptionLabel'."
}
$locations = @($locationJson | ConvertFrom-Json -ErrorAction Stop | Sort-Object displayName)
if ($locations.Count -eq 0) {
    throw "No physical Azure regions were returned for subscription '$subscriptionLabel'."
}
if ([string]::IsNullOrWhiteSpace($Location)) {
    $resourceGroupLocationNames = @($resourceGroups | Select-Object -ExpandProperty location -Unique)
    $resourceGroupLocations = @($resourceGroupLocationNames | ForEach-Object {
        $resourceGroupLocationName = $_
        $knownLocation = $locations | Where-Object name -IEQ $resourceGroupLocationName | Select-Object -First 1
        if ($null -ne $knownLocation) {
            $knownLocation
        }
        else {
            [PSCustomObject]@{
                name = $resourceGroupLocationName
                displayName = $resourceGroupLocationName
            }
        }
    } | Sort-Object displayName)
    $locationChoices = @($resourceGroupLocations) + [PSCustomObject]@{
        name = "__other__"
        displayName = "Other region"
    }
    $selectedLocation = Select-MenuItem -Title "Select the managed disk region in $subscriptionLabel" -Items $locationChoices -LabelExpression {
        param($azureLocation)
        if ($azureLocation.name -eq "__other__") {
            return "Other region (type a region CLI name)"
        }
        "$($azureLocation.displayName) ($($azureLocation.name))"
    }
    if ($selectedLocation.name -eq "__other__") {
        while ($true) {
            $typedLocation = (Read-Host "Enter an Azure region CLI name, for example eastus2").Trim()
            $matchingLocation = $locations | Where-Object name -IEQ $typedLocation | Select-Object -First 1
            if ($null -ne $matchingLocation) {
                $Location = [string]$matchingLocation.name
                break
            }
            Write-Warning "'$typedLocation' is not a physical Azure region available to subscription '$subscriptionLabel'."
        }
    }
    else {
        $Location = [string]$selectedLocation.name
    }
}
else {
    $matchingLocation = $locations | Where-Object name -IEQ $Location | Select-Object -First 1
    if ($null -eq $matchingLocation) {
        throw "Azure region '$Location' is not available in subscription '$subscriptionLabel'. Use a region CLI name such as eastus2."
    }
    $Location = [string]$matchingLocation.name
}

if ([string]::IsNullOrWhiteSpace($DiskName)) {
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath) -replace "[^a-zA-Z0-9._-]", "-"
    $suffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $DiskName = "$baseName-$suffix"
}

$diskMetadataDescription = if ($DiskType -eq "OS") { "$OsType OS, Hyper-V $HyperVGeneration" } else { "data disk" }
$targetDescription = "$diskMetadataDescription '$DiskName' in resource group '$ResourceGroupName'"
$operationDescription = "Create and upload $DiskType disk"
if (-not $PSCmdlet.ShouldProcess($targetDescription, $operationDescription)) {
    return
}

$diskCreated = $false
$accessGranted = $false
$uploadPath = $resolvedPath
$temporaryConvertedVhdPath = $null
try {
    if ($sourceExtension -ieq ".vhdx") {
        if (-not (Get-Command "Convert-VHD" -ErrorAction SilentlyContinue)) {
            throw "Uploading a VHDX requires the Hyper-V PowerShell module and its Convert-VHD cmdlet because Azure direct upload accepts only VHD content."
        }

        $sourceDirectory = [System.IO.Path]::GetDirectoryName($resolvedPath)
        $sourceBaseName = [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
        $temporaryConvertedVhdPath = [System.IO.Path]::Combine($sourceDirectory, "$sourceBaseName-$([Guid]::NewGuid().ToString('N')).azure-upload.vhd")
        Write-Host "Converting VHDX to temporary fixed VHD '$temporaryConvertedVhdPath'..." -ForegroundColor Cyan
        try {
            Convert-VHD -Path $resolvedPath -DestinationPath $temporaryConvertedVhdPath -VHDType Fixed -ErrorAction Stop
        }
        catch {
            throw "Unable to convert VHDX '$resolvedPath' to VHD. Run the script from an elevated PowerShell session and ensure the source directory has enough free space. $($_.Exception.Message)"
        }
        Assert-FixedVhd -LiteralPath $temporaryConvertedVhdPath
        $uploadPath = $temporaryConvertedVhdPath
    }

    $uploadSizeBytes = [int64](Get-Item -LiteralPath $uploadPath).Length
    if ($uploadSizeBytes -le 0) {
        throw "The virtual disk file is empty."
    }

    $createArguments = @(
        "disk", "create",
        "--name", $DiskName,
        "--resource-group", $ResourceGroupName,
        "--location", $Location,
        "--upload-type", "Upload",
        "--upload-size-bytes", $uploadSizeBytes,
        "--sku", $Sku,
        "--subscription", $subscriptionId,
        "--only-show-errors",
        "--output", "none"
    )
    if ($DiskType -eq "OS") {
        $createArguments += @("--os-type", $OsType, "--hyper-v-generation", $HyperVGeneration)
    }

    Write-Host "Creating $targetDescription..." -ForegroundColor Cyan
    & az @createArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed to create managed disk '$DiskName'."
    }
    $diskCreated = $true

    $grantJson = & az disk grant-access --name $DiskName --resource-group $ResourceGroupName --access-level Write --duration-in-seconds 86400 --subscription $subscriptionId --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed to grant temporary upload access to managed disk '$DiskName'."
    }

    $accessSas = [string](($grantJson | ConvertFrom-Json -ErrorAction Stop).accessSas)
    if ([string]::IsNullOrWhiteSpace($accessSas)) {
        throw "Azure CLI did not return a writable SAS URL for managed disk '$DiskName'."
    }
    $accessGranted = $true

    Write-Host "Uploading '$uploadPath' with AzCopy..." -ForegroundColor Cyan
    & azcopy copy $uploadPath $accessSas --blob-type PageBlob
    if ($LASTEXITCODE -ne 0) {
        throw "AzCopy failed to upload '$uploadPath'. The incomplete managed disk was retained for inspection."
    }
}
finally {
    if ($accessGranted) {
        Write-Host "Revoking temporary disk access..." -ForegroundColor Cyan
        & az disk revoke-access --name $DiskName --resource-group $ResourceGroupName --subscription $subscriptionId --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Temporary access could not be revoked automatically. Run: az disk revoke-access --name '$DiskName' --resource-group '$ResourceGroupName'"
        }
    }
    if ($null -ne $temporaryConvertedVhdPath -and (Test-Path -LiteralPath $temporaryConvertedVhdPath)) {
        Write-Host "Removing temporary converted VHD..." -ForegroundColor Cyan
        Remove-Item -LiteralPath $temporaryConvertedVhdPath -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $temporaryConvertedVhdPath) {
            Write-Warning "Temporary converted VHD could not be removed: '$temporaryConvertedVhdPath'"
        }
    }
}

if ($diskCreated) {
    $diskJson = & az disk show --name $DiskName --resource-group $ResourceGroupName --subscription $subscriptionId --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) {
        throw "The upload completed, but Azure CLI could not retrieve managed disk '$DiskName'."
    }

    $disk = $diskJson | ConvertFrom-Json -ErrorAction Stop
    if ($DiskType -eq "OS" -and ([string]$disk.osType -ine $OsType -or [string]$disk.hyperVGeneration -ine $HyperVGeneration)) {
        throw "Managed disk '$DiskName' was uploaded, but Azure returned unexpected OS metadata. Expected $OsType / $HyperVGeneration; received $($disk.osType) / $($disk.hyperVGeneration)."
    }
    [PSCustomObject]@{
        Name = $disk.name
        DiskType = $DiskType
        ResourceGroupName = $disk.resourceGroup
        Location = $disk.location
        Sku = $disk.sku.name
        OsType = $disk.osType
        HyperVGeneration = $disk.hyperVGeneration
        DiskSizeBytes = $uploadSizeBytes
        ResourceId = $disk.id
    }
}