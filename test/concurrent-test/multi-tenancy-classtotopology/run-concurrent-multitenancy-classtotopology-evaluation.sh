#!/usr/bin/env bash
# Concurrent counterpart of run-full-multitenancy-evaluation.sh
# (../../run-full-multitenancy-evaluation.sh) - see ../README.md for the
# general rationale. Unlike ../multi-tenancy-antiaffinity/'s own concurrent
# harness (fixing a genuine correctness gap - the sequential per-class loop
# never exercised the interClass AntiAffinity CSC under real cross-tenant
# contention at all), THIS classToTopology variant has no such gap: each
# tenant's own per-class node-affinity CSC is independently satisfiable
# regardless of what the other tenant is doing, so the sequential harness's
# numbers are already correct. This harness exists purely for a REALISTIC
# MIXED-LOAD measurement instead - both tenants' admission/classification/
# scheduling load landing on the cluster at the same time, the more
# realistic operating condition for a multi-tenant cluster than one
# tenant's full lifecycle completing before the next tenant's workload even
# starts.
#
# Creates BOTH tenants' AppGroups/namespaces up front, runs ONE combined
# clusterloader pass covering both (config-*-concurrent.yaml in this
# directory), and only tears both down at the very end.
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
# Usage:
#   ./run-concurrent-multitenancy-classtotopology-evaluation.sh
#   N_STEPS="20 100 1000" RUN_BASELINE=true ./run-concurrent-multitenancy-classtotopology-evaluation.sh

set -euo pipefail

N_STEPS="${N_STEPS:-20 100 1000}"
NODES="${NODES:-100}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/githubrepos/klastos}"
RUN_BASELINE="${RUN_BASELINE:-false}"
RUN_KLASTOS="${RUN_KLASTOS:-true}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
TEST_DIR=$( cd -- "$SCRIPT_DIR/../.." &> /dev/null && pwd )
HARNESS_DIR="$KLASTOS_REPO/experiment1/multi-tenancy/harness"
RESULT_ROOT="$TEST_DIR/result/use-case/concurrent-multitenancy-classtotopology-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"

echo "=== Experiment 1 CONCURRENT evaluation (multi-tenancy, classToTopology variant) ==="
echo "Steps (N per class): $N_STEPS"
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
  echo "--- Step: N=$N per class (threshold=$THRESHOLD pods/sec) ---"

  if [ "$RUN_KLASTOS" = true ]; then
    echo "[*] KLASTOS harness (classToTopology, CONCURRENT), N=$N per class"
    STEP_DIR="$RESULT_ROOT/klastos-n$N"
    mkdir -p "$STEP_DIR"

    python3 "$TEST_DIR/e2e-latency-watch.py" --output "$STEP_DIR/e2e-latency.json" &
    WATCHER_PID=$!
    sleep 1

    export CL2_SCHEDULER_THROUGHPUT_PODS="$N"
    export CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD"
    export CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""'
    export CL2_PROMETHEUS_TOLERATE_MASTER=true

    set +e
    (
      set -euo pipefail
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
    ) > "$STEP_DIR/run.log" 2>&1
    KLASTOS_RC=$?
    set -e

    unset CL2_SCHEDULER_THROUGHPUT_PODS CL2_SCHEDULER_THROUGHPUT_THRESHOLD CL2_PROMETHEUS_NODE_SELECTOR CL2_PROMETHEUS_TOLERATE_MASTER

    if [ $KLASTOS_RC -eq 0 ]; then
      echo "    OK — log: $STEP_DIR/run.log"
    else
      echo "    FAILED at N=$N — see $STEP_DIR/run.log"
      FAILED=true
    fi

    kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi

  if [ "$RUN_BASELINE" = true ]; then
    echo "[*] Gatekeeper baseline (standard mutation+nodeSelector, CONCURRENT), N=$N per class"
    STEP_DIR="$RESULT_ROOT/baseline-n$N"
    mkdir -p "$STEP_DIR"

    python3 "$TEST_DIR/e2e-latency-watch.py" --output "$STEP_DIR/e2e-latency.json" &
    WATCHER_PID=$!
    sleep 1

    export CL2_SCHEDULER_THROUGHPUT_PODS="$N"
    export CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD"
    export CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""'
    export CL2_PROMETHEUS_TOLERATE_MASTER=true

    set +e
    (
      set -euo pipefail
      POLICY=multi-tenancy "$TEST_DIR/update-policy.sh"
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
      DELETE=true POLICY=multi-tenancy "$TEST_DIR/update-policy.sh"
    ) > "$STEP_DIR/run.log" 2>&1
    BASELINE_RC=$?
    set -e

    unset CL2_SCHEDULER_THROUGHPUT_PODS CL2_SCHEDULER_THROUGHPUT_THRESHOLD CL2_PROMETHEUS_NODE_SELECTOR CL2_PROMETHEUS_TOLERATE_MASTER

    if [ $BASELINE_RC -eq 0 ]; then
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

python3 "$TEST_DIR/generate-report.py" "$RESULT_ROOT" --csv "$RESULT_ROOT/report.csv" | tee "$RESULT_ROOT/report.md"
echo ""
echo "Report: $RESULT_ROOT/report.md"
echo "CSV:    $RESULT_ROOT/report.csv"
