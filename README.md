# Azure VM Lifecycle Tools

## Disclaimer

The sample scripts are not supported under any Microsoft standard support program or service. They are provided AS IS without warranty of any kind. The entire risk arising from their use or performance remains with you.

PowerShell tools for Azure VM lifecycle operations and archived blob rehydration.

## Choose a tool

| Script | Purpose |
| --- | --- |
| `Import-AzVhdToManagedDisk.ps1` | Upload a local fixed-size VHD or VHDX into a new Azure managed disk. |
| `Copy-AzVmWithNewSize.ps1` | Clone selected VMs in a resource group using a different VM size. |
| `Convert-AzZonalVmToRegional.ps1` | Replace a zonal VM with a regional VM by recreating its managed disks without zones and reusing its NICs. |
| `Get-AzVmPlacementInventory.ps1` | Inventory VM placement by name, region, and zonal/regional state (including zone values). |
| `Start-AzBlobRehydration.ps1` | Rehydrate archived blobs to the Hot or Cool access tier. |

All scripts support `-WhatIf` and confirmation prompts because they create resources or submit billable operations.

## Shared requirements

- Windows PowerShell 5.1 or PowerShell 7.
- Azure CLI 2.x authenticated with `az login`.
- Permission to create the Azure resources used by the selected operation.

```powershell
git clone https://github.com/hrezenmsft/azure-vm-lifecycle-tools.git
Set-Location azure-vm-lifecycle-tools
az login
az account set --subscription "<subscription-name-or-id>"
```

Every script verifies the Azure CLI session before doing work. If the session is missing or expired, the script stops and instructs you to run `az login`; no script starts Azure CLI authentication automatically. For multi-tenant accounts, use `az login --tenant "<tenant-id>"` before selecting the subscription.

## Import a VHD or VHDX

### Additional requirements

- An elevated PowerShell session.
- AzCopy available as `azcopy`.
- A fixed-size `.vhd` or `.vhdx` file with a virtual size aligned to 1 MiB.
- The Hyper-V PowerShell module and its `Convert-VHD` cmdlet for VHDX files.
- Enough free space beside the source VHDX for a temporary fixed VHD.
- An existing Azure resource group.

Run the script without required parameters to receive a path prompt followed by destination menus populated from the active subscription. The region menu shows only regions containing resource groups and includes an option to type another physical Azure region. Named parameters remain available for automation and are validated against that subscription.

| Parameter | Description |
| --- | --- |
| `-Path` | Existing local fixed-size `.vhd` or `.vhdx` file. Relative or absolute paths are accepted. |
| `-ResourceGroupName` | Existing destination resource group in the selected subscription. When omitted, choose from a queried list. |
| `-Location` | Azure region CLI name, such as `eastus2` or `westus3`. When omitted, choose a region containing a resource group or type another valid physical region. |
| `-DiskName` | Optional managed disk name. A unique name based on the VHD filename is generated when omitted. |
| `-Sku` | `Standard_LRS` (default), `StandardSSD_LRS`, `Premium_LRS`, or `UltraSSD_LRS`. |
| `-DiskType` | `OS` or `Data`. If omitted, supplying `-OsType` implies `OS`; otherwise choose from a menu. |
| `-OsType` | `Linux` or `Windows`; prompted when omitted for an OS disk and invalid for data disks. |
| `-HyperVGeneration` | `V1` (default) or `V2`; prompted when OS metadata is selected interactively and used only for OS disks. |
| `-SubscriptionId` | Optional subscription name or ID; the active Azure CLI subscription is used when omitted. |

Preview the operation:

```powershell
.\Import-AzVhdToManagedDisk.ps1 -Path .\server.vhd -ResourceGroupName lab-rg -Location eastus2 -WhatIf
```

Upload an OS disk:

```powershell
.\Import-AzVhdToManagedDisk.ps1 `
    -Path .\linux.vhd `
    -ResourceGroupName lab-rg `
    -Location eastus2 `
    -DiskType OS `
    -OsType Linux `
    -HyperVGeneration V2 `
    -Sku Premium_LRS
