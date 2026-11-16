#!/usr/bin/env bash
# Experiment 14: many appgroups (Experiment 1 extension, research plan "Synthetic AppGroups N=10 to 500").
#
# G groups x S pods. Each group is its own tenant (its own namespace), its own AppGroup and, for
# KLASTOS, its own tenant class. The pods of one group must land in S DIFFERENT segments
# (anti-affinity among same-tenant pods on topology.kubernetes.io/segment); different groups are
# independent. This is the workload shape of Christoph Baumann's interclass-queue benchmark
# (Nestor-paper full-example/benchmarks/interclass-queue/, copied to klastos
# experiment1/many-appgroups/), moved into the Experiment 1 harness so that:
#   - every arm creates the SAME pods with ClusterLoader2 at the campaign rate (CL2_UNIFORM_QPS),
#     instead of the benchmark's parallel kubectl applies;
#   - every arm is measured the same way: the e2e-latency watcher (creation -> scheduled);
#   - Kyverno and Gatekeeper (injected anti-affinity) can run the same policy.
#
# Arms (ARM, or RUN_KLASTOS=true from run-campaign-n1000.sh):
#   klastos  KLASTOS stack (Profile 2). Policy: AppClass tenant-class (tenant = namespace,
#            identity_namespace AppInfoDefinition), one interClass AntiAffinity CSC (term: Same,
#            topologyKey topology.kubernetes.io/segment, strict) listing the step's G classes, and a
#            Manual Reactive NSP with S segments. klastos experiment1/multi-tenancy/harness-many-appgroups/.
#   kyverno  Kyverno stack. Policy: label tenant-isolation/tenant=<namespace> and a REQUIRED pod
#            anti-affinity on topology.kubernetes.io/segment against pods of the same namespace that
#            carry the label. klastos experiment1/kyverno-baseline/policies/multi-tenancy-many-appgroups.yaml.
#   gkinj    Gatekeeper with the same label and term injected by mutations.
#            klastos experiment1/gatekeeper-injected-baseline/policies/many-appgroups/.
#   For the two baselines the driver writes the segment labels itself, with the same partition the
#   NSP computes (round robin over the sorted schedulable nodes into seg-0..seg-(S-1)).
#
# Modes (MT14_MODES, default "cold warm"), the fairness question of the warm-up:
#   cold  the measured pass is the first time the cluster sees these groups. For KLASTOS it includes
#         classification: the webhook gates a pod it has no class for, the AppClass operator builds
#         the AppInfo of each new appgroup, writes the class-keys, then UCSS releases.
#   warm  an unmeasured warm-up pass creates and deletes the same pods (same namespaces, appgroups and
#         workload labels) first, as the benchmark does. For KLASTOS the sticky AppClass status then
#         lets the webhook resolve the class at admission, and the AppClass operator's AppInfos exist.
#         The webhook still only GATES an interclass pod (it annotates only non-interclass pods), so the
#         AppClass operator writes the class-keys in both modes: warm saves the per-appgroup AppInfo work,
#         not the annotation round trip. Kyverno and Gatekeeper keep no state per application, so for
#         them warm differs from cold only in cluster caches.
#   Every step uses namespaces no earlier step used (prefix mt14-<c|w><HHMMSS>-), so no step is warmed
#   by another, and the AppClass operator's AppInfo cache (keyed by appgroup) cannot hit.
#
# Sweep: MT14_GROUPS (default "10 50 100 250 500") x MT14_GROUP_SIZE (default 4, must be even: each
# CL2 replica creates one pod of workload a and one of workload b). Pods per step = G x S
# (40 .. 2000 by default; 2000 = experiments 8 and 9).
#
# One step = one result directory <arm>-<mode>-g<G>/ (e2e-latency.json, run.log, measurements/;
# for KLASTOS also logs/ with the UCSS, webhook, AppClass and scheduler logs of the measured pass, for
# klastos experiment1/many-appgroups/analyze-admission-release.py).
#
# Usage:
#   RUN_KLASTOS=true ./run-concurrent-multitenancy-many-appgroups-evaluation.sh
#   ARM=kyverno MT14_GROUPS="10 100" MT14_MODES=cold ./run-concurrent-multitenancy-many-appgroups-evaluation.sh
#   DRY_RUN=true ARM=gkinj ./run-concurrent-multitenancy-many-appgroups-evaluation.sh

