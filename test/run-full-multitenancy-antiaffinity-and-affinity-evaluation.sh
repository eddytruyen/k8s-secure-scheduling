#!/usr/bin/env bash
# Experiment 1 full evaluation driver - multi-tenancy use case,
# ANTI-AFFINITY-AND-AFFINITY variant: KLASTOS's interClass AntiAffinity CSC
# plus the same-tenant interClass Affinity term
# (klastos/experiment1/multi-tenancy/harness-antiaffinity-and-affinity/).
#
# Sequential counterpart of
# concurrent-test/multi-tenancy-antiaffinity-and-affinity/. Until now that
# variant had a concurrent driver but no sequential one, so it was the only
# HARNESS_MODE that could not be run the same way as the others. Invoking
# run-klastos-multitenancy-test.sh directly does apply the policy, but
# produces a report with e2e latency, classification-source and
# gate-release phases all blank - the plain per-mode script never starts
# e2e-latency-watch.py, which only runs inside a *-evaluation.sh wrapper
# like this one.
#
# KLASTOS-only, no RUN_BASELINE arm - same reason the concurrent script has
# none: the thing under test is the added same-tenant interClass Affinity
# term (c2, strict: false), which has no Gatekeeper equivalent at all
# (Gatekeeper's mutation/constraint pair has no placement-preference
# concept, only node-selector validation). There is nothing to compare it
# against on the baseline side. Compare this run's numbers against
# run-full-multitenancy-antiaffinity-evaluation.sh's own KLASTOS arm
# instead, to isolate the effect of adding the affinity term on top of the
# unchanged anti-affinity one - same N, same profile, same classes.
#
# Otherwise identical in structure to
# run-full-multitenancy-antiaffinity-evaluation.sh; see that script's header
# for the step-sequence and threshold rationale. Neither mechanism reads node
# labels, so no tenant labeling is required.
#
# Usage:
#   ./run-full-multitenancy-antiaffinity-and-affinity-evaluation.sh
#   N_STEPS="20 100 1000" ./run-full-multitenancy-antiaffinity-and-affinity-evaluation.sh
#   N_STEPS=1000 ./run-repeated-script.sh ./run-full-multitenancy-antiaffinity-and-affinity-evaluation.sh 5

set -euo pipefail

N_STEPS="${N_STEPS:-20 100 1000}"
NODES="${NODES:-100}"
CLASSES="${CLASSES:-uc1 uc2}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/githubrepos/klastos}"
RUN_KLASTOS="${RUN_KLASTOS:-true}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
RESULT_ROOT="$SCRIPT_DIR/result/use-case/full-multitenancy-antiaffinity-and-affinity-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"

echo "=== Experiment 1 full evaluation (multi-tenancy, anti-affinity + affinity variant) ==="
echo "Steps (N):    $N_STEPS"
echo "Classes:      $CLASSES"
echo "Run KLASTOS:  $RUN_KLASTOS"
echo "Run baseline: n/a (KLASTOS-only - no Gatekeeper equivalent for the affinity term)"
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
    echo "[*] KLASTOS harness (antiaffinity-and-affinity), N=$N"
    STEP_DIR="$RESULT_ROOT/klastos-n$N"
    mkdir -p "$STEP_DIR"

    python3 "$SCRIPT_DIR/e2e-latency-watch.py" --output "$STEP_DIR/e2e-latency.json" &
    WATCHER_PID=$!
    sleep 1

    if KLASTOS_REPO="$KLASTOS_REPO" NODES="$NODES" \
       CL2_SCHEDULER_THROUGHPUT_PODS="$N" CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD" \
       CLASSES="$CLASSES" HARNESS_MODE=antiaffinity-and-affinity \
       "$SCRIPT_DIR/run-klastos-multitenancy-test.sh" \
       > "$STEP_DIR/run.log" 2>&1; then
      cp -r "$SCRIPT_DIR/result/use-case/multi-tenancy-klastos-test" "$STEP_DIR/measurements"
      echo "    OK - log: $STEP_DIR/run.log"
    else
      echo "    FAILED at N=$N - see $STEP_DIR/run.log"
      FAILED=true
    fi

    kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi

  if [ "$FAILED" = true ]; then
    echo ""
    echo "Stopping before larger steps - a step failed at N=$N."
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
