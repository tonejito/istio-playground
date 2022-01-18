#!/bin/bash -xe
# https://istio.io/latest/docs/setup/getting-started/

MINIKUBE_PROFILE=minikube-virtualbox

TIMEOUT=5m

################################################################################
# Cleanup

reset
minikube delete --profile ${MINIKUBE_PROFILE}
sleep 10

################################################################################
# Create minikube instance

minikube start --driver=virtualbox --cpus=4 --memory=8g --profile ${MINIKUBE_PROFILE}
vboxmanage controlvm ${MINIKUBE_PROFILE} cpuexecutioncap 50

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

sleep 5

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

METALLB_IP_START=192.168.59.10
METALLB_IP_END=192.168.59.99
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

sleep 5

NAMESPACE=metallb-system
APP=metallb
for COMPONENT in controller speaker
do
  kubectl wait --for condition=ready pod -l app=${APP} -l component=${COMPONENT} -n ${NAMESPACE} --timeout=${TIMEOUT}
done

sleep 10

################################################################################
# Install and configure istio

export ISTIO_VERSION=1.12.1
# wget -c -nv -O download-istio.sh https://istio.io/downloadIstio
# chmod -c +x download-istio.sh
# ./download-istio.sh
wget -c -nv https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz
tar -xzf istio-${ISTIO_VERSION}-linux-amd64.tar.gz
rm -v istio-${ISTIO_VERSION}-linux-amd64.tar.gz
install --mode 0755 istio-${ISTIO_VERSION}/bin/istioctl ~/bin/
which istioctl
istioctl version

istioctl experimental precheck

istioctl install --set profile=demo -y

pushd istio-${ISTIO_VERSION}

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

# minikube
# Set the ingress IP and ports if MetalLB is not configured
# export INGRESS_HOST=$(minikube ip)
export INGRESS_HOST=$(kubectl get node ${MINIKUBE_PROFILE} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
export INGRESS_PORT=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
export SECURE_INGRESS_PORT=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
# minikube tunnel --profile ${MINIKUBE_PROFILE}

# other
# Execute the following command to determine if your Kubernetes cluster is running in an environment that supports external load balancers:
kubectl get svc istio-ingressgateway -n istio-system

# Set the ingress IP and ports if MetalLB is configured
export INGRESS_HOST=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export INGRESS_PORT=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
export SECURE_INGRESS_PORT=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].port}')

# # In certain environments, the load balancer may be exposed using a host name, instead of an IP address.
# export INGRESS_HOST=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Other environments:
# export INGRESS_HOST=$(kubectl get pods -l istio=ingressgateway -n istio-system -o jsonpath='{.items[0].status.hostIP}')

########################################
# Deploy istio addons
kubectl apply -f samples/addons

sleep 5

NAMESPACE=istio-system
for APP in grafana prometheus jaeger kiali
do
  kubectl wait --for condition=ready pod -l app=${APP} -n ${NAMESPACE} --timeout=${TIMEOUT}
done

kubectl rollout status deployment/kiali -n istio-system

# kubectl get all --all-namespaces

popd

# istioctl dashboard kiali

# TODO: Apply ingress resources for kubernetes-dashboard, kiali, prometheus, grafana, etc.

kubectl apply -f dashboard-istio.yaml

kubectl apply -f istio-ingress-resources.yaml

kubectl get ingresses,gateways,virtualservices -A

for APP in grafana prometheus kiali
do
  curl -vk#L http://${APP}.${INGRESS_HOST}.tonejito.work:${INGRESS_PORT}/ | \
  grep -o "<title>.*</title>"
done

######################################################################
# Install istio example applications

pushd istio-${ISTIO_VERSION}
kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml

sleep 5

NAMESPACE=default
# app=reviews version=v{1..3}
for APP in details productpage ratings reviews
do
  kubectl wait --for condition=ready pod -l app=${APP} -n ${NAMESPACE} --timeout=${TIMEOUT}
done

kubectl exec -it deployment/ratings-v1 -c ratings -- \
  curl -sS productpage:9080/productpage | \
grep -o "<title>.*</title>"

kubectl apply -f samples/bookinfo/networking/bookinfo-gateway.yaml -n default

BOOKINFO_HOST=bookinfo.${INGRESS_HOST}.tonejito.work
kubectl patch gateway bookinfo-gateway -n default --type json \
  -p '[{"op":"replace","path":"/spec/servers/0/hosts","value":["'${BOOKINFO_HOST}'"]}]'

kubectl patch virtualservice bookinfo -n default --type json \
  -p '[{"op":"replace","path":"/spec/hosts","value":["'${BOOKINFO_HOST}'"]}]'

popd

istioctl analyze

export GATEWAY_URL=${INGRESS_HOST}:${INGRESS_PORT}
echo "${GATEWAY_URL}"
echo "http://${GATEWAY_URL}/"

sleep 10

curl -vk# http://bookinfo.${INGRESS_HOST}.tonejito.work:${INGRESS_PORT}/productpage | \
grep -o "<title>.*</title>"
