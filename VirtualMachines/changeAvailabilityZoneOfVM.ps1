# Set variables
$subscriptionId="" #Set to your subscription id where the VM is created
$resourceGroup = "" #Resouce group of the VM
$vmName = "" #VM Name
$location = "westeurope" #VM Location
$zone = "2" #1 2 or 3

#Login to the Azure
Login-AzAccount

#Set the subscription
Set-AzContext -Subscription $subscriptionId

# Get the details of the VM to be moved to the Availability Set
$originalVM = Get-AzVM -ResourceGroupName $resourceGroup -Name $vmName

# Stop the VM to take snapshot
Stop-AzVM -ResourceGroupName $resourceGroup -Name $vmName -Force 

# Create a SnapShot of the OS disk and then, create an Azure Disk with Zone information
$snapshotOSConfig = New-AzSnapshotConfig -SourceUri $originalVM.StorageProfile.OsDisk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS
$OSSnapshot = New-AzSnapshot -Snapshot $snapshotOSConfig -SnapshotName ($originalVM.StorageProfile.OsDisk.Name + "-snapshot") -ResourceGroupName $resourceGroup 
$diskSkuOS = (Get-AzDisk -DiskName $originalVM.StorageProfile.OsDisk.Name -ResourceGroupName $originalVM.ResourceGroupName).Sku.Name

$diskConfig = New-AzDiskConfig -Location $OSSnapshot.Location -SourceResourceId $OSSnapshot.Id -CreateOption Copy -SkuName  $diskSkuOS -Zone $zone 
$OSdisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $resourceGroup -DiskName ($originalVM.StorageProfile.OsDisk.Name + "zone")


# Create a Snapshot from the Data Disks and the Azure Disks with Zone information
foreach ($disk in $originalVM.StorageProfile.DataDisks) { 

   $snapshotDataConfig = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS
   $DataSnapshot = New-AzSnapshot -Snapshot $snapshotDataConfig -SnapshotName ($disk.Name + '-snapshot') -ResourceGroupName $resourceGroup

   $diskSkuData = (Get-AzDisk -DiskName $disk.Name -ResourceGroupName $originalVM.ResourceGroupName).Sku.Name
   $datadiskConfig = New-AzDiskConfig -Location $DataSnapshot.Location -SourceResourceId $DataSnapshot.Id -CreateOption Copy -SkuName $diskSkuData -Zone $zone
   $datadisk = New-AzDisk -Disk $datadiskConfig -ResourceGroupName $resourceGroup -DiskName ($disk.Name + "zone")
}

# Remove the original VM
Remove-AzVM -ResourceGroupName $resourceGroup -Name $vmName  -Force

# Create the basic configuration for the replacement VM
$newVM = New-AzVMConfig -VMName $originalVM.Name -VMSize $originalVM.HardwareProfile.VmSize -Zone $zone

# Add the pre-existed OS disk 
Set-AzVMOSDisk -VM $newVM -CreateOption Attach -ManagedDiskId $OSdisk.Id -Name $OSdisk.Name -Windows

# Add the pre-existed data disks
foreach ($disk in $originalVM.StorageProfile.DataDisks) { 
    $datadisk = Get-AzDisk -ResourceGroupName $resourceGroup -DiskName ($disk.Name + "zone")
    Add-AzVMDataDisk -VM $newVM -Name $datadisk.Name -ManagedDiskId $datadisk.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach 
}

# Add NIC(s) and keep the same NIC as primary
# If there is a Public IP from the Basic SKU remove it because it doesn't supports zones
foreach ($nic in $originalVM.NetworkProfile.NetworkInterfaces) {  
   $netInterface = Get-AzNetworkInterface -ResourceId $nic.Id 
   $publicIPId = $netInterface.IpConfigurations[0].PublicIpAddress.Id
   $publicIP = Get-AzPublicIpAddress -Name $publicIPId.Substring($publicIPId.LastIndexOf("/")+1) 
   if ($publicIP)
   {      
      if ($publicIP.Sku.Name -eq 'Basic')
      {
         $netInterface.IpConfigurations[0].PublicIpAddress = $null
         Set-AzNetworkInterface -NetworkInterface $netInterface
      }
   }
if ($nic.Primary -eq "True")
   {
      Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id -Primary
   }
   else
   {
      Add-AzVMNetworkInterface -VM $newVM -Id $nic.Id 
   }
}

# Recreate the VM
New-AzVM -ResourceGroupName $resourceGroup -Location $originalVM.Location -VM $newVM -DisableBginfoExtension

# If the machine is SQL server, create a new SQL Server object
New-AzSqlVM -ResourceGroupName $resourceGroup -Name $newVM.Name -Location $location -LicenseType PAYG 
