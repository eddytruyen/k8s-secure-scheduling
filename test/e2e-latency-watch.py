#!/usr/bin/env python3
"""True e2e pod scheduling latency, measured identically regardless of
which scheduler processes the pod.

Why this exists: ClusterLoader2's own "SchedulingMetrics" measurement
hardcodes a direct proxy call to a pod literally named
"kube-scheduler-<masterName>" on port 10259 (the DEFAULT scheduler's own
static pod) - it can never see a second/custom scheduler like
diktyo-scheduler, whose pods it never touches. Separately, confirmed
live this session that diktyo-scheduler's own binary (a custom,
non-standard build) doesn't even register the
scheduler_pod_scheduling_duration_seconds histogram that measurement
queries for. Both are real, but neither means "scheduling took 0ms" -
it means "unmeasurable via that path". This script sidesteps both
problems entirely by computing latency from the pod objects themselves:
creationTimestamp -> the first time its PodScheduled condition became
True - the same definition, computed the same way, for any scheduler.

Watches (kubectl get --watch -o json) all pods matching a label
selector across all namespaces for as long as this process runs,
grouping each pod under the "data-sovereignty" label value on its own
object (defaulting to "vanilla" when absent) - the same label both the
KLASTOS harness's and the baseline's pod templates already carry, so
grouping is consistent across both without any extra wiring. On
SIGTERM/SIGINT, stops watching and writes per-pod records plus
aggregate percentiles (grouped by that label) to the given output file.

Also captures, per pod (KLASTOS only - the baseline has no equivalent
annotation/gate, so these are always None/absent for it):
  - classification_source: the FINAL observed value of
    scheduling.diktyo.x-k8s.io/classification-source ("admission" if
    OPA's own fast path set it and it was never overwritten,
    "appclass_operator" if Stage 3 wrote or later overwrote it) -
    added because manually re-deriving this via an ad-hoc raw pod-watch
    every time it comes up wasted a repeat question; it's now a
    standard part of every run's output.
  - a three-phase latency breakdown (classification / gate-release
    (UCSS) / scheduling), decomposing the single e2e latency number
    into where the time actually goes:
      classification: pod created -> class-keys annotation first
        appears (whichever path wrote it).
      gate-release: class-keys annotation appears -> schedulingGates
        actually cleared - only applies to a pod that was OBSERVED
        gated at some point (OPA's CASE 2); a pod that took the
        admission fast path (CASE 1, never gated at all) has no
        separate gate-release phase, so this is None for it rather
        than a misleading zero.
      scheduling: from whichever event unblocks the pod (gate-release
        if it was ever gated, otherwise classification itself) -> the
        PodScheduled condition. This isolates the scheduler's own
        processing time from whatever happened before the pod was even
        eligible to be scheduled.

Latency is timed from THIS PROCESS'S OWN wall-clock receipt time for
each watch event, not the pod objects' embedded creationTimestamp /
lastTransitionTime fields - confirmed live those are truncated to
whole-SECOND precision by the API server (metav1.Time has no
sub-second component), while the actual latencies in this benchmark's
regime are tens of milliseconds - entirely lost below that precision
floor, silently rounding every real measurement to 0. Using this
process's own receipt timestamps trades that away for genuine
sub-second precision, at the cost of adding a small, roughly-constant
watch-delivery-latency bias - applied identically to both approaches
through the same watcher, so relative comparisons stay fair even
though the absolute numbers include it.

Usage (wrap a harness invocation with it - the harness creates AND
deletes the pods, so the watcher must be running for the pods' entire
lifetime, not just its own read afterward):
  python3 e2e-latency-watch.py --output /tmp/watch.json &
  WATCHER=$!
  ./run-klastos-use-case-test.sh ...
  kill -TERM $WATCHER; wait $WATCHER
  cat /tmp/watch.json
"""
import argparse
import json
import select
import signal
import subprocess
import sys
from datetime import datetime, timezone


def canonical_class(s):
    """Normalize a pod's generateName (preferred) into "eu"/"us"/
    "italynorth"/"vanilla", matching generate-report.py's own
    canonical_class() exactly - both must agree, since this is how the
    two scripts' outputs get joined together.

    Not the "data-sovereignty" label: confirmed live this session that
    the baseline's own italynorth-region/pod.yaml sets
    data-sovereignty: eu (not italynorth) - grouping by that label would
    silently merge eu-region and italynorth-region pods together.
    generateName reliably distinguishes them ("pod-churn-eu-" vs
    "pod-churn-italynorth-"), for both the baseline (pod-churn-<region>-)
    and KLASTOS (klastos-<region>-<a|b>-) naming conventions.
    """
    s = (s or "").lower().rstrip("-")
    for p in ("pod-churn", "klastos", "pod"):
        if s == p:
            s = ""
            break
        if s.startswith(p + "-"):
            s = s[len(p) + 1:]
            break
    for suf in ("-region", "-a", "-b"):
        if s.endswith(suf):
            s = s[: -len(suf)]
            break
    return s.strip("-") or "vanilla"


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


