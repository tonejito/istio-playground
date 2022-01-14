#!/bin/bash -xe
# https://istio.io/latest/docs/setup/getting-started/

MINIKUBE_PROFILE=minikube-virtualbox-test

reset
minikube delete --profile ${MINIKUBE_PROFILE}
sleep 10

minikube start --driver=virtualbox --cpus=4 --memory=8g --profile ${MINIKUBE_PROFILE}
minikube profile list
kubectl config get-contexts

sleep 30

kubectl wait --for condition=ready pods -l k8s-app=kube-proxy -n kube-system --timeout=5m
kubectl wait --for condition=ready pods -l k8s-app=kube-dns   -n kube-system --timeout=5m

sleep 5

minikube addons enable dashboard --profile ${MINIKUBE_PROFILE}
kubectl wait --for condition=ready pod -l k8s-app=kubernetes-dashboard      -n kubernetes-dashboard --timeout=5m
kubectl wait --for condition=ready pod -l k8s-app=dashboard-metrics-scraper -n kubernetes-dashboard --timeout=5m

sleep 5

minikube addons enable metrics-server --profile ${MINIKUBE_PROFILE}
kubectl wait --for condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=5m

kubectl get all --all-namespaces

METALLB_IP_START=192.168.59.10
METALLB_IP_END=192.168.59.99
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

export ISTIO_VERSION=1.12.1
# wget -c -nv -O download-istio.sh https://istio.io/downloadIstio
# chmod -c +x download-istio.sh
# ./download-istio.sh
wget -c -nv https://github.com/istio/istio/releases/download/${ISTIO_VERSION}/istio-${ISTIO_VERSION}-linux-amd64.tar.gz
tar -xvzf istio-${ISTIO_VERSION}-linux-amd64.tar.gz
rm -v istio-${ISTIO_VERSION}-linux-amd64.tar.gz
install --mode 0755 istio-${ISTIO_VERSION}/bin/istioctl ~/bin/
which istioctl
istioctl version

istioctl x precheck

istioctl install --set profile=demo -y

# Enable istio-proxy on certain namespaces
# TODO: Create demo namespace for the example applications
for NAMESPACE in default kubernetes-dashboard
do
  kubectl label namespace ${NAMESPACE} istio-injection=enabled --overwrite
done
kubectl get namespaces --show-labels

# Scale down-up the kubernetes-dashboard to get istio-proxy sidecar working
for TARGET in kubernetes-dashboard dashboard-metrics-scraper
do
  kubectl scale deployment ${TARGET} -n kubernetes-dashboard --replicas 0
  sleep 1
  kubectl scale deployment ${TARGET} -n kubernetes-dashboard --replicas 1
  # sleep 5
  # kubectl wait --for condition=ready pod -l k8s-app=${TARGET} -n kubernetes-dashboard --timeout=5m
done

# Install istio example applications
pushd istio-${ISTIO_VERSION}
kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml

kubectl wait --for condition=ready pod -l app=details -n default --timeout=5m
kubectl wait --for condition=ready pod -l app=productpage -n default --timeout=5m
kubectl wait --for condition=ready pod -l app=ratings -n default --timeout=5m
kubectl wait --for condition=ready pod -l app=reviews -n default --timeout=5m  # version=v{1..3}

kubectl exec -it deployment/ratings-v1 -c ratings -- \
  curl -sS productpage:9080/productpage | \
grep -o "<title>.*</title>"

kubectl apply -f samples/bookinfo/networking/bookinfo-gateway.yaml

istioctl analyze

set +e

# minikube
# Set the ingress IP and ports if MetalLB is not configured
# export INGRESS_HOST=$(minikube ip)
export INGRESS_HOST=$(kubectl get node ${MINIKUBE_PROFILE} -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
export INGRESS_PORT=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
export SECURE_INGRESS_PORT=$(kubectl get service istio-ingressgateway -n istio-system -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
minikube tunnel

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

export GATEWAY_URL=${INGRESS_HOST}:${INGRESS_PORT}
echo "${GATEWAY_URL}"
echo "http://${GATEWAY_URL}/productpage"

sleep 10

kubectl apply -f samples/addons

kubectl wait --for condition=ready pod -l app=grafana    -n istio-system --timeout=5m
kubectl wait --for condition=ready pod -l app=prometheus -n istio-system --timeout=5m
kubectl wait --for condition=ready pod -l app=jaeger     -n istio-system --timeout=5m
kubectl wait --for condition=ready pod -l app=kiali      -n istio-system --timeout=5m

popd 

kubectl rollout status deployment/kiali -n istio-system

kubectl get all --all-namespaces

# istioctl dashboard kiali

# TODO: Apply ingress resources for kubernetes-dashboard, kiali, prometheus, grafana, etc.

kubectl get ingresses,gateways,virtualservices -A
