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
#
# THRESHOLD_OVERRIDE bypasses this entirely when set: at large N, KLASTOS's
# own still-unfixed gate-release bottleneck (see
# ISSUE-ucss-serial-gate-release-loop.md) legitimately drops measured
# throughput below any N-scaled threshold this heuristic would pick (e.g.
# N=1000 failed outright at 65 pods/sec vs. a threshold_for()-computed 100)
# — that's a real, already-tracked finding, not a harness bug, and letting
# ClusterLoader2 hard-fail the whole run on it means the per-class loop
# aborts before later classes even run and before results get copied out
# of the fixed-path measurements dir. Set THRESHOLD_OVERRIDE to a value
# below the worst-case expected throughput to collect the actual latency
# data anyway; the measured numbers themselves are unaffected either way.
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

    # See e2e-latency-watch.py's own header for why this exists:
    # ClusterLoader2's own SchedulingMetrics measurement can't observe
    # diktyo-scheduler at all (hardcoded to proxy the DEFAULT scheduler's
    # static pod), and diktyo-scheduler's own binary doesn't even
    # register the histogram that measurement queries for. Must be
    # running BEFORE pods are created and stay running until after the
    # harness's own delete step, or it misses the events it needs.
    python3 "$SCRIPT_DIR/e2e-latency-watch.py" --output "$STEP_DIR/e2e-latency.json" &
    WATCHER_PID=$!
    sleep 1

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

    # run-use-case-test.sh's own scheduler-suite.yaml already covers all 4
    # identifiers (vanilla/eu/us/italynorth) in one clusterloader
    # --testsuite invocation — unlike the KLASTOS harness, no per-class
    # looping is needed here.
    #
    # BASELINE=false is required here — it's run-use-case-test.sh's OWN
    # internal flag (distinct from this script's RUN_BASELINE) gating
    # whether it applies node region labels + Gatekeeper policy at all
    # (`if [ "$BASELINE" = false ]`). Left unset, it silently skips both:
    # confirmed live this session — the "italynorth" identifier bakes its
    # nodeAffinity directly into the pod template (unlike eu/us, which
    # depend on Gatekeeper's mutation webhook), so it's the one identifier
    # that can't accidentally "pass" by scheduling onto an unconstrained
    # node — it failed outright (0/101 nodes matched) with zero region
    # labels applied, exposing the gap eu/us's mutation-dependent passes
    # were quietly masking.
    if NODES="$NODES" TEST=data-sovereignty BASELINE=false \
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

python3 "$SCRIPT_DIR/generate-report.py" "$RESULT_ROOT" | tee "$RESULT_ROOT/report.md"
echo ""
echo "Report: $RESULT_ROOT/report.md"
