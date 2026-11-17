#!/usr/bin/env bash
# Experiment 14: many tenants (Experiment 1 extension, research plan "Synthetic AppGroups N=10 to 500").
#
# Experiments 8 and 9 isolate 2 tenants x N=1000 pods. Experiment 14 keeps their policy and their load and changes
# only the structure: the same 2000 pods, created by ClusterLoader2 at the campaign rate (CL2_UNIFORM_QPS, 40/s),
# split over G tenants of S = 2000/G pods. Each tenant is its own namespace, its own AppGroup (workloads a and b,
# ceil(S/2) and floor(S/2) pods) and, for KLASTOS, its own tenant class.
#
# The rule is experiment 9's: pods of DIFFERENT tenants never share a node (strict anti-affinity on
# kubernetes.io/hostname), and a tenant's pods prefer the same node (soft affinity), so each tenant packs onto
# nodes of its own. A tenant of at most 110 pods fits on one KWOK node, so G is bounded by the 100 nodes: the
# default sweep is G = 40, 50, 80, 100 (S = 50, 40, 25, 20); G = 100 needs exactly one node per tenant.
#
# Arms (ARM, or RUN_KLASTOS=true from run-campaign-n1000.sh):
#   klastos  KLASTOS stack (Profile 2). AppClass tenant-class (tenant = namespace, identity_namespace
#            AppInfoDefinition) and experiment 9's CSC (classSelector All, scope Workload).
#            klastos experiment1/multi-tenancy/harness-many-tenants/.
#   klastospc  KLASTOS stack, the same two terms both STRICT and classSelector In with the step's G tenant classes
#            named: the true-isolation idiom, which UCSS pre-compiles into one dedicated node per tenant class
#            (Nestor-paper class-scheduling-operator DESIGN.md 1c), so the tenants skip the interclass release path.
#            apply-step-policy.sh <prefix> <G> <S> precompiled.
#   kyverno  Kyverno stack. Label tenant-isolation/tenant=<namespace>, a REQUIRED pod anti-affinity against labelled
#            pods of other tenants (experiment 8's term) and a PREFERRED pod affinity to the own tenant's pods.
#            One policy for all tenants. klastos experiment1/kyverno-baseline/policies/multi-tenancy-many-tenants.yaml.
#   gkinj    Gatekeeper with the same label and terms injected by mutations; the anti-affinity term needs the
#            tenant's own value, so it is one Assign per tenant, created per step (not measured).
#            klastos experiment1/gatekeeper-injected-baseline/policies/many-tenants/ + apply-tenant-mutations.sh.
#
# Modes (MT14_MODES, default "cold warm"):
#   cold  the measured pass is the first time the cluster sees these tenants. For KLASTOS it includes
#         classification: the webhook gates a pod it has no class for, the AppClass operator builds the AppInfo of
#         each new appgroup and writes the class-keys, then UCSS releases.
#   warm  an unmeasured warm-up pass creates and deletes the same pods (same namespaces, appgroups and workload
#         labels) first. For KLASTOS the sticky AppClass status then lets the webhook resolve the class at
#         admission, and the AppClass operator's AppInfos exist. The webhook still only GATES an interclass pod (it
#         annotates only non-interclass pods), so the AppClass operator writes the class-keys in both modes: warm
#         saves the per-appgroup AppInfo work, not the annotation round trip. In klastospc the tenant classes are
#         topology classes, not interclass ones, so there the webhook can take its fast path for a warm pod:
#         annotate it at admission and admit it without a gate (csi-gate-webhook README, step 5). Kyverno and Gatekeeper keep no state
#         per application, so for them warm differs from cold only in cluster caches.
#   Every step uses namespaces no earlier step used (prefix mt14-<c|w><HHMMSS>-), so no step is warmed by another.
#
# A failed step is recorded and the sweep goes on with the next step (a G the cluster cannot place must not cost
# the other steps); the run exits 1 at the end, so run-repeated-script.sh excludes the repeat from the stats.
#
# One step = one result directory <arm>-<mode>-g<G>/ (e2e-latency.json, run.log, measurements/, isolation.txt;
# for KLASTOS also logs/ with the UCSS, webhook, AppClass and scheduler logs of the measured pass, for
# klastos experiment1/many-appgroups/analyze-admission-release.py).
#
# Usage:
#   RUN_KLASTOS=true ./run-concurrent-multitenancy-many-tenants-evaluation.sh
#   ARM=klastospc ./run-concurrent-multitenancy-many-tenants-evaluation.sh
#   ARM=kyverno MT14_GROUPS="40 100" MT14_MODES=cold ./run-concurrent-multitenancy-many-tenants-evaluation.sh
#   DRY_RUN=true ARM=gkinj ./run-concurrent-multitenancy-many-tenants-evaluation.sh

