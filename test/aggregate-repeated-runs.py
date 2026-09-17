#!/usr/bin/env python3
"""Aggregate several run-full-evaluation.sh result roots (each containing its
own report.csv, see generate-report.py --csv) into one mean/stdev summary per
reported metric — for answering "is this number stable across repeats, or
noise?" instead of trusting a single run.

Each report.csv row's own "run" column is prefixed with that run's own
result-root basename (e.g. "full-evaluation-20260917-132102/klastos-n1000/
measurements/eu") — repeats land in DIFFERENT result roots (each
run-full-evaluation.sh invocation makes its own timestamped directory), so
rows can't be joined on that column as-is. This strips exactly that leading
path segment before grouping, so the same class/N-step/harness-arm row from
every repeat lands in the same group regardless of which repeat produced it.

classification_source (e.g. "admission=690,appclass_operator=310") is parsed
per key and averaged per key too — a missing key in one repeat counts as 0
for that repeat, not as absent data, since "admission" not appearing means
zero pods used that source that run, a real zero.

status (PASS/FAIL/?) is reported as "<pass_count>/<total>" rather than
averaged — it's categorical, not a number to take a mean of.

Every other column from report.csv is a plain numeric metric (percentile in
ms, or pods/sec) — mean/stdev computed directly, skipping any repeat where
that cell was empty ("-": no such measurement exists for this row's harness
arm, e.g. validation_p99_ms for a KLASTOS row) rather than treating it as 0.

Usage:
  aggregate-repeated-runs.py <result_root> [<result_root> ...] --out DIR
    (writes DIR/stats.csv and DIR/stats.md)
"""
import argparse
import csv
import os
import statistics
import sys
from collections import defaultdict

_STATUS_COL = "status"
_LABEL_COL = "run"
_CLASSIFICATION_SOURCE_COL = "classification_source"


def strip_result_root_prefix(label: str) -> str:
    """"full-evaluation-<ts>/klastos-n1000/measurements/eu" ->
    "klastos-n1000/measurements/eu" — drop exactly the first path segment
    (that repeat's own result-root basename), keep everything after it."""
    parts = label.split("/", 1)
    return parts[1] if len(parts) > 1 else label


def parse_classification_source(s: str):
    """"admission=690,appclass_operator=310" -> {"admission": 690,
    "appclass_operator": 310}. "-" (no such annotation ever observed, e.g.
    baseline rows) -> {}."""
    if not s or s == "-":
        return {}
    out = {}
    for kv in s.split(","):
        if "=" not in kv:
            continue
        k, v = kv.split("=", 1)
        try:
            out[k] = float(v)
        except ValueError:
            pass
    return out


def mean_stdev(values):
    """values: list of floats (already filtered to non-missing). Returns
    (mean, stdev) — stdev is "" (not 0) when there's only one sample, since
    a single data point has no meaningful spread to report, and 0 would
    falsely read as "confirmed zero variance"."""
    if not values:
        return "", ""
    if len(values) == 1:
        return round(values[0], 1), ""
    return round(statistics.mean(values), 1), round(statistics.stdev(values), 2)


