#!/usr/bin/env bash
# Experiment 1 full evaluation driver — multi-tenancy use case,
# KLASTOS vs. Gatekeeper baseline. Same structure as
# run-full-evaluation.sh (data-sovereignty) — see that script's own header
# for the full rationale (gradual N steps, threshold scaling, why
# THRESHOLD_OVERRIDE exists).
#
# Usage:
#   ./run-full-multitenancy-evaluation.sh                        # default step sequence
#   N_STEPS="20 100 1000" ./run-full-multitenancy-evaluation.sh   # custom steps
#   RUN_BASELINE=true ./run-full-multitenancy-evaluation.sh       # also run the Gatekeeper baseline at each step
#   RUN_KLASTOS=false RUN_BASELINE=true ./run-full-multitenancy-evaluation.sh   # baseline only
#
# Each step's full clusterloader log + JUnit report lands under
# result/use-case/full-multitenancy-evaluation-<timestamp>/{klastos,baseline}-n<N>/.

set -euo pipefail

N_STEPS="${N_STEPS:-20 100 1000}"
NODES="${NODES:-100}"
CLASSES="${CLASSES:-uc1 uc2}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/githubrepos/klastos}"
RUN_BASELINE="${RUN_BASELINE:-false}"
RUN_KLASTOS="${RUN_KLASTOS:-true}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
RESULT_ROOT="$SCRIPT_DIR/result/use-case/full-multitenancy-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"

echo "=== Experiment 1 full evaluation (multi-tenancy) ==="
echo "Steps (N):    $N_STEPS"
echo "Classes:      $CLASSES"
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
       CLASSES="$CLASSES" "$SCRIPT_DIR/run-klastos-multitenancy-test.sh" \
       > "$STEP_DIR/run.log" 2>&1; then
      cp -r "$SCRIPT_DIR/result/use-case/multi-tenancy-klastos-test" "$STEP_DIR/measurements"
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

    # run-use-case-test.sh's own multi-tenancy/scheduler-suite.yaml already
    # covers vanilla + both uc1/uc2 identifiers in one clusterloader
    # --testsuite invocation — same as data-sovereignty's own baseline arm.
    if NODES="$NODES" TEST=multi-tenancy BASELINE=false \
       CL2_SCHEDULER_THROUGHPUT_PODS="$N" CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD" \
       "$SCRIPT_DIR/run-use-case-test.sh" \
       > "$STEP_DIR/run.log" 2>&1; then
      cp -r "$SCRIPT_DIR/result/use-case/multi-tenancy-test" "$STEP_DIR/measurements"
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