set -euo pipefail

NODES="${NODES:-100}"
KLASTOS_REPO="${KLASTOS_REPO:-$HOME/githubrepos/klastos}"
MT14_GROUPS="${MT14_GROUPS:-40 50 80 100}"
MT14_TOTAL_PODS="${MT14_TOTAL_PODS:-2000}"
MT14_MODES="${MT14_MODES:-cold warm}"
WARMUP_SETTLE_SECONDS="${WARMUP_SETTLE_SECONDS:-30}"
DRY_RUN="${DRY_RUN:-false}"

ARM="${ARM:-}"
if [ -z "$ARM" ]; then
  if [ "${RUN_KLASTOS:-false}" = true ]; then ARM=klastos
  elif [ "${RUN_BASELINE:-false}" = true ]; then
    echo "RUN_BASELINE=true: this experiment has no reactive Gatekeeper arm; use ARM=kyverno or ARM=gkinj" >&2; exit 1
  else ARM=klastos; fi
fi
case "$ARM" in klastos|klastospc|kyverno|gkinj) ;; *) echo "ARM must be klastos, klastospc, kyverno or gkinj" >&2; exit 1 ;; esac
# KL: the arm runs on the KLASTOS stack; CSC_VARIANT: the CSC of apply-step-policy.sh
KL=false; CSC_VARIANT=reactive
case "$ARM" in klastos) KL=true ;; klastospc) KL=true; CSC_VARIANT=precompiled ;; esac
for m in $MT14_MODES; do case "$m" in cold|warm) ;; *) echo "MT14_MODES: cold and/or warm, got '$m'" >&2; exit 1 ;; esac; done
for G in $MT14_GROUPS; do
  [ $((MT14_TOTAL_PODS % G)) -eq 0 ] && [ $((MT14_TOTAL_PODS / G)) -ge 2 ] \
    || { echo "MT14_GROUPS: $G does not divide $MT14_TOTAL_PODS into tenants of at least 2 pods" >&2; exit 1; }
done

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
TEST_DIR=$( cd -- "$SCRIPT_DIR/../.." &> /dev/null && pwd )
EXP="$KLASTOS_REPO/experiment1"
HARNESS_DIR="$EXP/multi-tenancy/harness-many-tenants"
KYVERNO_DIR="$EXP/kyverno-baseline"
GKI_DIR="$EXP/gatekeeper-injected-baseline"
USE_CASE=multi-tenancy-many-tenants

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

if [ "$DRY_RUN" = true ]; then
  echo "DRY-RUN: arm $ARM, modes: $MT14_MODES, tenants: $MT14_GROUPS, $MT14_TOTAL_PODS pods per step"
  case "$ARM" in
    klastos|klastospc) echo "DRY-RUN: once: $HARNESS_DIR/apply-shared-policy.sh (AppInfoDefinition)" ;;
    kyverno) echo "DRY-RUN: once: $KYVERNO_DIR/apply-policy.sh $USE_CASE" ;;
    gkinj)   echo "DRY-RUN: once: $GKI_DIR/apply-policy.sh $USE_CASE" ;;
  esac
  for mode in $MT14_MODES; do for G in $MT14_GROUPS; do
    S=$((MT14_TOTAL_PODS / G))
    echo "DRY-RUN: step $ARM-$mode-g$G: $G tenants x $S pods ($(( (S + 1) / 2 )) a + $((S / 2)) b), namespaces mt14-${mode:0:1}<HHMMSS>-g1..g$G" \
         "$(case "$ARM" in klastos|klastospc) echo "+ apply-step-policy.sh (AppClass, $CSC_VARIANT CSC, $G AppGroups)" ;; gkinj) echo "+ apply-tenant-mutations.sh ($G Assigns)" ;; esac)"
    [ "$mode" = warm ] && echo "DRY-RUN:   warm-up CL2 pass (not measured), wait for its pods to be gone, settle ${WARMUP_SETTLE_SECONDS}s"
    echo "DRY-RUN:   measured CL2 pass with the e2e-latency watcher; isolation check; delete the namespaces"
  done; done
  echo "DRY-RUN: remove the policy; generate-report.py"
  exit 0
fi

