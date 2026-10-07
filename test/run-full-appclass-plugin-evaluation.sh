#!/usr/bin/env bash
# Experiment 1 full evaluation driver — multi-tenancy use case, AppClass
# scheduler-plugin variant (klastos/experiment1/multi-tenancy/
# harness-appclass-plugin/). KLASTOS-only: unlike the other two variants
# (classToTopology vs. mutated nodeSelector; interClass AntiAffinity vs.
# Gatekeeper's reactive binding-time policy), this mode has no natural
# Gatekeeper counterpart to run as RUN_BASELINE — it isn't a CSC/UCSS
# mechanism being compared against an equivalent Gatekeeper mechanism, it's
# a structurally different, simpler scheduler plugin. The closest existing
# comparison for "different tenants never share a node" already exists as
# harness-antiaffinity/ vs. policy-antiaffinity/
# (run-full-multitenancy-antiaffinity-evaluation.sh); this script exists to
# characterize the AppClass-plugin arm's own behavior in isolation, with
# the same e2e-latency-watch.py instrumentation the other two get via
# their own full-evaluation wrappers — confirmed live that invoking
# run-klastos-multitenancy-test.sh directly produces a report with e2e
# latency, admission-mutation, classification-source/phase, and
# gate-release-phase ALL blank: the plain per-mode script never starts
# that watcher (by design — it only runs inside a *-evaluation.sh wrapper
# for every mode, not just this one). Note even with the watcher running,
# classification-source/phase and gate-release-phase will stay blank for
# this mode specifically and correctly: there is no class-keys annotation
# and no gating admission controller in this topology at all (see
# harness-appclass-plugin/README.md) — only e2e latency and the raw
# scheduling-phase breakdown are meaningful here.
#
# Usage:
#   ./run-full-appclass-plugin-evaluation.sh
#   N_STEPS="20 100 1000" ./run-full-appclass-plugin-evaluation.sh

set -euo pipefail

N_STEPS="${N_STEPS:-20 100 1000}"
NODES="${NODES:-100}"
CLASSES="${CLASSES:-appclass-test-a appclass-test-b}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/klastos}"
APPCLASS_NAME="${APPCLASS_NAME:-app-class}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
RESULT_ROOT="$SCRIPT_DIR/result/use-case/full-appclass-plugin-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"

echo "=== Experiment 1 full evaluation (multi-tenancy, AppClass-plugin variant) ==="
echo "Steps (N):     $N_STEPS"
echo "Classes:       $CLASSES"
echo "APPCLASS_NAME: $APPCLASS_NAME"
echo "Results:       $RESULT_ROOT"
echo ""

threshold_for() {
  local n="$1"
  if [ -n "${THRESHOLD_OVERRIDE:-}" ]; then
    echo "$THRESHOLD_OVERRIDE"
    return
  fi
  # Deliberately more conservative than the other evaluation scripts'
  # n/10 floor-5 formula: the AppClass plugin's PreFilter lists every
  # AppGroup-labeled pod cluster-wide and rebuilds satisfied/violated
  # maps per node on every scheduling decision (see
  # nestor-scheduling-work/pkg/security/appclass.go) — a fundamentally
  # more expensive per-pod cost. Observed actual throughput was ~66
  # pods/sec at N=1000 on this cluster (confirmed live); n/20 floor-3
  # leaves real margin below that for run-to-run variance.
  local t=$((n / 20))
  [ "$t" -lt 3 ] && t=3
  echo "$t"
}

FAILED=false

for N in $N_STEPS; do
  THRESHOLD=$(threshold_for "$N")
  echo "--- Step: N=$N (threshold=$THRESHOLD pods/sec) ---"

  echo "[*] KLASTOS harness (appclass-plugin), N=$N"
  STEP_DIR="$RESULT_ROOT/appclass-plugin-n$N"
  mkdir -p "$STEP_DIR"

  python3 "$SCRIPT_DIR/e2e-latency-watch.py" --output "$STEP_DIR/e2e-latency.json" &
  WATCHER_PID=$!
  sleep 1

  if KLASTOS_REPO="$KLASTOS_REPO" NODES="$NODES" \
     CL2_SCHEDULER_THROUGHPUT_PODS="$N" CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD" \
     CLASSES="$CLASSES" HARNESS_MODE=appclass-plugin APPCLASS_NAME="$APPCLASS_NAME" \
     "$SCRIPT_DIR/run-klastos-multitenancy-test.sh" \
     > "$STEP_DIR/run.log" 2>&1; then
    cp -r "$SCRIPT_DIR/result/use-case/appclass-plugin-test" "$STEP_DIR/measurements"
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

python3 "$SCRIPT_DIR/generate-report.py" "$RESULT_ROOT" --csv "$RESULT_ROOT/report.csv" | tee "$RESULT_ROOT/report.md"
echo ""
echo "Report: $RESULT_ROOT/report.md"
echo "CSV:    $RESULT_ROOT/report.csv"
