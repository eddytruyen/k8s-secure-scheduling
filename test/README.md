# test/

Evaluation harness. ClusterLoader2 (CL2) drives pod-creation load; our
scripts orchestrate the sweeps and build the reports.

## Build CL2 first

```bash
cd perf-tests/clusterloader2
go build -o clusterloader ./cmd/
```

`perf-tests/` is a git submodule pointing at a **fork** of
`kubernetes/perf-tests` (`eddytruyen/perf-tests`, branch
`fix-scheduler-latency-metrics`) — some env vars we rely on do not exist
upstream. See [TUNING.md](TUNING.md) §1.

## Tuning parameters

**[TUNING.md](TUNING.md)** — what every CL2 knob does, which layer it
lives in, and what to set it to per scenario (CloudCom reproduction,
sequential, concurrent, smoke test). Read it before changing a QPS or a
throughput threshold; it also covers the N/2 AppGroup rule and why the
~20 pods/s ReplicaSet ceiling does *not* apply to these runs.

## Layout

- `use-case/` — sequential CL2 configs (baseline + KLASTOS arms)
- `concurrent-test/` — concurrent variants (both classes alive at once),
  sharing `concurrent-test/lib/common.sh`
- `run-full-*-evaluation.sh` — multi-N sweep orchestrators
- `run-klastos-*-test.sh` / `run-use-case-test.sh` — single-run entry points
- `generate-report.py` — builds `report.md` / `report.csv` from a result tree
- `e2e-latency-watch.py` — per-pod phase-latency watcher
- `result/` — run outputs