# --- preflight ------------------------------------------------------------------------------------
present() { kubectl -n "$1" get "$2" >/dev/null 2>&1; }
preflight() {
  [ -x "$TEST_DIR/clusterloader" ] || { echo "Preflight failed: $TEST_DIR/clusterloader missing" >&2; return 1; }
  [ -d "$HARNESS_DIR" ] || { echo "Preflight failed: $HARNESS_DIR not found (KLASTOS_REPO=$KLASTOS_REPO)" >&2; return 1; }
  local k=false; present kube-system pod/unified-operator && k=true
  case "$ARM" in
    klastos|klastospc)
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
  local n G; n=$(kubectl get nodes --no-headers | wc -l)
  for G in $MT14_GROUPS; do
    [ "$n" -ge "$G" ] || { echo "Preflight failed: $n nodes, $G tenants need a node each" >&2; return 1; }
  done
}

# --- per-step pieces ------------------------------------------------------------------------------
# CL2 config for one step, from config-concurrent.yaml.tmpl: one phase per tenant and workload, as experiments 8 and
# 9 have one per class and workload. The phases of a CL2 step run in parallel and share the global UniformQPS
# budget (CL2_UNIFORM_QPS_GLOBAL=true in the campaign), so the tenants' pods arrive interleaved, as uc1 and uc2 do
# there. CL2 resolves objectTemplatePath relative to the config, so the config and the two pod templates are
# written into the step's own cl2/ directory.
gen_cl2() {  # gen_cl2 <dir> <prefix> <G> <S>
  local d="$1" prefix="$2" G="$3" S="$4" g ns w r
  local ra=$(( (S + 1) / 2 )) rb=$((S / 2))
  mkdir -p "$d"
  cp "$SCRIPT_DIR/workload-a.yaml" "$SCRIPT_DIR/workload-b.yaml" "$d/"
  phases() {  # phases <replicas a> <replicas b> <tuningSet>
    for g in $(seq 1 "$G"); do
      ns="${prefix}g$g"
      for w in a b; do
        if [ "$w" = a ]; then r="$1"; else r="$2"; fi
        cat <<YAML
  - namespaceList: [$ns]
    replicasPerNamespace: $r
    tuningSet: $3
    objectBundle:
    - basename: klastos-mt14-$w
      objectTemplatePath: workload-$w.yaml
      templateFillMap:
        Group: direct-scheduler-throughput
YAML
      done
    done
  }
  phases "$ra" "$rb" UniformQPS > "$d/.create"
  phases 0 0 default > "$d/.delete"
  awk -v total=$((G * S)) -v create="$d/.create" -v del="$d/.delete" '
    /^__CREATE_PHASES__$/ { while ((getline l < create) > 0) print l; next }
    /^__DELETE_PHASES__$/ { while ((getline l < del) > 0) print l; next }
    { gsub(/__TOTAL__/, total); print }' "$SCRIPT_DIR/config-concurrent.yaml.tmpl" > "$d/config.yaml"
  rm -f "$d/.create" "$d/.delete"
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
  if [ "$KL" = true ]; then
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
# 10 s), then a fixed settle. Without this, the measured pass competes with the warm-up's deletions in UCSS (seen
# in the 2026-11-16 benchmark sweep: G=10 measured 12.8 s p50 behind 1227 delete events).
settle() {
  local last="" stable=0 i rv
  if [ "$KL" = true ]; then
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
  # CSI size at the end of the pass: it grows with tenant classes x nodes, and has to fit one etcd request (1.5 MiB)
  kubectl get csi cluster-scheduling-info -o json 2>/dev/null | wc -c > "$d/csi-bytes.txt" || true
  return 0
}

# Correctness of a measured pass: CL2 deletes its pods at the end, so the bindings are recorded by a watch during
# the pass (placements.txt: namespace, pod, node) and checked afterwards: no node hosts pods of two tenants
# (namespaces), and every pod is placed. Also reported: nodes per tenant (1 = fully packed).
start_placement_watch() {  # start_placement_watch <dir>; sets PW_PID
  kubectl get pods -A --watch --no-headers \
      -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,NODE:.spec.nodeName > "$1/placements.txt" 2>/dev/null &
  PW_PID=$!
}
check_isolation() {  # check_isolation <dir> <prefix> <expected pods>
  kill "$PW_PID" 2>/dev/null || true; wait "$PW_PID" 2>/dev/null || true
  python3 - "$1" "$2" "$3" <<'PYCHECK' | tee "$1/isolation.txt"
import collections, sys
d, prefix, want = sys.argv[1], sys.argv[2], int(sys.argv[3])
node = {}
for l in open(d + "/placements.txt"):
    f = l.split()
    if len(f) == 3 and f[0].startswith(prefix) and f[2] != "<none>":
        node[(f[0], f[1])] = f[2]          # a pod binds once; the last bound node wins
tenants_on = collections.defaultdict(set)
nodes_of = collections.defaultdict(set)
for (ns, _), n in node.items():
    tenants_on[n].add(ns)
    nodes_of[ns].add(n)
shared = sorted(n for n, t in tenants_on.items() if len(t) > 1)
per = sorted(len(v) for v in nodes_of.values()) or [0]
print("isolation: %d of %d pods placed; %d tenants on %d nodes; nodes per tenant min %d / median %d / max %d; "
      "nodes hosting two tenants: %d%s"
      % (len(node), want, len(nodes_of), len(tenants_on), per[0], per[len(per) // 2], per[-1], len(shared),
         (" e.g. %s %s" % (shared[0], sorted(tenants_on[shared[0]]))) if shared else ""))
print("ISOLATION " + ("OK" if not shared and len(node) == want else "VIOLATED"))
PYCHECK
}

# --- run ------------------------------------------------------------------------------------------
preflight
RESULT_ROOT="$TEST_DIR/result/use-case/concurrent-multitenancy-many-tenants-$ARM-evaluation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULT_ROOT"
{
  echo "arm: $ARM"; echo "modes: $MT14_MODES"; echo "tenants: $MT14_GROUPS"; echo "pods_per_step: $MT14_TOTAL_PODS"
  echo "cl2_uniform_qps: ${CL2_UNIFORM_QPS:-default}"; echo "warmup_settle_seconds: $WARMUP_SETTLE_SECONDS"
  case "$ARM" in
    klastos|klastospc) kubectl -n kube-system get pods unified-operator appclass-operator -o jsonpath='{range .items[*]}{.metadata.name}: {.status.containerStatuses[0].imageID}{"\n"}{end}' 2>/dev/null
             kubectl -n kube-system get pods -l app=csi-admission -o jsonpath='{range .items[*]}{.metadata.name}: {.status.containerStatuses[0].imageID}{"\n"}{end}' 2>/dev/null ;;
    kyverno) kubectl -n kyverno get deployment kyverno-admission-controller -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' ;;
    gkinj)   kubectl -n gatekeeper-system get deployment gatekeeper-controller-manager -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}' ;;
  esac
  echo "klastos: $(git -C "$KLASTOS_REPO" rev-parse --short HEAD 2>/dev/null)"
  echo "k8s-secure-scheduling: $(git -C "$TEST_DIR" rev-parse --short HEAD 2>/dev/null)"
} > "$RESULT_ROOT/ARM.txt" 2>&1
# kyverno-baseline/run-kyverno-evaluation.sh writes ENGINE.txt; keep the same file for the two baselines
[ "$KL" = true ] || { [ "$ARM" = kyverno ] && echo kyverno || echo gatekeeper-injected; } > "$RESULT_ROOT/ENGINE.txt"

# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

echo "=== Experiment 14: many tenants ($ARM arm) ==="
echo "Modes: $MT14_MODES   Tenants: $MT14_GROUPS   Pods per step: $MT14_TOTAL_PODS"
echo "Results:      $RESULT_ROOT"
echo ""

cleanup() {
  log "cleanup: namespaces mt14-*, $ARM policy"
  delete_namespaces mt14-
  case "$ARM" in
    klastos|klastospc) "$HARNESS_DIR/delete-step-policy.sh" >/dev/null 2>&1 || true
             "$HARNESS_DIR/delete-shared-policy.sh" >/dev/null 2>&1 || true ;;
    kyverno) "$KYVERNO_DIR/delete-policy.sh" "$USE_CASE" >/dev/null 2>&1 || true ;;
    gkinj)   "$GKI_DIR/delete-policy.sh" "$USE_CASE" >/dev/null 2>&1 || true ;;
  esac
}
trap cleanup EXIT

# leftovers of a killed run would share the cluster with this one
delete_namespaces mt14-
case "$ARM" in
  klastos|klastospc) "$HARNESS_DIR/apply-shared-policy.sh" ;;
  kyverno) "$KYVERNO_DIR/apply-policy.sh" "$USE_CASE" ;;
  gkinj)   "$GKI_DIR/delete-tenant-mutations.sh"; "$GKI_DIR/apply-policy.sh" "$USE_CASE" ;;
esac

