#!/usr/bin/env python3
"""Summarize Experiment 1 ClusterLoader2 result directories (KLASTOS
harness and/or Gatekeeper baseline) into a markdown table.

Recursively discovers every directory containing a junit.xml (one such
directory = one clusterloader run: one class/identifier for KLASTOS, or
ALL 4 identifiers flatly mixed together for the baseline's own
--testsuite report-dir) under each given root.

Within a leaf directory, measurement files are further grouped by the
identifier embedded in their own filename — e.g.
"SchedulingThroughput_direct-scheduler-throughput_pod-eu-region_<ts>.json"
groups under "pod-eu-region"; KLASTOS's per-class dirs have no such
suffix (each dir already holds exactly one class) and group under "".
This step is required for the baseline, whose --testsuite invocation
writes all 4 identifiers' files into ONE flat directory — without it,
a single row would silently merge measurements from 4 different
identifiers together.

Freshness is judged by the ISO-8601 timestamp EMBEDDED IN EACH
FILENAME, never filesystem mtime — confirmed live this session that
copying a result directory with `cp -r` (as run-full-evaluation.sh
does, to keep each N-step's measurements before the next step
overwrites the shared source directory) resets every file's mtime to
the copy time, making "latest by mtime" indistinguishable and liable to
pick a file left over from a run days earlier once several metric
files share the same result directory (the baseline's own
result/use-case/<test>-test/ has never been cleared between runs all
session, unlike KLASTOS's harness which overwrites the same fixed
per-class path every run instead of accumulating).

e2e latency comes from e2e-latency-watch.py's own output
(<STEP_DIR>/e2e-latency.json — one directory above each leaf, since one
watcher runs for a whole step covering all identifiers), NOT from
SchedulingMetrics' own e2eSchedulingLatency field: confirmed live this
session that ClusterLoader2's SchedulingMetrics measurement hardcodes a
direct proxy call to a pod literally named "kube-scheduler-<masterName>"
(the DEFAULT scheduler's own static pod) — it can never observe
diktyo-scheduler (a separate Deployment) at all, and separately, that
custom-built diktyo-scheduler binary doesn't even register the
histogram that measurement queries for. Every KLASTOS-side
e2eSchedulingLatency value was silently 0 because of this, not because
scheduling was instant — see e2e-latency-watch.py's own header for the
full story and why it measures this independently, from pod-watch
events instead.

Usage:
  generate-report.py <root> [<root> ...]

Known measurement files read (all optional — missing ones render as "-"):
  junit.xml                                    — pass/fail (failures+errors == 0)
  SchedulingThroughput_*.json                  — scheduled pods/sec percentiles
  ../e2e-latency.json                          — true e2e scheduling latency (see above)
  *OPAAdmissionRequestDuration_*.json           — KLASTOS admission-mutation latency
  *GatekeeperMutationRequestDuration_*.json     — baseline admission-mutation latency
  *GatekeeperValidationRequestDuration_*.json   — baseline validation latency
"""
import sys
import os
import re
import glob
import json
import argparse
import xml.etree.ElementTree as ET

_TS_RE = re.compile(r"_(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)\.json$")

# (report-column key, literal filename prefix before the identifier segment)
_METRIC_PREFIXES = {
    "throughput": "SchedulingThroughput_",
    "scheduling_metrics": "SchedulingMetrics_",
    "opa": "GenericPrometheusQuery OPAAdmissionRequestDuration_",
    "gk_mutation": "GenericPrometheusQuery GatekeeperMutationRequestDuration_",
    "gk_validation": "GenericPrometheusQuery GatekeeperValidationRequestDuration_",
}


def canonical_class(s):
    """Normalize a CL2 identifier ("pod-eu-region", "vanilla", "") or a
    KLASTOS leaf directory's own basename ("eu", "vanilla") into
    "eu"/"us"/"italynorth"/"vanilla" — MUST match
    e2e-latency-watch.py's own canonical_class() exactly, since this is
    how this script's per-row identifiers get joined against that
    script's own generateName-derived groups."""
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