def load_rows(result_roots):
    """Yield every row dict from every result_root's report.csv, tagged
    with which root it came from (for error messages only)."""
    for root in result_roots:
        path = os.path.join(root, "report.csv")
        if not os.path.isfile(path):
            print(f"WARNING: no report.csv under {root} - skipping", file=sys.stderr)
            continue
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                yield root, row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("result_roots", nargs="+", help="run-full-evaluation.sh result-root directories (one per repeat)")
    parser.add_argument("--out", required=True, metavar="DIR", help="directory to write stats.csv / stats.md into")
    args = parser.parse_args()

    # label -> column -> [values across repeats that had this column non-empty]
    numeric_by_label = defaultdict(lambda: defaultdict(list))
    # label -> [ {source_key: count}, ... ] one dict per repeat that had this label
    classification_by_label = defaultdict(list)
    # label -> [status_str, ...] one per repeat that had this label
    status_by_label = defaultdict(list)
    numeric_cols = None

    for root, row in load_rows(args.result_roots):
        label = strip_result_root_prefix(row[_LABEL_COL])
        status_by_label[label].append(row[_STATUS_COL])
        classification_by_label[label].append(parse_classification_source(row[_CLASSIFICATION_SOURCE_COL]))

        if numeric_cols is None:
            numeric_cols = [
                c for c in row.keys()
                if c not in (_LABEL_COL, _STATUS_COL, _CLASSIFICATION_SOURCE_COL)
            ]

        for col in numeric_cols:
            raw = row.get(col, "")
            if raw == "" or raw is None:
                continue
            try:
                numeric_by_label[label][col].append(float(raw))
            except ValueError:
                pass

    if not numeric_by_label and not status_by_label:
        print("No rows found in any given result_root's report.csv.", file=sys.stderr)
        sys.exit(1)

    labels = sorted(set(status_by_label.keys()))

    # Every classification_source key seen anywhere, across every label -
    # used to build a consistent column set for the CSV/markdown headers.
    all_source_keys = sorted({
        k for dicts in classification_by_label.values() for d in dicts for k in d
    })

    numeric_cols = numeric_cols or []
    os.makedirs(args.out, exist_ok=True)

    _write_csv(os.path.join(args.out, "stats.csv"), labels, numeric_cols, all_source_keys,
               numeric_by_label, classification_by_label, status_by_label)
    _write_markdown(os.path.join(args.out, "stats.md"), labels, numeric_cols, all_source_keys,
                     numeric_by_label, classification_by_label, status_by_label)
    print(f"Wrote {os.path.join(args.out, 'stats.csv')}")
    print(f"Wrote {os.path.join(args.out, 'stats.md')}")


def _source_stats(dicts, key):
    """Mean/stdev of one classification_source key across repeats - a
    repeat that has the key absent contributes 0 (a real "0 pods used this
    source that repeat"), not a skipped/missing value, unlike the plain
    numeric columns handled by mean_stdev() above."""
    values = [d.get(key, 0.0) for d in dicts]
    return mean_stdev(values)


def _write_csv(path, labels, numeric_cols, source_keys, numeric_by_label, classification_by_label, status_by_label):
    with open(path, "w", newline="") as f:
        headers = ["run", "n_repeats", "pass_count"]
        for col in numeric_cols:
            headers += [f"{col}_mean", f"{col}_stdev"]
        for key in source_keys:
            headers += [f"classification_source_{key}_mean", f"classification_source_{key}_stdev"]
        writer = csv.writer(f)
        writer.writerow(headers)
        for label in labels:
            statuses = status_by_label[label]
            row = [label, len(statuses), sum(1 for s in statuses if s == "PASS")]
            for col in numeric_cols:
                mean, stdev = mean_stdev(numeric_by_label[label][col])
                row += [mean, stdev]
            for key in source_keys:
                mean, stdev = _source_stats(classification_by_label[label], key)
                row += [mean, stdev]
            writer.writerow(row)


def _write_markdown(path, labels, numeric_cols, source_keys, numeric_by_label, classification_by_label, status_by_label):
    def fmt(mean, stdev):
        if mean == "":
            return "-"
        return f"{mean}" if stdev == "" else f"{mean} ± {stdev}"

    headers = ["Run", "Repeats", "Pass rate"] + numeric_cols + [f"classification_source[{k}]" for k in source_keys]
    lines = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    for label in labels:
        statuses = status_by_label[label]
        cells = [label, str(len(statuses)), f"{sum(1 for s in statuses if s == 'PASS')}/{len(statuses)}"]
        for col in numeric_cols:
            cells.append(fmt(*mean_stdev(numeric_by_label[label][col])))
        for key in source_keys:
            cells.append(fmt(*_source_stats(classification_by_label[label], key)))
        lines.append("| " + " | ".join(cells) + " |")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
