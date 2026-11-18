| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) | Pods e2e/classif./gate/sched |
|---|---|---|---|---|---|---|---|---|
| full-evaluation-20261118-121040/klastos-n20/measurements/eu | PASS | 0/20/20 | 485.0ms/545.6ms/607.4ms | appclass_operator=20 | 275.1ms/320.7ms/355.4ms | 169.8ms/240.6ms/320.0ms | 14.7ms/18.4ms/21.6ms | 20/20/20/20 |
| full-evaluation-20261118-121040/klastos-n20/measurements/italynorth | PASS | 0/20/20 | 524.8ms/676.3ms/713.3ms | appclass_operator=20 | 321.6ms/362.2ms/370.4ms | 191.8ms/303.2ms/346.6ms | 12.3ms/16.5ms/17.0ms | 20/20/20/20 |
| full-evaluation-20261118-121040/klastos-n20/measurements/us | PASS | 0/20/20 | 408.3ms/548.1ms/577.0ms | appclass_operator=20 | 243.9ms/305.8ms/323.5ms | 149.3ms/220.4ms/264.7ms | 9.1ms/14.4ms/18.8ms | 20/20/20/20 |
| full-evaluation-20261118-121040/klastos-n20/measurements/vanilla | PASS | 0/20/20 | 518.6ms/623.3ms/650.4ms | appclass_operator=20 | 351.7ms/425.8ms/451.8ms | 154.2ms/217.2ms/246.1ms | 11.6ms/17.0ms/18.1ms | 20/20/20/20 |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| full-evaluation-20261118-121040/klastos-n20/measurements/eu | appclass_operator | 20 | 485.0ms | 545.6ms | 607.4ms | 607.4ms |
| full-evaluation-20261118-121040/klastos-n20/measurements/italynorth | appclass_operator | 20 | 524.8ms | 676.3ms | 713.3ms | 713.3ms |
| full-evaluation-20261118-121040/klastos-n20/measurements/us | appclass_operator | 20 | 408.3ms | 548.1ms | 577.0ms | 577.0ms |
| full-evaluation-20261118-121040/klastos-n20/measurements/vanilla | appclass_operator | 20 | 518.6ms | 623.3ms | 650.4ms | 650.4ms |
