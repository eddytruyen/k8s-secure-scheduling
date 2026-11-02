# Etcd stalls observed during Experiment 1 sweeps (2026-11-01 / 2026-11-02)

In three sweeps one repeat was dominated by a ~1 minute etcd stall. That repeat
was excluded from the filtered stats.md / stats.csv; the originals are kept as
stats.with-outlier.md / .csv, next to a stats-NOTE.txt in each result dir.

| Sweep result dir | Excluded repeat | Stall (UTC) |
|---|---|---|
| repeated-run-full-evaluation-20261101-220111 (data-sovereignty) | klastos eu, repeat 5 (full-evaluation-20261101-224047) | ~22:42:29-22:42:53 |
| repeated-run-full-multitenancy-evaluation-20261102-092551 | repeat 3 (full-multitenancy-evaluation-20261102-093816) | ~09:42-09:43 |
| repeated-run-concurrent-multitenancy-classtotopology-evaluation-20261102-103754 | repeat 2 (...-20261102-104227) | ~10:43:00-10:43:30 |

Not a KLASTOS effect. Evidence for the concurrent sweep, repeat 2 (KLASTOS arm):

- Etcd request p99 (Prometheus, etcd_request_duration_seconds) rose from 0.024 s
  to 2.1-2.5 s for ~60 s from 10:43:00, then returned to 0.04 s.
- Apiserver p99 (non-watch/list) rose from ~1 s to 2.5 s; pod binding p99 from
  0.03 s to 0.8 s over the same window.
- Pods created 10:43:10-10:43:30 had scheduling-phase median 2.17 s, then 0.65 s;
  before and after, the median was 10-30 ms. 602 pods were >1 s (vs 34 in
  repeat 3), but only 73 were gated, so the slowness is scheduling/binding,
  not gate wait. Classification and gate numbers match the other repeats.
- The e2e watcher had no gap during the burst (its one reconnect was at 10:44:27,
  after all 2000 pods were seen).
- Etcd logged no slow-apply warnings in this particular window; the evidence is
  in the Prometheus metrics. Etcd snapshot (10:43:40) and compaction (10:43:35)
  came after the stall began, so they are not the established cause.
- Baseline arm of the same repeat was clean.

Other stalls: the data-sovereignty and multi-tenancy ones logged "apply request
took too long" (up to 1.19 s and 3.56 s) and ReadIndex warnings; more occurred
on an idle cluster at 10:10-10:16 (UTC, 2026-11-02). Cause not found: no
iostat/sar history, kernel journal clean, no timers or cron at :42.

Suggested next step: capture "iostat -x 5" and etcd metrics (wal fsync,
backend commit) in the background during sweeps to tell host disk from etcd.

Prometheus note: the service IP is not reachable from the host; query via
kubectl get --raw /api/v1/namespaces/monitoring/services/prometheus-k8s:9090/proxy/api/v1/query_range?...
