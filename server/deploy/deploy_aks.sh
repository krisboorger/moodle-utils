#!/bin/sh
set -euo pipefail

### CONFIG ###
# the namespace used
k8s_namespace="moodle-utils-ns"
# ingress service name
ingress_service_name="server-service"
#############

# apply terraform files
terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve

# update helm repo
helm repo add csi-secrets-store-provider-azure https://azure.github.io/secrets-store-csi-driver-provider-azure/charts

# save tf values for use with k8s
cluster_name=$(terraform -chdir=terraform output -raw kubernetes_cluster_name)
cluster_rg_name=$(terraform -chdir=terraform output -raw resource_group_name)
export tenant_id=$(terraform -chdir=terraform output -raw tenant_id)

# switch to new k8s context
az aks get-credentials --name $cluster_name --resource-group $cluster_rg_name

# create new namespace
kubectl apply -f ./k8s/00-namespace.yaml

# apply the rest of k8s config files before key vault
cat ./k8s/1* | kubectl apply -f - --overwrite=true -n $k8s_namespace

# install key vault driver to the k8s cluster
helm install csi csi-secrets-store-provider-azure/csi-secrets-store-provider-azure --namespace $k8s_namespace

# add envvars to key vault config file
cat ./k8s/20-key-vault.yaml | envsubst | kubectl apply -f - --overwrite=true -n $k8s_namespace

# apply the rest of k8s config files after key vault
cat ./k8s/3* | kubectl apply -f - --overwrite=true -n $k8s_namespace

# wait for deployment to complete
deployment_name=$(kubectl get deployment -n $k8s_namespace| awk '!/NAME/{print $1}')
kubectl -n $k8s_namespace rollout status deployment/"$deployment_name"
if [[ "$?" -ne 0 ]]; then
    exit 1
fi

# wait until ingress is up
until kubectl get service/$ingress_service_name --output=jsonpath='{.status.loadBalancer}' -n $k8s_namespace | grep "ingress"; do echo "aaa" ; done

# get external IP to add to DNS
external_ip=$(kubectl get service/$ingress_service_name --output=jsonpath='{.status.loadBalancer.ingress[0].ip}' -n $k8s_namespace)

echo "The server is ready. Add the following IP to the DNS record: $external_ip"
