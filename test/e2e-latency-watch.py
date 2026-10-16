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

Liveness: a kubectl watch stream can stop delivering events while the
process stays alive and silent - no EOF, no error, nothing on stderr.
Measured (5x run-full-evaluation.sh, 2026-10-15): the baseline arm
recorded only the first 2 of 4 sequential classes in 3 of 5 repeats,
~6000 pods of latency data lost per affected repeat, with the reconnect
counter frozen because reconnecting was only ever triggered by EOF. An
--idle-timeout watchdog now treats "no event for N seconds" as a dead
stream and respawns kubectl. Respawning is lossless for pods that still
exist, because `kubectl get --watch` LISTs before it watches: the new
stream re-delivers every live pod, and records are keyed by UID and
merged, so a pod observed before the gap keeps its original first_seen.
The watchdog also fires during the genuine ~60s lull between two
sequential classes; that respawn is harmless and gives each class a
fresh stream, so it is left to fire rather than suppressed. Respawns
caused by the watchdog are counted separately (idle_respawns) and every
gap is recorded (watch_gaps), so a run that lost data says so in its own
result file instead of looking complete.

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
import os
import select
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone


def canonical_class(s):
    """Normalize a pod's generateName (preferred) into "eu"/"us"/
    "italynorth"/"uc1"/"uc2"/"vanilla", matching generate-report.py's own
    canonical_class() exactly - both must agree, since this is how the
    two scripts' outputs get joined together.

    Not the "data-sovereignty" label: confirmed live this session that
    the baseline's own italynorth-region/pod.yaml sets
    data-sovereignty: eu (not italynorth) - grouping by that label would
    silently merge eu-region and italynorth-region pods together.
    generateName reliably distinguishes them ("pod-churn-eu-" vs
    "pod-churn-italynorth-"), for both the baseline (pod-churn-<region>-,
    pod-churn-<tenant>-tenant-) and KLASTOS (klastos-<region>-<a|b>-)
    naming conventions.
    """
    s = (s or "").lower().rstrip("-")
    for p in ("pod-churn", "klastos", "pod"):
        if s == p:
            s = ""
            break
        if s.startswith(p + "-"):
            s = s[len(p) + 1:]
            break
    for suf in ("-region", "-tenant", "-a", "-b"):
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
    def __init__(self, label_selector, kubeconfig=None, context=None,
                 idle_timeout=30.0, stderr_path=None, resync_interval=20.0):
        self.records = {}  # (namespace, name) -> {"created", "scheduled", "class"}
        self._stop = False
        self._cmd = ["kubectl", "get", "pods", "-A", "-l", label_selector, "--watch", "-o", "json"]
        # Same selector, one-shot: the resync LIST (see _resync_once).
        self._list_cmd = ["kubectl", "get", "pods", "-A", "-l", label_selector, "-o", "json"]
        if kubeconfig:
            self._cmd += ["--kubeconfig", kubeconfig]
            self._list_cmd += ["--kubeconfig", kubeconfig]
        if context:
            self._cmd += ["--context", context]
            self._list_cmd += ["--context", context]
        self.proc = None
        self._reconnects = 0
        # Watchdog state. _last_event_at is monotonic (immune to wall-clock
        # steps); the human-readable gap records use wall-clock separately.
        self._idle_timeout = idle_timeout
        self._last_event_at = time.monotonic()
        self._idle_respawns = 0
        self._gaps = []
        # Resync state. records is mutated from both the watch loop and
        # the resync thread, so every mutation goes through _lock
        # (reentrant: _handle recurses for a kind:List payload).
        self._lock = threading.RLock()
        self._resync_interval = resync_interval
        self._resyncs = 0
        self._resync_failures = 0
        self._resync_first_seen = 0
        self._resync_thread = None
        # kubectl's own stderr was previously inherited, so it landed in
        # whatever log the orchestrator happened to redirect - and when
        # this failure was investigated, nothing was there to find.
        # Capturing it next to the output makes a recurrence diagnosable
        # instead of silent.
        self._stderr = open(stderr_path, "a", buffering=1) if stderr_path else subprocess.DEVNULL
        self._spawn()
        if self._resync_interval and self._resync_interval > 0:
            self._resync_thread = threading.Thread(target=self._resync_loop,
                                                   daemon=True)
            self._resync_thread.start()

    def _spawn(self):
        self.proc = subprocess.Popen(self._cmd, stdout=subprocess.PIPE,
                                     stderr=self._stderr, text=True, bufsize=1)
        self._last_event_at = time.monotonic()

    def _kill_current(self):
        """Reap the current kubectl before replacing it. Previously the old
        Popen was simply dropped on respawn, leaving an orphan kubectl
        holding a watch open against the apiserver for the rest of the run
        - one more per reconnect, all of them still being served."""
        proc, self.proc = self.proc, None
        if proc is None:
            return
        try:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
        except Exception:
            pass
        try:
            if proc.stdout:
                proc.stdout.close()
        except Exception:
            pass

    def _resync_loop(self):
        """Periodic full LIST, merged into the same records dict.

        Independent of the watch stream on purpose: it is the only recovery
        path that works when kubectl is neither erroring (so no EOF to
        reconnect on) nor silent (so the idle watchdog never fires), which is
        exactly the failure that lost 2 of 4 classes on three baseline arms.

        A pod created AND deleted entirely between two resyncs is still
        missed; at a 20s interval against pods that live minutes, that is a
        far smaller hole than the one it closes.
        """
        while not self._stop:
            deadline = time.monotonic() + self._resync_interval
            while not self._stop and time.monotonic() < deadline:
                time.sleep(0.5)
            if self._stop:
                return
            self._resync_once()

    def _resync_once(self):
        try:
            out = subprocess.run(self._list_cmd, stdout=subprocess.PIPE,
                                 stderr=self._stderr, text=True, timeout=180)
            if out.returncode != 0 or not out.stdout:
                self._resync_failures += 1
                return
            obj = json.loads(out.stdout)
        except Exception:
            # A failed resync is a lost safety net, not a lost run - the
            # watch stream is still primary. Counted, never fatal.
            self._resync_failures += 1
            return
        self._resyncs += 1
        self._handle(obj, source="resync")

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
            reason = self._read_until_eof_or_stop()
            if self._stop:
                break
            self._reconnects += 1
            if reason != "eof":
                self._idle_respawns += 1
            self._gaps.append({
                "reason": reason,
                "idle_seconds": round(time.monotonic() - self._last_event_at, 1),
                "resumed_at": datetime.now(timezone.utc).isoformat(),
                "pods_seen_so_far": len(self.records),
            })
            self._kill_current()
            self._spawn()

    # A pretty-printed `kubectl get -o json` LIST of 3000 pods is ~15MB;
    # 64MB is well clear of any legitimate payload while still bounding a
    # stream that has started emitting something that will never parse.
    _MAX_BUF = 64 * 1024 * 1024

    def _read_until_eof_or_stop(self):
        """Returns why it stopped: "eof", "idle", "wedged" or "stop"."""
        decoder = json.JSONDecoder()
        buf = ""
        fd = self.proc.stdout
        while not self._stop:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if not ready:
                # The failure this watchdog exists for: kubectl alive,
                # stream silent, no EOF ever delivered. Without this
                # branch the loop spins here for the rest of the run.
                if time.monotonic() - self._last_event_at > self._idle_timeout:
                    return "idle"
                continue
            line = fd.readline()
            if not line:
                return "eof"  # let run() reconnect
            buf += line
            # Only attempt a parse when the buffer plausibly ends a
            # top-level object. kubectl pretty-prints, so a closing "}" in
            # column 0 ends one. Attempting raw_decode on every line
            # instead is quadratic in the buffer: a 15MB initial LIST
            # (what a respawn mid-class receives) arrives over ~400k
            # lines, each re-scanning everything accumulated so far.
            if not (line.startswith("}") or len(buf) < 1024 * 1024):
                continue
            stripped = buf.strip()
            while stripped:
                try:
                    obj, idx = decoder.raw_decode(stripped)
                except json.JSONDecodeError:
                    break
                self._handle(obj)
                self._last_event_at = time.monotonic()
                stripped = stripped[idx:].strip()
            buf = stripped
            if len(buf) > self._MAX_BUF:
                return "wedged"
        return "stop"

    def _handle(self, pod, source="watch"):
        # A respawned `kubectl get --watch` LISTs before it watches, and
        # that initial payload can arrive as a single List object rather
        # than as individual pods. Unwrapping it is what makes a mid-class
        # respawn lossless instead of silently dropping everything that
        # already existed at reconnect time.
        if isinstance(pod, dict) and pod.get("kind") == "List":
            for item in (pod.get("items") or []):
                self._handle(item, source=source)
            return
        received_at = datetime.now(timezone.utc)
        with self._lock:
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
            # The watch should have delivered this pod and did not.
            # Surfaced in the output so a deaf watch is visible rather
            # than inferred from a short class list - and marked on the
            # record, because such a pod's timings are not comparable
            # with a watch-observed one's (see dump()).
            was_new_via_resync = (source == "resync" and key not in self.records)
            if was_new_via_resync:
                self._resync_first_seen += 1
            rec = self.records.setdefault(key, {
                "namespace": meta["namespace"], "name": meta["name"],
                "created_api": None, "scheduled_api": None,
                "first_seen": None, "scheduled_seen": None,
                "class": cls,
                "classification_source": None,
                "classified_at": None,
                "ever_gated": False,
                "gate_released_at": None,
                "recovered_via_resync": False,
            })
            if was_new_via_resync:
                rec["recovered_via_resync"] = True
            if created_api:
                rec["created_api"] = created_api
            if rec["first_seen"] is None:
                # A resync-discovered pod has been alive for an unknown
                # while, so observation time would overstate its latency.
                # Its API creationTimestamp is what the watch would have
                # seen. Watch-path behaviour is unchanged.
                rec["first_seen"] = (created_api if (source == "resync" and created_api)
                                     else received_at)
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
            # Only a watch event times a phase. A resync observation says
            # "this annotation exists NOW", not when it appeared, so using
            # it here would charge the whole resync delay to classification.
            if (source == "watch"
                    and annotations.get("scheduling.diktyo.x-k8s.io/class-keys")
                    and rec["classified_at"] is None):
                rec["classified_at"] = received_at
            # Gate-state transition tracking: a pod that's never gated at
            # all (OPA's admission-time fast path, is_ready=true at CREATE)
            # has no separate "gate-release" phase - gate_released_at stays
            # None for it, and its scheduling phase is timed from
            # classified_at instead (see dump()). Only a pod OBSERVED with
            # a non-empty schedulingGates at some point, then later
            # observed with none, gets a real gate_released_at.
            # Same reasoning as classified_at: the gated -> ungated
            # transition is only meaningful when actually witnessed. A
            # resync sees one side of it and cannot date the crossing.
            if source == "watch":
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
                        rec["scheduled_seen"] = (t if (source == "resync" and t)
                                                 else received_at)
          except Exception:
            pass  # malformed/unexpected event shape - skip, don't crash the watcher

    def request_stop(self):
        self._stop = True

    def terminate_kubectl(self):
        self._kill_current()
        try:
            if self._stderr is not subprocess.DEVNULL:
                self._stderr.close()
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
        recovered = rec.get("recovered_via_resync", False)
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
        # from whichever event unblocks the pod:
        #   - gated pod: gate release (it genuinely could not schedule
        #     before that).
        #   - never-gated pod, admission fast path (class-keys set AND
        #     gate released atomically at CREATE, e.g. OPA's CASE 1):
        #     classified_at is already ~= first_seen, so anchoring to
        #     first_seen instead makes no practical difference.
        #   - never-gated pod, NO gate exists in this topology at all
        #     (e.g. the AppClass scheduler plugin): classified_at can
        #     reflect some OTHER, unrelated, much-later event (confirmed
        #     live: a classifier's own separate per-pod annotation pass,
        #     unread by the scheduler, lagging real scheduling by
        #     seconds under load) - nothing ever blocked this pod, so its
        #     scheduling phase is anchored to its own creation instead.
        # Both never-gated sub-cases use first_seen - harmless for the
        # fast-path case, correct for the no-gate-at-all case.
        if rec["ever_gated"]:
            unblocked_at = gate_released_at
        else:
            unblocked_at = first_seen
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
            # True = the watch never delivered this pod; it was recovered
            # by a periodic LIST. Present in the pod list for
            # completeness, excluded from every percentile below.
            "recovered_via_resync": recovered,
            # API-embedded timestamps, second-precision only - kept for
            # cross-checking, not used for the actual latency computation.
            "created_api": rec["created_api"].isoformat() if rec["created_api"] else None,
            "scheduled_api": rec["scheduled_api"].isoformat() if rec["scheduled_api"] else None,
        })
        # A recovered pod contributes to completeness (it is in per_pod and
        # in classes_observed) but never to a percentile: its latency is
        # second-quantized API arithmetic and its phases are undatable.
        # Mixing the two bases silently shifts the distribution - measured
        # at 2x on classification p50 and 16x on scheduling p99.
        if not recovered:
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
    summary["__all__"] = percentiles([v for vals in by_class.values() for v in vals])

    phase_summary = {
        phase: {cls: percentiles(vals) for cls, vals in per_class.items()}
        for phase, per_class in by_class_phases.items()
    }
    # Combined-across-every-class aggregate, alongside each real class's
    # own entry — read by generate-report.py's own "__all__" fallback for
    # a combined-run report-dir that covers every class in one pass (see
    # that script's own summarize() for why a per-class key alone isn't
    # enough there).
    for phase in phase_summary:
        phase_summary[phase]["__all__"] = percentiles(
            [v for vals in by_class_phases[phase].values() for v in vals]
        )

    combined_classification_source = {}
    for counts in classification_source_summary.values():
        for src_key, n in counts.items():
            combined_classification_source[src_key] = combined_classification_source.get(src_key, 0) + n
    classification_source_summary["__all__"] = combined_classification_source

    with open(output_path, "w") as f:
        json.dump({
            "summary": summary,
            "phase_summary": phase_summary,
            "classification_source_summary": classification_source_summary,
            "reconnects": watcher._reconnects,
            # Split out of "reconnects" so a silent-stream respawn is
            # distinguishable from an ordinary EOF reconnect, and so the
            # gap list can be checked against the classes actually present
            # in "summary" when a run's output looks short.
            "idle_respawns": watcher._idle_respawns,
            "watch_gaps": watcher._gaps,
            "resyncs": watcher._resyncs,
            "resync_failures": watcher._resync_failures,
            # 0 when the watch is healthy. >0 means the watch stream
            # failed to deliver that many pods and the periodic LIST
            # caught them - the direct measure of the silent-deafness
            # failure this resync exists for.
            "pods_first_seen_via_resync": watcher._resync_first_seen,
            # Same pods, counted where it matters for reading the
            # percentiles: this many are in "pods" but in no percentile.
            "pods_excluded_from_percentiles": sum(
                1 for r in watcher.records.values()
                if r.get("recovered_via_resync")),
            "classes_observed": sorted(k for k in summary if k != "__all__"),
            "pods": per_pod,
        }, f, indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="group=direct-scheduler-throughput")
    ap.add_argument("--output", required=True)
    ap.add_argument("--kubeconfig", default=None)
    ap.add_argument("--context", default=None)
    ap.add_argument("--idle-timeout", type=float, default=30.0,
                    help="respawn kubectl after this many seconds with no "
                         "watch event (default 30; 0 disables the watchdog)")
    ap.add_argument("--resync-interval", type=float, default=20.0,
                    help="full LIST every this many seconds as a safety "
                         "net against a watch that stops delivering new "
                         "pods without erroring (default 20; 0 disables)")
    args = ap.parse_args()

    # Sidecar next to the output rather than inherited, so it survives
    # whatever the orchestrator does with its own stdout/stderr.
    stderr_path = os.path.splitext(args.output)[0] + ".watch-stderr.log"
    watcher = Watcher(args.label, args.kubeconfig, args.context,
                      idle_timeout=(args.idle_timeout or float("inf")),
                      stderr_path=stderr_path,
                      resync_interval=args.resync_interval)

    def handle_signal(signum, frame):
        watcher.request_stop()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    watcher.run()
    watcher.terminate_kubectl()
    dump(watcher, args.output)

    # Surface a lost-data gap on the orchestrator's own stderr. A silent
    # stream previously produced a short-but-plausible result file that
    # looked complete; the point of detecting it is to say so.
    if watcher._resync_first_seen:
        print("WARNING: watch stream missed %d pod(s) in %s - recovered by "
              "periodic resync (%d resyncs, %d failed). Those pods are in "
              "\"pods\" and in classes_observed, but are EXCLUDED from every "
              "percentile: their timestamps come from the second-precision "
              "API, and their phase boundaries were never witnessed. Treat "
              "this arm's percentiles as covering %d pods, not %d."
              % (watcher._resync_first_seen, args.output, watcher._resyncs,
                 watcher._resync_failures,
                 len(watcher.records) - watcher._resync_first_seen,
                 len(watcher.records)), file=sys.stderr)

    long_gaps = [g for g in watcher._gaps if g["idle_seconds"] > 60]
    if long_gaps:
        observed = sorted(k for k in json.load(open(args.output))["summary"]
                          if k != "__all__")
        print("WARNING: %d watch gap(s) over 60s in %s - classes observed: %s"
              % (len(long_gaps), args.output, ", ".join(observed)),
              file=sys.stderr)


if __name__ == "__main__":
    main()
