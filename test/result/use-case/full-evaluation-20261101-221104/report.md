| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Admission-mutation (p50/p90/p99) | Validation p99 | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) |
|---|---|---|---|---|---|---|---|---|---|
| full-evaluation-20261101-221104/baseline-n1000/measurements/pod-eu-region | PASS | 40/41/77 | 13.1ms/23.4ms/86.7ms | 0.5ms/0.9ms/2.6ms | 3.7ms | none=1000 | -/-/- | -/-/- | 13.1ms/23.4ms/86.7ms |
| full-evaluation-20261101-221104/baseline-n1000/measurements/pod-italynorth-region | PASS | 40/41/76 | 12.1ms/20.5ms/81.0ms | 0.6ms/1.1ms/3.5ms | 5.2ms | none=1000 | -/-/- | -/-/- | 12.1ms/20.5ms/81.0ms |
| full-evaluation-20261101-221104/baseline-n1000/measurements/pod-us-region | PASS | 40/41/77 | 12.5ms/21.7ms/117.2ms | 0.6ms/1.1ms/3.6ms | 4.9ms | none=1000 | -/-/- | -/-/- | 12.5ms/21.7ms/117.2ms |
| full-evaluation-20261101-221104/baseline-n1000/measurements/vanilla | PASS | 40/41/79 | 12.1ms/20.3ms/65.8ms | 0.5ms/0.9ms/1.9ms | 2.7ms | none=1000 | -/-/- | -/-/- | 12.1ms/20.3ms/65.8ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/eu | PASS | 40/43/63 | 12.2ms/21.6ms/1341.5ms | -/-/- | - | admission=944,appclass_operator=56 | 0.0ms/0.0ms/1278.7ms | 225.6ms/593.0ms/1700.5ms | 12.0ms/19.2ms/29.1ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/italynorth | PASS | 40/42/74 | 11.5ms/21.8ms/1488.9ms | -/-/- | - | admission=940,appclass_operator=60 | 0.0ms/0.0ms/1423.7ms | 243.0ms/796.7ms/998.7ms | 11.3ms/18.6ms/26.9ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/us | PASS | 40/41/64 | 12.9ms/23.5ms/967.6ms | -/-/- | - | admission=944,appclass_operator=56 | 0.0ms/0.0ms/950.1ms | 0.0ms/239.6ms/291.5ms | 12.6ms/21.1ms/30.2ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/vanilla | PASS | 40/41/64 | 13.5ms/24.4ms/1484.3ms | -/-/- | - | admission=944,appclass_operator=56 | 0.0ms/0.0ms/1471.3ms | 289.5ms/471.9ms/520.1ms | 13.0ms/21.5ms/37.0ms |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| full-evaluation-20261101-221104/baseline-n1000/measurements/pod-eu-region | none | 1000 | 13.1ms | 23.4ms | 86.7ms | 119.0ms |
| full-evaluation-20261101-221104/baseline-n1000/measurements/pod-italynorth-region | none | 1000 | 12.1ms | 20.5ms | 81.0ms | 86.5ms |
| full-evaluation-20261101-221104/baseline-n1000/measurements/pod-us-region | none | 1000 | 12.5ms | 21.7ms | 117.2ms | 153.7ms |
| full-evaluation-20261101-221104/baseline-n1000/measurements/vanilla | none | 1000 | 12.1ms | 20.3ms | 65.8ms | 74.0ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/eu | admission | 944 | 11.9ms | 19.1ms | 29.0ms | 70.4ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/eu | appclass_operator | 56 | 839.0ms | 1441.1ms | 2632.3ms | 2649.6ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/italynorth | admission | 940 | 11.2ms | 18.6ms | 26.9ms | 44.0ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/italynorth | appclass_operator | 60 | 1245.7ms | 1570.0ms | 1717.4ms | 1784.0ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/us | admission | 944 | 12.6ms | 21.2ms | 30.2ms | 108.6ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/us | appclass_operator | 56 | 781.4ms | 1028.0ms | 1076.3ms | 1107.5ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/vanilla | admission | 944 | 12.9ms | 21.0ms | 36.0ms | 147.7ms |
| full-evaluation-20261101-221104/klastos-n1000/measurements/vanilla | appclass_operator | 56 | 816.7ms | 1555.8ms | 1666.7ms | 1721.2ms |