```

Upload a fixed VHDX OS disk:

```powershell
.\Import-AzVhdToManagedDisk.ps1 `
    -Path .\server.vhdx `
    -ResourceGroupName lab-rg `
    -Location eastus2 `
    -DiskType OS `
    -OsType Windows `
    -HyperVGeneration V2
```

Create a data disk explicitly:

```powershell
.\Import-AzVhdToManagedDisk.ps1 `
    -Path .\data.vhd `
    -ResourceGroupName lab-rg `
    -Location eastus2 `
    -DiskType Data
```

For backward compatibility, omitting `-DiskType` while supplying `-OsType` creates an OS disk. When both are omitted, the script asks whether the upload is an OS or data disk. OS disk selection also prompts for Linux or Windows and Hyper-V generation when those values were not supplied. If `-DiskName` is omitted, the script generates a name from the VHD filename.

For OS disks, the script passes `--os-type` and `--hyper-v-generation` to Azure during managed disk creation, displays those selections in the confirmation prompt, and verifies that Azure retained the expected OS metadata after upload.

The Azure direct-upload endpoint accepts fixed VHD content and validates its `conectix` footer. For VHDX input, the script uses `Convert-VHD` to create a temporary fixed VHD beside the source, uploads that VHD, and removes it afterward. It uses `Get-VHD` for an earlier VHDX check when available; if that check cannot run, conversion remains the authoritative validation step. See the [official Microsoft Learn preparation guidance](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/prepare-for-upload-vhd-image). Pasted paths can include surrounding single or double quotes, including paths containing spaces.

The upload SAS is held in process memory and revoked in a `finally` block. If revocation fails, the script prints the exact recovery command without displaying the SAS URL.

```powershell
Get-Help .\Import-AzVhdToManagedDisk.ps1 -Full
```

## Rehydrate archived blobs

### Additional requirements

- Az PowerShell modules: `Az.Accounts` and `Az.Storage`.
- Management-plane read access to discover storage accounts.
- `Storage Blob Data Contributor` or equivalent data-plane permissions on the target storage account or selected containers.
- Network access permitted by the storage firewall, virtual network rules, or private endpoint configuration.
- A standard general-purpose v2 or Blob Storage account containing archived base blobs.

```powershell
Install-Module Az.Accounts, Az.Storage -Scope CurrentUser
```

Preview every eligible archived blob in a selected storage account:

```powershell
.\Start-AzBlobRehydration.ps1 -WhatIf
```

The script does not start Azure CLI authentication. Run `az login` before the script; for a multi-tenant account, scope login to the tenant containing the subscription:

```powershell
az login --tenant "<tenant-id>"

.\Start-AzBlobRehydration.ps1 `
    -SubscriptionId "<subscription-id>" `
    -TenantId "<tenant-id>" `
    -WhatIf
```

If the Azure CLI session is missing or expired, the script stops and prints the required login command. Az PowerShell may open a browser separately when Az.Storage needs a matching tenant context.

Rehydrate one container to Cool with Standard priority:

```powershell
.\Start-AzBlobRehydration.ps1 `
    -ResourceGroupName archive-rg `
    -StorageAccountName archivestore01 `
    -ContainerName backups `
    -TargetTier Cool `
    -RehydratePriority Standard
```

Use `-ContainerName container1,container2` to limit scanning to multiple containers, `-BatchSize` to control enumeration page size, and `-MaxBlobCount` to cap eligible blobs in one run. Blobs already showing a pending rehydration status are skipped. Supplying `-ContainerName` also supports least-privilege role assignments scoped to those containers because the script does not attempt account-wide container discovery. Omitting it requires permission to list containers at storage-account scope.

An Azure Storage 403 can be caused by either data-plane RBAC or storage networking. Management roles such as Owner or Contributor do not grant blob access; use `Storage Blob Data Contributor`. Storage accounts with public access disabled or a default network action of `Deny` must be reached from an allowed IP/VNet or through a correctly resolved private endpoint. Role assignments can take up to 10 minutes to propagate. The script reports the relevant RBAC scope, network settings, and diagnostic commands when access is denied.

The script uses Microsoft Entra ID for blob enumeration and Azure CLI `--auth-mode login` for tier changes. It does not retrieve account keys or enable shared-key access. Each container has its own continuation-token sequence, so large accounts are paginated correctly.

Changing an archived blob to Hot or Cool can incur retrieval, transaction, online storage, and early deletion charges. Standard priority may take up to 15 hours for smaller blobs under ideal conditions. High priority costs more and should be reserved for urgent restores. Azure processes accepted requests asynchronously, and tier changes cannot be canceled after submission. Review [Microsoft's blob rehydration guidance](https://learn.microsoft.com/azure/storage/blobs/archive-rehydrate-overview) before running the script.

```powershell
Get-Help .\Start-AzBlobRehydration.ps1 -Full
```

## Clone VMs at a new size

### Additional requirements

- Az PowerShell modules: `Az.Accounts` and `Az.Compute`.
- Quota for the target VM size and created disks, snapshots, NICs, and VMs.

```powershell
Install-Module Az.Accounts, Az.Compute -Scope CurrentUser
```

Run without parameters for guided numbered menus:

```powershell
.\Copy-AzVmWithNewSize.ps1
```

The script does not start Azure CLI authentication. Run `az login` first. For accounts with access to multiple tenants, authenticate to the tenant containing the subscription:

```powershell
az login --tenant "<tenant-id>"

