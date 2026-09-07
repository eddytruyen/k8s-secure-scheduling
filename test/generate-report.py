#!/usr/bin/env python3
"""Summarize Experiment 1 ClusterLoader2 result directories (KLASTOS
harness and/or Gatekeeper baseline) into a markdown table.

Recursively discovers every directory containing a junit.xml (one such
directory = one clusterloader run: one class/identifier, one report-dir)
under each given root, rather than assuming a fixed subfolder layout —
the KLASTOS harness and the baseline use different --report-dir
conventions, and testsuite-driven multi-identifier runs (the baseline)
create their own internal per-identifier structure this script doesn't
need to know about ahead of time.

Usage:
  generate-report.py <root> [<root> ...]
  generate-report.py --md <root> [<root> ...] > report.md

Known measurement files read (all optional — missing ones render as "-"):
  junit.xml                                    — pass/fail (failures+errors == 0)
  SchedulingThroughput_*.json                  — scheduled pods/sec percentiles
  SchedulingMetrics_*.json                     — e2eSchedulingLatency percentiles
  *OPAAdmissionRequestDuration_*.json           — KLASTOS admission-mutation latency
  *GatekeeperMutationRequestDuration_*.json     — baseline admission-mutation latency
  *GatekeeperValidationRequestDuration_*.json   — baseline validation latency
"""
import sys
import os
import glob
import json
import argparse
import xml.etree.ElementTree as ET


def latest(pattern):
    files = sorted(glob.glob(pattern), key=os.path.getmtime)
    return files[-1] if files else None


def load_json(path):
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def junit_status(dirpath):
    path = os.path.join(dirpath, "junit.xml")
    if not os.path.exists(path):
        return "?"
    try:
        root = ET.parse(path).getroot()
        ts = root if root.tag == "testsuite" else root.find(".//testsuite")
        if ts is None:
            return "?"
        failures = int(ts.get("failures", 0))
        errors = int(ts.get("errors", 0))
        return "PASS" if failures == 0 and errors == 0 else "FAIL"
    except Exception:
        return "?"


def generic_query_percentiles(dirpath, name_glob):
    """Parse a GenericPrometheusQuery result file's dataItems[0].data —
    confirmed live this session: {"version":"v1","dataItems":[{"data":
    {"Perc50":..,"Perc90":..,"Perc99":..,"Sum":..},"unit":"s"}]}, or
    dataItems: null if the query returned no samples (e.g. the metric
    hasn't been scraped yet, or the ServiceMonitor/query is misconfigured
    — this session hit both, so treat null as "not available", not zero.
    """
    d = load_json(latest(os.path.join(dirpath, name_glob)))
    if not d or not d.get("dataItems"):
        return None
    return d["dataItems"][0].get("data", {})


def fmt_ms(seconds):
    return "-" if seconds is None else f"{seconds * 1000:.1f}ms"


def fmt_num(v):
    return "-" if v is None else str(v)


def summarize(label, dirpath):
    st = load_json(latest(os.path.join(dirpath, "SchedulingThroughput_*.json")))
    sm = load_json(latest(os.path.join(dirpath, "SchedulingMetrics_*.json")))
    e2e = (sm or {}).get("e2eSchedulingLatency", {}) or {}

    opa = generic_query_percentiles(dirpath, "*OPAAdmissionRequestDuration_*.json")
    gk_mut = generic_query_percentiles(dirpath, "*GatekeeperMutationRequestDuration_*.json")
    gk_val = generic_query_percentiles(dirpath, "*GatekeeperValidationRequestDuration_*.json")
    admission = opa or gk_mut

    return {
        "label": label,
        "status": junit_status(dirpath),
        "throughput_p50": (st or {}).get("perc50"),
        "throughput_p90": (st or {}).get("perc90"),
        "throughput_p99": (st or {}).get("perc99"),
        "e2e_p50": e2e.get("Perc50"),
        "e2e_p90": e2e.get("Perc90"),
        "e2e_p99": e2e.get("Perc99"),
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
            label = root_label if rel == "." else f"{root_label}/{rel}"
            rows.append(summarize(label, leaf))

    if not rows:
        print("No runs found (no junit.xml under any given root).", file=sys.stderr)
        sys.exit(1)

    print(render_markdown(rows))


if __name__ == "__main__":
    main()
