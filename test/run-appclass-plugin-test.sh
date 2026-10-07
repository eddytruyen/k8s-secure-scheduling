#!/usr/bin/env bash
# KLASTOS counterpart of run-klastos-multitenancy-test.sh, for the "AppClass"
# scheduler-plugin variant of the multi-tenancy use case — see
# klastos/experiment1/multi-tenancy/harness-appclass-plugin/README.md.
#
# Requires: the KLASTOS stack already deployed with
# APPCLASS_PLUGIN_ONLY=true (deploy-klastos-stack.sh). Does NOT require
# node tenant labels (this mechanism never reads node labels at all).

set -euo pipefail

NODES="${NODES:-100}"
CL2_SCHEDULER_THROUGHPUT_PODS="${CL2_SCHEDULER_THROUGHPUT_PODS:-1000}"
CLASSES="${CLASSES:-appclass-test-a appclass-test-b}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

if [ -z "${KLASTOS_REPO:-}" ]; then
  if [ -d "$SCRIPT_DIR/../../experiment1" ]; then
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
  elif [ -d "$SCRIPT_DIR/../../klastos/experiment1" ]; then
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../../klastos" && pwd)
  else
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
  fi
fi
HARNESS_DIR="$KLASTOS_REPO/experiment1/multi-tenancy/harness-appclass-plugin"

if [ ! -d "$HARNESS_DIR" ]; then
  echo "ERROR: $HARNESS_DIR not found. Set KLASTOS_REPO to your klastos checkout." >&2
  exit 1
fi

echo -e "[*] Apply shared policy (classification schema)"
"$HARNESS_DIR/apply-shared-policy.sh"
echo

for CLASS in $CLASSES; do
  echo -e "\n=== Class: $CLASS (N=$CL2_SCHEDULER_THROUGHPUT_PODS) ==="

  echo -e "[*] Apply $CLASS policy (namespace + AppGroup)"
  "$HARNESS_DIR/apply-class-policy.sh" "$CLASS" "$CL2_SCHEDULER_THROUGHPUT_PODS"

  mkdir -p "$SCRIPT_DIR/result/use-case/appclass-plugin-test/$CLASS"

  echo -e "\n[*] Run $CLASS clusterloader pass"
  CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""' \
  CL2_PROMETHEUS_TOLERATE_MASTER=true \
  CL2_SCHEDULER_THROUGHPUT_PODS="$CL2_SCHEDULER_THROUGHPUT_PODS" \
      "$SCRIPT_DIR/clusterloader" --alsologtostderr --logtostderr=false \
      --enable-prometheus-server=true \
      --tear-down-prometheus-server=false \
      --prometheus-apiserver-scrape-port=6443 \
      --prometheus-pvc-storage-class=standard \
      --prometheus-ready-timeout=0 \
      --log_file="$SCRIPT_DIR/result/use-case/appclass-plugin-test/$CLASS.log" \
      --report-dir="$SCRIPT_DIR/result/use-case/appclass-plugin-test/$CLASS" \
      --testconfig="$SCRIPT_DIR/use-case/appclass-plugin-test/config-appclass.yaml" \
      --testoverrides="$SCRIPT_DIR/use-case/appclass-plugin-test/${CLASS}/override.yaml" \
      --nodes="$NODES" --provider=kind --kubeconfig="$HOME/.kube/config" --v=2

  echo -e "Look into $SCRIPT_DIR/result/use-case/appclass-plugin-test/$CLASS for the measurements\n"

  echo -e "[*] Remove $CLASS policy (namespace + AppGroup)"
  "$HARNESS_DIR/delete-class-policy.sh" "$CLASS"
done

echo -e "\n[*] Remove shared policy"
"$HARNESS_DIR/delete-shared-policy.sh"
echo
