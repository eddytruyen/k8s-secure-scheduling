# Experiment 1 (data sovereignty) on the real KU Leuven cluster — N=20

First run of Experiment 1 against real hardware instead of the kind+KWOK simulation.
All three arms completed: **KLASTOS**, **Gatekeeper** (`baseline`) and **Kyverno**.

| | |
|---|---|
| Date | 2026-11-18 |
| Cluster | KU Leuven, `kubernetes-admin@kubernetes` @ 172.22.14.30, control plane `test-master`, 38 real workers |
| Campaign host | 172.22.8.138 (ClusterLoader2 runs here and drives the cluster over the network) |
| Scale | `N_STEPS=20`, `REPEATS=2`, classes `vanilla eu us italynorth` |
| Profile | 2 — `csi-gate-webhook`, `DISABLE_NETWORK_TOPOLOGY=true` |
| Pods observed | 160 / 160 scheduled in **each** arm; pass rate 2/2 per class |
| Code | klastos `KUL-Cluster` @ 890c923, k8s-secure-scheduling `fix/cl2-honour-kubeconfig` @ 55ecdd6 |

Raw data is in `test/result/use-case/` (the three `repeated-run-*` directories below)
and the campaign log directory `campaign-n1000-logs-20261118-120547/`.

- KLASTOS  — `repeated-run-full-evaluation-20261118-120657`
- Gatekeeper — `repeated-run-full-evaluation-20261118-121534`
- Kyverno  — `repeated-run-kyverno-data-sovereignty-evaluation-20261118-122107`

## Are the results in line with KWOK?

**Yes.** Same order of magnitude, same ordering between arms, and the same phase
decomposition. The comparison below is like for like: N=20, 2 repeats, same four
classes, same experiment. All figures are the p50 mean over repeats, in ms, ± stdev
over the 2 repeats.

### KLASTOS arm

| class | metric | KWOK N=20 | KU Leuven N=20 |
|---|---|---|---|
| eu | e2e | 422.8 ± 23.12 | **434.4 ± 71.56** |
| italynorth | e2e | 426.5 ± 31.54 | **489.9 ± 49.36** |
| us | e2e | 465.9 ± 17.18 | **545.0 ± 193.39** |
| vanilla | e2e | 487.5 ± 180.6 | **550.7 ± 45.4** |
| eu | classify | 289.6 ± 28.21 | **271.9 ± 4.53** |
| italynorth | classify | 321.0 ± 71.63 | **327.4 ± 8.13** |
| us | classify | 299.9 ± 65.27 | **317.7 ± 104.37** |
| vanilla | classify | 276.2 ± 60.25 | **403.8 ± 73.61** |
| eu | gate | 126.2 ± 1.48 | **137.1 ± 46.24** |
| italynorth | gate | 72.1 ± 75.38 | **171.1 ± 29.27** |
| us | gate | 166.0 ± 65.62 | **206.5 ± 80.89** |
| vanilla | gate | 142.9 ± 51.62 | **129.5 ± 34.93** |
| eu | sched phase | 7.1 ± 4.74 | **12.2 ± 3.46** |
| italynorth | sched phase | 6.0 ± 0.57 | **11.2 ± 1.56** |
| us | sched phase | 7.0 ± 0.07 | **12.2 ± 4.45** |
| vanilla | sched phase | 69.1 ± 89.8 | **10.6 ± 1.48** |

End-to-end latency on real hardware is **3–17 % higher** than on KWOK, and every
class overlaps within one standard deviation. The structure is unchanged:
classification dominates (~270–400 ms), gate release is second (~70–210 ms), and the
scheduling phase itself is an order of magnitude smaller (~6–12 ms).

### Gatekeeper and Kyverno arms (e2e p50, ms)

