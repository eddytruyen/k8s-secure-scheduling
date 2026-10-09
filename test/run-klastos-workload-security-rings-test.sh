#!/usr/bin/env bash
# KLASTOS counterpart of run-use-case-test.sh (TEST=workload-security-rings),
# for the workload-security-rings use case — third use-case instantiation
# of Experiment 1, alongside run-klastos-use-case-test.sh (data-sovereignty)
# and run-klastos-multitenancy-test.sh (multi-tenancy).
#
# Structural pattern identical to run-klastos-multitenancy-test.sh — see
# that script's own header for the general rationale. One difference:
# both classes here (sensitive/unhardened) share the SAME namespace (the
# harness's one shared namespace — see
# klastos/experiment1/workload-security-rings/harness/README.md), not a
# per-class one, matching the Gatekeeper baseline's own namespace-agnostic
# design for this use case.
#
# CLASSIFICATION_SOURCE=rbac|podlabel (default rbac) picks which KLASTOS-
# side classification variant is applied — see the harness README for the
# full rationale (RBAC/SA-derived "hardened" arm vs. pod-label "parity"
# arm matching the Gatekeeper baseline's own trust model).
#
# Requires the KLASTOS stack deployed in its default (non-
# APPCLASS_PLUGIN_ONLY) mode — this harness needs UCSS/CSC/NSP.

set -euo pipefail

NODES="${NODES:-100}"
CL2_SCHEDULER_THROUGHPUT_PODS="${CL2_SCHEDULER_THROUGHPUT_PODS:-1000}"
CLASSIFICATION_SOURCE="${CLASSIFICATION_SOURCE:-rbac}"
CLASSES="${CLASSES:-sensitive unhardened}"
NAMESPACE="${NAMESPACE:-workload-security-rings-eval}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Same klastos-root auto-detection as run-klastos-use-case-test.sh/
# run-klastos-multitenancy-test.sh.
if [ -z "${KLASTOS_REPO:-}" ]; then
  if [ -d "$SCRIPT_DIR/../../experiment1" ]; then
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
  elif [ -d "$SCRIPT_DIR/../../klastos/experiment1" ]; then
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../../klastos" && pwd)
  else
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
  fi
fi

HARNESS_DIR="$KLASTOS_REPO/experiment1/workload-security-rings/harness"
RESULT_DIR_NAME="workload-security-rings-klastos-test"

if [ ! -d "$HARNESS_DIR" ]; then
  echo "ERROR: $HARNESS_DIR not found. Set KLASTOS_REPO to your klastos checkout." >&2
  exit 1
fi

echo -e "[*] Apply shared KLASTOS classification schema (CLASSIFICATION_SOURCE=$CLASSIFICATION_SOURCE)"
CLASSIFICATION_SOURCE="$CLASSIFICATION_SOURCE" NAMESPACE="$NAMESPACE" "$HARNESS_DIR/apply-shared-policy.sh"
echo

for CLASS in $CLASSES; do
  echo -e "\n=== Ring: $CLASS (N=$CL2_SCHEDULER_THROUGHPUT_PODS) ==="

  echo -e "[*] Apply $CLASS ring policy (AppGroup; shared NSP/CSC already applied)"
  NAMESPACE="$NAMESPACE" "$HARNESS_DIR/apply-class-policy.sh" "$CLASS" "$CL2_SCHEDULER_THROUGHPUT_PODS" "$NAMESPACE"

  mkdir -p "$SCRIPT_DIR/result/use-case/$RESULT_DIR_NAME/$CLASS"

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
      --log_file="$SCRIPT_DIR/result/use-case/$RESULT_DIR_NAME/$CLASS.log" \
      --report-dir="$SCRIPT_DIR/result/use-case/$RESULT_DIR_NAME/$CLASS" \
      --testconfig="$SCRIPT_DIR/use-case/workload-security-rings-klastos/config-klastos.yaml" \
      --testoverrides="$SCRIPT_DIR/use-case/workload-security-rings-klastos/${CLASS}-tenant/override.yaml" \
      --nodes="$NODES" --provider=kind --kubeconfig="$HOME/.kube/config" --v=2

  echo -e "Look into $SCRIPT_DIR/result/use-case/$RESULT_DIR_NAME/$CLASS for the measurements\n"

  echo -e "[*] Remove $CLASS ring policy"
  NAMESPACE="$NAMESPACE" "$HARNESS_DIR/delete-class-policy.sh" "$CLASS" "$NAMESPACE"
done

echo -e "\n[*] Remove shared KLASTOS classification schema"
NAMESPACE="$NAMESPACE" "$HARNESS_DIR/delete-shared-policy.sh"
echo
