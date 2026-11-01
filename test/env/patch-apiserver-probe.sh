#!/usr/bin/env bash
#
# Widen the kube-apiserver liveness probe so a transient etcd stall cannot
# get a healthy apiserver killed mid-benchmark.
#
# WHY (diagnosed 2026-11-01, N=1000 campaign, experiment 1/10):
#   Under a ClusterLoader2 sweep this host's etcd WAL fsync latency spikes
#   past its 1s budget ("slow fdatasync" / "waiting for ReadIndex response
#   took too long"). The apiserver's /livez etcd subcheck reads
#   /registry/health; that read then blocks ~1s, the subcheck fails, and
#   /livez answers 500 ("Liveness probe failed: HTTP probe failed with
#   statuscode: 500"). After failureThreshold consecutive failures kubelet
#   SIGKILLs the container -> exit 137.
#
#   Exit 137 looks exactly like an OOM. It is not: 37 days of host dmesg
#   contain zero OOM-killer events, the control-plane cgroup reports
#   oom_kill 0, and the apiserver static pod has no memory limit to hit.
#
# MEASUREMENT-NEUTRAL: changes only kubelet's willingness to kill the
# apiserver, not the system under test.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-secure-sched}"
CP="${CLUSTER_NAME}-control-plane"
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml

# Idempotent: if the probe is already widened the manifest will not change,
# kubelet will not restart anything, and waiting for a new container below
# would hang until timeout. Bail out early instead.
if docker exec "$CP" awk '
      /^    livenessProbe:/ { f = 1; next }
      f && /^    [a-zA-Z]/  { exit }
      f && /failureThreshold: 20/ { print "already"; exit }
    ' "$MANIFEST" 2>/dev/null | grep -q already; then
  echo "[*] kube-apiserver liveness probe already widened - skipping"
  exit 0
fi

# Record the running apiserver container so we can tell when kubelet has
# actually acted on the manifest change. Without this the health check
# below races: kubelet has not noticed the edit yet, the OLD apiserver
# answers /livez fine, the loop exits immediately, and the restart then
# lands in the middle of a later setup step (it took out the Gatekeeper
# helm --wait on 2026-11-01 and aborted the whole cluster build).
OLD_ID="$(docker exec "$CP" crictl ps --name kube-apiserver -q 2>/dev/null | head -1 || true)"

echo "[*] Widen kube-apiserver liveness probe (etcd fsync stall tolerance)"
docker exec -i "$CP" bash -c 'cat > /tmp/probe.awk' < "$SCRIPT_DIR/apiserver-probe-patch.awk"
docker exec "$CP" bash -c \
  "awk -f /tmp/probe.awk $MANIFEST > /tmp/ka.yaml && cp /tmp/ka.yaml $MANIFEST"

echo "[*] Waiting for kubelet to replace the kube-apiserver container"
replaced=0
for _i in $(seq 1 60); do
  NEW_ID="$(docker exec "$CP" crictl ps --name kube-apiserver -q 2>/dev/null | head -1 || true)"
  if [ -n "$NEW_ID" ] && [ "$NEW_ID" != "$OLD_ID" ]; then replaced=1; break; fi
  sleep 2
done
if [ "$replaced" -ne 1 ]; then
  echo "ERROR: kubelet never replaced the kube-apiserver container" >&2
  exit 1
fi

# Require consecutive successes: a single OK can come from an apiserver
# that is up but still finishing its poststarthooks.
echo "[*] Waiting for kube-apiserver to serve /livez consistently"
ok=0
for _i in $(seq 1 90); do
  if kubectl get --raw /livez >/dev/null 2>&1; then
    ok=$((ok + 1)); [ "$ok" -ge 3 ] && break
  else
    ok=0
  fi
  sleep 2
done
if [ "$ok" -lt 3 ]; then
  echo "ERROR: apiserver did not become consistently healthy after the probe patch" >&2
  exit 1
fi
docker exec "$CP" grep -A3 'livenessProbe:' "$MANIFEST" | sed 's/^/    /'
echo ""