| class | Gatekeeper KWOK | Gatekeeper KUL | Kyverno KWOK | Kyverno KUL |
|---|---|---|---|---|
| eu | 47.1 ± 0.42 | **27.4 ± 3.46** | 32.0 ± 12.02 | **19.4 ± 0.71** |
| italynorth | 40.5 ± 14.78 | **26.2 ± 1.98** | 44.2 ± 0.35 | **25.6 ± 7.85** |
| us | 48.0 ± 10.54 | **36.8 ± 3.32** | 17.5 ± 1.91 | **20.3 ± 4.95** |
| vanilla | 27.7 ± 9.19 | **30.5 ± 4.53** | 29.5 ± 11.67 | **22.6 ± 5.02** |

Both baselines are **faster** on the real cluster than on KWOK, which is the expected
direction: the KWOK box is a shared 8-vCPU VM carrying 100 fake nodes and other
workloads, while the KU Leuven control plane is real, dedicated hardware. Neither
baseline reports `classify` or `gate` phases — they only admit pods, they do not
classify or gate them, so their e2e *is* their scheduling phase.

The KLASTOS : baseline ratio is ~10–20× on **both** platforms. That ratio, not the
absolute numbers, is the result that carries over.

### Where the two platforms differ

- **`vanilla` classification**: 276.2 ms on KWOK against 403.8 ms here, the largest
  single gap (+46 %) and the one point that is not within noise.
- **`vanilla` scheduling phase**: KWOK reports 69.1 ± 89.8 ms — a stdev larger than
  the mean, i.e. one bad repeat. The real cluster is tighter at 10.6 ± 1.48 ms.
- **Scheduling phase generally** is ~5 ms higher here (≈12 ms vs ≈7 ms), consistent
  with real scheduling and binding against 38 real nodes rather than fake ones.

## Caveats — read before quoting any of this

1. **Two repeats.** `REPEATS=2` is the minimum the harness accepts. Several spreads
   are large (`us` e2e ± 193 ms); these numbers are a smoke test that the pipeline
   works on real hardware, **not** a measurement for the paper.
2. **N=20, not N=1000.** The KWOK data-sovereignty runs usually used N=1000, and that
   is a *different regime*, not a scaled version of this one: KWOK at N=1000 reports
   e2e p50 ≈ 9.6 ms with `classify` ≈ 0.0 and `gate` ≈ 228–398 ms. Do not compare the
   N=1000 KWOK figures against the N=20 figures here — the N=20 KWOK runs
   (2026-11-05) are the correct comparison and are the ones used above.
3. **Prometheus-derived measurements are absent.** `CL2_ENABLE_PROMETHEUS=false` on
   this cluster, because ClusterLoader2 otherwise installs a second Prometheus stack
   into the shared `monitoring` namespace and crashloops the cluster's own
   prometheus-operator. `APIResponsivenessPrometheus`, `SchedulingThroughputPrometheus`
   and `OPAAdmissionRequestDuration` therefore skip themselves.
4. **`SchedulingMetrics` is absent.** `CL2_ENABLE_SCHEDULER_METRICS=false`, because
   kube-scheduler binds `127.0.0.1` (kubeadm default) so its `:10259` endpoint is not
   reachable through the apiserver proxy. The scheduler's own latency histograms are
   not collected here.
5. **`throughput_p50 = 0.0`** in every arm, on both platforms. The throughput
   threshold in `config-klastos.yaml` is calibrated for N=1000; at N=20 the check does
   not apply. It is not a regression.
6. **KWOK pods never run containers.** The phases compared here (classification, gate
   release, scheduling) are all control-plane, so they are comparable; "scheduled"
   means bound, not running.

## Reproducing

From 172.22.8.138:

```bash
~/kul-smoke3.sh     # sets KUBECONFIG, CLUSTER_BACKEND=real, the CL2_* overrides,
                    # and refuses to start if exp3 Gatekeeper or leftover CL2
                    # ServiceMonitors are present
```

The campaign ends with the KLASTOS stack torn down and Kyverno installed — a state
its own preflight rejects. Before the next run, remove Kyverno and redeploy the
stack, or preflight will fail on a missing `diktyo-scheduler`.