.\Copy-AzVmWithNewSize.ps1 `
    -SubscriptionId "<subscription-id>" `
    -TenantId "<tenant-id>"
```

If the Azure CLI session is missing or expired, the script stops and prints the required login command. `-TenantId` is optional but recommended for multi-tenant accounts.

The script prompts for:

1. Source resource group.
2. One or more source VMs.
3. The number of clones to create for each selected VM.
4. A target-size search term and a VM size available to the active subscription in the source VM region.

Each menu displays the active Azure subscription name and ID at the top.

In the source VM menu, enter a single number, comma-separated values such as `1,3,5`, a range such as `2-4`, a combination such as `1,3-5`, or `A` to select all VMs. Enter `0` to cancel. Target-size searches that return more than 50 results ask for a narrower filter.

When multiple VMs are selected, the target menu shows only sizes present in Azure's available-size list for every source VM. Explicit `-TargetVmSize` values are validated against the same per-VM availability data before any resources are created.

Enter an exact target size such as `Standard_D4s_v5` to validate it directly against every selected source VM in the active subscription and region. Enter a partial name such as `D4s_v5` or `Dsv5` to search current Microsoft Learn VM size documentation and choose from documented matches that pass the same availability checks. The script uses Azure's per-VM available resize-size endpoint instead of downloading the slow Resource SKUs catalog.

Use `-CloneCount` to create multiple clones per selected source VM in one run. The accepted range is 1-100 and the default is 1 for noninteractive execution. Each clone receives a unique generated name, disk, and NIC. Clones of the same source share one temporary snapshot; generalized Windows clones also share one Sysprep preparation VM and generalized image. Shared artifacts remain until every clone for that source has been created, then are removed.

Before changing Azure resources, the confirmation prompt summarizes every selected source and target VM, total clone count, and inherited boot diagnostics state. Each clone enables or disables boot diagnostics to match its source VM.

During cloning, a parent progress bar tracks completed or skipped clone plans against the total. A child progress bar reports the current step and total steps for source preparation, each clone, and cleanup; cleanup totals reflect only resources that still exist. Final clones remain running; only a temporary Sysprep preparation VM is deallocated when creating a generalized Windows image.

If cloning or generalization fails for one source VM, the script displays an error message with the failure reason, skips any remaining clone plans for that source, performs best-effort cleanup, and continues with the next selected source VM. Successfully created clones are retained and included in the final results. A failed clone can leave its copied disk or NIC for inspection and manual cleanup.

### Optional Windows generalization

When an interactive selection includes a Windows VM, the script offers two modes:

1. `Specialized` copies the VM as-is and preserves its machine-specific identity.
2. `Generalized` boots a temporary copy on an isolated, unpeered preparation VNet, schedules `sysprep.exe /generalize /oobe /shutdown /quiet` through Azure Run Command, marks only that temporary VM generalized in Azure, captures a temporary managed image, and deploys the final VM with new local administrator credentials on the source subnet.

The selected source VM is never generalized or modified. Use `-GeneralizeWindows` for noninteractive runs and optionally provide `-WindowsAdminCredential`; otherwise the script prompts securely after plan confirmation. Noninteractive execution also requires `-AcknowledgeSysprepPrerequisites`. Linux VMs in a mixed selection remain specialized.

Generalization requires a healthy Azure Windows VM Agent with outbound Azure connectivity. Following the [Microsoft Learn Windows generalization guidance](https://learn.microsoft.com/en-us/azure/virtual-machines/generalize#generalizing-a-windows-vm-before-creating-an-image), the temporary guest preflight verifies that CD/DVD-ROM is enabled, removes `C:\Windows\Panther`, verifies that every BitLocker-capable volume is fully decrypted, and blocks removable-storage deny policies that could prevent Azure OOBE from mounting provisioning media. Microsoft documents `sysprep.exe /generalize /shutdown` for an interactive administrator session; the script adds `/oobe /quiet` because its SYSTEM scheduled task is noninteractive and otherwise waits indefinitely at an invisible mode-selection dialog. It waits for shutdown without restarting the VM, deallocates it, and marks only the temporary VM generalized in Azure. No custom unattend file is used.

The script blocks Trusted Launch VMs and domain controllers. Domain-joined member VMs are booted only on the isolated preparation VNet so they cannot contact the source network with a duplicate machine identity; Sysprep then removes their machine-specific domain identity. The final generalized clone is not domain joined and must be joined to the domain separately if required. Automation cannot prove that every installed application or role supports Sysprep, so the operator must explicitly confirm product-specific requirements for server roles, SQL Server, security agents, Store applications, and Microsoft Defender for Endpoint. Ensure Windows has no pending servicing work. The script removes the temporary VM, preparation NIC/VNet, copied preparation disk, snapshot, and managed image after deployment and makes a best-effort cleanup attempt after failure.

```powershell
.\Copy-AzVmWithNewSize.ps1 `
    -ResourceGroupName lab-rg `
    -SourceVmName winserver01 `
    -TargetVmSize Standard_D4s_v5 `
    -CloneCount 3 `
    -GeneralizeWindows `
    -AcknowledgeSysprepPrerequisites