def load_e2e_latency(dirpath, class_key):
    """e2e-latency-watch.py writes ONE file per evaluation step (STEP_DIR
    /e2e-latency.json), covering every identifier/class run during that
    step. How many directory levels above the leaf (junit.xml-containing)
    directory STEP_DIR sits differs by harness: baseline's leaf IS
    STEP_DIR/measurements (one level), but KLASTOS's leaf is
    STEP_DIR/measurements/<class> (two levels) — confirmed live this
    session that assuming a fixed one-level distance silently missed
    e2e-latency.json for every KLASTOS row. Walk upward instead of
    assuming a fixed depth."""
    d = os.path.dirname(dirpath.rstrip("/"))
    for _ in range(3):
        data = load_json(os.path.join(d, "e2e-latency.json"))
        if data:
            return (data.get("summary") or {}).get(class_key)
        parent = os.path.dirname(d)
        if parent == d:
            break
        d = parent
    return None


def load_json(path):
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def junit_status(dirpath, identifier=""):
    """Pass/fail for this directory, or for just one identifier within it.

    The baseline writes all 4 identifiers into ONE junit.xml (a
    --testsuite run) — its suite-level failures/errors counts cover all
    of them mixed together, so a real failure in "eu" would otherwise
    mark "vanilla"'s row FAIL too. When identifier is given, check only
    that identifier's own <testcase> entries (named "<identifier> overall
    (...)" / "<identifier>: ...") for a <failure>/<error> child instead.
    """
    path = os.path.join(dirpath, "junit.xml")
    if not os.path.exists(path):
        return "?"
    try:
        root = ET.parse(path).getroot()
        ts = root if root.tag == "testsuite" else root.find(".//testsuite")
        if ts is None:
            return "?"
        if not identifier:
            failures = int(ts.get("failures", 0))
            errors = int(ts.get("errors", 0))
            return "PASS" if failures == 0 and errors == 0 else "FAIL"
        found_any = False
        for tc in ts.findall("testcase"):
            name = tc.get("name", "")
            if name.startswith(identifier + ":") or name.startswith(identifier + " "):
                found_any = True
                if tc.find("failure") is not None or tc.find("error") is not None:
                    return "FAIL"
        return "PASS" if found_any else "?"
    except Exception:
        return "?"


def identifier_of(basename, prefix):
    """Strip a known literal metric-name prefix, the CONSTANT group-name
    segment CL2's own config `name:` field contributes right after it
    (e.g. "direct-scheduler-throughput", "klastos-scheduler-throughput" —
    always hyphenated, never containing an underscore, so it's always
    exactly the first "_"-separated segment), and the trailing
    _<timestamp>.json — leaving whatever's left as the identifier key
    (e.g. "pod-eu-region" for the baseline's own --testsuite identifiers,
    or "" when there's nothing left at all — KLASTOS's per-class dirs,
    which hold only one identifier already, contribute no such suffix)."""
    if not basename.startswith(prefix):
        return None
    rest = basename[len(prefix):]
    m = _TS_RE.search(rest)
    if not m:
        return None
    rest = rest[: m.start()].strip("_")
    parts = rest.split("_", 1)
    return parts[1] if len(parts) > 1 else ""


def discover_identifiers(dirpath):
    """All distinct identifier keys present in this directory, derived
    from whichever metric files always exist (throughput + scheduling
    latency are present for every run of either harness)."""
    ids = set()
    for prefix in (_METRIC_PREFIXES["throughput"], _METRIC_PREFIXES["scheduling_metrics"]):
        for path in glob.glob(os.path.join(dirpath, prefix + "*.json")):
            ident = identifier_of(os.path.basename(path), prefix)
            if ident is not None:
                ids.add(ident)
    return ids or {""}


def latest_for(dirpath, prefix, identifier):
    """Newest (by filename timestamp, not mtime) file for this metric
    prefix + identifier combination in dirpath, or None."""
    candidates = []
    for path in glob.glob(os.path.join(dirpath, prefix + "*.json")):
        basename = os.path.basename(path)
        ident = identifier_of(basename, prefix)
        if ident != identifier:
            continue
        m = _TS_RE.search(basename)
        ts = m.group(1) if m else ""  # ISO-8601 sorts lexicographically = chronologically
        candidates.append((ts, path))
    if not candidates:
        return None
    return sorted(candidates)[-1][1]


