#!/usr/bin/env bash
# Experiment 1 full evaluation driver — data-sovereignty use case,
# KLASTOS vs. Gatekeeper baseline. Runs a sequence of increasing N
# (pods per class), stopping at the first failed step rather than
# blindly escalating past a broken run — "gradual steps, tryout first".
#
# Usage:
#   ./run-full-evaluation.sh                        # default step sequence
#   N_STEPS="20 100 1000" ./run-full-evaluation.sh   # custom steps
#   RUN_BASELINE=true ./run-full-evaluation.sh       # also run the Gatekeeper baseline at each step
#   RUN_KLASTOS=false RUN_BASELINE=true ./run-full-evaluation.sh   # baseline only
#
# Each step's full clusterloader log + JUnit report lands under
# result/use-case/full-evaluation-<timestamp>/{klastos,baseline}-n<N>/.

set -euo pipefail

N_STEPS="${N_STEPS:-20 100 1000}"
NODES="${NODES:-100}"
CLASSES="${CLASSES:-vanilla eu us italynorth}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/klastos}"
RUN_BASELINE="${RUN_BASELINE:-false}"
RUN_KLASTOS="${RUN_KLASTOS:-true}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
RESULT_ROOT="$SCRIPT_DIR/result/use-case/full-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"

echo "=== Experiment 1 full evaluation ==="
echo "Steps (N):    $N_STEPS"
echo "Classes:      $CLASSES"
echo "Run KLASTOS:  $RUN_KLASTOS"
echo "Run baseline: $RUN_BASELINE"
echo "Results:      $RESULT_ROOT"
echo ""

# A single fixed SchedulingThroughput threshold doesn't scale down to small
# N: the ClusterLoader2 config's own default (400 pods/sec) is calibrated
# for large runs, so it "fails" the measurement at tryout scale even when
# scheduling itself is completely correct (confirmed this session's own
# N=20 tryout runs) — not a real signal at that size. Scale it down with N
# instead of using one fixed value for every step.
threshold_for() {
  local n="$1"
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
    if KLASTOS_REPO="$KLASTOS_REPO" NODES="$NODES" \
       CL2_SCHEDULER_THROUGHPUT_PODS="$N" CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD" \
       CLASSES="$CLASSES" "$SCRIPT_DIR/run-klastos-use-case-test.sh" \
       > "$STEP_DIR/run.log" 2>&1; then
      # run-klastos-use-case-test.sh writes to a FIXED per-class path
      # (result/use-case/data-sovereignty-klastos-test/<class>/), not one
      # scoped to this N — copy it out now or the next step's run
      # overwrites these measurements before generate-report.py ever
      # sees them.
      cp -r "$SCRIPT_DIR/result/use-case/data-sovereignty-klastos-test" "$STEP_DIR/measurements"
      echo "    OK — log: $STEP_DIR/run.log"
    else
      echo "    FAILED at N=$N — see $STEP_DIR/run.log"
      FAILED=true
    fi
  fi

  if [ "$RUN_BASELINE" = true ]; then
    echo "[*] Gatekeeper baseline, N=$N"
    STEP_DIR="$RESULT_ROOT/baseline-n$N"
    mkdir -p "$STEP_DIR"
    # run-use-case-test.sh's own scheduler-suite.yaml already covers all 4
    # identifiers (vanilla/eu/us/italynorth) in one clusterloader
    # --testsuite invocation — unlike the KLASTOS harness, no per-class
    # looping is needed here.
    if NODES="$NODES" TEST=data-sovereignty \
       CL2_SCHEDULER_THROUGHPUT_PODS="$N" CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD" \
       "$SCRIPT_DIR/run-use-case-test.sh" \
       > "$STEP_DIR/run.log" 2>&1; then
      # Same fixed-path overwrite risk as the KLASTOS branch above.
      cp -r "$SCRIPT_DIR/result/use-case/data-sovereignty-test" "$STEP_DIR/measurements"
      echo "    OK — log: $STEP_DIR/run.log"
    else
      echo "    FAILED at N=$N — see $STEP_DIR/run.log"
      FAILED=true
    fi
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

python3 "$SCRIPT_DIR/generate-report.py" "$RESULT_ROOT" | tee "$RESULT_ROOT/report.md"
echo ""
echo "Report: $RESULT_ROOT/report.md"
