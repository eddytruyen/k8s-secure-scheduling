| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Admission-mutation (p50/p90/p99) | Validation p99 | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) |
|---|---|---|---|---|---|---|---|---|---|
| full-multitenancy-evaluation-20261102-093816/baseline-n1000/measurements/pod-uc1-tenant | PASS | 35.4/55/55 | 116.8ms/587.3ms/2280.6ms | 0.5ms/1.0ms/3.7ms | 4.0ms | none=1000 | -/-/- | -/-/- | 116.8ms/587.3ms/2280.6ms |
| full-multitenancy-evaluation-20261102-093816/baseline-n1000/measurements/pod-uc2-tenant | PASS | 40/44.6/44.6 | 16.0ms/338.0ms/467.5ms | 0.5ms/1.0ms/3.9ms | 4.4ms | none=1000 | -/-/- | -/-/- | 16.0ms/338.0ms/467.5ms |
| full-multitenancy-evaluation-20261102-093816/baseline-n1000/measurements/vanilla | PASS | 40/41/78 | 11.9ms/21.4ms/71.8ms | 0.5ms/0.9ms/2.7ms | 2.9ms | none=1000 | -/-/- | -/-/- | 11.9ms/21.4ms/71.8ms |
| full-multitenancy-evaluation-20261102-093816/klastos-n1000/measurements/uc1 | PASS | 40/47.6/47.6 | 12.5ms/107.0ms/1869.3ms | -/-/- | - | admission=943,appclass_operator=57 | 0.0ms/0.0ms/1803.9ms | 251.4ms/661.4ms/859.8ms | 12.2ms/36.5ms/294.7ms |
| full-multitenancy-evaluation-20261102-093816/klastos-n1000/measurements/uc2 | PASS | 40/47.6/47.6 | 11.7ms/21.4ms/1369.6ms | -/-/- | - | admission=937,appclass_operator=63 | 0.0ms/0.0ms/1346.9ms | 216.8ms/430.4ms/592.8ms | 11.4ms/18.3ms/30.2ms |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| full-multitenancy-evaluation-20261102-093816/baseline-n1000/measurements/pod-uc1-tenant | none | 1000 | 116.8ms | 587.3ms | 2280.6ms | 3626.5ms |
| full-multitenancy-evaluation-20261102-093816/baseline-n1000/measurements/pod-uc2-tenant | none | 1000 | 16.0ms | 338.0ms | 467.5ms | 543.0ms |
| full-multitenancy-evaluation-20261102-093816/baseline-n1000/measurements/vanilla | none | 1000 | 11.9ms | 21.4ms | 71.8ms | 148.2ms |
| full-multitenancy-evaluation-20261102-093816/klastos-n1000/measurements/uc1 | admission | 943 | 12.1ms | 30.1ms | 325.1ms | 353.1ms |
| full-multitenancy-evaluation-20261102-093816/klastos-n1000/measurements/uc1 | appclass_operator | 57 | 1151.3ms | 1986.3ms | 1996.7ms | 3131.5ms |
| full-multitenancy-evaluation-20261102-093816/klastos-n1000/measurements/uc2 | admission | 937 | 11.4ms | 17.9ms | 29.5ms | 62.0ms |
| full-multitenancy-evaluation-20261102-093816/klastos-n1000/measurements/uc2 | appclass_operator | 63 | 984.6ms | 1502.0ms | 1579.8ms | 1629.0ms |
