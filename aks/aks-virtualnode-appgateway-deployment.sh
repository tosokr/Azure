# set the value for the parameters
resourceGroupName="rg-aks"
location="westeurope"
aksClusterName="tosokr"
aksClusterNodeSize="Standard_DS1_v2"
aksClusterNodeCount=2

# create the resource group
az group create --name $resourceGroupName --location $location

# create the service principle for the AKS
servicePrinciplePassword=$(az ad sp create-for-rbac --skip-assignment --name myAKSClusterServicePrincipal --query password --output tsv) 
servicePrincipleId=$(az ad sp show --id http://myAKSClusterServicePrincipal --query appId --output tsv)

# create the AKS cluster
az aks create --resource-group $resourceGroupName --name $aksClusterName \
--node-count $aksClusterNodeCount --location $location \
--generate-ssh-keys --service-principal $servicePrincipleId \
--client-secret $servicePrinciplePassword --node-vm-size $aksClusterNodeSize \
--network-plugin azure

# get the AKS resource group for the nodes and vnet name
nodeResourceGroup=$(az aks show --resource-group rg-aks --name tosokr --query nodeResourceGroup --o tsv)
vnetName=$(az network vnet list --query [].name --o tsv --resource-group $nodeResourceGroup)

# create subnet for the ACI instances
az network vnet subnet create \
    --resource-group $nodeResourceGroup \
    --vnet-name $vnetName \
    --name aci-subnet \
    --address-prefixes 10.241.0.0/16

# enable ACI connector on the AKS cluster
az aks enable-addons --addons virtual-node \
--resource-group $resourceGroupName --name $aksClusterName \
--subnet-name aci-subnet

# create subnet for Application Gateway
az network vnet subnet create \
  --name ag-subnet \
  --resource-group $nodeResourceGroup \
  --vnet-name $vnetName \
  --address-prefix 10.242.0.0/27

# Create public IP address for Application Gateway
az network public-ip create \
  --resource-group $nodeResourceGroup \
  --name myAGPublicIPAddress \
  --allocation-method Static \
  --sku Standard

#Create the ApplicationGateway
az network application-gateway create \
  --name aksAppGateway \
  --location $location \
  --resource-group $nodeResourceGroup \
  --capacity 1 \
  --sku Standard_v2 \
  --http-settings-cookie-based-affinity Enabled \
  --public-ip-address myAGPublicIPAddress \
  --vnet-name $vnetName \
  --subnet ag-subnet

# get the AKS credentials
az aks get-credentials --resource-group $resourceGroupName --name $aksClusterName
# get the subscriptionId
subscriptionId=$(az account show --query id -o tsv)
# create aad-pod-identity
kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment-rbac.yaml
# create an Azure identity
azureIdentityId=$(az identity create -g $nodeResourceGroup -n azureIdentity --query id -o tsv)
azureIdentityClientId=$(az identity show --ids $azureIdentityId --query clientId -o tsv)
# install the Azure Identity into AKS
cat <<EOF | kubectl apply -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentity
metadata:
  name: azureidentity
spec:
  type: 1
  ResourceID: $azureIdentityId
  ClientID: $azureIdentityClientId
EOF
# set the Azure Identity Binding
cat <<EOF | kubectl apply -f -
apiVersion: "aadpodidentity.k8s.io/v1"
kind: AzureIdentityBinding
metadata:
  name: azure-identity-binding
spec:
  AzureIdentity: azureidentity
  Selector: ingress-azure
EOF
# create an Azure identity and give it permissions to ARM
armAzureIdentityPrincipalId=$(az identity create -g $nodeResourceGroup -n armAzureIdentity --query principalId -o tsv)
# get the Application Gateway resourceid
appGatewayResourceId=$(az network application-gateway list --resource-group $nodeResourceGroup --query '[].id' -o tsv)
# get the nodeResourceGroup id
nodeResourceGroupId=$(az group show --name $nodeResourceGroup --query id -o tsv)
# give Contributor access to the Application Gateway
az role assignment create \
    --role Contributor \
    --assignee $armAzureIdentityPrincipalId \
    --scope $appGatewayResourceId
# give Reader access to the Resource Group
az role assignment create \
    --role Reader \
    --assignee $armAzureIdentityPrincipalId \
    --scope $nodeResourceGroupId
# install tiller for Helm v2
kubectl create serviceaccount \
--namespace kube-system tiller-sa
kubectl create clusterrolebinding tiller-cluster-rule \
--clusterrole=cluster-admin --serviceaccount=kube-system:tiller-sa
helm init --tiller-namespace kube-system --service-account tiller-sa

# add the application-gateway-kubernetes-ingress helm repo and perform a helm update
helm repo add application-gateway-kubernetes-ingress \
https://appgwingress.blob.core.windows.net/ingress-azure-helm-package/
helm repo update

# Install the Application Gateway Ingress Controler (AGIC) using helm
armAzureIdentityId=$(az identity show --name armAzureIdentity \
--resource-group $nodeResourceGroup --query id -o tsv)
armAzureIdentityClientId=$(az identity show --name armAzureIdentity \
--resource-group $nodeResourceGroup --query clientId -o tsv)
aksApiServerAddress=$(az aks show --resource-group rg-aks \
--name tosokr --query fqdn -o tsv)
helm install application-gateway-kubernetes-ingress/ingress-azure \
     --name ingress-azure \
     --namespace default \
     --debug \
     --set appgw.name=aksAppGateway \
     --set appgw.resourceGroup=$nodeResourceGroup \
     --set appgw.subscriptionId=$subscriptionId \
     --set appgw.shared=false \
     --set armAuth.type=aadPodIdentity \
     --set armAuth.identityResourceID=$armAzureIdentityId \
     --set armAuth.identityClientID=$armAzureIdentityClientId \
     --set rbac.enabled=true \
     --set verbosityLevel=3 \
     --set kubernetes.watchNamespace=default \
     --set aksClusterConfiguration.apiServerAddress=$aksApiServerAddress

# IMPORTANT !!!! IT WILL SAVE YOU COUPLE OF HOURS !!!
# after pod is created, view its details using:
# kubectl describe pod -l app=ingress-azure
# if you see the followin messages, you need to manually edit the deployment (THIS IS A AGIC BUG)
# Liveness probe failed: Get http://10.240.0.44:8123/health/alive: dial tcp 10.240.0.44:8123: connect: connection refused
# Readiness probe failed: Get http://10.240.0.44:8123/health/ready: dial tcp 10.240.0.44:8123: connect: connection refused
# kubectl edit deployment ingress-azure
# and remove the livenessProbe and readinessProbe sections from the yaml file

# deploy a simple demo application. 
# the deployment will create pods on the ACI, and horizonal pod autoscaler
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: aci-aspnetapp
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aci-aspnetapp
  template:
    metadata:
      labels:
        app: aci-aspnetapp
    spec:
      containers:
      - image: "mcr.microsoft.com/dotnet/core/samples:aspnetapp"
        name: aspnetapp-image
        ports:
        - containerPort: 80
          protocol: TCP
        resources:
          requests:
            cpu: 250m
            memory: 250Mi
          limits:
            cpu: 250m
            memory: 250Mi
      nodeSelector:
        kubernetes.io/role: agent
        beta.kubernetes.io/os: linux
        type: virtual-kubelet
      tolerations:
      - key: virtual-kubelet.io/provider
        operator: Exists
      - key: azure.com/aci
        effect: NoSchedule
      
---

apiVersion: autoscaling/v1
kind: HorizontalPodAutoscaler
metadata:
  name: aci-aspnetapp-hpa
spec:
  maxReplicas: 3 # define max replica count
  minReplicas: 1  # define min replica count
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: aci-aspnetapp
  targetCPUUtilizationPercentage: 50 # target CPU utilization

---

apiVersion: v1
kind: Service
metadata:
  name: aci-aspnetapp
spec:
  selector:
    app: aci-aspnetapp
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80

---

apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: aci-aspnetapp
  annotations:
    kubernetes.io/ingress.class: azure/application-gateway
spec:
  rules:
  - http:
      paths:
      - path: /
        backend:
          serviceName: aci-aspnetapp
          servicePort: 80
EOF

# generate traffic to the demo application 
# (you need to install go first: sudo apt install golang-go) 
appGatewayPublicIp=$(az network public-ip show \
--name myAGPublicIPAddress --resource-group $nodeResourceGroup \
--query ipAddress -o tsv)
export GOPATH=~/go
export PATH=$GOPATH/bin:$PATH
go get -u github.com/rakyll/hey
hey -z 20m http://$appGatewayPublicIp

# in a new window monitor how the pods are scalled automaticaly using Azure Container Instances
kubectl get hpa aci-aspnetapp-hpa -w