#!/bin/bash -xe

MINIKUBE_PROFILE=minikube-kvm

reset
minikube delete --profile ${MINIKUBE_PROFILE}

sleep 10

minikube start --driver=kvm2 --cpus=4 --memory=8g --profile ${MINIKUBE_PROFILE}
minikube profile list
kubectl config get-contexts

sleep 30

kubectl wait --for condition=ready pods -l k8s-app=kube-proxy -n kube-system --timeout=5m
kubectl wait --for condition=ready pods -l k8s-app=kube-dns   -n kube-system --timeout=5m

sleep 5

minikube addons enable dashboard --profile ${MINIKUBE_PROFILE}
kubectl wait --for condition=ready pod -l k8s-app=kubernetes-dashboard      -n kubernetes-dashboard --timeout=5m
kubectl wait --for condition=ready pod -l k8s-app=dashboard-metrics-scraper -n kubernetes-dashboard --timeout=5m

# minikube addons enable metrics-server --profile ${MINIKUBE_PROFILE}

kubectl get all --all-namespaces

METALLB_IP_START=192.168.39.100
METALLB_IP_END=192.168.39.200
minikube addons list --profile ${MINIKUBE_PROFILE}
minikube addons enable metallb --profile ${MINIKUBE_PROFILE}
sleep 10
echo -e "${METALLB_IP_START}\n${METALLB_IP_END}\n" | minikube addons configure metallb --profile ${MINIKUBE_PROFILE} || true
sleep 10
kubectl get configmap/config -n metallb-system

cat > metallb-config.yaml << EOF
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

kubectl apply -n metallb-system -f metallb-config.yaml

kubectl wait --for condition=ready pod -l app=metallb -l component=controller -n metallb-system --timeout=5m
kubectl wait --for condition=ready pod -l app=metallb -l component=speaker -n metallb-system --timeout=5m

sleep 10

kubectl get all --all-namespaces

which helm
helm version
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm repo update

sleep 5

kubectl create namespace istio-system
helm install istio-base istio/base -n istio-system
helm install istiod istio/istiod -n istio-system --wait

sleep 15

kubectl create namespace istio-ingress
kubectl label namespace istio-ingress istio-injection=enabled --overwrite
helm install istio-ingress istio/gateway -n istio-ingress --wait

sleep 15

helm status istiod -n istio-system

kubectl get all --all-namespaces