class Watcher:
    def __init__(self, label_selector, kubeconfig=None, context=None):
        self.records = {}  # (namespace, name) -> {"created", "scheduled", "class"}
        self._stop = False
        self._cmd = ["kubectl", "get", "pods", "-A", "-l", label_selector, "--watch", "-o", "json"]
        if kubeconfig:
            self._cmd += ["--kubeconfig", kubeconfig]
        if context:
            self._cmd += ["--context", context]
        self.proc = None
        self._reconnects = 0
        self._spawn()

    def _spawn(self):
        self.proc = subprocess.Popen(self._cmd, stdout=subprocess.PIPE, text=True, bufsize=1)

    def run(self):
        """Runs until request_stop() is called. A watch stream can end on
        its own well before that (apiserver watch timeout, a transient
        connection drop) - confirmed live this session: an early,
        unrequested EOF silently ended the whole watcher after only the
        FIRST class's pods (of several run sequentially within one step)
        had been observed, with no exception/traceback at all, since a
        clean EOF isn't an error condition to Python - just ~3 of 4
        classes' worth of e2e latency data going quietly missing from
        that step's output. Reconnects (respawning kubectl) on any EOF
        that wasn't from request_stop(), preserving already-collected
        records across the gap.
        """
        while not self._stop:
            self._read_until_eof_or_stop()
            if self._stop:
                break
            self._reconnects += 1
            self._spawn()

    def _read_until_eof_or_stop(self):
        decoder = json.JSONDecoder()
        buf = ""
        fd = self.proc.stdout
        while not self._stop:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if not ready:
                continue
            line = fd.readline()
            if not line:
                return  # EOF - let run() decide whether to reconnect
            buf += line
            stripped = buf.strip()
            while stripped:
                try:
                    obj, idx = decoder.raw_decode(stripped)
                except json.JSONDecodeError:
                    break
                self._handle(obj)
                stripped = stripped[idx:].strip()
            buf = stripped

    def _handle(self, pod):
        received_at = datetime.now(timezone.utc)
        try:
            meta = pod["metadata"]
            # Keyed by UID, not (namespace, name): confirmed live this
            # session that ClusterLoader2 assigns pods explicit,
            # index-based names ("klastos-scheduler-throughput-pod-b-0")
            # that are IDENTICAL across every sequential class run within
            # a step (vanilla/eu/us/italynorth all reuse the same N
            # names) - keying by name alone collided every later class's
            # pods into the first class's already-existing record,
            # silently classifying 100% of pods as whichever class ran
            # first (setdefault never updates "class" on a pre-existing
            # key). UID is unique per object even when names repeat.
            key = meta.get("uid") or (meta["namespace"], meta["name"])
            created_api = parse_ts(meta.get("creationTimestamp"))
            labels = meta.get("labels", {}) or {}
            gen_name = meta.get("generateName")
            cls = canonical_class(gen_name) if gen_name else labels.get("data-sovereignty", "vanilla")
            rec = self.records.setdefault(key, {
                "namespace": meta["namespace"], "name": meta["name"],
                "created_api": None, "scheduled_api": None,
                "first_seen": None, "scheduled_seen": None,
                "class": cls,
                "classification_source": None,
                "classified_at": None,
                "ever_gated": False,
                "gate_released_at": None,
            })
            if created_api:
                rec["created_api"] = created_api
            if rec["first_seen"] is None:
                rec["first_seen"] = received_at
            # Tracks the LATEST observed value, not the first: this can
            # legitimately change over a pod's life (OPA's admission-time
            # fast path writes "admission" at CREATE; appclass_operator's
            # Stage 3 may later overwrite it to "appclass_operator" if its
            # own recompute disagrees) - the final, settled value is what
            # answers "which path actually won," not whichever was seen
            # first during the watch.
            annotations = meta.get("annotations", {}) or {}
            src = annotations.get("scheduling.diktyo.x-k8s.io/classification-source")
            if src:
                rec["classification_source"] = src
            # First appearance of the class-keys annotation at all (either
            # path writes it) - the end of the "classification" phase,
            # start of "gate-release"/"scheduling" below.
            if annotations.get("scheduling.diktyo.x-k8s.io/class-keys") and rec["classified_at"] is None:
                rec["classified_at"] = received_at
            # Gate-state transition tracking: a pod that's never gated at
            # all (OPA's admission-time fast path, is_ready=true at CREATE)
            # has no separate "gate-release" phase - gate_released_at stays
            # None for it, and its scheduling phase is timed from
            # classified_at instead (see dump()). Only a pod OBSERVED with
            # a non-empty schedulingGates at some point, then later
            # observed with none, gets a real gate_released_at.
            gates = (pod.get("spec", {}) or {}).get("schedulingGates")
            if gates:
                rec["ever_gated"] = True
            elif rec["ever_gated"] and rec["gate_released_at"] is None:
                rec["gate_released_at"] = received_at
            for cond in (pod.get("status", {}) or {}).get("conditions", []) or []:
                if cond.get("type") == "PodScheduled" and cond.get("status") == "True":
                    t = parse_ts(cond.get("lastTransitionTime"))
                    if t and (rec["scheduled_api"] is None or t < rec["scheduled_api"]):
                        rec["scheduled_api"] = t
                    if rec["scheduled_seen"] is None:
                        rec["scheduled_seen"] = received_at
        except Exception:
            pass  # malformed/unexpected event shape - skip, don't crash the watcher

    def request_stop(self):
        self._stop = True

    def terminate_kubectl(self):
        try:
            self.proc.terminate()
        except Exception:
            pass


