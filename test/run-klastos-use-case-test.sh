#!/usr/bin/env bash
# ClusterLoader2 target selection. Both default to the historical values, so an
# unset environment behaves exactly as before (local kind+KWOK cluster):
#   KUBECONFIG    - the cluster to drive. CL2 takes an explicit --kubeconfig, so
#                   without this it ignores the environment and silently runs
#                   against ~/.kube/config whatever the caller intended.
#   CL2_PROVIDER  - kind|local|skeleton|gce|... "kind" assumes a kind cluster and
#                   probes for its control-plane container; use "skeleton" for a
#                   plain remote cluster.
#   CL2_ENABLE_PROMETHEUS - "false" on any cluster that already runs its own
#                   monitoring. CL2 otherwise installs a COMPLETE second Prometheus
#                   stack into the monitoring namespace; on the shared KU Leuven
#                   cluster one of its ServiceMonitors panicked the cluster's own
#                   prometheus-operator and left it crashlooping (2026-11-18).
#                   Prometheus-backed measurements then skip themselves with a
#                   warning, so no testconfig has to change.
#   CL2_TEARDOWN_PROMETHEUS - "true" to remove that stack afterwards. The default
#                   false leaves every object behind, which is what made the damage
#                   above outlive the run.
#   CL2_PROMETHEUS_READY_TIMEOUT - 0 means wait FOREVER, and readiness requires ALL
#                   scrape targets healthy, so one unhealthy target hangs the run.
# KLASTOS counterpart of run-use-case-test.sh, for the data-sovereignty use
# case (Experiment 1's apples-to-apples harness).
#
# Structural difference from the baseline script, deliberate: baseline runs
# all 4 identifiers (vanilla/eu/us/italynorth) as ONE clusterloader
# --testsuite invocation, because Gatekeeper's mutation/constraint objects
# are all applied once upfront and handle every region simultaneously
# (which pod gets mutated depends only on that pod's own data-sovereignty
# label, not on which identifier is "active"). KLASTOS can't do that: each
# class needs its own CSC + AppGroup CR applied before its pods exist and
# removed after (an AppGroup is inherently class-specific, unlike
# Gatekeeper's blanket mutation.yaml) - so this script loops over the 4
# classes, running a SEPARATE `clusterloader --testconfig=` invocation per
# class, wrapped by harness/apply-class-policy.sh and
# harness/delete-class-policy.sh. Each class's run is still a complete,
# independent create-measure-delete cycle, same as one identifier within
# baseline's suite - just orchestrated here instead of inside
# ClusterLoader2's own suite iteration.
#
# Requires:
# - Node region labels already applied via `POLICY=data-sovereignty
#   update-labels.sh`, BEFORE the KLASTOS stack (in particular
#   unified-operator/UCSS) was ever deployed - do this exactly once per
#   cluster lifecycle, not per test run. This script used to apply/remove
#   labels itself on every invocation; that's gone (see below) because a
#   live investigation traced a genuine, severe bottleneck to it: UCSS's
#   on_node_event handler runs _run_conflict_scan (a full cluster-wide
#   pod LIST, since UCSS_CONFLICT_ON_RECONFIG defaults to "event" here,
#   not "warn") on every node whose topology actually changes, and
#   update-labels.sh's data-sovereignty policy re-randomizes one EU and
#   one US region string on every call - a genuine label VALUE change,
#   every time, for every one of ~100 nodes. Relabeling once per test run
#   (as this harness always has) meant ~100-200 redundant full-cluster
#   pod LISTs firing back-to-back at the start of every single run,
#   confirmed live to delay UCSS's CSI update for a newly-classified
#   AppGroup by ~36 seconds - dwarfing anything either appclass_operator
#   fix (d9c8427, appclass-fastpath-scoped-classify) changes, since the
#   bottleneck isn't in appclass_operator's classification speed at all.
#   This also isn't realistic: production node topology labels are set
#   once at provisioning and essentially never change afterward - relabel
#   churn on every benchmark run was a harness artifact, not something
#   this benchmark should have been measuring in the first place.
# - The KLASTOS stack already deployed (deploy-klastos-stack.sh) on this
#   cluster (AFTER the labels above), including the OPA admission
#   controller - and harness/policy/opa-servicemonitor.yaml applied AFTER
#   the first-ever Prometheus-enabled clusterloader run on this cluster
#   (same Prometheus-CRD timing caveat as gatekeeper-metrics-exporter/'s
#   own PodMonitors - see test/env/setup-kind-kwok-manual.sh).

set -euo pipefail

