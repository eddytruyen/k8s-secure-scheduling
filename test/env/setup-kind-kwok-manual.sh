#!/usr/bin/env bash
# Reproduces the exact manual command sequence used to build the KWOK
# benchmark cluster for Experiment 1's evaluation work this session —
# leaner than setup-kind-kwok-test-cluster.sh, which also does things never
# actually needed here (metrics-server, ingress, a separate generic
# Prometheus-bootstrap pass): no metrics-server, no ingress. Kept as a
# separate script rather than replacing the original, since that one still
# serves other, more general uses of this repo.
#
# Deliberately NOT run as part of this script: gatekeeper-metrics-exporter
# PodMonitors. Applying them requires the Prometheus-operator CRDs
# (PodMonitor, ServiceMonitor, ...) to already exist, and those are only
# created the first time ClusterLoader2 runs with
# --enable-prometheus-server=true (e.g. test/run-use-case-test.sh) — that's
# exactly what happened this session: the first benchmark run created them,
# and only then did applying the PodMonitors succeed. Run one benchmark
# pass first, then:
#   kubectl apply -f test/env/gatekeeper-metrics-exporter/

set -euo pipefail

CONTROL_PLANE_NODES="${CONTROL_PLANE_NODES:-1}"
FAKE_NODES="${FAKE_NODES:-100}"
GATEKEEPER_VERSION="${GATEKEEPER_VERSION:-3.23.1}"
KWOK_VERSION="${KWOK_VERSION:-v0.8.0}"
NODE_IMAGE="${NODE_IMAGE:-kindest/node:v1.29.2}"
CLUSTER_NAME="${CLUSTER_NAME:-secure-sched}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

echo "=== KWOK benchmark cluster (manual sequence) ==="
echo "CLUSTER_NAME=$CLUSTER_NAME  CONTROL_PLANE_NODES=$CONTROL_PLANE_NODES  FAKE_NODES=$FAKE_NODES"
echo "GATEKEEPER_VERSION=$GATEKEEPER_VERSION  KWOK_VERSION=$KWOK_VERSION  NODE_IMAGE=$NODE_IMAGE"
echo ""

# --- Step 1: kind cluster, with the control-plane metrics bind-address
# patches (needed so ClusterLoader2's Prometheus, run later by whichever
# benchmark script, can actually scrape kube-controller-manager/
# kube-scheduler/etcd — they default to 127.0.0.1-only) ---
echo "[*] Create KinD cluster ($CONTROL_PLANE_NODES control-plane node(s), image $NODE_IMAGE)"

nodes_yaml=""
for ((i = 0; i < CONTROL_PLANE_NODES; i++)); do
  nodes_yaml+="- role: control-plane
  image: ${NODE_IMAGE}
"
done

cat <<EOF | kind create cluster --config=- --wait=90s --name "$CLUSTER_NAME"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
- |-
  kind: ClusterConfiguration
  controllerManager:
    extraArgs:
      bind-address: 0.0.0.0
  etcd:
    local:
      extraArgs:
        listen-metrics-urls: http://0.0.0.0:2381
  scheduler:
    extraArgs:
      bind-address: 0.0.0.0
- |-
  kind: KubeProxyConfiguration
  metricsBindAddress: 0.0.0.0
nodes:
${nodes_yaml}
EOF

kubectl config use-context "kind-${CLUSTER_NAME}"
echo ""

# --- Step 2: untaint control-plane node(s) — no real worker nodes exist in
# this topology, so Gatekeeper/monitoring pods need somewhere schedulable ---
echo "[*] Untaint control-plane node(s)"
kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>&1 || true
echo ""

# --- Step 3: restore the auth-delegator RBAC bindings kind's kubeadm
# bootstrap omits (breaks ClusterLoader2's SchedulingMetrics measurement
# otherwise — see fix-auth-delegator-rbac.yaml's own header) ---
echo "[*] Apply auth-delegator RBAC fix"
kubectl apply -f "$SCRIPT_DIR/fix-auth-delegator-rbac.yaml"
echo ""

# --- Step 4: Gatekeeper, pinned ---
echo "[*] Install Gatekeeper (pinned: $GATEKEEPER_VERSION)"
helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts >/dev/null 2>&1 || true
helm repo update gatekeeper >/dev/null 2>&1 || true
helm upgrade --install gatekeeper gatekeeper/gatekeeper \
  --version "$GATEKEEPER_VERSION" \
  --namespace gatekeeper-system --create-namespace --wait --timeout 5m
echo ""

# --- Step 5: KWOK, pinned ---
echo "[*] Install KWOK (pinned: $KWOK_VERSION)"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok.yaml"
kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/stage-fast.yaml"
kubectl -n kube-system rollout status deploy/kwok-controller --timeout=60s
echo ""

# --- Step 6: fake nodes ---
if [ "$FAKE_NODES" -gt 0 ]; then
  echo "[*] Create $FAKE_NODES fake KWOK nodes"
  "$SCRIPT_DIR/node.sh" "$FAKE_NODES"
fi
echo ""

echo "=== Cluster ready ==="
echo "Verify with: kubectl get nodes"
echo "             kubectl -n gatekeeper-system get pods"
echo ""
echo "Prometheus-operator CRDs (needed for gatekeeper-metrics-exporter"
echo "PodMonitors) do not exist yet — run a benchmark pass first, e.g.:"
echo "  cd ../ && TEST=data-sovereignty NODES=$FAKE_NODES ./run-use-case-test.sh"
echo "then:"
echo "  kubectl apply -f $SCRIPT_DIR/gatekeeper-metrics-exporter/"
