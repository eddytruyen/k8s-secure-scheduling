#!/usr/bin/env bash
# Shared helpers for every concurrent-test/*/run-concurrent-*.sh script.
# Sourced, not executed directly. Extracted from the near-identical
# boilerplate that was duplicated across multi-tenancy-antiaffinity,
# multi-tenancy-antiaffinity-and-affinity, multi-tenancy-appclass-plugin,
# and multi-tenancy-classtotopology's own run-concurrent-*.sh scripts
# (same step-loop/threshold/watcher/report pattern in all four) when the
# workload-security-rings concurrent variant was added, to stop a fifth
# near-duplicate copy from being written. The four pre-existing scripts
# were refactored to use this lib too, so the dedup is real (every
# concurrent-test variant source this, not just the new one).
#
# Callers must set SCRIPT_DIR and TEST_DIR before sourcing this (same
# convention every run-concurrent-*.sh already uses):
#   SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
#   TEST_DIR=$( cd -- "$SCRIPT_DIR/../.." &> /dev/null && pwd )

# Per-step scheduling-throughput violation threshold (pods/sec). Honors
# THRESHOLD_OVERRIDE if the caller set one; otherwise scales with N
# (n/10, floor 5) — identical formula every existing concurrent script used.
concurrent_threshold_for() {
  local n="$1"
  if [ -n "${THRESHOLD_OVERRIDE:-}" ]; then
    echo "$THRESHOLD_OVERRIDE"
    return
  fi
  local t=$((n / 10))
  [ "$t" -lt 5 ] && t=5
  echo "$t"
}

# Runs one measured step: starts the e2e-latency watcher, exports the
# common CL2_* env vars every concurrent config template reads, invokes
# the caller-supplied work function (by name — it runs in this same shell,
# so it sees the caller's own variables, e.g. N/HARNESS_DIR/SCRIPT_DIR,
# with no need to pass them through explicitly), captures its exit code
# without letting a failure abort the whole script before the watcher is
# stopped and run.log is flushed, then prints the same OK/FAILED line
# every variant already printed.
#
# Usage: concurrent_run_step <step_dir> <n> <threshold> <work_fn>
# Returns: 0 if work_fn succeeded, 1 otherwise (same as `if ! concurrent_run_step ...; then FAILED=true; fi`).
concurrent_run_step() {
  local step_dir="$1" n="$2" threshold="$3" work_fn="$4"
  mkdir -p "$step_dir"

  python3 "$TEST_DIR/e2e-latency-watch.py" --output "$step_dir/e2e-latency.json" &
  local watcher_pid=$!
  sleep 1

  export CL2_SCHEDULER_THROUGHPUT_PODS="$n"
  export CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$threshold"
  export CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""'
  export CL2_PROMETHEUS_TOLERATE_MASTER=true

  set +e
  ( set -euo pipefail; "$work_fn" ) > "$step_dir/run.log" 2>&1
  local rc=$?
  set -e

  unset CL2_SCHEDULER_THROUGHPUT_PODS CL2_SCHEDULER_THROUGHPUT_THRESHOLD CL2_PROMETHEUS_NODE_SELECTOR CL2_PROMETHEUS_TOLERATE_MASTER

  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  if [ "$rc" -eq 0 ]; then
    echo "    OK — log: $step_dir/run.log"
    return 0
  else
    echo "    FAILED at N=$n — see $step_dir/run.log"
    return 1
  fi
}

# Final report generation + the same closing lines every variant printed.
concurrent_finalize() {
  local result_root="$1"
  echo "=== All steps passed ==="
  echo "Results under: $result_root"
  python3 "$TEST_DIR/generate-report.py" "$result_root" --csv "$result_root/report.csv" | tee "$result_root/report.md"
  echo ""
  echo "Report: $result_root/report.md"
  echo "CSV:    $result_root/report.csv"
}