set -euo pipefail

NODES="${NODES:-100}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/githubrepos/klastos}"
MT14_GROUPS="${MT14_GROUPS:-10 50 100 250 500}"
MT14_GROUP_SIZE="${MT14_GROUP_SIZE:-4}"
MT14_MODES="${MT14_MODES:-cold warm}"
WARMUP_SETTLE_SECONDS="${WARMUP_SETTLE_SECONDS:-30}"
DRY_RUN="${DRY_RUN:-false}"
SEG_KEY="topology.kubernetes.io/segment"

ARM="${ARM:-}"
if [ -z "$ARM" ]; then
  if [ "${RUN_KLASTOS:-false}" = true ]; then ARM=klastos
  elif [ "${RUN_BASELINE:-false}" = true ]; then
    echo "RUN_BASELINE=true: this experiment has no reactive Gatekeeper arm; use ARM=kyverno or ARM=gkinj" >&2; exit 1
  else ARM=klastos; fi
fi
case "$ARM" in klastos|kyverno|gkinj) ;; *) echo "ARM must be klastos, kyverno or gkinj" >&2; exit 1 ;; esac
S="$MT14_GROUP_SIZE"
[ $((S % 2)) -eq 0 ] && [ "$S" -ge 2 ] || { echo "MT14_GROUP_SIZE ($S) must be even and >= 2" >&2; exit 1; }
for m in $MT14_MODES; do case "$m" in cold|warm) ;; *) echo "MT14_MODES: cold and/or warm, got '$m'" >&2; exit 1 ;; esac; done

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
TEST_DIR=$( cd -- "$SCRIPT_DIR/../.." &> /dev/null && pwd )
EXP="$KLASTOS_REPO/experiment1"
HARNESS_DIR="$EXP/multi-tenancy/harness-many-appgroups"
KYVERNO_DIR="$EXP/kyverno-baseline"
GKI_DIR="$EXP/gatekeeper-injected-baseline"
USE_CASE=multi-tenancy-many-appgroups

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

if [ "$DRY_RUN" = true ]; then
  echo "DRY-RUN: arm $ARM, modes: $MT14_MODES, groups: $MT14_GROUPS, group size $S"
  case "$ARM" in
    klastos) echo "DRY-RUN: once: $HARNESS_DIR/apply-shared-policy.sh $S (AppInfoDefinition + Manual NSP)" ;;
    kyverno) echo "DRY-RUN: once: label $SEG_KEY on the schedulable nodes; $KYVERNO_DIR/apply-policy.sh $USE_CASE" ;;
    gkinj)   echo "DRY-RUN: once: label $SEG_KEY on the schedulable nodes; $GKI_DIR/apply-policy.sh $USE_CASE" ;;
  esac
  for mode in $MT14_MODES; do for G in $MT14_GROUPS; do
    echo "DRY-RUN: step $ARM-$mode-g$G ($((G * S)) pods): namespaces mt14-${mode:0:1}<HHMMSS>-g1..g$G" \
         "$([ "$ARM" = klastos ] && echo "+ apply-step-policy.sh (AppClass, CSC for $G classes, AppGroups)")"
    [ "$mode" = warm ] && echo "DRY-RUN:   warm-up CL2 pass (not measured), wait for its pods to be gone, settle ${WARMUP_SETTLE_SECONDS}s"
    echo "DRY-RUN:   measured CL2 pass with the e2e-latency watcher; delete the namespaces"
  done; done
  echo "DRY-RUN: remove the policy and the $SEG_KEY labels; generate-report.py"
  exit 0
fi

