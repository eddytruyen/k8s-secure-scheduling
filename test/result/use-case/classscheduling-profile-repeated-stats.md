# ClassScheduling-only profile, published `:latest` images: 5-repeat statistics

Data-sovereignty use case, all four classes (`vanilla`/`eu`/`us`/`italynorth`),
N=20/100/1000. 5 repeats of `test/run-repeated-evaluation.sh` against the
ClassScheduling-only (Profile 2) diktyo-scheduler chart profile (see
[appclass-operator-classification-fix-comparison.md](appclass-operator-classification-fix-comparison.md)
for what that profile is and how it compares to the default Diktyo+ClassScheduling
profile), using the **published** `decomads/appclasscontroller:latest`
(digest `b0fc8c3f...`, pushed 2026-09-17T14:09:38Z — freshly updated just
before this run, not this repo's own fix branches) and `decomads/ucsss:latest`
(digest `63f56854...`, unchanged from earlier in this investigation).

Full stats: [`repeated-evaluation-20260917-152834/stats.md`](repeated-evaluation-20260917-152834/stats.md)
([`.csv`](repeated-evaluation-20260917-152834/stats.csv)). Per-repeat raw
summaries: [`full-evaluation-20260917-152834`](full-evaluation-20260917-152834/report.md),
[`-154104`](full-evaluation-20260917-154104/report.md),
[`-155327`](full-evaluation-20260917-155327/report.md),
[`-160544`](full-evaluation-20260917-160544/report.md),
[`-161800`](full-evaluation-20260917-161800/report.md).

Logs checked clean across the full 63-minute, 5-repeat session: 0 restarts
across `appclass-operator`/`unified-operator`/`diktyo-scheduler`/`scheduler-plugins-controller`,
180 tracebacks in the appclass log — all confirmed the same known/harmless
`ExplicitClass_operator.py`/`on_appinfo_event` 404 (exactly 36×5, as
expected), 0 errors in the UCSS log.

## What `classification_source[admission]` actually measures

Every pod gets exactly one value for the `scheduling.diktyo.x-k8s.io/classification-source`
annotation:
- **`admission`** — OPA's mutating webhook wrote the pod's class-keys
  *synchronously at CREATE time* (`main.rego`'s CASE 1) because its class was
  already known and resolvable from OPA's replicated data. Near-zero extra
  latency - the fast path.
- **`appclass_operator`** — the pod missed that window and had its class-keys
  written later, asynchronously, once the full appclass_operator/UCSS
  pipeline (discover → classify → annotate → release gate) caught up. Much
  slower - the slow path.

`classification_source[admission]`'s mean/stdev in the stats tables is the
count (out of N) of pods that took the fast path, averaged across the 5
repeats.

## Headline: N=1000 admission fast-path rate is real, not single-run noise

| Class | admission (mean ± stdev, out of 1000) | e2e latency p50 (mean ± stdev) |
|---|---|---|
| eu | 724.4 ± 15.2 (72.4%) | 5731.2 ± 438.4ms |
| italynorth | 710.6 ± 30.7 (71.1%) | 5111.9 ± 919.7ms |
| us | 698.8 ± 44.3 (69.9%) | 5796.6 ± 587.6ms |

A stdev of 15-44 pods out of 1000 (1.5-4.4 percentage points) across 5
independent repeats is tight. This settles a concern raised earlier in this
investigation about whether a single N=1000 run's numbers could be trusted -
for this specific metric, on this specific configuration, ~70-72% is a real,
reproducible number.

## `vanilla` is a genuine, equally consistent outlier — and it's explained by design, not a bug

| Class | N=1000 admission rate | N=1000 e2e p50 | N=1000 classify_p50 |
|---|---|---|---|
| eu/us/italynorth | ~70-72% | ~5.1-5.8s | 0.0ms (fast path, no wait) |
| **vanilla** | **0.0 ± 0.0 (0%)** | **8852.1 ± 958.1ms** | **8785.0 ± 955.5ms** |

Zero admissions, every single repeat, with zero variance - this is not noise,
it's deterministic. Traced to the actual code, not inferred:

1. **`vanilla` never gets a ClassSchedulingConstraint (CSC) applied at all** -
   `klastos/experiment1/data-sovereignty/harness/apply-class-policy.sh`'s own
   comment: *"Applies one class's CSC (skipped for 'vanilla', which has no
   constraint)"*, and its code: `if [ "$CLASS" != "vanilla" ]; then kubectl
   apply -f csc-$CLASS.yaml; fi`.

2. **Without a CSC, UCSS can only ever place `vanilla`'s class-key in
   `unconstrainedClasses`, never `constrainedClasses`** -
   `class-scheduling-operator/ucss/csi_writer.py`'s `build_csi_spec()`:
   `constrained_classes = set(filtered_singlemap.keys())` (populated only from
   CSC-derived node allow/deny computation), then
   `unconstrained = known_classes - constrained_classes - constrained_inter`.
   A class with no CSC never gets a `singlemap` entry, so it always falls out
   into `unconstrained`.

3. **`main.rego`'s admission fast path (`is_ready`) requires the pod's
   *constrained* classes to be non-empty - membership in `unconstrainedClasses`
   doesn't count**:
   ```rego
   relevant_classes := pod_classes & (constrained | constrained_inter)
   is_ready if {
       count(relevant_classes) > 0
       not has_interclass
       ...
   }
   ```
   `constrained` is built only from `csi.constrainedClasses` - never from
   `unconstrainedClasses`. For a pod whose only class is unconstrained,
   `relevant_classes` is always empty, `count(relevant_classes) > 0` is always
   false, and `is_ready` defaults to `false` unconditionally. There's no path
   through this policy that ever admits it at CREATE time.

4. **This is deliberate, not an oversight** - `main.rego`'s own comment right
   above `is_ready` explains why:
   > *"gate whenever the class is unknown, CSI doesn't exist, or the pod is
   > interclass-constrained - with no exception for classes that merely show
   > up in CSI's unconstrainedClasses. ... There used to be a CASE B here that
   > fast-pathed on 'count(pod_classes - unconstrained) == 0' alone; it let
   > exactly that race through and was the root cause of a live interclass
   > tenant-isolation violation (demo-03: two different tenants' pods
   > scheduled into the same segment). Removed - only CASE A (relevant,
   > non-interclass, all allowed) may skip the gate."*

   In other words: an earlier version of this policy *did* fast-path
   unconstrained classes, and that caused a real security bug (a race where a
   pod's workload-scoped class hadn't yet been computed as interclass-constrained,
   but its appgroup-scoped variant already showed up as unconstrained, wrongly
   admitting it). The fix removed that exception entirely, correctly
   prioritizing correctness over performance - the side effect being that
   *every* truly unconstrained class, `vanilla` included, now always pays the
   slow path, even though semantically "no constraints to check" sounds like
   the safest, simplest case to fast-path.

**Bottom line**: `vanilla`'s 0% admission rate is not a defect to fix - it's
the correct, by-design behavior of a policy that was deliberately hardened
against a real tenant-isolation vulnerability. Recovering a fast path for
genuinely unconstrained classes without reintroducing that race would need a
narrower condition than the one that was removed (e.g. explicitly checking
that *every* one of the pod's classes - both `@workload` and `@appgroup`
variants - resolves to `unconstrained`, not just that the intersection with
constrained classes happens to be empty) - not attempted here, since it's a
security-sensitive change and out of scope for this statistics run.
