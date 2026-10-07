#!/usr/bin/env bash
# KLASTOS counterpart of run-use-case-test.sh (TEST=multi-tenancy), for the
# multi-tenancy use case — second use-case instantiation of Experiment 1,
# alongside run-klastos-use-case-test.sh (data-sovereignty).
#
# Structural pattern identical to run-klastos-use-case-test.sh — see that
# script's own header for the full rationale (per-class clusterloader
# invocation, not one --testsuite, since each class needs its own
# CSC/AppGroup CR applied/removed around its pods). One difference: every
# class here has a CSC/classification entry (no "vanilla"/unconstrained
# skip case — the Gatekeeper baseline itself only ever tests uc1/uc2).
#
# Three mutually exclusive HARNESS_MODE values, one per KLASTOS-side
# variant of this use case (see each harness's own README.md):
#   classToTopology (default) — per-tenant node-partition CSCs
#   antiaffinity              — a single shared interClass AntiAffinity CSC
#   appclass-plugin           — the AppClass scheduler plugin, no CSC/UCSS
#
# Requires:
# - classToTopology/antiaffinity: node tenant labels already applied via
#   `POLICY=multi-tenancy update-labels.sh`, BEFORE the KLASTOS stack was
#   deployed — same ordering rationale as run-klastos-use-case-test.sh's
#   own header (UCSS's on_node_event conflict-scan cost on relabeling).
#   The KLASTOS stack deployed in its DEFAULT mode (deploy-klastos-stack.sh,
#   no APPCLASS_PLUGIN_ONLY).
# - appclass-plugin: the KLASTOS stack deployed with
#   APPCLASS_PLUGIN_ONLY=true instead (a different, mutually exclusive
#   topology — see deploy-klastos-stack.sh's own header). No node tenant
#   labels needed (this mechanism never reads node labels at all).
#   APPCLASS_NAME must match whatever the stack was deployed with (default
#   "app-class" on both sides) — read directly from the environment by
#   harness-appclass-plugin/apply-shared-policy.sh, nothing to set here.

set -euo pipefail

NODES="${NODES:-100}"
CL2_SCHEDULER_THROUGHPUT_PODS="${CL2_SCHEDULER_THROUGHPUT_PODS:-1000}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Same klastos-root auto-detection as run-klastos-use-case-test.sh — see
# that script's own header for the full rationale.
if [ -z "${KLASTOS_REPO:-}" ]; then
  if [ -d "$SCRIPT_DIR/../../experiment1" ]; then
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
  elif [ -d "$SCRIPT_DIR/../../klastos/experiment1" ]; then
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../../klastos" && pwd)
  else
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
  fi
fi

HARNESS_MODE="${HARNESS_MODE:-classToTopology}" # options: classToTopology, antiaffinity, appclass-plugin
case "$HARNESS_MODE" in
  classToTopology)
    HARNESS_SUBDIR="harness"
    USE_CASE_SUBDIR="multi-tenancy-klastos"
    TESTCONFIG_NAME="config-klastos.yaml"
    OVERRIDE_SUFFIX="-tenant"
    RESULT_DIR_NAME="multi-tenancy-klastos-test"
    DEFAULT_CLASSES="uc1 uc2"
    POLICY_DESC="CSC + AppGroup"
    ;;
  antiaffinity)
    HARNESS_SUBDIR="harness-antiaffinity"
    USE_CASE_SUBDIR="multi-tenancy-klastos"
    TESTCONFIG_NAME="config-klastos.yaml"
    OVERRIDE_SUFFIX="-tenant"
    RESULT_DIR_NAME="multi-tenancy-klastos-test"
    DEFAULT_CLASSES="uc1 uc2"
    POLICY_DESC="AppGroup (shared CSC already applied)"
    ;;
  appclass-plugin)
    HARNESS_SUBDIR="harness-appclass-plugin"
    USE_CASE_SUBDIR="appclass-plugin-test"
    TESTCONFIG_NAME="config-appclass.yaml"
    OVERRIDE_SUFFIX=""
    RESULT_DIR_NAME="appclass-plugin-test"
    DEFAULT_CLASSES="uc1 uc2"
    POLICY_DESC="AppGroup (no CSC in this mode)"
    ;;
  *) echo "ERROR: unknown HARNESS_MODE: $HARNESS_MODE (expected classToTopology, antiaffinity, or appclass-plugin)" >&2; exit 1 ;;
esac
HARNESS_DIR="$KLASTOS_REPO/experiment1/multi-tenancy/$HARNESS_SUBDIR"
CLASSES="${CLASSES:-$DEFAULT_CLASSES}"

if [ ! -d "$HARNESS_DIR" ]; then
  echo "ERROR: $HARNESS_DIR not found. Set KLASTOS_REPO to your klastos checkout." >&2
  exit 1
fi

echo -e "[*] Apply shared KLASTOS classification schema"
"$HARNESS_DIR/apply-shared-policy.sh"
echo

for CLASS in $CLASSES; do
  echo -e "\n=== Class: $CLASS (N=$CL2_SCHEDULER_THROUGHPUT_PODS) ==="

  echo -e "[*] Apply $CLASS policy ($POLICY_DESC)"
  "$HARNESS_DIR/apply-class-policy.sh" "$CLASS" "$CL2_SCHEDULER_THROUGHPUT_PODS"

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
      --testconfig="$SCRIPT_DIR/use-case/$USE_CASE_SUBDIR/$TESTCONFIG_NAME" \
      --testoverrides="$SCRIPT_DIR/use-case/$USE_CASE_SUBDIR/${CLASS}${OVERRIDE_SUFFIX}/override.yaml" \
      --nodes="$NODES" --provider=kind --kubeconfig="$HOME/.kube/config" --v=2

  echo -e "Look into $SCRIPT_DIR/result/use-case/$RESULT_DIR_NAME/$CLASS for the measurements\n"

  echo -e "[*] Remove $CLASS policy ($POLICY_DESC)"
  "$HARNESS_DIR/delete-class-policy.sh" "$CLASS"
done

echo -e "\n[*] Remove shared KLASTOS classification schema"
"$HARNESS_DIR/delete-shared-policy.sh"
echo