# --- preflight ------------------------------------------------------------------------------------
present() { kubectl -n "$1" get "$2" >/dev/null 2>&1; }
preflight() {
  [ -x "$TEST_DIR/clusterloader" ] || { echo "Preflight failed: $TEST_DIR/clusterloader missing" >&2; return 1; }
  [ -d "$HARNESS_DIR" ] || { echo "Preflight failed: $HARNESS_DIR not found (KLASTOS_REPO=$KLASTOS_REPO)" >&2; return 1; }
  local k=false; present kube-system pod/unified-operator && k=true
  case "$ARM" in
    klastos)
      [ "$k" = true ] || { echo "Preflight failed: the KLASTOS stack (unified-operator) is not deployed" >&2; return 1; }
      present kube-system deployment/csi-admission || { echo "Preflight failed: csi-admission (Profile 2) is not deployed" >&2; return 1; }
      local other
      other=$(kubectl get appinfodefinitions -A -o name 2>/dev/null | grep -vc '/multi-tenancy-policy$' || true)
      [ "${other:-0}" -eq 0 ] || { echo "Preflight failed: another AppInfoDefinition is installed (the AppClass operator needs exactly one):"; kubectl get appinfodefinitions -A; return 1; } >&2 ;;
    kyverno)
      [ "$k" = false ] || { echo "Preflight failed: the KLASTOS stack is deployed" >&2; return 1; }
      present kyverno deployment/kyverno-admission-controller || { echo "Preflight failed: Kyverno is not deployed" >&2; return 1; }
      present gatekeeper-system deployment/gatekeeper-controller-manager && { echo "Preflight failed: Gatekeeper is installed" >&2; return 1; } ;;
    gkinj)
      [ "$k" = false ] || { echo "Preflight failed: the KLASTOS stack is deployed" >&2; return 1; }
      present gatekeeper-system deployment/gatekeeper-controller-manager || { echo "Preflight failed: Gatekeeper is not installed" >&2; return 1; }
      present kyverno deployment/kyverno-admission-controller && { echo "Preflight failed: Kyverno is deployed" >&2; return 1; } ;;
  esac
  if pgrep -f "[c]lusterloader --|[e]2e-latency-watch" >/dev/null; then
    echo "Preflight failed: another clusterloader or e2e-latency watcher is running" >&2; return 1
  fi
  local n; n=$(schedulable_nodes | wc -l)
  [ "$n" -ge "$S" ] || { echo "Preflight failed: $n schedulable nodes, a group of $S needs $S segments" >&2; return 1; }
}

# Schedulable worker nodes, sorted: the control-plane node of the kind cluster is untainted (the operators
# run there), so it is excluded explicitly, as in the many-appgroups benchmark copy.
schedulable_nodes() { kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers -o custom-columns=N:.metadata.name | sort; }

# The baselines get the partition the Manual NSP computes for KLASTOS: round robin into seg-0..seg-(S-1).
label_segments() {
  local i=0 n
  while IFS= read -r n; do
    echo "$n seg-$(( i % S ))"; i=$((i + 1))
  done < <(schedulable_nodes) | xargs -P 16 -n 2 sh -c 'kubectl label node "$0" "'"$SEG_KEY"'=$1" --overwrite >/dev/null'
  log "segment labels: $(kubectl get nodes -L "$SEG_KEY" --no-headers | awk '{print $NF}' | sort | uniq -c | tr -s ' ' | tr '\n' ' ')"
}
unlabel_segments() { kubectl label nodes --all "${SEG_KEY}-" >/dev/null 2>&1 || true; }

# --- per-step pieces ------------------------------------------------------------------------------
# CL2 config for one step: the namespace list is the step's G namespaces; one replica = one pod of
# workload a + one of workload b, S/2 replicas per namespace. CL2 resolves objectTemplatePath relative
# to the config, so the config and the two templates are written into the step's own cl2/ directory.
gen_cl2() {  # gen_cl2 <dir> <prefix> <G>
  local d="$1" prefix="$2" G="$3" g list=""
  mkdir -p "$d"
  for g in $(seq 1 "$G"); do list="$list${list:+, }${prefix}g$g"; done
  cp "$SCRIPT_DIR/workload-a.yaml" "$SCRIPT_DIR/workload-b.yaml" "$d/"
  sed -e "s/__NAMESPACES__/$list/" -e "s/__REPLICAS__/$((S / 2))/" -e "s/__TOTAL__/$((G * S))/" \
      "$SCRIPT_DIR/config-concurrent.yaml.tmpl" > "$d/config.yaml"
}

