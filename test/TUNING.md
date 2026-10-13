# ClusterLoader2 tuning parameters — reference and per-scenario settings

Every knob that changes *how fast pods arrive* and *whether a run passes*,
where each one actually lives, and what to set it to in each test
environment we run.

Written because these knobs are spread across four different layers —
upstream ClusterLoader2, a non-upstream fork patch, our own harness
scripts, and the cluster's own controller defaults — and confusing one
layer for another has cost us real debugging time more than once.

---

## 1. What ClusterLoader2 actually is

**CL2 is not ours.** It is [`kubernetes/perf-tests`](https://github.com/kubernetes/perf-tests),
the official Kubernetes SIG-Scalability load-testing framework — the same
tool used to validate upstream's 5k-node scalability SLOs. It is the
canonical answer to "how do I generate a controlled pod-creation load and
measure what the control plane did with it".

We consume it as a **git submodule**:

```
# .gitmodules
[submodule "test/perf-tests"]
	path = test/perf-tests
	url = https://github.com/eddytruyen/perf-tests
	branch = fix-scheduler-latency-metrics
```

Note the URL: it points at **a fork, not upstream**, on a custom branch.
Six non-upstream commits sit on top of upstream master:

| Commit | What it adds | Author |
|---|---|---|
| `e67f4dede` | `CL2_DEFAULT_QPS` / `CL2_DEFAULT_BURST` env vars for the shared client rate limiter (was a hardcoded 100/200) | Eddy Truyen |
| `b2c8ead51` | Fix `scheduler_latency` SchedulingMetrics for K8s 1.23+ | — |
| `bfd897d5c` | Obtain average scheduling throughput from Prometheus | Michele Beretta |
| `a15166917` | Fix `APIAvailability` measurement | — |
| `8e1323388` | Add more percentiles to `SchedulingThroughput` | Michele Beretta |
| `ed714be37` | Pin Grafana deployment to a control-plane node | — |

Two consequences worth internalising:

- **`CL2_DEFAULT_QPS`/`CL2_DEFAULT_BURST` do not exist upstream.** Don't
  look for them in upstream docs; they are `clusterloader2/pkg/framework/config/client_config.go`
  in this fork only.
- **The percentile breakdown we report comes from the CloudCom authors'
  own patches.** `8e1323388` and `bfd897d5c` are by Michele Beretta, a
  co-author of the Rossi et al. CloudCom paper. Upstream `SchedulingThroughput`
  reports less. So "what CL2 reports" is already fork-specific when
  comparing against that paper.

**Documentation.** Upstream docs apply to everything except the fork
commits above, and are checked out in-tree:

- `test/perf-tests/clusterloader2/README.md` — the test-config API
  (phases, tuningSets, measurements) — the single most useful file
- `test/perf-tests/clusterloader2/docs/GETTING_STARTED.md`
- `test/perf-tests/clusterloader2/docs/design.md`
- `test/perf-tests/clusterloader2/api/types.go` — authoritative struct
  definitions for every config field
- Online: https://github.com/kubernetes/perf-tests/tree/master/clusterloader2

Build it with:

```bash
cd test/perf-tests/clusterloader2 && go build -o clusterloader ./cmd/
```

---

## 2. The three independent rate layers (do not confuse them)

A pod's journey is throttled at three separate, independently-configured
points. Most of our past confusion came from attributing a limit to the
wrong layer.

### Layer 1 — CL2's own client rate limiter

One shared `client-go` rate limiter for every API call the test makes.
Fork-only, set via env:

- `CL2_DEFAULT_QPS` (fork default 100, our configs pass 500)
- `CL2_DEFAULT_BURST` (fork default 200, our configs pass 1000)

This is a **ceiling**, not a target. It can only prevent requests going
out faster than X; it never makes them go faster.

### Layer 2 — the per-phase `tuningSet`

This is what actually *paces* pod creation. Each phase names a tuningSet;
each tuningSet picks exactly one load type:

| Load type | Field(s) | Behaviour |
|---|---|---|
| `qpsLoad` | `qps` | Fixed rate, per-phase limiter |
| `globalQPSLoad` | `qps`, `burst` | Fixed rate + burst, limiter **shared across all phases** using this set |
| `randomizedLoad` | `averageQps` | Inter-arrival uniform in `[0, 2s/averageQps)` |
| `steppedLoad` | `burstSize`, `stepDelay` | A burst of N every `stepDelay` |
| `poissonLoad` | `expectedActionsPerSecond` | Poisson arrivals at rate λ |
| `timeLimitedLoad` | `timeLimit` | Spread all operations evenly over a fixed duration |
| `randomizedTimeLimitedLoad` | `timeLimit` | Each operation starts at a uniformly random point in the window |
| `parallelismLimitedLoad` | `parallelismLimit` | As fast as possible, capped concurrency |

Plus `initialDelay` on any tuningSet.

Our configs define exactly two:

```yaml
tuningSets:
- name: default            # teardown phases
  globalQPSLoad:
    qps:   {{$defaultQps}}     # CL2_DEFAULT_QPS,   default 500
    burst: {{$defaultBurst}}   # CL2_DEFAULT_BURST, default 1000
- name: UniformQPS         # the measured pod-creation phase
{{if $uniformQpsGlobal}}     # CL2_UNIFORM_QPS_GLOBAL, default false
  globalQPSLoad:
    qps:   {{$uniformQps}}     # CL2_UNIFORM_QPS,   default 500
    burst: {{$uniformBurst}}   # CL2_UNIFORM_BURST, default 30
{{else}}
  qpsLoad:
    qps: {{$uniformQps}}       # CL2_UNIFORM_QPS,   default 500
{{end}}
```

**`CL2_UNIFORM_QPS` is the knob that controls arrival rate for the measured
phase.** `CL2_DEFAULT_QPS`/`BURST` only govern the `default` tuningSet
(teardown) plus the global client ceiling.

#### `CL2_UNIFORM_QPS` is per phase, not cluster-wide — multiply by the phase count

This is the single easiest number to get wrong here, so it is worth stating
bluntly rather than leaving it implied by the table above.

`qpsLoad` gives **each phase its own limiter**. The concurrent configs have
**four** creation phases (two AppGroup workloads x two classes), each
referencing `UniformQPS`. So `CL2_UNIFORM_QPS=20` does not cap arrivals at
20/s — it permits up to **4 x 20 = 80/s** in aggregate.

Measured, not theorised: a concurrent classToTopology run at
`CL2_UNIFORM_QPS=20` recorded **40 pods/s** scheduled at N=100, which a
genuine cluster-wide 20/s cap makes arithmetically impossible.

Set `CL2_UNIFORM_QPS_GLOBAL=true` to switch the tuning set to
`globalQPSLoad`, whose limiter is shared across every phase using it. Then
`CL2_UNIFORM_QPS` means what it looks like it means.

Two further consequences of the same schema distinction:

- **Burst only exists on `globalQPSLoad`.** `QPSLoad` is `{qps}`;
  `GlobalQPSLoad` is `{qps, burst}`. There is no burst to set on the default
  per-phase path, so `CL2_UNIFORM_BURST` only takes effect together with
  `CL2_UNIFORM_QPS_GLOBAL=true`. (`CL2_DEFAULT_BURST` is a different knob —
  it reaches only the `default` tuning set, used for teardown.)
- **A per-phase limiter is also shape-wrong for emulating a controller.**
  A shared token bucket with a burst allowance is what
  `kube-controller-manager` actually runs; four independent uniform pacers
  are not.

### Layer 3 — the cluster's own capacity

Admission webhooks, the scheduler, etcd. This is the thing under test; it
is not a knob.

### The ReplicaSet ceiling — why it does NOT apply here

`kube-controller-manager`'s pod-creation path is rate-limited by
`--kube-api-qps` (default **20**), `--kube-api-burst` (default **30**) and
`--concurrent-replicaset-syncs` (default **5**) — one shared token bucket
across every ReplicaSet in the cluster. That is a real and frequently-cited
~20 pods/s ceiling. On our cluster these flags are **not set explicitly**
(verified against the live `kube-controller-manager` pod spec), so the
upstream defaults are in force.

**But this harness never uses that path.** Every pod template here is:

```yaml
apiVersion: v1
kind: Pod
metadata:
  generateName: klastos-sensitive-a-
```

— a **bare Pod created directly by CL2's own client**. There is no
Deployment, no ReplicaSet, and therefore no ReplicaSet controller
involved. The 20 pods/s ceiling governs a code path these runs do not
touch, and does not bound our measured throughput.

It *would* apply the moment a config switched to `kind: Deployment` or
`kind: ReplicaSet`. If you ever add such a config, revisit this section
and expect a hard ~20 pods/s wall regardless of any CL2 setting.

---

## 3. The `SchedulingThroughput` measurement — and its pass/fail gate

Source: `test/perf-tests/clusterloader2/pkg/measurement/common/scheduling_throughput.go`.

Params:

| Param | Default | Meaning |
|---|---|---|
| `action` | — | `start` / `gather` |
| `labelSelector` | — | Which pods to count |
| `measurmentInterval` | `5s` | Sampling window. **Spelling is a typo in upstream — keep it.** Our configs override to `1s` |
| `threshold` | `0` (off) | Minimum required throughput, pods/sec |
| `enableViolations` | `true` | Whether failing `threshold` is an error or just reported |

**The gate keys on `Max`, not the median:**

```go
if threshold > 0 && throughputSummary.Max < threshold {
    err = errors.NewMetricViolationError("scheduler throughput", ...)
}
```

So the run fails only if the **single best sampling window** fell below
the threshold. With our `measurmentInterval: 1s`, `Max` is the peak
one-second scheduling rate.

This is exactly why thresholds that look reasonable are not: a threshold
of 400 demands that at least one 1-second window scheduled 400 pods. It
is not an average requirement.

Reported statistics: `perc01`, `perc10`, `perc50`, `perc90`, `perc99`,
`max`, `min` (the richer percentile set comes from fork commit `8e1323388`).

`enableViolations: false` keeps every number in the report but stops a
missed threshold from aborting the run — the right setting whenever the
threshold is an extrapolation rather than a real requirement.

---

## 4. Environment variable reference

### Read by the CL2 configs

| Variable | Default | Effect |
|---|---|---|
| `CL2_SCHEDULER_THROUGHPUT_PODS` | 5000 (baseline) / 1000 (concurrent) | N — pods per class. Split `N/2` across two AppGroup workloads |
| `CL2_SCHEDULER_THROUGHPUT_THRESHOLD` | 400 (sequential) / 30 (concurrent) | `threshold` for the violation gate (compared against **Max**) |
| `CL2_ENABLE_VIOLATIONS_FOR_SCHEDULING_THROUGHPUT` | `true` | `false` reports throughput without failing the run |
| `CL2_UNIFORM_QPS` | 500 | Arrival rate for the measured creation phase |
| `CL2_UNIFORM_QPS_GLOBAL` | `false` | `true` switches that phase to a **shared** `globalQPSLoad` limiter instead of a per-phase `qpsLoad` one |
| `CL2_UNIFORM_BURST` | 30 | Burst allowance; **only effective with `CL2_UNIFORM_QPS_GLOBAL=true`**, since `qpsLoad` has no burst field |
| `CL2_DEFAULT_QPS` | 500 (fork default 100) | Client limiter + `default` tuningSet qps |
| `CL2_DEFAULT_BURST` | 1000 (fork default 200) | Client limiter + `default` tuningSet burst |
| `POD_SPEC` | `pod-default.yaml` | Which pod template the baseline config uses |
| `CL2_PROMETHEUS_NODE_SELECTOR` | — | Pin Prometheus to the control plane |
| `CL2_PROMETHEUS_TOLERATE_MASTER` | — | Required alongside the above |

### Read by our orchestrator scripts

| Variable | Used by | Effect |
|---|---|---|
| `N_STEPS` | `run-full-*-evaluation.sh` | Space-separated list of N values to sweep |
| `THRESHOLD_OVERRIDE` | `threshold_for()` / `concurrent_threshold_for()` | Pin the threshold instead of the `N/10` formula |
| `ENABLE_VIOLATIONS_OVERRIDE` | `enable_violations_for()` | Force the violations toggle either way |
| `CLASSES` | all | Which classes/rings to run |
| `CLASSIFICATION_SOURCE` | KLASTOS arm | `rbac` (default) or `podlabel` |
| `NODES` | all | Node count passed through to the harness |
| `KLASTOS_REPO` | KLASTOS arm | Path to the klastos checkout |

The default threshold formula in both the sequential and concurrent
orchestrators is `max(N/10, 5)`.

### Which threshold variable to set — they are not interchangeable

Setting `CL2_SCHEDULER_THROUGHPUT_THRESHOLD` on the command line of a run
script **has no effect**. The step runner exports it itself, unconditionally,
overwriting whatever the caller set:

```bash
# concurrent-test/lib/common.sh
export CL2_SCHEDULER_THROUGHPUT_THRESHOLD="$threshold"   # clobbers your value
```

The value it exports comes from `concurrent_threshold_for()` /
`threshold_for()`, which read **`THRESHOLD_OVERRIDE`**. So:

| How you run | Variable to set |
|---|---|
| Through any `run-*.sh` orchestrator | `THRESHOLD_OVERRIDE` |
| Invoking `clusterloader` directly | `CL2_SCHEDULER_THROUGHPUT_THRESHOLD` |

The same applies to `CL2_SCHEDULER_THROUGHPUT_PODS` (exported from `N`) and
`CL2_ENABLE_VIOLATIONS_FOR_SCHEDULING_THROUGHPUT` on the sequential
workload-security-rings orchestrator (exported from `enable_violations_for()`,
overridable with `ENABLE_VIOLATIONS_OVERRIDE`).

Note also that a config's own `DefaultParam` fallback (e.g. `30` in the
concurrent configs) only applies to a direct `clusterloader` invocation —
through an orchestrator the exported `max(N/10, 5)` always wins. For
`N_STEPS="20 100 1000"` that is 5 / 10 / 100, not 30.

