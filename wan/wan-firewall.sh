# set the value for the parameters
resourceGroupName="rg-wan"
location="westeurope"
wanName="tosokr-wan"
virtualHubName="tosokr-westEurope-hub"
virtulHubAddressPrefix="10.0.0.0/16"
sharedServicesVnetName="vnet-sharedServices"
sharedServicesVnetAddressPrefix="10.1.0.0/16"
sharedServicesVnetSubnet1Name="default"
sharedServicesVnetSubnet1AddressPrefix="10.1.0.0/24"
spokeVnetName="vnet-spoke"
spokeVnetAddressPrefix="10.2.0.0/16"
spokeVnetSubnet1Name="default"
spokeVnetSubnet1AddressPrefix="10.2.0.0/24"
spokeVMName="nginxServer"
spokeVMUserName="tosokr"
spokeVMPassword="MyP@ssw0rd637!"
spokeVMIPAddress="10.2.0.4"

# add the virtual-wan and azure-firewall cli extensions
az extension add --name virtual-wan
az extension add --name azure-firewall

# create the resource group
az group create --name $resourceGroupName --location $location

# create Azure WAN network
az network vwan create --name $wanName \
--resource-group $resourceGroupName --type Standard \
--location $location --vnet-to-vnet-traffic --branch-to-branch-traffic 

# create virtual hub
az network vhub create --name $virtualHubName \
--address-prefix $virtulHubAddressPrefix \
--resource-group $resourceGroupName \
--vwan $wanName --location $location \
--sku Standard

# convert the virtual hub into secured virtual hub
az network firewall create --name virtulHubFirewall \
--resource-group $resourceGroupName \
--location $location --sku AZFW_Hub \
--vhub $virtualHubName

# create vnet for hosting shared services
az network vnet create --name $sharedServicesVnetName \
--resource-group $resourceGroupName \
--address-prefixes $sharedServicesVnetAddressPrefix \
--location $location \
--subnet-name $sharedServicesVnetSubnet1Name \
--subnet-prefixes $sharedServicesVnetSubnet1AddressPrefix

# crete a spoke vnet  
az network vnet create --name $spokeVnetName \
--resource-group $resourceGroupName \
--address-prefixes $spokeVnetAddressPrefix \
--location $location \
--subnet-name $spokeVnetSubnet1Name \
--subnet-prefixes $spokeVnetSubnet1AddressPrefix

# get shared services vnet id
sharedServicesVnetId=$(az network vnet show --name $sharedServicesVnetName \
--resource-group $resourceGroupName --query id -o tsv )

# get the spoke vnet id
spokeVnetId=$(az network vnet show --name $spokeVnetName \
--resource-group $resourceGroupName --query id -o tsv)

# get default subnet id from the spoke vnet
spokeSubnet1Id=$(az network vnet subnet show --name $spokeVnetSubnet1Name \
--resource-group $resourceGroupName --vnet-name $spokeVnetName \
--query id -o tsv)

# peer the shared services vnet with the secured hub
az network vhub connection create \
--name sharedServicesConnectionPeer \
--remote-vnet $sharedServicesVnetId \
--resource-group $resourceGroupName \
--internet-security true \
--vhub-name $virtualHubName

# peer the spoke vnet with the secured hub
az network vhub connection create \
--name spokeConnectionPeer \
--remote-vnet $spokeVnetId \
--resource-group $resourceGroupName \
--internet-security true \
--vhub-name $virtualHubName

# send traffic from vnets and branches through Azure Firewall
az network vhub route-table create \
--connections All_Branches All_Vnets \
--destination-type CIDR \
--destinations $sharedServicesVnetAddressPrefix $spokeVnetAddressPrefix \
--name VirtualNetworkAndBranchRouteTable \
--next-hop-type IPAddress \
--next-hops 10.0.64.4 \
--resource-group $resourceGroupName \
--vhub-name $virtualHubName \
--location $location

# create a cloud-init script for the Linux VM that will install nginx on provisioning
cat <<EOF > cloud-init.yaml
#cloud-config
package_upgrade: true
packages:
  - nginx
EOF

# deploy Linux VM in spoke vnet and install nginx
az vm create --name $spokeVMName \
--resource-group $resourceGroupName \
--image UbuntuLTS --authentication-type password \
--admin-username $spokeVMUserName \
--admin-password $spokeVMPassword \
--location $location \
--private-ip-address $spokeVMIPAddress \
--public-ip-address "" \
--size Standard_A1_v2 \
--subnet $spokeSubnet1Id \
--generate-ssh-keys \
--custom-data cloud-init.yaml

# Create public IP address for Application Gateway
az network public-ip create \
  --resource-group $resourceGroupName \
  --name myAGPublicIPAddress \
  --allocation-method Static \
  --sku Standard

# Create the ApplicationGateway
az network application-gateway create \
  --name aksAppGateway \
  --location $location \
  --resource-group $resourceGroupName \
  --capacity 1 \
  --sku Standard_v2 \
  --public-ip-address myAGPublicIPAddress \
  --vnet-name $sharedServicesVnetName \
  --subnet $sharedServicesVnetSubnet1Name \
  --http-settings-port 80 \
  --http-settings-protocol Http \
  --servers $spokeVMIPAddress

# create a firewall policy
az network firewall policy create \
  --name WanBasePolicy \
  --resource-group $resourceGroupName \
  --location $location


# create a rule collection group
az network firewall policy rule-collection-group create \
--name spokeRules --policy-name WanBasePolicy \
--priority 201 --resource-group $resourceGroupName

# add filter collection 
az network firewall policy rule-collection-group collection add-filter-collection \
--collection-priority 201 \
--name spokeCollection \
--policy-name WanBasePolicy \
--resource-group $resourceGroupName \
--rule-collection-group-name spokeRules \
--action Allow \
--rule-type NetworkRule \
--destination-addresses $spokeVMIPAddress \
--destination-ports 80 \
--ip-protocols TCP \
--source-addresses $sharedServicesVnetSubnet1AddressPrefix

# assing the policy to the firewall
az network firewall update \
--name virtulHubFirewall \
--resource-group $resourceGroupName \
--firewall-policy WanBasePolicy
                                                                     
# access the Application Gateway listener
curl http://$(az network public-ip show --name myAGPublicIPAddress --resource-group $resourceGroupName --query ipAddress -o tsv)