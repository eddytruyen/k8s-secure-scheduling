| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Admission-mutation (p50/p90/p99) | Validation p99 | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) |
|---|---|---|---|---|---|---|---|---|---|
| concurrent-multitenancy-classtotopology-evaluation-20261102-105555/baseline-n1000/measurements | PASS | 40/40/47.4 | 11.8ms/18.7ms/66.1ms | -/-/- | - | none=2000 | -/-/- | -/-/- | 11.8ms/18.7ms/66.1ms |
| concurrent-multitenancy-classtotopology-evaluation-20261102-105555/klastos-n1000/measurements | PASS | 40/40.2/47.4 | 11.9ms/20.4ms/1190.3ms | -/-/- | - | admission=1939,appclass_operator=61 | 0.0ms/0.0ms/668.4ms | 187.7ms/649.3ms/806.6ms | 11.8ms/19.3ms/28.6ms |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| concurrent-multitenancy-classtotopology-evaluation-20261102-105555/baseline-n1000/measurements | none | 2000 | 11.8ms | 18.7ms | 66.1ms | 172.2ms |
| concurrent-multitenancy-classtotopology-evaluation-20261102-105555/klastos-n1000/measurements | admission | 1939 | 11.8ms | 19.1ms | 27.4ms | 112.7ms |
| concurrent-multitenancy-classtotopology-evaluation-20261102-105555/klastos-n1000/measurements | appclass_operator | 61 | 1054.6ms | 1344.7ms | 1497.0ms | 1593.0ms |
