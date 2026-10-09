#!/usr/bin/env bash
# Generic N-times repeat wrapper for any ...-evaluation.sh script that
# follows the established contract run-repeated-evaluation.sh already
# relies on (prints "Results: <dir>" and writes <dir>/report.csv) -
# run-full-evaluation.sh, run-full-multitenancy-evaluation.sh,
# run-full-multitenancy-antiaffinity-evaluation.sh, and every
# concurrent-test/*/run-concurrent-*.sh all already satisfy it.
# run-repeated-evaluation.sh only ever called run-full-evaluation.sh -
# this generalizes the same repeat+aggregate methodology (via the
# existing, unchanged aggregate-repeated-runs.py) to any of them, so a
# single-run number is never trusted over a measured spread.
#
# Does NOT control which UCSS image/version is deployed - comparing two
# images is a manual deploy step you do BETWEEN two separate invocations
# of this wrapper (one per image), same as a single run already requires.
#
# Usage:
#   ./run-repeated-script.sh <target-script> <repeats> [-- <args to target-script>]
#   REPEATS=5; N_STEPS=20 RUN_BASELINE=true \
#     ./run-repeated-script.sh concurrent-test/multi-tenancy-antiaffinity/run-concurrent-multitenancy-antiaffinity-evaluation.sh "$REPEATS"
#
# Every env var the target script itself reads (N_STEPS, RUN_BASELINE,
# THRESHOLD_OVERRIDE, KLASTOS_REPO, ...) is inherited from this script's own
# environment - set them the same way you would for a single invocation of
# the target script.

set -euo pipefail

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

TARGET="${1:?usage: run-repeated-script.sh <target-script> <repeats>}"
REPEATS="${2:?usage: run-repeated-script.sh <target-script> <repeats>}"

if ! [[ "$REPEATS" =~ ^[0-9]+$ ]] || [ "$REPEATS" -lt 2 ]; then
  echo "ERROR: repeats must be an integer >= 2 - one run has no spread to measure." >&2
  exit 1
fi

if [ ! -x "$TARGET" ]; then
  echo "ERROR: target script not found or not executable: $TARGET" >&2
  exit 1
fi
TARGET=$(cd -- "$(dirname -- "$TARGET")" &> /dev/null && pwd)/$(basename -- "$TARGET")

LABEL=$(basename -- "$TARGET" .sh)
STATS_ROOT="$SCRIPT_DIR/result/use-case/repeated-$LABEL-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$STATS_ROOT"

echo "=== Repeated evaluation: $REPEATS x $TARGET ==="
echo "Stats output: $STATS_ROOT"
echo ""

RESULT_ROOTS=()
FAILED_REPEATS=0

for i in $(seq 1 "$REPEATS"); do
  echo "--- Repeat $i/$REPEATS ---"
  LOG="$STATS_ROOT/repeat-$i.log"
  if "$TARGET" > "$LOG" 2>&1; then
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
