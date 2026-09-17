#!/usr/bin/env bash
# Repeat run-full-evaluation.sh X times against whatever is CURRENTLY
# deployed (this script does not deploy/teardown anything itself - same
# "one command, one already-set-up cluster" contract run-full-evaluation.sh
# itself has), then aggregate every repeat's own report.csv into one
# mean/stdev summary per reported metric via aggregate-repeated-runs.py.
#
# Motivation: this experiment's own N=1000 numbers have already been shown
# (see test/result/use-case/appclass-operator-classification-fix-comparison.md)
# to swing a lot run-to-run at this scale - a single run can't tell a real
# effect apart from noise. Repeating the SAME configuration X times and
# looking at the spread is the only way to actually know.
#
# Every env var run-full-evaluation.sh itself reads (KLASTOS_REPO, NODES,
# CLASSES, N_STEPS, RUN_KLASTOS, RUN_BASELINE, THRESHOLD_OVERRIDE) is just
# forwarded straight through - set them the same way you would for a single
# run-full-evaluation.sh invocation; this wrapper doesn't add any new ones
# for that script itself.
#
# Usage:
#   ./run-repeated-evaluation.sh <repeats>
#   REPEATS=5 KLASTOS_REPO=$HOME/githubrepos/klastos RUN_BASELINE=false \
#     THRESHOLD_OVERRIDE=5 ./run-repeated-evaluation.sh
#
# (First positional arg wins over $REPEATS if both are given.)

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPEATS="${1:-${REPEATS:-}}"

if [ -z "$REPEATS" ] || ! [[ "$REPEATS" =~ ^[0-9]+$ ]] || [ "$REPEATS" -lt 2 ]; then
  echo "Usage: $0 <repeats>   (repeats must be an integer >= 2 - one run has no spread to measure)" >&2
  exit 1
fi

STATS_ROOT="$SCRIPT_DIR/result/use-case/repeated-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STATS_ROOT"

echo "=== Repeated evaluation: $REPEATS x run-full-evaluation.sh ==="
echo "Stats output: $STATS_ROOT"
echo ""

RESULT_ROOTS=()
FAILED_REPEATS=0

for i in $(seq 1 "$REPEATS"); do
  echo "--- Repeat $i/$REPEATS ---"
  LOG="$STATS_ROOT/repeat-$i.log"
  if "$SCRIPT_DIR/run-full-evaluation.sh" > "$LOG" 2>&1; then
    ROOT=$(grep -m1 '^Results:' "$LOG" | awk '{print $2}')
    if [ -z "$ROOT" ] || [ ! -f "$ROOT/report.csv" ]; then
      echo "  WARNING: repeat $i produced no report.csv (see $LOG) - excluded from stats"
      FAILED_REPEATS=$((FAILED_REPEATS + 1))
      continue
    fi
    echo "  OK - $ROOT"
    RESULT_ROOTS+=("$ROOT")
  else
    echo "  FAILED - see $LOG - excluded from stats"
    FAILED_REPEATS=$((FAILED_REPEATS + 1))
  fi
done

echo ""
if [ "${#RESULT_ROOTS[@]}" -lt 2 ]; then
  echo "ERROR: fewer than 2 successful repeats (${#RESULT_ROOTS[@]} of $REPEATS) - nothing to compute stdev over." >&2
  echo "See per-repeat logs under $STATS_ROOT" >&2
  exit 1
fi

if [ "$FAILED_REPEATS" -gt 0 ]; then
  echo "NOTE: $FAILED_REPEATS of $REPEATS repeats failed/produced no report.csv and were excluded - stats below are over the remaining ${#RESULT_ROOTS[@]}."
  echo ""
fi

python3 "$SCRIPT_DIR/aggregate-repeated-runs.py" "${RESULT_ROOTS[@]}" --out "$STATS_ROOT"

echo ""
echo "=== Done ==="
echo "Per-repeat results: $(printf '%s ' "${RESULT_ROOTS[@]}")"
echo "Stats:              $STATS_ROOT/stats.md"
echo "Stats (CSV):        $STATS_ROOT/stats.csv"
