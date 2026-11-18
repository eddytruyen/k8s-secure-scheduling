| Run | Status | Sched pods/s (p50/p90/p99) | e2e latency (p50/p90/p99) | Classification source | Classification phase (p50/p90/p99) | Gate-release phase (p50/p90/p99) | Scheduling phase (p50/p90/p99) | Pods e2e/classif./gate/sched |
|---|---|---|---|---|---|---|---|---|
| data-sovereignty-kyverno-evaluation-20261118-122245/baseline-n20/measurements/pod-eu-region | PASS | 0/20/20 | 18.9ms/30.1ms/36.6ms | none=20 | -/-/- | -/-/- | 18.9ms/30.1ms/36.6ms | 20/-/-/20 |
| data-sovereignty-kyverno-evaluation-20261118-122245/baseline-n20/measurements/pod-italynorth-region | PASS | 0/20/20 | 20.1ms/23.8ms/27.8ms | none=20 | -/-/- | -/-/- | 20.1ms/23.8ms/27.8ms | 20/-/-/20 |
| data-sovereignty-kyverno-evaluation-20261118-122245/baseline-n20/measurements/pod-us-region | PASS | 0/20/20 | 23.8ms/34.0ms/43.6ms | none=20 | -/-/- | -/-/- | 23.8ms/34.0ms/43.6ms | 20/-/-/20 |
| data-sovereignty-kyverno-evaluation-20261118-122245/baseline-n20/measurements/vanilla | PASS | 0/20/20 | 26.1ms/41.4ms/43.3ms | none=20 | -/-/- | -/-/- | 26.1ms/41.4ms/43.3ms | 20/-/-/20 |

### E2E latency by classification source

| Run | Source | Pods | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| data-sovereignty-kyverno-evaluation-20261118-122245/baseline-n20/measurements/pod-eu-region | none | 20 | 18.9ms | 30.1ms | 36.6ms | 36.6ms |
| data-sovereignty-kyverno-evaluation-20261118-122245/baseline-n20/measurements/pod-italynorth-region | none | 20 | 20.1ms | 23.8ms | 27.8ms | 27.8ms |
| data-sovereignty-kyverno-evaluation-20261118-122245/baseline-n20/measurements/pod-us-region | none | 20 | 23.8ms | 34.0ms | 43.6ms | 43.6ms |
| data-sovereignty-kyverno-evaluation-20261118-122245/baseline-n20/measurements/vanilla | none | 20 | 26.1ms | 41.4ms | 43.3ms | 43.3ms |
