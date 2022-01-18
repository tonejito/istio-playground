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
