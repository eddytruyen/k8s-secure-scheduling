| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Admission-mutation (p50/p90/p99) | Validation p99 | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) |
|---|---|---|---|---|---|---|---|---|---|
| concurrent-multitenancy-classtotopology-evaluation-20261102-103754/baseline-n1000/measurements | PASS | 40/40.2/47.2 | 11.3ms/19.4ms/70.5ms | -/-/- | - | none=2000 | -/-/- | -/-/- | 11.3ms/19.4ms/70.5ms |
| concurrent-multitenancy-classtotopology-evaluation-20261102-103754/klastos-n1000/measurements | PASS | 40/40.2/47 | 11.9ms/21.1ms/1683.0ms | -/-/- | - | admission=1934,appclass_operator=66 | 0.0ms/0.0ms/1374.2ms | 249.6ms/872.3ms/1115.0ms | 11.7ms/19.1ms/39.0ms |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| concurrent-multitenancy-classtotopology-evaluation-20261102-103754/baseline-n1000/measurements | none | 2000 | 11.3ms | 19.4ms | 70.5ms | 115.2ms |
| concurrent-multitenancy-classtotopology-evaluation-20261102-103754/klastos-n1000/measurements | admission | 1934 | 11.7ms | 19.1ms | 38.9ms | 67.3ms |
| concurrent-multitenancy-classtotopology-evaluation-20261102-103754/klastos-n1000/measurements | appclass_operator | 66 | 1434.2ms | 1858.7ms | 1980.5ms | 2153.3ms |
