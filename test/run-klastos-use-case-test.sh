#!/usr/bin/env bash
# KLASTOS counterpart of run-use-case-test.sh, for the data-sovereignty use
# case (Experiment 1's apples-to-apples harness).
#
# Structural difference from the baseline script, deliberate: baseline runs
# all 4 identifiers (vanilla/eu/us/italynorth) as ONE clusterloader
# --testsuite invocation, because Gatekeeper's mutation/constraint objects
# are all applied once upfront and handle every region simultaneously
# (which pod gets mutated depends only on that pod's own data-sovereignty
# label, not on which identifier is "active"). KLASTOS can't do that: each
# class needs its own CSC + AppGroup CR applied before its pods exist and
# removed after (an AppGroup is inherently class-specific, unlike
# Gatekeeper's blanket mutation.yaml) - so this script loops over the 4
# classes, running a SEPARATE `clusterloader --testconfig=` invocation per
# class, wrapped by harness/apply-class-policy.sh and
# harness/delete-class-policy.sh. Each class's run is still a complete,
# independent create-measure-delete cycle, same as one identifier within
# baseline's suite - just orchestrated here instead of inside
# ClusterLoader2's own suite iteration.
#
# Requires: the KLASTOS stack already deployed (deploy-klastos-stack.sh) on
# this cluster, including the OPA admission controller - and
# harness/policy/opa-servicemonitor.yaml applied AFTER the first-ever
# Prometheus-enabled clusterloader run on this cluster (same Prometheus-CRD
# timing caveat as gatekeeper-metrics-exporter/'s own PodMonitors - see
# test/env/setup-kind-kwok-manual.sh).

set -euo pipefail

NODES="${NODES:-100}"
CL2_SCHEDULER_THROUGHPUT_PODS="${CL2_SCHEDULER_THROUGHPUT_PODS:-1000}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/klastos}"
CLASSES="${CLASSES:-vanilla eu us italynorth}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
HARNESS_DIR="$KLASTOS_REPO/experiment1/harness"

if [ ! -d "$HARNESS_DIR" ]; then
  echo "ERROR: $HARNESS_DIR not found. Set KLASTOS_REPO to your klastos checkout." >&2
  exit 1
fi

echo -e "[*] Apply node region labels (same script/labels as the Gatekeeper baseline)"
POLICY=data-sovereignty "$SCRIPT_DIR/update-labels.sh"
echo

echo -e "[*] Apply shared KLASTOS classification schema (AppClass + AppInfoDefinition)"
"$HARNESS_DIR/apply-shared-policy.sh"
echo

for CLASS in $CLASSES; do
  echo -e "\n=== Class: $CLASS (N=$CL2_SCHEDULER_THROUGHPUT_PODS) ==="

  echo -e "[*] Apply $CLASS policy (CSC + AppGroup)"
  "$HARNESS_DIR/apply-class-policy.sh" "$CLASS" "$CL2_SCHEDULER_THROUGHPUT_PODS"

  mkdir -p "$SCRIPT_DIR/result/use-case/data-sovereignty-klastos-test/$CLASS"

  OVERRIDE_ARGS=()
  if [ "$CLASS" != "vanilla" ]; then
    OVERRIDE_ARGS=(--testoverrides="$SCRIPT_DIR/use-case/data-sovereignty-klastos/${CLASS}-region/override.yaml")
  fi

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
      --log_file="$SCRIPT_DIR/result/use-case/data-sovereignty-klastos-test/$CLASS.log" \
      --report-dir="$SCRIPT_DIR/result/use-case/data-sovereignty-klastos-test/$CLASS" \
      --testconfig="$SCRIPT_DIR/use-case/data-sovereignty-klastos/config-klastos.yaml" \
      "${OVERRIDE_ARGS[@]}" \
      --nodes="$NODES" --provider=kind --kubeconfig="$HOME/.kube/config" --v=2

  echo -e "Look into $SCRIPT_DIR/result/use-case/data-sovereignty-klastos-test/$CLASS for the measurements\n"

  echo -e "[*] Remove $CLASS policy (CSC + AppGroup)"
  "$HARNESS_DIR/delete-class-policy.sh" "$CLASS"
done

echo -e "\n[*] Remove shared KLASTOS classification schema"
"$HARNESS_DIR/delete-shared-policy.sh"
echo

echo -e "[*] Remove node region labels"
DELETE=true POLICY=data-sovereignty "$SCRIPT_DIR/update-labels.sh"