**Pairing this with a paced arrival rate:** `Max` can never exceed the
arrival rate, so a threshold above `CL2_UNIFORM_QPS` is unreachable by
construction. Pacing at 20 qps with the auto-scaled threshold of 100 at
N=1000 fails every time with nothing actually wrong. Set
`THRESHOLD_OVERRIDE` below the QPS, or disable violations.

---

## 5. The N/2 AppGroup rule (KLASTOS arm only)

This one bites because the number means something non-obvious.

`klastos/experiment1/*/harness/policy/appgroup-template.yaml` creates one
Diktyo `AppGroup` per class with **exactly 2 workloads** (Diktyo's minimum)
and:

```yaml
spec:
  numMembers: __N__      # TOTAL POD COUNT, not workload-entry count
```

The CRD's own schema defines `numMembers` as "the number of Pods belonging
to the App Group". So with 2 workload entries, **CL2 creates `N/2` pods per
workload**, all sharing that workload's `selector` *label value* — Diktyo
matches workloads by pod label value, not by literal pod name, so one
`workloads[]` entry stands for many pods.

Consequences:

1. **N must be even.** `apply-class-policy.sh` hard-errors otherwise:
   `ERROR: N (...) must be even — split N/2 per AppGroup workload.`
2. **The same N must be passed to both sides.** `CL2_SCHEDULER_THROUGHPUT_PODS=N`
   and `apply-class-policy.sh <class> N` must agree, or the AppGroup's
   `numMembers` will not match the pods that actually exist.
3. The CL2 configs encode the split themselves:
   `{{$halfPods := DivideInt $totalSchedulerThroughputPods 2}}`, used as
   `replicasPerNamespace` for each of the two workload phases.

### Diktyo gotcha: `TopologicalSort.namespaces` must cover your namespace

`diktyo-scheduler` panics with a nil dereference in `TopologicalSort.Less`
whenever an AppGroup lives in a namespace outside the plugin's configured
`namespaces` list — it looks the AppGroup up only in those namespaces,
returns `nil` silently, then dereferences it. The result is a
`CrashLoopBackOff` and **zero pods scheduled**, which looks like a harness
failure but is not. Full analysis:
`Nestor-paper/appclass_operator/ISSUE-diktyo-scheduler-topologicalsort-panic.md`.

Before a KLASTOS run, confirm:

```bash
kubectl -n diktyo get cm diktyo-scheduler-config -o yaml | grep -A4 TopologicalSort
```

covers the namespace your AppGroups are created in.

---

## 6. Per-scenario settings

### 6a. Reproducing the CloudCom paper (Rossi et al.)

**The paper states none of these values.** Its §V gives only the testbed
(12-core Ryzen 9 7900X, 64 GiB, kind + containerd 2.0.4, Gatekeeper 1.0.10,
3 control-plane + 5 workers, KWOK v0.6.1 scaled to 1k simulated nodes,
Prometheus 2.25.0) and reports Table I, which is **latency only**. The
settings below come from their committed rendered configs, not the text —
cite them as artifact-derived.

| Knob | Value |
|---|---|
| `CL2_DEFAULT_QPS` | 500 |
| `CL2_DEFAULT_BURST` | 1000 |
| `CL2_UNIFORM_QPS` | 500 |
| `CL2_SCHEDULER_THROUGHPUT_THRESHOLD` | 400 |
| `measurmentInterval` | 1s |
| Namespaces | single (`enableExistingNamespaces: false`) |
| Pod-startup threshold | 5s |
| Scaling rule | 30 pods per node (10→300, 100→3000, 1000→30000) |

**Known caveat — their threshold was never met.** Their own committed
`SchedulingThroughput_*.json` files show p50 ≈ 50 and max 142–145 at every
scale, against `threshold: 400`. The paper reports no throughput number at
all, consistent with that. Treat ~50 p50 / ~145 max as a property of this
harness, not of the system under test, and do not present a comparable
number from our runs as an improvement over theirs.

A second caveat if you compare against Table I: the Mutation and Validation
columns all read exactly `0.50 / 0.90 / 0.99` ms, which is `q × 1ms` —
every observation landed in Gatekeeper's first histogram bucket and
`histogram_quantile` interpolated linearly inside it. The honest reading is
"Gatekeeper admission completed in under 1 ms, unresolved below that", and
the headline "1.00–1.98 ms total admission overhead" is twice a bucket-width
artifact. The Scheduling column is real.

### 6b. Sequential workload-security-rings (our main arm)

One class at a time, each torn down before the next.

```bash
N_STEPS=1000 ./run-full-workload-security-rings-evaluation.sh
```

| Knob | Value | Why |
|---|---|---|
| `CL2_SCHEDULER_THROUGHPUT_PODS` | N per class | 2 classes → 2N pods total across the run |
| `CL2_SCHEDULER_THROUGHPUT_THRESHOLD` | `max(N/10, 5)` | `threshold_for()` |
| `CL2_ENABLE_VIOLATIONS_FOR_SCHEDULING_THROUGHPUT` | `true` for N<1000, `false` at N≥1000 | `enable_violations_for()` |
| `CL2_UNIFORM_QPS` | 500 | |

**Why violations are disabled at N≥1000.** The `N/10` threshold
extrapolates linearly, but real throughput saturates at a fixed ceiling.
At N=1000 every pod schedules correctly and promptly — `WaitForRunningPods`
always completes, nothing times out — yet `Max` still falls short of 100
and the gate aborts the sweep. Disabling violations keeps the real
p50/p90/p99/max in the report without letting a bad extrapolation kill a
healthy run.

### 6c. Concurrent runs (`test/concurrent-test/`)

Five scenarios: `workload-security-rings`, `multi-tenancy-antiaffinity`,
`multi-tenancy-antiaffinity-and-affinity`, `multi-tenancy-appclass-plugin`,
`multi-tenancy-classtotopology`. All share `concurrent-test/lib/common.sh`
(`concurrent_threshold_for`, `concurrent_run_step`, `concurrent_finalize`).

The difference from sequential: **both classes are created in the same CL2
run with no teardown in between**, so they are genuinely alive on the
cluster simultaneously. That means:

- Four creation phases of `N/2` each → **2N pods total, concurrently**
- `enableExistingNamespaces: true` (sequential uses `number: 1`)
- `SchedulingThroughput` is **not class-aware** — the report shows one
  combined number across both classes' 2N pods. For a per-class breakdown
  read that step's `e2e-latency.json`, which groups by `generateName`.

| Knob | Value | Why |
|---|---|---|
| `CL2_SCHEDULER_THROUGHPUT_PODS` | N per class | 2N pods actually created |
| `CL2_SCHEDULER_THROUGHPUT_THRESHOLD` | default **30**, else `max(N/10,5)` | Lower default than sequential's 400 — the config authors already accounted for a combined, contended run |
| `CL2_PROMETHEUS_NODE_SELECTOR` | control-plane | Exported by `concurrent_run_step` |

**Threshold advice:** because the two classes contend for the same
scheduler, per-class throughput is lower than a sequential run at the same
N. Do not reuse the sequential threshold. Either keep the built-in 30, or
set `THRESHOLD_OVERRIDE` from a measured baseline.

### 6d. Smoke test

```bash
CL2_SCHEDULER_THROUGHPUT_PODS=100 ./run-klastos-workload-security-rings-test.sh
```

N=100 → threshold 10, violations enabled. Fast, and the threshold is low
enough to be genuinely meaningful.

### 6e. Emulating ReplicaSet-paced arrival

Our pod templates are bare `kind: Pod` created directly by CL2, so the
`kube-controller-manager` ceiling never applies (see section 2). To
*approximate* that arrival pattern without rewriting the templates as
Deployments, pace the measured phase with a shared limiter matching the
controller's own defaults:

```bash
CL2_UNIFORM_QPS_GLOBAL=true CL2_UNIFORM_QPS=20 CL2_UNIFORM_BURST=30 \
CL2_ENABLE_VIOLATIONS_FOR_SCHEDULING_THROUGHPUT=false \
N_STEPS="20 100 1000" ./run-concurrent-multitenancy-classtotopology-evaluation.sh
```

`qps: 20` / `burst: 30` are the `kube-controller-manager` defaults
(`--kube-api-qps` / `--kube-api-burst`), and `globalQPSLoad` uses the same
client-go token bucket the controller does, so the arrival *shape* matches,
not just the mean rate.

Violations are disabled because no single threshold fits both ends of the
sweep: `Max` can never exceed the arrival rate, so at 20 qps the N=1000
step's auto-scaled threshold of 100 is unreachable, while a threshold low
enough for N=20 (which produces one ~8/s sample) is meaningless at N=1000.

**What this does and does not reproduce.** It reproduces the arrival rate
and burst shape, which is what throughput and latency claims depend on. It
does **not** reproduce ReplicaSet *semantics*: slow-start batching (1, 2, 4,
8 ... per sync), retry/backoff reconciliation toward a desired replica count,
`ownerReference`s, or the controller identity on the admission request. The
retry behaviour is the significant one for NESTOR, since a held gate or a
rejected admission behaves differently under a controller that keeps
retrying. Report this as "ReplicaSet-paced arrival", never as "tested with
ReplicaSets".

Worth pairing with an unpaced saturation arm (the default 500 qps), since
20 qps sits well below the harness ceiling of ~50 p50 / ~145 max and will
show admission and scheduling keeping up essentially by construction.

---

## 7. Choosing a threshold — the general rule

1. The gate compares against **Max over 1-second windows**, not the mean.
2. Measured scheduling throughput on this harness saturates around
   **p50 ≈ 50, max ≈ 145** pods/s, roughly independently of N. The CloudCom
   artifacts show the same numbers, which is good evidence it is a harness
   property.
3. Therefore any threshold above ~140 will fail at every N, and a formula
   that scales linearly with N will inevitably cross that line.
4. Practical choice:
   - **Regression gate** → a fixed threshold around 40–50, independent of N
   - **Characterisation run** → `enableViolations: false`, read the numbers
   - **Never** → a linear `N/10` extrapolation past N=1000 with violations on

---

## 8. Known gaps

- **Only the sequential workload-security-rings orchestrator disables
  violations automatically.** All 14 CL2 configs now read
  `CL2_ENABLE_VIOLATIONS_FOR_SCHEDULING_THROUGHPUT`, so the toggle works
  everywhere — but only `run-full-workload-security-rings-evaluation.sh`
  has an `enable_violations_for()` that flips it to `false` at N>=1000.
  For a concurrent or multi-tenancy run at large N, set it yourself:

  ```bash
  CL2_ENABLE_VIOLATIONS_FOR_SCHEDULING_THROUGHPUT=false \
    ./concurrent-test/workload-security-rings/run-concurrent-workload-security-rings-evaluation.sh
  ```

  Adding the automatic N-based rule to the other orchestrators is
  deliberately deferred until a run actually hits the condition.
- `measurmentInterval` is misspelled upstream. Fixing it upstream would
  silently change the sampling window from 1s to the 5s default and move
  every `Max` we have recorded. Pin it explicitly in any new config.