# The CL2 threshold and violations are those of experiments 8 and 9: concurrent_threshold_for gets N per class
# there (1000 of 2000 pods), so it gets half the step's pods here. The campaign turns violations off anyway.
THRESHOLD=$(concurrent_threshold_for $((MT14_TOTAL_PODS / 2)))
FAILED_STEPS=""
for mode in $MT14_MODES; do
  for G in $MT14_GROUPS; do
    S=$((MT14_TOTAL_PODS / G))
    STEP="$ARM-$mode-g$G"
    STEP_DIR="$RESULT_ROOT/$STEP"
    PREFIX="mt14-${mode:0:1}$(date -u +%H%M%S)-"
    TOTAL=$((G * S))
    ok=true
    mkdir -p "$STEP_DIR"
    echo "--- Step $STEP: $G tenants x $S pods = $TOTAL pods, namespaces ${PREFIX}g1..g$G (threshold=$THRESHOLD pods/sec, violations=$(concurrent_violations_state)) ---"
    printf 'namespace_prefix: %s\ntenants: %s\npods_per_tenant: %s\n' "$PREFIX" "$G" "$S" > "$STEP_DIR/step.txt"
    gen_cl2 "$STEP_DIR/cl2" "$PREFIX" "$G" "$S"

    # setup, not measured: namespaces (+ KLASTOS: AppClass, CSC, AppGroups; + gkinj: one Assign per tenant)
    if ! {
      create_namespaces "$PREFIX" "$G"
      case "$ARM" in
        klastos|klastospc) "$HARNESS_DIR/apply-step-policy.sh" "$PREFIX" "$G" "$S" "$CSC_VARIANT" ;;
        gkinj)   "$GKI_DIR/apply-tenant-mutations.sh" "$PREFIX" "$G" ;;
      esac
    } > "$STEP_DIR/setup.log" 2>&1; then
      echo "    FAILED: setup (see $STEP_DIR/setup.log)"; ok=false
    fi
    [ "$CSC_VARIANT" != precompiled ] || grep -h "^isolation pins:" "$STEP_DIR/setup.log" | sed 's/^/    /' || true

    if [ "$ok" = true ] && [ "$mode" = warm ]; then
      log "warm-up pass (not measured)"
      mkdir -p "$STEP_DIR/warmup"; cp -r "$STEP_DIR/cl2" "$STEP_DIR/warmup/cl2"
      export CL2_SCHEDULER_THROUGHPUT_PODS="$TOTAL" CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$THRESHOLD"
      export CL2_PROMETHEUS_NODE_SELECTOR='node-role.kubernetes.io/control-plane: ""' CL2_PROMETHEUS_TOLERATE_MASTER=true
      if ! cl2 "$STEP_DIR/warmup" warmup > "$STEP_DIR/warmup/run.log" 2>&1; then
        echo "    FAILED: warm-up pass (see $STEP_DIR/warmup/run.log)"; ok=false
      fi
      unset CL2_SCHEDULER_THROUGHPUT_PODS CL2_SCHEDULER_THROUGHPUT_THRESHOLD CL2_PROMETHEUS_NODE_SELECTOR CL2_PROMETHEUS_TOLERATE_MASTER
      # generate-report.py makes a row of every directory with a junit.xml, and would give the warm-up the
      # measured pass's e2e-latency.json (it looks upward for it): keep the warm-up out of the report
      find "$STEP_DIR/warmup" -name junit.xml -exec sh -c 'mv "$1" "${1%.xml}-warmup.xml"' _ {} \;
      wait_pods_gone "$PREFIX"
      log "settling after the warm-up's deletions"
      settle
    fi

    if [ "$ok" = true ]; then
      SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      echo "measured_start: $SINCE" >> "$STEP_DIR/step.txt"
      measured() { cl2 "$STEP_DIR" "$ARM"; }
      start_placement_watch "$STEP_DIR"
      concurrent_run_step "$STEP_DIR" "$TOTAL" "$THRESHOLD" measured || ok=false
      check_isolation "$STEP_DIR" "$PREFIX" "$TOTAL" | sed 's/^/    /'
      grep -q "^ISOLATION OK" "$STEP_DIR/isolation.txt" || ok=false
      [ "$KL" != true ] || capture_klastos_logs "$STEP_DIR" "$SINCE"
    fi

    # teardown of the step, not measured
    delete_namespaces "$PREFIX"
    case "$ARM" in
      klastos|klastospc) "$HARNESS_DIR/delete-step-policy.sh" >> "$STEP_DIR/setup.log" 2>&1 || true ;;
      gkinj)   "$GKI_DIR/delete-tenant-mutations.sh" >> "$STEP_DIR/setup.log" 2>&1 || true ;;
    esac
    [ "$ok" = true ] || FAILED_STEPS="$FAILED_STEPS $STEP"
  done
done

if [ -n "$FAILED_STEPS" ]; then
  echo ""
  echo "FAILED steps:$FAILED_STEPS"
  concurrent_finalize "$RESULT_ROOT" || true
  exit 1
fi
concurrent_finalize "$RESULT_ROOT"