def generic_query_percentiles(dirpath, prefix, identifier):
    d = load_json(latest_for(dirpath, prefix, identifier))
    if not d or not d.get("dataItems"):
        return None
    return d["dataItems"][0].get("data", {})


def fmt_ms(seconds):
    """For GenericPrometheusQuery-derived values (OPA/Gatekeeper mutation
    and validation) — these come from PromQL evaluation, always seconds."""
    return "-" if seconds is None else f"{seconds * 1000:.1f}ms"




def fmt_num(v):
    return "-" if v is None else str(v)


def summarize(label, dirpath, identifier):
    st = load_json(latest_for(dirpath, _METRIC_PREFIXES["throughput"], identifier))

    class_key = canonical_class(identifier or os.path.basename(dirpath.rstrip("/")))
    e2e = load_e2e_latency(dirpath, class_key) or {}

    opa = generic_query_percentiles(dirpath, _METRIC_PREFIXES["opa"], identifier)
    gk_mut = generic_query_percentiles(dirpath, _METRIC_PREFIXES["gk_mutation"], identifier)
    gk_val = generic_query_percentiles(dirpath, _METRIC_PREFIXES["gk_validation"], identifier)
    admission = opa or gk_mut

    return {
        "label": label,
        "status": junit_status(dirpath, identifier),
        "throughput_p50": (st or {}).get("perc50"),
        "throughput_p90": (st or {}).get("perc90"),
        "throughput_p99": (st or {}).get("perc99"),
        "e2e_p50": e2e.get("p50"),
        "e2e_p90": e2e.get("p90"),
        "e2e_p99": e2e.get("p99"),
        "e2e_count": e2e.get("count"),
        "admission_p50": (admission or {}).get("Perc50"),
        "admission_p90": (admission or {}).get("Perc90"),
        "admission_p99": (admission or {}).get("Perc99"),
        "validation_p99": (gk_val or {}).get("Perc99"),
    }


def find_leaf_dirs(root):
    leaves = []
    for dirpath, _dirnames, filenames in os.walk(root):
        if "junit.xml" in filenames:
            leaves.append(dirpath)
    return sorted(leaves)


def render_markdown(rows):
    headers = [
        "Run", "Status", "Sched pods/s (p50/p90/p99)",
        "e2e latency (p50/p90/p99)", "Admission-mutation (p50/p90/p99)",
        "Validation p99",
    ]
    lines = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    for r in rows:
        sched = f"{fmt_num(r['throughput_p50'])}/{fmt_num(r['throughput_p90'])}/{fmt_num(r['throughput_p99'])}"
        e2e = f"{fmt_ms(r['e2e_p50'])}/{fmt_ms(r['e2e_p90'])}/{fmt_ms(r['e2e_p99'])}"
        adm = f"{fmt_ms(r['admission_p50'])}/{fmt_ms(r['admission_p90'])}/{fmt_ms(r['admission_p99'])}"
        val = fmt_ms(r["validation_p99"])
        lines.append(f"| {r['label']} | {r['status']} | {sched} | {e2e} | {adm} | {val} |")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="+", help="result root directories to scan recursively")
    args = parser.parse_args()

    rows = []
    for root in args.roots:
        root = root.rstrip("/")
        root_label = os.path.basename(root)
        for leaf in find_leaf_dirs(root):
            rel = os.path.relpath(leaf, root)
            base_label = root_label if rel == "." else f"{root_label}/{rel}"
            for identifier in sorted(discover_identifiers(leaf)):
                label = base_label if not identifier else f"{base_label}/{identifier}"
                rows.append(summarize(label, leaf, identifier))

    if not rows:
        print("No runs found (no junit.xml under any given root).", file=sys.stderr)
        sys.exit(1)

    print(render_markdown(rows))


if __name__ == "__main__":
    main()
