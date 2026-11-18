#!/usr/bin/env bash
# ClusterLoader2 target selection. Both default to the historical values, so an
# unset environment behaves exactly as before (local kind+KWOK cluster):
#   KUBECONFIG    - the cluster to drive. CL2 takes an explicit --kubeconfig, so
#                   without this it ignores the environment and silently runs
#                   against ~/.kube/config whatever the caller intended.
#   CL2_PROVIDER  - kind|local|skeleton|gce|... "kind" assumes a kind cluster and
#                   probes for its control-plane container; use "skeleton" for a
#                   plain remote cluster.

cwd=$(pwd)
mkdir -p $cwd/result/simple-test

# NOTE: Requires cloning https://github.com/kubernetes/perf-tests and move into
# the perf-tests/clusterloader2 directory
cd $CLUSTERLOADER_PATH
go run cmd/clusterloader.go --logtostderr=false --log_file=$cwd/result/simple-test.log \
    --report-dir=$cwd/result/simple-test --testconfig=config.yaml --provider="${CL2_PROVIDER:-kind}" --kubeconfig="${KUBECONFIG:-$HOME/.kube/config}" --v=2
cd $cwd

echo -e "\nLook into $cwd/result/simple-test for the measurements"