```

Source NIC metadata and cloned NIC creation use Azure CLI resource IDs. The script does not load Az.Network, avoiding its model-deserialization failures while preserving the source subnet and NIC-level network security group.

Clone one VM without menus:

```powershell
.\Copy-AzVmWithNewSize.ps1 `
    -ResourceGroupName lab-rg `
    -SourceVmName server01 `
    -TargetVmSize Standard_D4s_v5
```

`-SourceVM` is an alias for `-SourceVmName`.

Preview cloning every VM in a resource group:

```powershell
.\Copy-AzVmWithNewSize.ps1 -ResourceGroupName lab-rg -TargetVmSize Standard_D4s_v5 -WhatIf
```

## Convert a zonal VM to regional

### Additional requirements

- Az PowerShell modules: `Az.Accounts`, `Az.Compute`, and `Az.Resources`.
- Permission to stop/delete the source VM and create replacement disks, snapshots, and the new VM.
- A zonal VM that uses managed disks.
- A maintenance window, because the source VM is stopped, deleted, and recreated with the same name.

```powershell
Install-Module Az.Accounts, Az.Compute, Az.Resources -Scope CurrentUser
```

Run without parameters for guided numbered menus:

```powershell
.\Convert-AzZonalVmToRegional.ps1
```

The script does not start Azure CLI authentication. Run `az login` first. For accounts with access to multiple tenants, authenticate to the tenant containing the subscription:

```powershell
az login --tenant "<tenant-id>"

.\Convert-AzZonalVmToRegional.ps1 `
    -SubscriptionId "<subscription-id>" `
    -TenantId "<tenant-id>"
```

If the Azure CLI session is missing or expired, the script stops and prints the required login command. `-TenantId` is optional but recommended for multi-tenant accounts.

The script prompts for:

1. Source resource group.
2. Source zonal VM.

Each menu displays the active Azure subscription name and ID at the top. The VM picker lists only zonal VMs in the selected resource group and also supports manual entry.

Preview the conversion:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01 `
    -WhatIf
```

Convert a zonal VM and keep its current size:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01
```

Convert a zonal VM and change the VM size during recreation:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01 `
    -TargetVmSize Standard_D4s_v5