def percentiles(values):
    if not values:
        return {"p50": None, "p90": None, "p99": None, "count": 0}
    s = sorted(values)

    def pct(p):
        idx = min(len(s) - 1, int(round(p * (len(s) - 1))))
        return s[idx]

    return {"p50": pct(0.50), "p90": pct(0.90), "p99": pct(0.99), "count": len(s)}


def dump(watcher, output_path):
    by_class = {}
    by_class_phases = {"classification": {}, "gate_release": {}, "scheduling": {}}
    classification_source_summary = {}
    per_pod = []
    for rec in watcher.records.values():
        ns, name = rec["namespace"], rec["name"]
        first_seen, scheduled_seen = rec["first_seen"], rec["scheduled_seen"]
        classified_at, gate_released_at = rec["classified_at"], rec["gate_released_at"]
        cls = rec["class"]
        src = rec["classification_source"]
        latency = (
            (scheduled_seen - first_seen).total_seconds()
            if (first_seen and scheduled_seen) else None
        )

        # Phase 1: classification - pod created -> class-keys annotation
        # first appears, whichever path wrote it (admission or Stage 3).
        classification_seconds = (
            (classified_at - first_seen).total_seconds()
            if (first_seen and classified_at) else None
        )
        # Phase 2: gate-release/UCSS - only meaningful for a pod that was
        # actually gated at some point (OPA's CASE 2). A pod that took the
        # admission fast path (CASE 1) never carries a gate at all, so
        # this phase doesn't apply to it - stays None, not zero, so it's
        # excluded from that phase's percentiles rather than dragging them
        # down with a false "instant" data point.
        gate_release_seconds = (
            (gate_released_at - classified_at).total_seconds()
            if (rec["ever_gated"] and classified_at and gate_released_at) else None
        )
        # Phase 3: scheduling - actual scheduler processing time, timed
        # from whichever event unblocks the pod: gate release if it was
        # ever gated, otherwise classification itself (CASE 1 admits and
        # unblocks in the same atomic decision, no separate gate phase).
        if rec["ever_gated"]:
            unblocked_at = gate_released_at
        else:
            unblocked_at = classified_at
        scheduling_seconds = (
            (scheduled_seen - unblocked_at).total_seconds()
            if (unblocked_at and scheduled_seen) else None
        )

        per_pod.append({
            "namespace": ns, "name": name, "class": cls,
            "first_seen": first_seen.isoformat() if first_seen else None,
            "scheduled_seen": scheduled_seen.isoformat() if scheduled_seen else None,
            "latency_seconds": latency,
            "classification_source": src,
            "classification_seconds": classification_seconds,
            "gate_release_seconds": gate_release_seconds,
            "scheduling_seconds": scheduling_seconds,
            "ever_gated": rec["ever_gated"],
            # API-embedded timestamps, second-precision only - kept for
            # cross-checking, not used for the actual latency computation.
            "created_api": rec["created_api"].isoformat() if rec["created_api"] else None,
            "scheduled_api": rec["scheduled_api"].isoformat() if rec["scheduled_api"] else None,
        })
        if latency is not None:
            by_class.setdefault(cls, []).append(latency)
        if classification_seconds is not None:
            by_class_phases["classification"].setdefault(cls, []).append(classification_seconds)
        if gate_release_seconds is not None:
            by_class_phases["gate_release"].setdefault(cls, []).append(gate_release_seconds)
        if scheduling_seconds is not None:
            by_class_phases["scheduling"].setdefault(cls, []).append(scheduling_seconds)
        src_key = src or "none"
        classification_source_summary.setdefault(cls, {}).setdefault(src_key, 0)
        classification_source_summary[cls][src_key] += 1

    summary = {cls: percentiles(vals) for cls, vals in by_class.items()}
    phase_summary = {
        phase: {cls: percentiles(vals) for cls, vals in per_class.items()}
        for phase, per_class in by_class_phases.items()
    }
    with open(output_path, "w") as f:
        json.dump({
            "summary": summary,
            "phase_summary": phase_summary,
            "classification_source_summary": classification_source_summary,
            "reconnects": watcher._reconnects,
            "pods": per_pod,
        }, f, indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="group=direct-scheduler-throughput")
    ap.add_argument("--output", required=True)
    ap.add_argument("--kubeconfig", default=None)
    ap.add_argument("--context", default=None)
    args = ap.parse_args()

    watcher = Watcher(args.label, args.kubeconfig, args.context)

    def handle_signal(signum, frame):
        watcher.request_stop()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    watcher.run()
    watcher.terminate_kubectl()
    dump(watcher, args.output)


if __name__ == "__main__":
    main()
