| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Admission-mutation (p50/p90/p99) | Validation p99 | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) |
|---|---|---|---|---|---|---|---|---|---|
| full-evaluation-20261101-224047/baseline-n1000/measurements/pod-eu-region | PASS | 40/41/76 | 12.2ms/20.7ms/85.9ms | 0.5ms/1.0ms/3.0ms | 4.1ms | none=1000 | -/-/- | -/-/- | 12.2ms/20.7ms/85.9ms |
| full-evaluation-20261101-224047/baseline-n1000/measurements/pod-italynorth-region | PASS | 40/41/76 | 11.8ms/20.1ms/65.1ms | 0.6ms/1.1ms/3.5ms | 5.0ms | none=1000 | -/-/- | -/-/- | 11.8ms/20.1ms/65.1ms |
| full-evaluation-20261101-224047/baseline-n1000/measurements/pod-us-region | PASS | 40/41/76 | 12.2ms/20.8ms/135.6ms | 0.5ms/1.0ms/3.2ms | 4.4ms | none=1000 | -/-/- | -/-/- | 12.2ms/20.8ms/135.6ms |
| full-evaluation-20261101-224047/baseline-n1000/measurements/vanilla | PASS | 40/41/78 | 12.2ms/20.7ms/71.9ms | 0.5ms/0.9ms/1.9ms | 2.8ms | none=1000 | -/-/- | -/-/- | 12.2ms/20.7ms/71.9ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/eu | PASS | 30/97/125 | 83.1ms/692.0ms/1567.3ms | -/-/- | - | admission=930,appclass_operator=70 | 0.0ms/0.0ms/1267.9ms | 374.7ms/726.1ms/830.5ms | 55.4ms/560.1ms/1317.2ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/italynorth | PASS | 40/41/61 | 12.8ms/22.8ms/1954.3ms | -/-/- | - | admission=942,appclass_operator=58 | 0.0ms/0.0ms/873.0ms | 198.3ms/1423.5ms/1441.2ms | 12.6ms/20.7ms/28.0ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/us | PASS | 40/41/64 | 12.2ms/20.8ms/1974.2ms | -/-/- | - | admission=944,appclass_operator=56 | 0.0ms/0.0ms/1830.2ms | 427.4ms/973.6ms/1605.9ms | 11.9ms/19.2ms/27.2ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/vanilla | PASS | 40/41/71 | 11.6ms/21.0ms/1110.9ms | -/-/- | - | admission=947,appclass_operator=53 | 0.0ms/0.0ms/942.6ms | 347.0ms/642.6ms/820.5ms | 11.3ms/18.0ms/27.0ms |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| full-evaluation-20261101-224047/baseline-n1000/measurements/pod-eu-region | none | 1000 | 12.2ms | 20.7ms | 85.9ms | 112.7ms |
| full-evaluation-20261101-224047/baseline-n1000/measurements/pod-italynorth-region | none | 1000 | 11.8ms | 20.1ms | 65.1ms | 115.8ms |
| full-evaluation-20261101-224047/baseline-n1000/measurements/pod-us-region | none | 1000 | 12.1ms | 20.8ms | 135.9ms | 577.1ms |
| full-evaluation-20261101-224047/baseline-n1000/measurements/vanilla | none | 1000 | 12.2ms | 20.7ms | 71.9ms | 96.6ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/eu | admission | 930 | 65.5ms | 613.4ms | 1319.8ms | 2068.2ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/eu | appclass_operator | 70 | 1248.0ms | 1519.6ms | 1634.5ms | 1682.5ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/italynorth | admission | 942 | 12.5ms | 20.0ms | 27.8ms | 39.6ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/italynorth | appclass_operator | 58 | 1054.6ms | 2000.0ms | 2076.0ms | 2077.3ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/us | admission | 944 | 11.7ms | 18.2ms | 25.9ms | 48.8ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/us | appclass_operator | 56 | 1360.4ms | 2037.6ms | 2347.7ms | 2371.4ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/vanilla | admission | 947 | 11.3ms | 17.7ms | 26.4ms | 83.2ms |
| full-evaluation-20261101-224047/klastos-n1000/measurements/vanilla | appclass_operator | 53 | 975.1ms | 1145.3ms | 1212.8ms | 1319.2ms |
