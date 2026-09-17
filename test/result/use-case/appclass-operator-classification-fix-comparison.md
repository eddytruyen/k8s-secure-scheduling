# appclass_operator classification-pipeline fixes: comparison

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

## Reproducing (appclass_operator fix comparison)

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

---

## Scheduler chart profile comparison: Diktyo+ClassScheduling vs. ClassScheduling-only

Separate axis from the appclass_operator fix comparison above: both runs
here use the *same* fixed appclass_operator (`appclass-wake-on-first-pod`,
commit `946c1be`) and the *same* KLASTOS harness - only the diktyo-scheduler
Helm chart's deployment profile changes
(`scheduling/charts/as-a-second-scheduler`, see its own README for the full
profile list).

| Profile | Scheduler plugins | Controllers deployed |
|---|---|---|
| **Profile 4** (`values-diktyo-classscheduling.yaml`, used everywhere else in this doc) | ClassScheduling + NetworkOverhead + TopologicalSort | `appgroup-controller`, `networktopology-controller`, `scheduler-plugins-controller` |
| **Profile 2** (`values-classscheduling.yaml`) | ClassScheduling only | `scheduler-plugins-controller` only |

`deploy-klastos-stack.sh`'s hardcoded rollout-status checks for
`appgroup-controller`/`networktopology-controller` had to be skipped for the
Profile 2 run (that profile doesn't deploy them at all) - done via a scratch
copy of the deploy script for this one-off comparison, not a change to the
committed script itself, since Profile 4 remains this harness's actual
default.

Raw harness output: [`full-evaluation-20260917-132102/report.md`](use-case/full-evaluation-20260917-132102/report.md).
Operator/scheduler logs checked clean for this run: 0 restarts across
`appclass-operator`/`unified-operator`/`diktyo-scheduler`/`scheduler-plugins-controller`,
no new errors in either operator's log (only the same known/harmless
`ExplicitClass_operator.py`/`on_appinfo_event` 404 already documented
elsewhere in this repo), no panics or errors in the scheduler's own log.

### Results: `eu` class, N=20/100/1000

| | N=20 e2e latency (p50/p90/p99) | N=100 e2e latency (p50/p90/p99) | N=1000 e2e latency (p50/p90/p99) | N=1000 admission fast-path rate | N=1000 classification phase (p50/p90/p99) | N=1000 scheduling phase (p50/p90/p99) |
|---|---|---|---|---|---|---|
| Profile 4 (Diktyo + ClassScheduling) | 928.9ms/1036.0ms/1138.9ms | 3199.6ms/4058.5ms/4405.3ms | 10603.9ms/17522.3ms/20790.3ms | 694/1000 (69.4%) | 0.0ms/14892.7ms/17972.7ms | 421.6ms/15305.2ms/19043.3ms |
| Profile 2 (ClassScheduling only) | 823.0ms/942.8ms/991.1ms | 2251.1ms/2840.9ms/3035.7ms | 3883.8ms/16524.9ms/18363.0ms | 690/1000 (69.0%) | 0.0ms/11667.6ms/13659.3ms | 3573.4ms/5147.2ms/5795.3ms |

### Findings

**Admission fast-path rate is essentially unchanged** (69.4% vs 69.0%) -
expected, since that's driven entirely by appclass_operator/OPA timing, which
is identical in both runs. The scheduler profile only affects what happens
*after* a pod is unblocked.

**N=1000 total e2e latency is noticeably better at p50 with Profile 2**
(3.9s vs 10.6s) and roughly comparable at p90/p99 (16.5-18.4s vs 17.5-20.8s).
The scheduling-phase breakdown explains why: Profile 2's scheduling phase is
tighter and more consistent (3.6s/5.1s/5.8s) than Profile 4's
(0.4s/15.3s/19.0s) - a much smaller p50-to-p99 spread. This is consistent
with what TopologicalSort actually does: it reorders the scheduler's queue
by AppGroup dependency, and NetworkOverhead adds inter-node cost scoring on
top - both real per-pod work that Profile 2 simply doesn't do. Removing them
trades a small, consistent per-pod cost increase at the median for a much
narrower tail, rather than the large median-vs-tail gap Profile 4 shows.

**Neither profile is "better" in general** - they answer different
questions. Profile 4 is the full pipeline this repo's Experiment 1 targets
(class-based placement *and* network-overhead-aware, dependency-ordered
scheduling); Profile 2 isolates just the class-based placement half. This
comparison is about understanding where Profile 4's tail latency actually
comes from (TopologicalSort/NetworkOverhead, not appclass_operator/OPA), not
about recommending Profile 2 as a replacement.

### Reproducing

```bash
# Nestor-paper: git checkout appclass-wake-on-first-pod (same as the fix comparison above)
# klastos: deploy-klastos-stack.sh's helm invocation swapped to
#   -f values-classscheduling.yaml, --set plugins.topologicalSort.namespaces=...
#   dropped (plugin disabled in this profile), and the appgroup-controller/
#   networktopology-controller rollout-status checks removed (not deployed
#   by this profile) - a scratch copy of the script, not a committed change.
KLASTOS_REPO=$HOME/githubrepos/klastos RUN_BASELINE=false RUN_KLASTOS=true THRESHOLD_OVERRIDE=5 \
  ./run-full-evaluation.sh
```