cl2() {  # cl2 <dir> <logname>
  "$TEST_DIR/clusterloader" --alsologtostderr --logtostderr=false \
      --enable-prometheus-server=true \
      --tear-down-prometheus-server=false \
      --prometheus-apiserver-scrape-port=6443 \
      --prometheus-pvc-storage-class=standard \
      --prometheus-ready-timeout=0 \
      --log_file="$1/$2.log" \
      --report-dir="$1/measurements" \
      --testconfig="$1/cl2/config.yaml" \
      --nodes="$NODES" --provider=kind --kubeconfig="$HOME/.kube/config" --v=2
}

create_namespaces() {  # create_namespaces <prefix> <G>
  local g
  for g in $(seq 1 "$2"); do echo "${1}g$g"; done \
    | xargs -P 16 -I{} sh -c 'kubectl create namespace {} --dry-run=client -o yaml | kubectl apply -f - >/dev/null'
}

delete_namespaces() {  # delete_namespaces <prefix>: synchronous, the next step must not share the apiserver with a teardown
  local nss
  nss=$(kubectl get ns --no-headers -o custom-columns=N:.metadata.name | grep "^$1" || true)
  [ -z "$nss" ] && return 0
  # AppGroups carry a finalizer of the Diktyo controller; drop it so the namespace can go
  if [ "$ARM" = klastos ]; then
    for ns in $nss; do echo "$ns"; done | xargs -P 16 -I{} sh -c \
      'for a in $(kubectl -n {} get appgroups -o name 2>/dev/null); do kubectl -n {} patch $a --type=merge -p "{\"metadata\":{\"finalizers\":null}}" >/dev/null 2>&1; done'
  fi
  # shellcheck disable=SC2086
  kubectl delete namespace $nss --wait=true --timeout=300s >/dev/null 2>&1 || log "WARNING: namespaces with prefix $1 not gone after 300 s"
}

wait_pods_gone() {  # wait_pods_gone <prefix> [timeout]
  local i n
  for i in $(seq 1 "${2:-300}"); do
    n=$(kubectl get pods -A --no-headers 2>/dev/null | awk -v p="$1" 'index($1, p) == 1' | wc -l)
    [ "$n" -eq 0 ] && return 0
    sleep 1
  done
  log "WARNING: $n pods with namespace prefix $1 still present"
}

# After the warm-up's deletions: wait until the KLASTOS operators stop writing (CSI resourceVersion stable for
# 10 s), then a fixed settle. Without this, the measured pass of a small G competes with the warm-up's deletions
# in UCSS (seen in the 2026-11-16 benchmark sweep: G=10 measured 12.8 s p50 behind 1227 delete events).
settle() {
  local last="" stable=0 i rv
  if [ "$ARM" = klastos ]; then
    for i in $(seq 1 180); do
      rv=$(kubectl get csi cluster-scheduling-info -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo none)
      if [ "$rv" = "$last" ]; then stable=$((stable + 1)); else stable=0; last="$rv"; fi
      [ "$stable" -ge 10 ] && break
      sleep 1
    done
  fi
  sleep "$WARMUP_SETTLE_SECONDS"
}

capture_klastos_logs() {  # capture_klastos_logs <dir> <since>
  local d="$1/logs" since="$2" sp
  mkdir -p "$d"
  kubectl -n kube-system logs unified-operator --since-time="$since" > "$d/ucss.log" 2>/dev/null || true
  kubectl -n kube-system logs appclass-operator --since-time="$since" --timestamps > "$d/appclass.log" 2>/dev/null || true
  kubectl -n kube-system logs -l app=csi-admission --prefix --max-log-requests 20 --tail=-1 \
      --since-time="$since" --timestamps > "$d/webhook.log" 2>/dev/null || true
  sp=$(kubectl -n diktyo get pods -l component=scheduler --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | head -1)
  [ -z "$sp" ] || kubectl -n diktyo logs "$sp" --since-time="$since" --timestamps > "$d/scheduler.log" 2>/dev/null || true
  return 0
}