```

Convert a zonal VM and force the replacement disks to a target SKU:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01 `
    -TargetDiskSkuName Premium_LRS
```

Keep the temporary snapshots for a rollback window:

```powershell
.\Convert-AzZonalVmToRegional.ps1 `
    -ResourceGroupName prod-rg `
    -VmName app01 `
    -KeepSnapshots
```

The script snapshots the source OS disk and every attached data disk, creates new regional managed disks by intentionally omitting zone assignment, stops the source VM if needed, updates delete options to detach NICs and disks, deletes the source VM object, and recreates the VM with the same name. It preserves attached NICs, boot diagnostics configuration, license type, marketplace plan metadata, security profile, tags, and data-disk LUN and caching settings where Azure allows them on the replacement VM.

This is an in-place replacement, not an online migration. The original VM resource is deleted, and the original managed disks remain detached after recreation so you can validate the replacement VM before manual cleanup. If `-KeepSnapshots` is omitted, temporary snapshots are removed automatically after successful completion.

The script warns if the VM is not marked zonal at the VM resource level, but it still continues so you can handle cases where zonal behavior is represented primarily by the attached disks. Review the confirmation summary carefully, because `-TargetVmName` is reserved and the script always recreates the VM with the original name.

After validation, manually remove the original source disks and any retained snapshots listed in the cleanup summary to avoid ongoing charges.

```powershell
Get-Help .\Convert-AzZonalVmToRegional.ps1 -Full
```

Clone only VMs at a specific source size:

```powershell
.\Copy-AzVmWithNewSize.ps1 `
    -ResourceGroupName lab-rg `
    -SourceVmSize Standard_D2s_v5 `
    -TargetVmSize Standard_D4s_v5
```

For backward-compatible bulk automation, supplying `-ResourceGroupName` and `-TargetVmSize` without a source VM or source-size filter processes every VM in the resource group.

Specialized clones receive an OS disk copied from the shared source snapshot. Generalized Windows clones receive an OS disk provisioned from the shared temporary managed image. Every clone receives a new NIC in the source VM's first subnet and remains running after creation. Shared temporary artifacts are removed in a `finally` block.

### Clone limitations

- Source VMs are not modified.
- Specialized clones retain the guest hostname, accounts, machine identity, and domain membership.
- Generalized Windows clones receive a new computer name and machine identity, reuse the supplied local administrator credentials, and are not domain joined.
- Only the OS disk and first NIC/subnet are used.
- Data disks, additional NICs, public IPs, extensions, identities, tags, zones, availability settings, and custom IP configurations are not copied.
- Accelerated networking is disabled unless `-EnableAcceleratedNetworking` is supplied and must be supported by the target size and guest.
- A failed clone can leave its copied disk or NIC for inspection and manual cleanup; temporary shared artifacts are removed on a best-effort basis.

```powershell
Get-Help .\Copy-AzVmWithNewSize.ps1 -Full
```

## Inventory VM placement

Generate a VM inventory that shows each VM name, region, whether it is zonal
or regional, and the zone values when present.

The final report is rendered once as a single table with these columns:
`Name`, `ResourceGroupName`, `Region`, `Placement`, and `Zone`.

Run with guided menus:

```powershell
.\Get-AzVmPlacementInventory.ps1
```

Inventory one resource group:

```powershell
.\Get-AzVmPlacementInventory.ps1 -ResourceGroupName lab-rg
```

Inventory all resource groups in the active subscription:

```powershell
.\Get-AzVmPlacementInventory.ps1 -AllResourceGroups
```

Like other tools in this repository, this script expects a valid Azure CLI
session and does not run `az login` for you.

```powershell
Get-Help .\Get-AzVmPlacementInventory.ps1 -Full
```

## Security and cost

- Review `-WhatIf` output before creating resources.
- Azure disks, snapshots, NICs, and VMs can incur charges.
- Generalized Windows cloning requests a local administrator credential through `Get-Credential`; the credential remains in process memory and is passed to Azure deployment without being written to disk by the script.
- Avoid verbose or transcript logging when debugging token-bearing commands.
- Review all cloned resources before deleting or changing a source VM.

## Author

Henrique Rezende

## License

Licensed under the [MIT License](LICENSE).