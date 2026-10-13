#!/usr/bin/env bash
# Concurrent counterpart of the antiaffinity-and-affinity KLASTOS harness
# (../../../../klastos/experiment1/multi-tenancy/harness-antiaffinity-and-affinity/) -
# same rationale as ../multi-tenancy-antiaffinity/'s own concurrent script
# (genuine cross-tenant temporal overlap, not sequential isolated classes).
#
# KLASTOS-only - unlike ../multi-tenancy-antiaffinity/, this script has no
# RUN_BASELINE arm: the thing under test is the added same-tenant interClass
# Affinity term (c2, strict: false), which has no Gatekeeper equivalent at
# all (Gatekeeper's mutation/constraint pair has no placement-preference
# concept, only node-selector validation) - there is nothing to compare it
# against on the baseline side. Compare this run's own numbers against
# ../multi-tenancy-antiaffinity/'s own KLASTOS-arm numbers instead, to see
# the effect of adding the affinity term on top of the unchanged
# anti-affinity one.
#
# The step loop itself (threshold scaling, watcher start/stop, run.log
# capture, OK/FAILED reporting, final report generation) lives in
# ../lib/common.sh, shared by every concurrent-test variant - only the
# per-arm apply/run/delete sequence below is specific to this one.
#
# Usage:
#   ./run-concurrent-multitenancy-antiaffinity-and-affinity-evaluation.sh
#   N_STEPS="20 100 1000" ./run-concurrent-multitenancy-antiaffinity-and-affinity-evaluation.sh

set -euo pipefail

N_STEPS="${N_STEPS:-20 100 1000}"
NODES="${NODES:-100}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/githubrepos/klastos}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
TEST_DIR=$( cd -- "$SCRIPT_DIR/../.." &> /dev/null && pwd )
HARNESS_DIR="$KLASTOS_REPO/experiment1/multi-tenancy/harness-antiaffinity-and-affinity"
RESULT_ROOT="$TEST_DIR/result/use-case/concurrent-multitenancy-antiaffinity-and-affinity-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

echo "=== Experiment 1 CONCURRENT evaluation (multi-tenancy, anti-affinity + affinity variant) ==="
echo "Steps (N per class): $N_STEPS"
echo "Results:      $RESULT_ROOT"
echo ""

klastos_work() {
  "$HARNESS_DIR/apply-shared-policy.sh"
  "$HARNESS_DIR/apply-class-policy.sh" uc1 "$N"
  "$HARNESS_DIR/apply-class-policy.sh" uc2 "$N"

  "$TEST_DIR/clusterloader" --alsologtostderr --logtostderr=false \
      --enable-prometheus-server=true \
      --tear-down-prometheus-server=false \
      --prometheus-apiserver-scrape-port=6443 \
      --prometheus-pvc-storage-class=standard \
      --prometheus-ready-timeout=0 \
      --log_file="$STEP_DIR/klastos.log" \
      --report-dir="$STEP_DIR/measurements" \
      --testconfig="$SCRIPT_DIR/config-klastos-concurrent.yaml" \
      --nodes="$NODES" --provider=kind --kubeconfig="$HOME/.kube/config" --v=2

  "$HARNESS_DIR/delete-class-policy.sh" uc1
  "$HARNESS_DIR/delete-class-policy.sh" uc2
  "$HARNESS_DIR/delete-shared-policy.sh"
}

FAILED=false

for N in $N_STEPS; do
  THRESHOLD=$(concurrent_threshold_for "$N")
  echo "--- Step: N=$N per class (threshold=$THRESHOLD pods/sec, violations=$(concurrent_violations_state)) ---"

  echo "[*] KLASTOS harness (antiaffinity-and-affinity, CONCURRENT), N=$N per class"
  STEP_DIR="$RESULT_ROOT/klastos-n$N"
  if ! concurrent_run_step "$STEP_DIR" "$N" "$THRESHOLD" klastos_work; then
    FAILED=true
  fi

  if [ "$FAILED" = true ]; then
    echo ""
    echo "Stopping before larger steps — a step failed at N=$N."
    exit 1
  fi
  echo ""
done

concurrent_finalize "$RESULT_ROOT"
