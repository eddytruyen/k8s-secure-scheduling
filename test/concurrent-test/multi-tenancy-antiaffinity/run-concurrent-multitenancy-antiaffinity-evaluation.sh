#!/usr/bin/env bash
# Concurrent counterpart of run-full-multitenancy-antiaffinity-evaluation.sh
# (../../run-full-multitenancy-antiaffinity-evaluation.sh) - see
# ../README.md for why this exists: the sequential per-class harness
# fully tears down uc1 (including its namespace) before uc2's pods are
# even created, so the interClass AntiAffinity CSC (and the baseline's
# own policy-antiaffinity/) was never actually exercised under real
# cross-tenant contention by any sequential evaluation run. This script
# creates BOTH tenants' AppGroups/namespaces up front, runs ONE combined
# clusterloader pass covering both (config-*-concurrent.yaml in this
# directory), and only tears both down at the very end - uc1 and uc2 are
# genuinely alive on the cluster at the same time for the whole
# measurement window.
#
# Reuses the existing harness scripts completely unchanged
# (apply-class-policy.sh/delete-class-policy.sh are already stateless,
# per-class calls - this script just doesn't call delete-class-policy.sh
# for either class until BOTH have been applied and measured together).
#
# One consequence of a combined run: SchedulingThroughput is not
# class-aware, so the report shows ONE combined throughput number across
# both tenants' 2*N pods, not a per-class number - see
# config-klastos-concurrent.yaml's own header for why, and read this
# step's e2e-latency.json directly for a per-class e2e-latency/phase
# breakdown (e2e-latency-watch.py's own generateName-based grouping
# already works correctly across multiple classes within one run).
#
# The step loop itself (threshold scaling, watcher start/stop, run.log
# capture, OK/FAILED reporting, final report generation) lives in
# ../lib/common.sh, shared by every concurrent-test variant - only the
# per-arm apply/run/delete sequence below is specific to this one.
#
# Usage:
#   ./run-concurrent-multitenancy-antiaffinity-evaluation.sh
#   N_STEPS="20 100 1000" RUN_BASELINE=true ./run-concurrent-multitenancy-antiaffinity-evaluation.sh

set -euo pipefail

N_STEPS="${N_STEPS:-20 100 1000}"
NODES="${NODES:-100}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/githubrepos/klastos}"
RUN_BASELINE="${RUN_BASELINE:-false}"
RUN_KLASTOS="${RUN_KLASTOS:-true}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
TEST_DIR=$( cd -- "$SCRIPT_DIR/../.." &> /dev/null && pwd )
HARNESS_DIR="$KLASTOS_REPO/experiment1/multi-tenancy/harness-antiaffinity"
RESULT_ROOT="$TEST_DIR/result/use-case/concurrent-multitenancy-antiaffinity-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

echo "=== Experiment 1 CONCURRENT evaluation (multi-tenancy, anti-affinity variant) ==="
echo "Steps (N per class): $N_STEPS"
echo "Run KLASTOS:  $RUN_KLASTOS"
echo "Run baseline: $RUN_BASELINE"
echo "Results:      $RESULT_ROOT"
echo ""

klastos_work() {
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
}

baseline_work() {
  POLICY_VARIANT=antiaffinity POLICY=multi-tenancy "$TEST_DIR/update-policy.sh"
  kubectl apply -f "$TEST_DIR/use-case/namespaces.yaml"

  "$TEST_DIR/clusterloader" --alsologtostderr --logtostderr=false \
      --enable-prometheus-server=true \
      --tear-down-prometheus-server=false \
      --prometheus-apiserver-scrape-port=6443 \
      --prometheus-pvc-storage-class=standard \
      --prometheus-ready-timeout=0 \
      --log_file="$STEP_DIR/baseline.log" \
      --report-dir="$STEP_DIR/measurements" \
      --testconfig="$SCRIPT_DIR/config-baseline-concurrent.yaml" \
      --nodes="$NODES" --provider=kind --kubeconfig="$HOME/.kube/config" --v=2

  kubectl delete -f "$TEST_DIR/use-case/namespaces.yaml"
  DELETE=true POLICY_VARIANT=antiaffinity POLICY=multi-tenancy "$TEST_DIR/update-policy.sh"
}

FAILED=false

for N in $N_STEPS; do
  THRESHOLD=$(concurrent_threshold_for "$N")
  echo "--- Step: N=$N per class (threshold=$THRESHOLD pods/sec, violations=$(concurrent_violations_state)) ---"

  if [ "$RUN_KLASTOS" = true ]; then
    echo "[*] KLASTOS harness (antiaffinity, CONCURRENT), N=$N per class"
    STEP_DIR="$RESULT_ROOT/klastos-n$N"
    if ! concurrent_run_step "$STEP_DIR" "$N" "$THRESHOLD" klastos_work; then
      FAILED=true
    fi
  fi

  if [ "$RUN_BASELINE" = true ]; then
    echo "[*] Gatekeeper baseline (reactive binding-time policy, CONCURRENT), N=$N per class"
    STEP_DIR="$RESULT_ROOT/baseline-n$N"
    if ! concurrent_run_step "$STEP_DIR" "$N" "$THRESHOLD" baseline_work; then
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

concurrent_finalize "$RESULT_ROOT"