# Correctness of a measured pass: CL2 deletes its pods at the end, so the bindings are recorded by a watch
# during the pass (placements.txt: namespace, pod, node) and checked afterwards against the segment labels:
# no two pods of a group (namespace) on the same segment, and every pod placed.
start_placement_watch() {  # start_placement_watch <dir>; sets PW_PID
  kubectl get nodes --no-headers -o custom-columns=N:.metadata.name,S:".metadata.labels.topology\.kubernetes\.io/segment" > "$1/node-segments.txt"
  kubectl get pods -A --watch --no-headers \
      -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName > "$1/placements.txt" 2>/dev/null &
  PW_PID=$!
}
check_isolation() {  # check_isolation <dir> <prefix> <expected pods>
  kill "$PW_PID" 2>/dev/null || true; wait "$PW_PID" 2>/dev/null || true
  python3 - "$1" "$2" "$3" <<'PYCHECK' | tee "$1/isolation.txt"
import collections, sys
d, prefix, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
seg = dict(l.split()[:2] for l in open(d + "/node-segments.txt") if len(l.split()) >= 2)
node = {}
for l in open(d + "/placements.txt"):
    f = l.split()
    if len(f) == 3 and f[0].startswith(prefix) and f[2] != "<none>":
        node[(f[0], f[1])] = f[2]          # a pod binds once; the last bound node wins
per = collections.defaultdict(collections.Counter)
for (ns, _), n in node.items():
    per[ns][seg.get(n, "?")] += 1
bad = [ns for ns, c in per.items() if any(v > 1 for v in c.values()) or "?" in c or "<none>" in c]
print("isolation: %d of %d pods placed; %d groups; groups with two pods on one segment (or an unsegmented node): %d%s"
      % (len(node), want, len(per), len(bad), (" e.g. %s %s" % (bad[0], dict(per[bad[0]]))) if bad else ""))
print("ISOLATION " + ("OK" if not bad and len(node) == want else "VIOLATED"))
PYCHECK
}

# --- run ------------------------------------------------------------------------------------------
preflight
RESULT_ROOT="$TEST_DIR/result/use-case/concurrent-multitenancy-many-appgroups-$ARM-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"
{
  echo "arm: $ARM"; echo "modes: $MT14_MODES"; echo "groups: $MT14_GROUPS"; echo "group_size: $S"
  echo "cl2_uniform_qps: ${CL2_UNIFORM_QPS:-default}"; echo "warmup_settle_seconds: $WARMUP_SETTLE_SECONDS"
  case "$ARM" in
    klastos) kubectl -n kube-system get pods unified-operator appclass-operator -o jsonpath='{range .items[*]}{.metadata.name}: {.status.containerStatuses[0].imageID}{"\n"}{end}' 2>/dev/null
             kubectl -n kube-system get pods -l app=csi-admission -o jsonpath='{range .items[*]}{.metadata.name}: {.status.containerStatuses[0].imageID}{"\n"}{end}' 2>/dev/null ;;
    kyverno) kubectl -n kyverno get deployment kyverno-admission-controller -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' ;;
    gkinj)   kubectl -n gatekeeper-system get deployment gatekeeper-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' ;;
  esac
  echo "klastos: $(git -C "$KLASTOS_REPO" rev-parse --short HEAD 2>/dev/null)"
  echo "k8s-secure-scheduling: $(git -C "$TEST_DIR" rev-parse --short HEAD 2>/dev/null)"
} > "$RESULT_ROOT/ARM.txt" 2>&1
# kyverno-baseline/run-kyverno-evaluation.sh writes ENGINE.txt; keep the same file for the two baselines
[ "$ARM" = klastos ] || { [ "$ARM" = kyverno ] && echo kyverno || echo gatekeeper-injected; } > "$RESULT_ROOT/ENGINE.txt"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

echo "=== Experiment 14: many appgroups ($ARM arm) ==="
echo "Modes: $MT14_MODES   Groups: $MT14_GROUPS   Group size: $S"
echo "Results:      $RESULT_ROOT"
echo ""

cleanup() {
  log "cleanup: namespaces mt14-*, $ARM policy, $SEG_KEY labels"
  delete_namespaces mt14-
  case "$ARM" in
    klastos) "$HARNESS_DIR/delete-step-policy.sh" >/dev/null 2>&1 || true
             "$HARNESS_DIR/delete-shared-policy.sh" >/dev/null 2>&1 || true ;;
    kyverno) "$KYVERNO_DIR/delete-policy.sh" "$USE_CASE" >/dev/null 2>&1 || true ;;
    gkinj)   "$GKI_DIR/delete-policy.sh" "$USE_CASE" >/dev/null 2>&1 || true ;;
  esac
  unlabel_segments
}
trap cleanup EXIT

