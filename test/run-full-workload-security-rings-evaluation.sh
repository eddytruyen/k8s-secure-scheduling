#!/usr/bin/env bash
# Experiment 1 full evaluation driver — workload-security-rings use case,
# KLASTOS vs. Gatekeeper baseline. Same structure as
# run-full-multitenancy-evaluation.sh — see that script's own header for
# the general rationale (gradual N steps, threshold scaling,
# THRESHOLD_OVERRIDE).
#
# CLASSIFICATION_SOURCE=rbac|podlabel (default rbac) is passed through to
# the KLASTOS arm only — see
# klastos/experiment1/workload-security-rings/harness/README.md for what
# each means. The baseline arm has no equivalent (it only ever reads the
# pod's own self-declared label).
#
# Requires, before running with RUN_BASELINE=true:
#   POLICY=workload-security-rings ./update-labels.sh
# (node security-ring labels — see run-use-case-test.sh's own header for
# why this isn't auto-run per-invocation). The KLASTOS arm needs no node
# labeling at all (NSP-computed segmentation instead).
#
# Usage:
#   ./run-full-workload-security-rings-evaluation.sh
#   N_STEPS="20 100 1000" RUN_BASELINE=true ./run-full-workload-security-rings-evaluation.sh
#   CLASSIFICATION_SOURCE=podlabel ./run-full-workload-security-rings-evaluation.sh
#
# Each step's full clusterloader log + JUnit report lands under
# result/use-case/full-workload-security-rings-evaluation-<timestamp>/{klastos,baseline}-n<N>/.

set -euo pipefail

N_STEPS="${N_STEPS:-20 100 1000}"
NODES="${NODES:-100}"
CLASSES="${CLASSES:-sensitive unhardened}"
CLASSIFICATION_SOURCE="${CLASSIFICATION_SOURCE:-rbac}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/githubrepos/klastos}"
RUN_BASELINE="${RUN_BASELINE:-false}"
RUN_KLASTOS="${RUN_KLASTOS:-true}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
RESULT_ROOT="$SCRIPT_DIR/result/use-case/full-workload-security-rings-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"

echo "=== Experiment 1 full evaluation (workload-security-rings) ==="
echo "Steps (N):              $N_STEPS"
echo "Classes:                $CLASSES"
echo "Classification source:  $CLASSIFICATION_SOURCE (KLASTOS arm only)"
echo "Run KLASTOS:  $RUN_KLASTOS"
echo "Run baseline: $RUN_BASELINE"
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
  echo "--- Step: N=$N (threshold=$THRESHOLD pods/sec) ---"

  if [ "$RUN_KLASTOS" = true ]; then
    echo "[*] KLASTOS harness, N=$N"
    STEP_DIR="$RESULT_ROOT/klastos-n$N"
    mkdir -p "$STEP_DIR"

    python3 "$SCRIPT_DIR/e2e-latency-watch.py" --output "$STEP_DIR/e2e-latency.json" &
    WATCHER_PID=$!
    sleep 1

    if KLASTOS_REPO="$KLASTOS_REPO" NODES="$NODES" \
       CL2_SCHEDULER_THROUGHPUT_PODS="$N" CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD" \
       CLASSES="$CLASSES" CLASSIFICATION_SOURCE="$CLASSIFICATION_SOURCE" \
       "$SCRIPT_DIR/run-klastos-workload-security-rings-test.sh" \
       > "$STEP_DIR/run.log" 2>&1; then
      cp -r "$SCRIPT_DIR/result/use-case/workload-security-rings-klastos-test" "$STEP_DIR/measurements"
      echo "    OK — log: $STEP_DIR/run.log"
    else
      echo "    FAILED at N=$N — see $STEP_DIR/run.log"
      FAILED=true
    fi

    kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi

  if [ "$RUN_BASELINE" = true ]; then
    echo "[*] Gatekeeper baseline, N=$N"
    STEP_DIR="$RESULT_ROOT/baseline-n$N"
    mkdir -p "$STEP_DIR"

    python3 "$SCRIPT_DIR/e2e-latency-watch.py" --output "$STEP_DIR/e2e-latency.json" &
    WATCHER_PID=$!
    sleep 1

    # run-use-case-test.sh's own workload-security-rings/scheduler-suite.yaml
    # already covers vanilla + pod-sensitive + pod-unhandened identifiers in
    # one clusterloader --testsuite invocation — same pattern as
    # data-sovereignty/multi-tenancy's own baseline arms.
    if NODES="$NODES" TEST=workload-security-rings BASELINE=false \
       CL2_SCHEDULER_THROUGHPUT_PODS="$N" CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD" \
       "$SCRIPT_DIR/run-use-case-test.sh" \
       > "$STEP_DIR/run.log" 2>&1; then
      cp -r "$SCRIPT_DIR/result/use-case/workload-security-rings-test" "$STEP_DIR/measurements"
      echo "    OK — log: $STEP_DIR/run.log"
    else
      echo "    FAILED at N=$N — see $STEP_DIR/run.log"
      FAILED=true
    fi

    kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi

  if [ "$FAILED" = true ]; then
    echo ""
    echo "Stopping before larger steps — a step failed at N=$N."
    exit 1
  fi
  echo ""
done

echo "=== All steps passed ==="
echo "Results under: $RESULT_ROOT"

python3 "$SCRIPT_DIR/generate-report.py" "$RESULT_ROOT" --csv "$RESULT_ROOT/report.csv" | tee "$RESULT_ROOT/report.md"
echo ""
echo "Report: $RESULT_ROOT/report.md"
echo "CSV:    $RESULT_ROOT/report.csv"