NODES="${NODES:-100}"
CL2_SCHEDULER_THROUGHPUT_PODS="${CL2_SCHEDULER_THROUGHPUT_PODS:-1000}"
CLASSES="${CLASSES:-vanilla eu us italynorth}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Auto-detect klastos's root under either layout this harness is actually run
# from: (a) k8s-secure-scheduling checked out as klastos's own submodule
# (klastos/k8s-secure-scheduling/) - two levels up from here (test/) is
# klastos's own root; (b) the two repos checked out as separate SIBLING
# repos (e.g. ~/githubrepos/klastos + ~/githubrepos/k8s-secure-scheduling) -
# one level up from here, then into a sibling `klastos/` directory. Tries
# (a) first, then (b), before falling back to (a)'s guess so the error
# message below still names a sensible path. An explicit KLASTOS_REPO always
# wins over either guess. Confirmed live: guessing only (a) unconditionally
# silently computed a nonexistent path in the sibling layout (one directory
# short of klastos, at the two repos' shared parent,
# e.g. ~/githubrepos/experiment1/... instead of
# ~/githubrepos/klastos/experiment1/...) with no indication the wrong
# checkout was even being probed.
if [ -z "${KLASTOS_REPO:-}" ]; then
  if [ -d "$SCRIPT_DIR/../../experiment1" ]; then
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
  elif [ -d "$SCRIPT_DIR/../../klastos/experiment1" ]; then
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../../klastos" && pwd)
  else
    KLASTOS_REPO=$(cd "$SCRIPT_DIR/../.." && pwd)
  fi
fi
HARNESS_DIR="$KLASTOS_REPO/experiment1/data-sovereignty/harness"

if [ ! -d "$HARNESS_DIR" ]; then
  echo "ERROR: $HARNESS_DIR not found. Set KLASTOS_REPO to your klastos checkout." >&2
  exit 1
fi

echo -e "[*] Apply shared KLASTOS classification schema (AppClass + AppInfoDefinition)"
"$HARNESS_DIR/apply-shared-policy.sh"
echo

for CLASS in $CLASSES; do
  echo -e "\n=== Class: $CLASS (N=$CL2_SCHEDULER_THROUGHPUT_PODS) ==="

  echo -e "[*] Apply $CLASS policy (CSC + AppGroup)"
  "$HARNESS_DIR/apply-class-policy.sh" "$CLASS" "$CL2_SCHEDULER_THROUGHPUT_PODS"

  mkdir -p "$SCRIPT_DIR/result/use-case/data-sovereignty-klastos-test/$CLASS"

  OVERRIDE_ARGS=()
  if [ "$CLASS" != "vanilla" ]; then
    OVERRIDE_ARGS=(--testoverrides="$SCRIPT_DIR/use-case/data-sovereignty-klastos/${CLASS}-region/override.yaml")
  fi

  echo -e "\n[*] Run $CLASS clusterloader pass"
  CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""' \
  CL2_PROMETHEUS_TOLERATE_MASTER=true \
  CL2_SCHEDULER_THROUGHPUT_PODS="$CL2_SCHEDULER_THROUGHPUT_PODS" \
      "$SCRIPT_DIR/clusterloader" --alsologtostderr --logtostderr=false \
      --enable-prometheus-server="${CL2_ENABLE_PROMETHEUS:-true}" \
      --tear-down-prometheus-server="${CL2_TEARDOWN_PROMETHEUS:-false}" \
      --prometheus-apiserver-scrape-port=6443 \
      --prometheus-pvc-storage-class=standard \
      --prometheus-ready-timeout="${CL2_PROMETHEUS_READY_TIMEOUT:-0}" \
      --log_file="$SCRIPT_DIR/result/use-case/data-sovereignty-klastos-test/$CLASS.log" \
      --report-dir="$SCRIPT_DIR/result/use-case/data-sovereignty-klastos-test/$CLASS" \
      --testconfig="$SCRIPT_DIR/use-case/data-sovereignty-klastos/config-klastos.yaml" \
      "${OVERRIDE_ARGS[@]}" \
      --nodes="$NODES" --provider="${CL2_PROVIDER:-kind}" --kubeconfig="${KUBECONFIG:-$HOME/.kube/config}" --v=2

  echo -e "Look into $SCRIPT_DIR/result/use-case/data-sovereignty-klastos-test/$CLASS for the measurements\n"

  echo -e "[*] Remove $CLASS policy (CSC + AppGroup)"
  "$HARNESS_DIR/delete-class-policy.sh" "$CLASS"
done

echo -e "\n[*] Remove shared KLASTOS classification schema"
"$HARNESS_DIR/delete-shared-policy.sh"
echo
