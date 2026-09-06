#!/usr/bin/env bash

# Default is 1 control-plane node, not the original 3: on a resource-
# constrained shared host, a 3-node HA control plane's etcd-consensus
# overhead (peer round-trips, occasional leader elections under load) is a
# real, measured contributor to admission/scheduling latency noise that has
# nothing to do with Gatekeeper or the use-case policies under test. Set
# CONTROL_PLANE_NODES=3 explicitly to reproduce the paper's original HA
# topology on hardware that can actually absorb it.
CONTROL_PLANE_NODES="${CONTROL_PLANE_NODES:-1}"
NODES="${NODES:-0}"
FAKE_NODES="${FAKE_NODES:-100}"
WITHOUT_GATEKEEPER="${WITHOUT_GATEKEEPER:-false}"
GATEKEEPER_VERSION="${GATEKEEPER_VERSION:-3.23.1}"
KWOK_VERSION="${KWOK_VERSION:-v0.8.0}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo "[*] Create KinD cluster"

control_plane=""
for ((i=0; i<$CONTROL_PLANE_NODES; i++)); do control_plane+="{'role': 'control-plane'},"; done
worker=""
for ((i=0; i<$NODES; i++)); do worker+="{'role': 'worker'},"; done
KIND_NODES_CONFIG="[$control_plane$worker]"

cat <<EOF | kind create cluster --config=- --wait=30s
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
- |-
  kind: ClusterConfiguration
  # configure controller-manager bind address
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
      secure-port: "10257"
  # configure etcd metrics listen address
  etcd:
    local:
      extraArgs:
        listen-metrics-urls: http://0.0.0.0:2381
  # configure scheduler bind address
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
      secure-port: "10259"
- |-
  kind: KubeProxyConfiguration
  # configure proxy metrics bind address
  metricsBindAddress: 0.0.0.0
nodes: $KIND_NODES_CONFIG
EOF

control_plane_nodes=$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o json | jq -r '.items[].metadata.name')
readarray -t control_plane_nodes <<<"${control_plane_nodes}"

echo -e "\n[*] Enable scheduling pods on control plane nodes"
for node in "${control_plane_nodes[@]}"
do
  kubectl taint nodes ${node} node-role.kubernetes.io/control-plane=:NoSchedule-
done

if [ "$NODES" -gt 0 ]; then
  worker_nodes=$(kubectl get nodes -l !node-role.kubernetes.io/control-plane -o json | jq -r '.items[].metadata.name')
  readarray -t worker_nodes <<<"${worker_nodes}"

  echo -e "\n[*] Disable scheduling 'management' pods on worker nodes"
  for node in "${worker_nodes[@]}"
  do
    kubectl taint nodes ${node} node-role.kubernetes.io/control-plane=:NoSchedule
  done
fi

# echo -e "\n[*] Install Ingress NGINX Controller"
# # NOTE: The Ingress controller ports will be exposed in your localhost address
# # through paths (i.e., /alertmanager, /prometheus, and /grafana)
# kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
# kubectl wait --namespace ingress-nginx \
#   --for=condition=ready pod \
#   --selector=app.kubernetes.io/component=controller \
#   --timeout=90s

echo -e "\n[*] Restore missing auth-delegator RBAC bindings for kube-scheduler/kube-controller-manager"
kubectl apply -f $SCRIPT_DIR/fix-auth-delegator-rbac.yaml

echo -e "\n[*] Install metrics-server chart"
# kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
# kubectl patch -n kube-system deployment metrics-server --type=json \
#   -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
helm install metrics-server oci://registry-1.docker.io/bitnamicharts/metrics-server \
    --namespace kube-system --wait \
    --values $SCRIPT_DIR/values/metrics-server.yaml

# echo -e "\n[*] Install kube-prometheus-stack chart"
# helm upgrade --install kube-prometheus-stack --namespace monitoring --create-namespace --wait \
#     --repo https://prometheus-community.github.io/helm-charts kube-prometheus-stack \
#     --values $SCRIPT_DIR/values/kind-kube-prometheus-stack.yaml

echo -e "\n[*] Install prometheus-stack with clusterloader"
# Create fake test result directory
mkdir -p $SCRIPT_DIR/fake-test-report

CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""' \
CL2_PROMETHEUS_TOLERATE_MASTER=true \
    $SCRIPT_DIR/../clusterloader \
    --enable-prometheus-server=true \
    --kubeconfig=$HOME/.kube/config \
    --prometheus-apiserver-scrape-port=6443 \
    --prometheus-pvc-storage-class=standard \
    --prometheus-ready-timeout=0 \
    --provider=kind \
    --report-dir=$SCRIPT_DIR/fake-test-report \
    --tear-down-prometheus-server=false \
    --testconfig=$SCRIPT_DIR/config.yaml

# Remove fake test result directory
rm -rf $SCRIPT_DIR/fake-test-report

if [ "$WITHOUT_GATEKEEPER" = false ]; then
  echo -e "\n[*] Install Gatekeeper chart (pinned: $GATEKEEPER_VERSION)"
  helm upgrade --install gatekeeper --namespace gatekeeper-system --create-namespace --wait \
      --repo https://open-policy-agent.github.io/gatekeeper/charts gatekeeper \
      --version "$GATEKEEPER_VERSION"

  echo -e "\n[*] Install Gatekeeper pod monitors"
  kubectl apply -f $SCRIPT_DIR/gatekeeper-metrics-exporter/
fi

echo -e "\n[*] Install Kubernetes WithOut Kubelet (pinned: $KWOK_VERSION)"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok.yaml"
# NOTE: To better simulate real behavior of Pod stages do not use the default
# Pod Fast Stage (i.e., pod-fast.yaml), but use the Pod General Stage (i.e.,
# pod-general.yaml)
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/stage-fast.yaml"

# echo -e "\n[*] Setup default metrics usage policy"
# kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/latest/download/metrics-usage.yaml"

# Only re-taint control-plane nodes once there are REAL worker nodes to take
# over scheduling for them. Fake KWOK nodes don't run real containers, so
# with NODES=0 (our topology) this taint would leave zero schedulable nodes
# for Gatekeeper/Prometheus/metrics-server — a real bug in the original
# unconditional version of this step, not just a style choice.
if [ "$NODES" -gt 0 ]; then
  echo -e "\n[*] Disable scheduling pods on control plane nodes"
  for node in "${control_plane_nodes[@]}"
  do
    kubectl taint nodes ${node} node-role.kubernetes.io/control-plane=:NoSchedule --overwrite
  done
fi

if [ "$NODES" -gt 0 ]; then
  echo -e "\n[*] Enable scheduling pods on worker nodes"
  for node in "${worker_nodes[@]}"
  do
    kubectl taint nodes ${node} node-role.kubernetes.io/control-plane=:NoSchedule-
  done
fi

if [ "$FAKE_NODES" -gt 0 ]; then
  echo -e "\n[*] Create $FAKE_NODES fake nodes"
  ./node.sh $FAKE_NODES
fi
