| Run | Repeats | Pass rate | throughput_p50 | throughput_p90 | throughput_p99 | e2e_p50_ms | e2e_p90_ms | e2e_p99_ms | classify_p50_ms | classify_p90_ms | classify_p99_ms | gate_p50_ms | gate_p90_ms | gate_p99_ms | sched_phase_p50_ms | sched_phase_p90_ms | sched_phase_p99_ms | e2e_pods | classify_pods | gate_pods | sched_phase_pods | classification_source[admission] | classification_source[appclass_operator] |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| klastos-n1000/measurements | 4 | 4/4 | 40.0 ± 0.0 | 40.1 ± 0.19 | 47.3 ± 0.26 | 9.5 ± 0.1 | 15.9 ± 0.4 | 1736.0 ± 202.42 | 0.0 ± 0.0 | 0.0 ± 0.0 | 1303.7 ± 521.49 | 283.8 ± 102.63 | 820.9 ± 187.79 | 962.9 ± 236.36 | 9.3 ± 0.1 | 14.6 ± 0.22 | 22.7 ± 0.47 | 2000.0 ± 0.0 | 2000.0 ± 0.0 | 65.2 ± 4.5 | 2000.0 ± 0.0 | 1934.2 ± 4.57 | 65.8 ± 4.57 |

<!-- admission:begin (written by update-latest-results.py) -->

## Admission (apiserver-side)

Not part of the e2e latency above: the watcher first sees a pod after admission. Source: `~/campaign-n1000-logs-20261108-124342/admission-12_13_security-rings_CONCURRENT_(rbac)__klastos_arm_.txt` (apiserver metrics over all steps and repeats of this sweep). The POST pods mean is exact and covers all webhooks plus persistence; exact mean request-to-scheduled = that mean + the mean e2e above (means add, percentiles do not). Webhook percentiles are histogram bucket upper bounds.

```
webhook                                        type        op      rej      calls     mean   p50<=   p90<=   p99<=
csi-admission.scheduling.diktyo.x-k8s.io       admit       CREATE  false    10000    6.8ms     5ms    25ms   100ms

POST pods request, apiserver-side (webhooks + persistence): calls=10016 mean=11.7ms
Exact mean from request to scheduled = this mean + the watcher's mean e2e (means add; percentiles do not).
```

<!-- admission:end -->
