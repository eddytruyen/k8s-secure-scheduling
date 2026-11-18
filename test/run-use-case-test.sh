#!/usr/bin/env bash
# ClusterLoader2 target selection. Both default to the historical values, so an
# unset environment behaves exactly as before (local kind+KWOK cluster):
#   KUBECONFIG    - the cluster to drive. CL2 takes an explicit --kubeconfig, so
#                   without this it ignores the environment and silently runs
#                   against ~/.kube/config whatever the caller intended.
#   CL2_PROVIDER  - kind|local|skeleton|gce|... "kind" assumes a kind cluster and
#                   probes for its control-plane container; use "skeleton" for a
#                   plain remote cluster.
#   CL2_ENABLE_PROMETHEUS - "false" on any cluster that already runs its own
#                   monitoring. CL2 otherwise installs a COMPLETE second Prometheus
#                   stack into the monitoring namespace; on the shared KU Leuven
#                   cluster one of its ServiceMonitors panicked the cluster's own
#                   prometheus-operator and left it crashlooping (2026-11-18).
#                   Prometheus-backed measurements then skip themselves with a
#                   warning, so no testconfig has to change.
#   CL2_TEARDOWN_PROMETHEUS - "true" to remove that stack afterwards. The default
#                   false leaves every object behind, which is what made the damage
#                   above outlive the run.
#   CL2_PROMETHEUS_READY_TIMEOUT - 0 means wait FOREVER, and readiness requires ALL
#                   scrape targets healthy, so one unhealthy target hangs the run.
# Requires: node labels for $TEST's policy already applied once via
# `POLICY=$TEST update-labels.sh`, before this script's first invocation -
# see run-klastos-use-case-test.sh's header for why relabeling on every
# run (this script's old behavior) is a real, measured bottleneck for the
# KLASTOS side and not representative of a real cluster anyway. This
# script no longer applies/removes labels itself.

NODES="${NODES:-100}"
TEST="${TEST:-multi-tenancy}" # options: data-sovereignty, multi-tenancy, workload-security-rings

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [ "$BASELINE" = false ]; then
    # Apply policies
    POLICY=$TEST $SCRIPT_DIR/update-policy.sh
    echo
fi

if [ "$TEST" = "multi-tenancy" ]; then
    echo -e "[*] Create namespaces"
    kubectl apply -f $SCRIPT_DIR/use-case/namespaces.yaml
    echo
fi

# Create result directory
mkdir -p $SCRIPT_DIR/result/use-case/$TEST-test

# NOTE: The clusterloader binary has been built from
# https://github.com/kubernetes/perf-tests/tree/master/clusterloader2

# NOTE: To customize the test according to our test environment the following
# variables need to be set
# For example, with a small cluster of 3 control-plane and 10 worker nodes:
# CL2_SCHEDULER_THROUGHPUT_PODS=300 (10) / 3000 (100) / 30000 (1000)
# CL2_DEFAULT_QPS=50
# CL2_DEFAULT_BURST=100
# CL2_UNIFORM_QPS=50
# CL2_SCHEDULER_THROUGHPUT_THRESHOLD=40
echo -e "[*] Run $TEST test"
CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""' \
CL2_PROMETHEUS_TOLERATE_MASTER=true \
    $SCRIPT_DIR/clusterloader --alsologtostderr --logtostderr=false \
    --enable-prometheus-server="${CL2_ENABLE_PROMETHEUS:-true}" \
    --tear-down-prometheus-server="${CL2_TEARDOWN_PROMETHEUS:-false}" \
    --prometheus-apiserver-scrape-port=6443 \
    --prometheus-pvc-storage-class=standard \
    --prometheus-ready-timeout="${CL2_PROMETHEUS_READY_TIMEOUT:-0}" \
    --log_file=$SCRIPT_DIR/result/use-case/$TEST-test.log \
    --report-dir=$SCRIPT_DIR/result/use-case/$TEST-test \
    --testsuite=$SCRIPT_DIR/use-case/$TEST/scheduler-suite.yaml \
    --nodes=$NODES --provider="${CL2_PROVIDER:-kind}" --kubeconfig="${KUBECONFIG:-$HOME/.kube/config}" --v=2

echo -e "Look into $SCRIPT_DIR/result/use-case/$TEST-test for the measurements\n"

if [ "$TEST" = "multi-tenancy" ]; then
    echo -e "[*] Delete namespaces"
    kubectl delete -f $SCRIPT_DIR/use-case/namespaces.yaml
    echo
fi

if [ "$BASELINE" = false ]; then
    # Remove policies
    DELETE=true POLICY=$TEST $SCRIPT_DIR/update-policy.sh
    echo
fi
