#!/usr/bin/env bash
#
# Widen the kube-apiserver liveness probe so a transient etcd stall cannot
# get a healthy apiserver killed mid-benchmark.
#
# WHY (diagnosed 2026-11-01, N=1000 campaign, experiment 1/10):
#   Under a ClusterLoader2 sweep this host's etcd WAL fsync latency spikes
#   past its 1s budget ("slow fdatasync" / "waiting for ReadIndex response
#   took too long" in the etcd log). The apiserver's /livez etcd subcheck
#   does a read of /registry/health; that read then blocks ~1s, the subcheck
#   fails, and /livez answers 500 (confirmed in events:
#   "Liveness probe failed: HTTP probe failed with statuscode: 500").
#   After failureThreshold consecutive failures kubelet SIGKILLs the
#   container -> exit 137.
#
#   Exit 137 looks exactly like an OOM, and we read it as one for weeks. It
#   is not: the host kernel OOM killer has never fired (37 days of dmesg,
#   zero oom-kill events), the control-plane cgroup reports oom_kill 0, and
#   the apiserver static pod has no memory limit to hit in the first place.
#
#   kubeadm also ships timeoutSeconds(15) > periodSeconds(10) on this probe,
#   so probes overlap and the failure budget burns faster than the nominal
#   failureThreshold * periodSeconds would suggest. Fixed here too.
#
# A mid-sweep apiserver restart invalidates that repeat's tail statistics,
# which is a far worse outcome than tolerating a 1s etcd stall.
#
# MEASUREMENT-NEUTRAL: this changes only kubelet's willingness to kill the
# apiserver. It does not touch the system under test. (etcd batch tuning
# would NOT be neutral - it alters the write path that e2e latency measures -
# so it is deliberately not done here.)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-secure-sched}"
CP="${CLUSTER_NAME}-control-plane"
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml

echo "[*] Widen kube-apiserver liveness probe (etcd fsync stall tolerance)"
docker exec -i "$CP" bash -c 'cat > /tmp/probe.awk' < "$SCRIPT_DIR/apiserver-probe-patch.awk"
docker exec "$CP" bash -c \
  "awk -f /tmp/probe.awk $MANIFEST > /tmp/ka.yaml && cp /tmp/ka.yaml $MANIFEST"

echo "[*] Waiting for kube-apiserver to come back"
for _i in $(seq 1 60); do
  kubectl get --raw /livez >/dev/null 2>&1 && break
  sleep 5
done
if ! kubectl get --raw /livez >/dev/null 2>&1; then
  echo "ERROR: apiserver did not become healthy after the probe patch" >&2
  exit 1
fi
docker exec "$CP" grep -A3 'livenessProbe:' "$MANIFEST" | sed 's/^/    /'
echo ""
