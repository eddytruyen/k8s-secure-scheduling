| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Admission-mutation (p50/p90/p99) | Validation p99 | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) |
|---|---|---|---|---|---|---|---|---|---|
| full-multitenancy-evaluation-20261102-092551/baseline-n1000/measurements/pod-uc1-tenant | PASS | 40/47.2/47.2 | 12.4ms/22.6ms/66.1ms | 0.5ms/1.0ms/3.0ms | 3.1ms | none=1000 | -/-/- | -/-/- | 12.4ms/22.6ms/66.1ms |
| full-multitenancy-evaluation-20261102-092551/baseline-n1000/measurements/pod-uc2-tenant | PASS | 40/47.2/47.2 | 12.6ms/21.4ms/72.9ms | 0.5ms/1.0ms/3.4ms | 3.8ms | none=1000 | -/-/- | -/-/- | 12.6ms/21.4ms/72.9ms |
| full-multitenancy-evaluation-20261102-092551/baseline-n1000/measurements/vanilla | PASS | 40/41/77 | 12.6ms/22.4ms/65.7ms | 0.5ms/0.9ms/2.1ms | 2.4ms | none=1000 | -/-/- | -/-/- | 12.6ms/22.4ms/65.7ms |
| full-multitenancy-evaluation-20261102-092551/klastos-n1000/measurements/uc1 | PASS | 40/46.8/46.8 | 11.9ms/20.9ms/1464.4ms | -/-/- | - | admission=937,appclass_operator=63 | 0.0ms/0.0ms/1371.0ms | 234.1ms/720.5ms/1390.5ms | 11.5ms/18.2ms/25.7ms |
| full-multitenancy-evaluation-20261102-092551/klastos-n1000/measurements/uc2 | PASS | 40/47.4/47.4 | 12.8ms/23.9ms/1741.0ms | -/-/- | - | admission=940,appclass_operator=60 | 0.0ms/0.0ms/1314.0ms | 240.2ms/988.6ms/1238.3ms | 12.4ms/20.2ms/32.2ms |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| full-multitenancy-evaluation-20261102-092551/baseline-n1000/measurements/pod-uc1-tenant | none | 1000 | 12.4ms | 22.6ms | 66.1ms | 90.2ms |
| full-multitenancy-evaluation-20261102-092551/baseline-n1000/measurements/pod-uc2-tenant | none | 1000 | 12.6ms | 21.4ms | 72.9ms | 91.0ms |
| full-multitenancy-evaluation-20261102-092551/baseline-n1000/measurements/vanilla | none | 1000 | 12.6ms | 22.4ms | 65.7ms | 196.2ms |
| full-multitenancy-evaluation-20261102-092551/klastos-n1000/measurements/uc1 | admission | 937 | 11.5ms | 18.1ms | 26.1ms | 62.3ms |
| full-multitenancy-evaluation-20261102-092551/klastos-n1000/measurements/uc1 | appclass_operator | 63 | 1222.5ms | 1550.3ms | 2117.2ms | 2159.0ms |
| full-multitenancy-evaluation-20261102-092551/klastos-n1000/measurements/uc2 | admission | 940 | 12.3ms | 20.0ms | 32.2ms | 69.9ms |
| full-multitenancy-evaluation-20261102-092551/klastos-n1000/measurements/uc2 | appclass_operator | 60 | 1250.2ms | 1789.1ms | 1995.3ms | 2158.9ms |
