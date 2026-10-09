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

echo "=== Experiment 1 CONCURRENT evaluation (multi-tenancy, anti-affinity + affinity variant) ==="
echo "Steps (N per class): $N_STEPS"
echo "Results:      $RESULT_ROOT"
echo ""

threshold_for() {
  local n="$1"
  if [ -n "${THRESHOLD_OVERRIDE:-}" ]; then
    echo "$THRESHOLD_OVERRIDE"
    return
  fi
  local t=$((n / 10))
  [ "$t" -lt 5 ] && t=5
  echo "$t"
}

FAILED=false

for N in $N_STEPS; do
  THRESHOLD=$(threshold_for "$N")
  echo "--- Step: N=$N per class (threshold=$THRESHOLD pods/sec) ---"

  echo "[*] KLASTOS harness (antiaffinity-and-affinity, CONCURRENT), N=$N per class"
  STEP_DIR="$RESULT_ROOT/klastos-n$N"
  mkdir -p "$STEP_DIR"

  python3 "$TEST_DIR/e2e-latency-watch.py" --output "$STEP_DIR/e2e-latency.json" &
  WATCHER_PID=$!
  sleep 1

  export CL2_SCHEDULER_THROUGHPUT_PODS="$N"
  export CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD"
  export CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""'
  export CL2_PROMETHEUS_TOLERATE_MASTER=true

  set +e
  (
    set -euo pipefail
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
  ) > "$STEP_DIR/run.log" 2>&1
  KLASTOS_RC=$?
  set -e

  unset CL2_SCHEDULER_THROUGHPUT_PODS CL2_SCHEDULER_THROUGHPUT_THRESHOLD CL2_PROMETHEUS_NODE_SELECTOR CL2_PROMETHEUS_TOLERATE_MASTER

  if [ $KLASTOS_RC -eq 0 ]; then
    echo "    OK — log: $STEP_DIR/run.log"
  else
    echo "    FAILED at N=$N — see $STEP_DIR/run.log"
    FAILED=true
  fi

  kill -TERM "$WATCHER_PID" 2>/dev/null || true
  wait "$WATCHER_PID" 2>/dev/null || true

  if [ "$FAILED" = true ]; then
    echo ""
    echo "Stopping before larger steps — a step failed at N=$N."
    exit 1
  fi
  echo ""
done

echo "=== All steps passed ==="
echo "Results under: $RESULT_ROOT"

python3 "$TEST_DIR/generate-report.py" "$RESULT_ROOT" --csv "$RESULT_ROOT/report.csv" | tee "$RESULT_ROOT/report.md"
echo ""
echo "Report: $RESULT_ROOT/report.md"
echo "CSV:    $RESULT_ROOT/report.csv"
