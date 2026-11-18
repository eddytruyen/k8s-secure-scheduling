| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) | Pods e2e/classif./gate/sched |
|---|---|---|---|---|---|---|---|---|
| data-sovereignty-kyverno-evaluation-20261118-122108/baseline-n20/measurements/pod-eu-region | PASS | 0/20/20 | 19.9ms/23.4ms/27.5ms | none=20 | -/-/- | -/-/- | 19.9ms/23.4ms/27.5ms | 20/-/-/20 |
| data-sovereignty-kyverno-evaluation-20261118-122108/baseline-n20/measurements/pod-italynorth-region | PASS | 0/20/20 | 31.2ms/36.3ms/49.8ms | none=20 | -/-/- | -/-/- | 31.2ms/36.3ms/49.8ms | 20/-/-/20 |
| data-sovereignty-kyverno-evaluation-20261118-122108/baseline-n20/measurements/pod-us-region | PASS | 0/20/20 | 16.8ms/24.5ms/30.3ms | none=20 | -/-/- | -/-/- | 16.8ms/24.5ms/30.3ms | 20/-/-/20 |
| data-sovereignty-kyverno-evaluation-20261118-122108/baseline-n20/measurements/vanilla | PASS | 0/20/20 | 19.0ms/24.4ms/27.2ms | none=20 | -/-/- | -/-/- | 19.0ms/24.4ms/27.2ms | 20/-/-/20 |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| data-sovereignty-kyverno-evaluation-20261118-122108/baseline-n20/measurements/pod-eu-region | none | 20 | 19.9ms | 23.4ms | 27.5ms | 27.5ms |
| data-sovereignty-kyverno-evaluation-20261118-122108/baseline-n20/measurements/pod-italynorth-region | none | 20 | 31.2ms | 36.3ms | 49.8ms | 49.8ms |
| data-sovereignty-kyverno-evaluation-20261118-122108/baseline-n20/measurements/pod-us-region | none | 20 | 16.8ms | 24.5ms | 30.3ms | 30.3ms |
| data-sovereignty-kyverno-evaluation-20261118-122108/baseline-n20/measurements/vanilla | none | 20 | 19.0ms | 24.4ms | 27.2ms | 27.2ms |
