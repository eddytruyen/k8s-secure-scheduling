# appclass_operator classification-pipeline fixes: three-way comparison

Data-sovereignty use case (Experiment 1), `eu` class unless noted. All runs use
this repo's own harness (`test/run-full-evaluation.sh`) against the same
KWOK/kind cluster, OPA at 5 replicas, `THRESHOLD_OVERRIDE` set low enough
(5 pods/sec) to avoid the known N-scaled `SchedulingThroughput` gate
mismatch at small N (see `run-full-evaluation.sh`'s own `threshold_for()`
comment) without masking any real latency numbers - the override only
changes the pass/fail gate, never the measured values themselves.

## What's being compared

| Configuration | Nestor-paper ref | Notes |
|---|---|---|
| **Gatekeeper baseline** | this repo's own `run-use-case-test.sh` (`RUN_BASELINE=true` arm) | k8s-secure-scheduling's own reference mechanism for this use case: a single Gatekeeper mutation policy, no classification pipeline at all. Not a fix target - the reference point for what a simpler, non-composable mechanism costs. |
| **Pre-fix appclass_operator** | commit [`bcda459`](https://github.com/eddytruyen/Nestor-paper/commit/bcda459b3039cb516b02487864f0826efb08261d) | The actual starting point for this round of work - explicitly called "the known-good baseline for a fresh design attempt" in its own commit message, before Stage 1's O(N²) sibling-pod scan fix, Stage 2/3 signature-skip caching, the RBAC-index cache, or the wake-on-first-pod handler. |
| **This session's fixes** | branch `appclass-wake-on-first-pod` (PR pending), commit [`946c1be`](https://github.com/eddytruyen/Nestor-paper/commit/946c1be6cde455d03c52964e01a328da65d541af) | Stage 1 O(N) rewrite + per-appgroup skip, Stage 2/3 signature-skip caching, cached RBAC index (watching `Role`/`ClusterRole`/`RoleBinding`/`ClusterRoleBinding`), and the reintroduced wake-on-first-pod handler. Debug-only instrumentation (pipeline timing logs, trigger-source counters) added and used to validate this work is reverted out of this build - it doesn't affect scheduling behavior, just log volume. |

Raw harness output for the two Nestor-paper-side runs:
- Pre-fix + Gatekeeper: [`full-evaluation-20260916-134728/report.md`](use-case/full-evaluation-20260916-134728/report.md)
- This session's fixes: [`full-evaluation-20260916-141543/report.md`](use-case/full-evaluation-20260916-141543/report.md)

## Results: `eu` class, N=20/100/1000

| | N=20 e2e latency (p50/p90/p99) | N=100 e2e latency (p50/p90/p99) | N=1000 e2e latency (p50/p90/p99) | N=1000 admission fast-path rate | N=1000 classification phase (p50/p90/p99) |
|---|---|---|---|---|---|
| Gatekeeper baseline (`pod-eu-region`) | 28.8ms/64.2ms/78.0ms | 34.0ms/54.3ms/77.8ms | 4240.2ms/9025.8ms/9922.5ms | n/a (no classification pipeline) | n/a |
| Pre-fix appclass_operator (`bcda459`) | 1875.3ms/2309.1ms/2340.3ms | 3982.6ms/5370.4ms/5723.3ms | **152072.2ms/163331.0ms/173682.3ms** | **0/1000 (0%)** | **131761.2ms/133575.1ms/139655.2ms** |
| This session's fixes | 928.9ms/1036.0ms/1138.9ms | 3199.6ms/4058.5ms/4405.3ms | 10603.9ms/17522.3ms/20790.3ms | **694/1000 (69.4%)** | 0.0ms/14892.7ms/17972.7ms |

## Findings

**The pre-fix baseline is catastrophic at N=1000**: 152-174 second end-to-end
latency, driven by 131-140 seconds of classification time alone, and it never
once reached OPA's admission-time fast path across all 1000 pods (0%). This
matches the O(N²) sibling-pod-scan cost and uncached, four-way RBAC listing
this session's fixes specifically targeted - both scale with load, and
neither had any headroom left once the pipeline started re-running under
sustained pod-creation pressure.

**This session's fixes bring N=1000 end-to-end latency down to 10.6-20.8
seconds** - roughly an 8-15x improvement over the pre-fix baseline - and lift
the admission fast-path rate from 0% to 69.4%. At N=20/100 the gap is smaller
in absolute terms (the O(N²)/uncached-RBAC cost has less to compound against)
but still a consistent ~2x improvement.

**Gatekeeper remains far faster in absolute terms at every N.** This is
expected, not a regression to chase: Gatekeeper enforces this use case with a
single mutation webhook and no multi-stage classification pipeline, so it has
fundamentally less work to do per pod. It's included here as the reference
point for what a simpler, non-composable mechanism costs, not as a target the
classification pipeline is trying to match head-to-head - the whole point of
the classification pipeline is the composability and cross-class constraint
handling Gatekeeper's approach doesn't provide (see this repo's own
architecture rationale for the use case).

**One data oddity, noted but not investigated further**: the pre-fix
baseline's `us` class at N=1000 shows a negative gate-release p50
(-111957.4ms) in the raw report table. Almost certainly a timestamp-ordering
artifact in `e2e-latency-watch.py` surfacing only because classification took
so long (130+ seconds) that some ordering assumption between "classified" and
"gate released" events broke down - not worth chasing given it's superseded
code, but flagged here for anyone reading the raw baseline table who notices
the same thing.

## Reproducing

```bash
# Pre-fix baseline (appclass_operator only - Gatekeeper is this repo's own arm)
# Nestor-paper: git checkout bcda459 -- appclass_operator/code/MergedAppClass_operator_v3.py
KLASTOS_REPO=$HOME/githubrepos/klastos RUN_BASELINE=true RUN_KLASTOS=true THRESHOLD_OVERRIDE=5 \
  ./run-full-evaluation.sh

# This session's fixes
# Nestor-paper: git checkout appclass-wake-on-first-pod
KLASTOS_REPO=$HOME/githubrepos/klastos RUN_BASELINE=false RUN_KLASTOS=true THRESHOLD_OVERRIDE=5 \
  ./run-full-evaluation.sh
```
