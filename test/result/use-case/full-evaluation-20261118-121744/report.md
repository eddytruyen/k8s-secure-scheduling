| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) | Pods e2e/classif./gate/sched |
|---|---|---|---|---|---|---|---|---|
| full-evaluation-20261118-121744/baseline-n20/measurements/pod-eu-region | PASS | 0/20/20 | 29.8ms/39.2ms/45.0ms | none=20 | -/-/- | -/-/- | 29.8ms/39.2ms/45.0ms | 20/-/-/20 |
| full-evaluation-20261118-121744/baseline-n20/measurements/pod-italynorth-region | PASS | 0/20/20 | 24.8ms/30.1ms/36.6ms | none=20 | -/-/- | -/-/- | 24.8ms/30.1ms/36.6ms | 20/-/-/20 |
| full-evaluation-20261118-121744/baseline-n20/measurements/pod-us-region | PASS | 0/20/20 | 39.1ms/48.8ms/53.4ms | none=20 | -/-/- | -/-/- | 39.1ms/48.8ms/53.4ms | 20/-/-/20 |
| full-evaluation-20261118-121744/baseline-n20/measurements/vanilla | PASS | 0/20/20 | 27.3ms/32.8ms/39.4ms | none=20 | -/-/- | -/-/- | 27.3ms/32.8ms/39.4ms | 20/-/-/20 |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| full-evaluation-20261118-121744/baseline-n20/measurements/pod-eu-region | none | 20 | 29.8ms | 39.2ms | 45.0ms | 45.0ms |
| full-evaluation-20261118-121744/baseline-n20/measurements/pod-italynorth-region | none | 20 | 24.8ms | 30.1ms | 36.6ms | 36.6ms |
| full-evaluation-20261118-121744/baseline-n20/measurements/pod-us-region | none | 20 | 39.1ms | 48.8ms | 53.4ms | 53.4ms |
| full-evaluation-20261118-121744/baseline-n20/measurements/vanilla | none | 20 | 27.3ms | 32.8ms | 39.4ms | 39.4ms |
