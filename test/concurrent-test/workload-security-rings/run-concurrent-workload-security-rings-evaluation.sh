#!/usr/bin/env bash
# Concurrent counterpart of run-full-workload-security-rings-evaluation.sh
# (../../run-full-workload-security-rings-evaluation.sh) - alternative to
# it, not a replacement: that sequential script is untouched and still the
# default way to run this use case. Same rationale as
# ../multi-tenancy-classtotopology/'s own concurrent script (which this one
# is structurally closest to): workload-security-rings' two CSCs
# (csc-security-ring-sensitive-*/csc-security-ring-unhardened-*) are each a
# standalone classToTopology Affinity constraint with no interClass
# relationship between sensitive and unhardened at all - there is no
# correctness gap the sequential per-ring loop misses (unlike
# ../multi-tenancy-antiaffinity/'s own concurrent script, which fixes a
# real one). This harness exists purely for a REALISTIC MIXED-LOAD
# measurement: both rings' admission/classification/scheduling load
# landing on the cluster at the same time, instead of one ring's full
# lifecycle completing before the next ring's workload even starts.
#
# Creates BOTH rings' AppGroups up front (same shared namespace -
# workload-security-rings-eval - unlike multi-tenancy's per-tenant
# namespaces, matching the harness's own namespace-agnostic design), runs
# ONE combined clusterloader pass covering both
# (config-*-concurrent.yaml in this directory), and only tears both down
# at the very end.
#
# Reuses the existing harness scripts completely unchanged
# (apply-class-policy.sh/delete-class-policy.sh are already stateless,
# per-ring calls - this script just doesn't call delete-class-policy.sh
# for either ring until BOTH have been applied and measured together).
#
# One consequence of a combined run: SchedulingThroughput is not
# class-aware, so the report shows ONE combined throughput number across
# both rings' 2*N pods, not a per-ring number - see
# config-klastos-concurrent.yaml's own header for why, and read this
# step's e2e-latency.json directly for a per-class e2e-latency/phase
# breakdown (e2e-latency-watch.py's own generateName-based grouping
# already works correctly across multiple classes within one run).
#
# The step loop itself (threshold scaling, watcher start/stop, run.log
# capture, OK/FAILED reporting, final report generation) lives in
# ../lib/common.sh, shared by every concurrent-test variant.
#
# CLASSIFICATION_SOURCE=rbac|podlabel (default rbac) picks which KLASTOS-
# side classification variant is applied - see
# klastos/experiment1/workload-security-rings/harness/README.md.
#
# Requires, before running with RUN_BASELINE=true:
#   POLICY=workload-security-rings ./update-labels.sh
# (node security-ring labels). The KLASTOS arm needs no node labeling at
# all (NSP-computed segmentation instead).
#
# Usage:
#   ./run-concurrent-workload-security-rings-evaluation.sh
#   N_STEPS="20 100 1000" RUN_BASELINE=true ./run-concurrent-workload-security-rings-evaluation.sh
#   CLASSIFICATION_SOURCE=podlabel ./run-concurrent-workload-security-rings-evaluation.sh

set -euo pipefail

N_STEPS="${N_STEPS:-20 100 1000}"
NODES="${NODES:-100}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/githubrepos/klastos}"
RUN_BASELINE="${RUN_BASELINE:-false}"
RUN_KLASTOS="${RUN_KLASTOS:-true}"
CLASSIFICATION_SOURCE="${CLASSIFICATION_SOURCE:-rbac}"
NAMESPACE="${NAMESPACE:-workload-security-rings-eval}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
TEST_DIR=$( cd -- "$SCRIPT_DIR/../.." &> /dev/null && pwd )
HARNESS_DIR="$KLASTOS_REPO/experiment1/workload-security-rings/harness"
RESULT_ROOT="$TEST_DIR/result/use-case/concurrent-workload-security-rings-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

echo "=== Experiment 1 CONCURRENT evaluation (workload-security-rings) ==="
echo "Steps (N per ring):     $N_STEPS"
echo "Classification source:  $CLASSIFICATION_SOURCE (KLASTOS arm only)"
echo "Run KLASTOS:  $RUN_KLASTOS"
echo "Run baseline: $RUN_BASELINE"
echo "Results:      $RESULT_ROOT"
echo ""

klastos_work() {
  CLASSIFICATION_SOURCE="$CLASSIFICATION_SOURCE" NAMESPACE="$NAMESPACE" "$HARNESS_DIR/apply-shared-policy.sh"
  "$HARNESS_DIR/apply-class-policy.sh" sensitive "$N" "$NAMESPACE"
  "$HARNESS_DIR/apply-class-policy.sh" unhardened "$N" "$NAMESPACE"

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

  "$HARNESS_DIR/delete-class-policy.sh" sensitive "$NAMESPACE"
  "$HARNESS_DIR/delete-class-policy.sh" unhardened "$NAMESPACE"
  NAMESPACE="$NAMESPACE" "$HARNESS_DIR/delete-shared-policy.sh"
}

baseline_work() {
  POLICY=workload-security-rings "$TEST_DIR/update-policy.sh"

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

  DELETE=true POLICY=workload-security-rings "$TEST_DIR/update-policy.sh"
}

FAILED=false

for N in $N_STEPS; do
  THRESHOLD=$(concurrent_threshold_for "$N")
  echo "--- Step: N=$N per ring (threshold=$THRESHOLD pods/sec) ---"

  if [ "$RUN_KLASTOS" = true ]; then
    echo "[*] KLASTOS harness (workload-security-rings, CONCURRENT), N=$N per ring"
    STEP_DIR="$RESULT_ROOT/klastos-n$N"
    if ! concurrent_run_step "$STEP_DIR" "$N" "$THRESHOLD" klastos_work; then
      FAILED=true
    fi
  fi

  if [ "$RUN_BASELINE" = true ]; then
    echo "[*] Gatekeeper baseline (mutation+nodeSelector, CONCURRENT), N=$N per ring"
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
