| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) | Pods e2e/classif./gate/sched |
|---|---|---|---|---|---|---|---|---|
| full-evaluation-20261118-120657/klastos-n20/measurements/eu | PASS | 0/20/20 | 383.8ms/468.9ms/484.3ms | appclass_operator=20 | 268.7ms/305.1ms/329.7ms | 104.4ms/155.2ms/161.0ms | 9.8ms/16.5ms/20.7ms | 20/20/20/20 |
| full-evaluation-20261118-120657/klastos-n20/measurements/italynorth | PASS | 0/20/20 | 455.0ms/611.1ms/682.8ms | appclass_operator=20 | 333.1ms/399.7ms/451.4ms | 150.4ms/205.8ms/224.2ms | 10.1ms/13.1ms/15.7ms | 20/20/20/20 |
| full-evaluation-20261118-120657/klastos-n20/measurements/us | PASS | 0/20/20 | 681.8ms/768.4ms/880.3ms | appclass_operator=20 | 391.5ms/470.4ms/496.8ms | 263.7ms/289.0ms/393.3ms | 15.4ms/21.4ms/26.4ms | 20/20/20/20 |
| full-evaluation-20261118-120657/klastos-n20/measurements/vanilla | PASS | 0/20/20 | 582.8ms/681.7ms/737.9ms | appclass_operator=20 | 455.8ms/530.3ms/575.1ms | 104.8ms/157.8ms/162.7ms | 9.5ms/12.3ms/15.8ms | 20/20/20/20 |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| full-evaluation-20261118-120657/klastos-n20/measurements/eu | appclass_operator | 20 | 383.8ms | 468.9ms | 484.3ms | 484.3ms |
| full-evaluation-20261118-120657/klastos-n20/measurements/italynorth | appclass_operator | 20 | 455.0ms | 611.1ms | 682.8ms | 682.8ms |
| full-evaluation-20261118-120657/klastos-n20/measurements/us | appclass_operator | 20 | 681.8ms | 768.4ms | 880.3ms | 880.3ms |
| full-evaluation-20261118-120657/klastos-n20/measurements/vanilla | appclass_operator | 20 | 582.8ms | 681.7ms | 737.9ms | 737.9ms |