# leftovers of a killed run would share the cluster with this one
delete_namespaces mt14-
case "$ARM" in
  klastos) unlabel_segments; "$HARNESS_DIR/apply-shared-policy.sh" "$S" ;;
  kyverno) label_segments; "$KYVERNO_DIR/apply-policy.sh" "$USE_CASE" ;;
  gkinj)   label_segments; "$GKI_DIR/apply-policy.sh" "$USE_CASE" ;;
esac

FAILED=false
for mode in $MT14_MODES; do
  for G in $MT14_GROUPS; do
    STEP="$ARM-$mode-g$G"
    STEP_DIR="$RESULT_ROOT/$STEP"
    PREFIX="mt14-${mode:0:1}$(date -u +%H%M%S)-"
    TOTAL=$((G * S))
    THRESHOLD=$(concurrent_threshold_for "$TOTAL")
    mkdir -p "$STEP_DIR"
    echo "--- Step $STEP: $G groups x $S pods = $TOTAL pods, namespaces ${PREFIX}g1..g$G (threshold=$THRESHOLD pods/sec, violations=$(concurrent_violations_state)) ---"
    echo "namespace_prefix: $PREFIX" > "$STEP_DIR/step.txt"
    gen_cl2 "$STEP_DIR/cl2" "$PREFIX" "$G"

    # setup, not measured: namespaces (+ KLASTOS: AppClass, CSC for these G classes, AppGroups)
    {
      create_namespaces "$PREFIX" "$G"
      [ "$ARM" != klastos ] || "$HARNESS_DIR/apply-step-policy.sh" "$PREFIX" "$G" "$S"
    } > "$STEP_DIR/setup.log" 2>&1 || { echo "    FAILED: setup (see $STEP_DIR/setup.log)"; FAILED=true; break 2; }

    if [ "$mode" = warm ]; then
      log "warm-up pass (not measured)"
      mkdir -p "$STEP_DIR/warmup"; cp -r "$STEP_DIR/cl2" "$STEP_DIR/warmup/cl2"
      export CL2_SCHEDULER_THROUGHPUT_PODS="$TOTAL" CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD"
      export CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""' CL2_PROMETHEUS_TOLERATE_MASTER=true
      if ! cl2 "$STEP_DIR/warmup" warmup > "$STEP_DIR/warmup/run.log" 2>&1; then
        echo "    FAILED: warm-up pass (see $STEP_DIR/warmup/run.log)"; FAILED=true; break 2
      fi
      unset CL2_SCHEDULER_THROUGHPUT_PODS CL2_SCHEDULER_THROUGHPUT_THRESHOLD CL2_PROMETHEUS_NODE_SELECTOR CL2_PROMETHEUS_TOLERATE_MASTER
      # generate-report.py makes a row of every directory with a junit.xml, and would give the warm-up the
      # measured pass's e2e-latency.json (it looks upward for it): keep the warm-up out of the report
      find "$STEP_DIR/warmup" -name junit.xml -exec sh -c 'mv "$1" "${1%.xml}-warmup.xml"' _ {} \;
      wait_pods_gone "$PREFIX"
      log "settling after the warm-up's deletions"
      settle
    fi

    SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    echo "measured_start: $SINCE" >> "$STEP_DIR/step.txt"
    measured() { cl2 "$STEP_DIR" "$ARM"; }
    start_placement_watch "$STEP_DIR"
    if ! concurrent_run_step "$STEP_DIR" "$TOTAL" "$THRESHOLD" measured; then FAILED=true; fi
    check_isolation "$STEP_DIR" "$PREFIX" "$TOTAL" | sed 's/^/    /'
    [ "$ARM" != klastos ] || capture_klastos_logs "$STEP_DIR" "$SINCE"

    # teardown of the step, not measured
    delete_namespaces "$PREFIX"
    [ "$ARM" != klastos ] || "$HARNESS_DIR/delete-step-policy.sh" >> "$STEP_DIR/setup.log" 2>&1 || true
    if [ "$FAILED" = true ]; then break 2; fi
  done
done

if [ "$FAILED" = true ]; then
  echo ""
  echo "Stopping: step $STEP failed."
  exit 1
fi
concurrent_finalize "$RESULT_ROOT"
