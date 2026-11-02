| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Admission-mutation (p50/p90/p99) | Validation p99 | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) |
|---|---|---|---|---|---|---|---|---|---|
| concurrent-multitenancy-classtotopology-evaluation-20261102-105127/baseline-n1000/measurements | PASS | 40/40.2/47.2 | 12.7ms/21.8ms/53.7ms | -/-/- | - | none=2000 | -/-/- | -/-/- | 12.7ms/21.8ms/53.7ms |
| concurrent-multitenancy-classtotopology-evaluation-20261102-105127/klastos-n1000/measurements | PASS | 40/41/47.4 | 12.9ms/90.4ms/1181.0ms | -/-/- | - | admission=1934,appclass_operator=66 | 0.0ms/0.0ms/859.0ms | 135.7ms/292.8ms/393.5ms | 12.8ms/70.3ms/1017.4ms |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| concurrent-multitenancy-classtotopology-evaluation-20261102-105127/baseline-n1000/measurements | none | 2000 | 12.7ms | 21.8ms | 53.7ms | 145.4ms |
| concurrent-multitenancy-classtotopology-evaluation-20261102-105127/klastos-n1000/measurements | admission | 1934 | 12.7ms | 59.9ms | 1018.3ms | 1766.1ms |
| concurrent-multitenancy-classtotopology-evaluation-20261102-105127/klastos-n1000/measurements | appclass_operator | 66 | 1144.9ms | 1187.2ms | 1368.0ms | 1420.5ms |
