#!/bin/bash -xe

MINIKUBE_PROFILE=minikube-kvm

TIMEOUT=5m

################################################################################
# Cleanup

reset
minikube delete --profile ${MINIKUBE_PROFILE}
sleep 10

################################################################################
# Create minikube instance

minikube start --driver=kvm2 --cpus=4 --memory=8g --profile ${MINIKUBE_PROFILE}
minikube profile list
kubectl config get-contexts

sleep 30

########################################
# Wait for cluster to be ready

NAMESPACE=kube-system
for APP in kube-proxy kube-dns
do
  kubectl wait --for condition=ready pod -l k8s-app=${APP} -n ${NAMESPACE} --timeout=${TIMEOUT}
done

sleep 5

########################################
# Enable kubernetes-dashboard addon

minikube addons enable dashboard --profile ${MINIKUBE_PROFILE}
NAMESPACE=kubernetes-dashboard
for APP in kubernetes-dashboard dashboard-metrics-scraper
do
  kubectl wait --for condition=ready pod -l k8s-app=${APP} -n ${NAMESPACE} --timeout=${TIMEOUT}
done

########################################
# Enable metrics-server addon

minikube addons enable metrics-server --profile ${MINIKUBE_PROFILE}
NAMESPACE=kube-system
for APP in metrics-server
do
  kubectl wait --for condition=ready pod -l k8s-app=${APP} -n ${NAMESPACE} --timeout=${TIMEOUT}
done

kubectl get all --all-namespaces

################################################################################
# Install and configure MetalLB

METALLB_IP_START=192.168.39.100
METALLB_IP_END=192.168.39.110
minikube addons list --profile ${MINIKUBE_PROFILE}
minikube addons enable metallb --profile ${MINIKUBE_PROFILE}
sleep 10
echo -e "${METALLB_IP_START}\n${METALLB_IP_END}\n" | \
minikube addons configure metallb --profile ${MINIKUBE_PROFILE} || true
sleep 10
kubectl get configmap/config -n metallb-system

# Patch MetalLB config with updated IP address range
kubectl apply -f - -n metallb-system << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: config
  namespace: metallb-system
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - ${METALLB_IP_START}-${METALLB_IP_END}
EOF

NAMESPACE=metallb-system
APP=metallb
for COMPONENT in controller speaker
do
  kubectl wait --for condition=ready pod -l app=${APP} -l component=${COMPONENT} -n ${NAMESPACE} --timeout=${TIMEOUT}
done

sleep 10

kubectl get all --all-namespaces

################################################################################
# Install and configure istio with helm

export ISTIO_VERSION=1.12.1

which helm
helm version
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

sleep 5

kubectl create namespace istio-system
helm install istio-base istio/base -n istio-system --version ${ISTIO_VERSION} --wait --timeout=${TIMEOUT}
helm install istiod istio/istiod -n istio-system --version ${ISTIO_VERSION} --wait --timeout=${TIMEOUT}

sleep 15

kubectl create namespace istio-ingress
kubectl label namespace istio-ingress istio-injection=enabled --overwrite
helm install istio-ingress istio/gateway -n istio-ingress  --version ${ISTIO_VERSION} --wait --timeout=${TIMEOUT}

sleep 15

helm status istiod -n istio-system

kubectl get all --all-namespaces

# Enable istio-proxy on certain namespaces
# TODO: Create demo namespace for the example applications

sleep 5

for NAMESPACE in default kubernetes-dashboard
do
  kubectl label namespace ${NAMESPACE} istio-injection=enabled --overwrite
done
kubectl get namespaces --show-labels

sleep 5

# Scale down-up the kubernetes-dashboard to get istio-proxy sidecar working
for TARGET in kubernetes-dashboard dashboard-metrics-scraper
do
  kubectl scale deployment ${TARGET} -n kubernetes-dashboard --replicas 0
  sleep 1
  kubectl scale deployment ${TARGET} -n kubernetes-dashboard --replicas 1
  sleep 5
  kubectl wait --for condition=ready pod -l k8s-app=${TARGET} -n kubernetes-dashboard --timeout=${TIMEOUT}
done

########################################
# Get istio ingress endpoint
set +e
INGRESS_SERVICE=istio-ingress
INGRESS_NAMESPACE=istio-ingress
INGRESS_SELECTOR="istio=ingress"
# minikube
# Set the ingress IP and ports if MetalLB is not configured
# export INGRESS_HOST=$(minikube ip)
export INGRESS_HOST=$(kubectl get node ${MINIKUBE_PROFILE} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
export INGRESS_PORT=$(kubectl get service ${INGRESS_SERVICE} -n ${INGRESS_NAMESPACE} -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
export SECURE_INGRESS_PORT=$(kubectl get service ${INGRESS_SERVICE} -n ${INGRESS_NAMESPACE} -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
# minikube tunnel --profile ${MINIKUBE_PROFILE}

# other
# Execute the following command to determine if your Kubernetes cluster is running in an environment that supports external load balancers:
kubectl get service ${INGRESS_SERVICE} -n ${INGRESS_NAMESPACE}

# Set the ingress IP and ports if MetalLB is configured
export INGRESS_HOST=$(kubectl get service ${INGRESS_SERVICE} -n ${INGRESS_NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT=$(kubectl get service ${INGRESS_SERVICE} -n ${INGRESS_NAMESPACE} -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export SECURE_INGRESS_PORT=$(kubectl get service ${INGRESS_SERVICE} -n ${INGRESS_NAMESPACE} -o jsonpath='{.spec.ports[?(@.name=="https")].port}')

# # In certain environments, the load balancer may be exposed using a host name, instead of an IP address.
# export INGRESS_HOSTNAME=$(kubectl get service ${INGRESS_SERVICE} -n ${INGRESS_NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Other environments:
# export INGRESS_HOST=$(kubectl get pods -l ${INGRESS_SELECTOR} -n ${INGRESS_NAMESPACE} -o jsonpath='{.items[0].status.hostIP}')

set -e
