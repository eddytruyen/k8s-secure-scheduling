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
per key and averaged per key too — a missing key in a cell that IS present
counts as 0 for that repeat, not as absent data, since "admission" not
appearing means zero pods used that source that run, a real zero.

A repeat whose whole classification_source cell is "-" is different: that
happens only when the row has no pod records at all for that repeat, so it
is a missing observation, not a row of zeros. Counting it as zeros turned
"3000 pods, in each of the 2 repeats that recorded this class" into
"1200.0 ± 1643.17", which reads like a measured collapse rather than absent
data. Such repeats are skipped and reflected in the per-key sample count.

status (PASS/FAIL/?) is reported as "<pass_count>/<total>" rather than
averaged — it's categorical, not a number to take a mean of.

Every other column from report.csv is a plain numeric metric (percentile in
ms, or pods/sec) — mean/stdev computed directly, skipping any repeat where
that cell was empty ("-": no such measurement exists for this row's harness
arm, e.g. validation_p99_ms for a KLASTOS row) rather than treating it as 0.

Because those cells are skipped individually, a row's "Repeats" count is an
upper bound, not the sample count behind every cell in it: a row present in
5 repeats can still hold a mean over 2 if the other 3 had that cell empty.
Measured live (repeated-evaluation-20261015-150230): an e2e-latency watcher
that went deaf partway through 3 of 5 repeats left two baseline rows showing
"Repeats 5 | 5/5" with n=2 latency means and no indication of it. So any
cell whose sample count is below its row's repeat count is now annotated
"(n=k)" in stats.md, and stats.csv carries an explicit "<col>_n" column for
every metric. Cells with the full count are rendered exactly as before.

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
    "appclass_operator": 310}.

    "-"/empty -> None, meaning "this repeat recorded nothing for this row",
    which is NOT the same as a cell that is present but lacks a given key
    (that key is a real 0). generate-report.py writes "-" here only when a
    row has no pod records at all, so None is the honest reading and lets
    _source_stats() skip the repeat instead of averaging in zeros."""
    if not s or s == "-":
        return None
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
    (mean, stdev, n) — stdev is "" (not 0) when there's only one sample,
    since a single data point has no meaningful spread to report, and 0
    would falsely read as "confirmed zero variance". n is returned so
    callers can show how many repeats actually backed the mean."""
    if not values:
        return "", "", 0
    if len(values) == 1:
        return round(values[0], 1), "", 1
    return round(statistics.mean(values), 1), round(statistics.stdev(values), 2), len(values)


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
        k for dicts in classification_by_label.values() for d in dicts if d for k in d
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
    """Mean/stdev/n of one classification_source key across repeats.

    A repeat whose cell is present but lacks this key contributes 0 (a
    real "0 pods used this source that repeat"). A repeat whose cell was
    absent entirely (None, i.e. no pod records for this row at all) is
    skipped like any other missing numeric cell - averaging it in as 0
    understates the mean and inflates the stdev with data that was never
    measured."""
    values = [d.get(key, 0.0) for d in dicts if d is not None]
    return mean_stdev(values)


def _write_csv(path, labels, numeric_cols, source_keys, numeric_by_label, classification_by_label, status_by_label):
    with open(path, "w", newline="") as f:
        headers = ["run", "n_repeats", "pass_count"]
        for col in numeric_cols:
            headers += [f"{col}_mean", f"{col}_stdev", f"{col}_n"]
        for key in source_keys:
            headers += [f"classification_source_{key}_mean",
                        f"classification_source_{key}_stdev",
                        f"classification_source_{key}_n"]
        writer = csv.writer(f)
        writer.writerow(headers)
        for label in labels:
            statuses = status_by_label[label]
            row = [label, len(statuses), sum(1 for s in statuses if s == "PASS")]
            for col in numeric_cols:
                mean, stdev, n = mean_stdev(numeric_by_label[label][col])
                row += [mean, stdev, n]
            for key in source_keys:
                mean, stdev, n = _source_stats(classification_by_label[label], key)
                row += [mean, stdev, n]
            writer.writerow(row)


def _write_markdown(path, labels, numeric_cols, source_keys, numeric_by_label, classification_by_label, status_by_label):
    def fmt(stats, expected_n):
        """Render a cell, flagging it when fewer repeats backed it than the
        row claims. A full-count cell is rendered exactly as before, so the
        "(n=k)" suffix appears only where it signals something."""
        mean, stdev, n = stats
        if mean == "":
            return "-"
        cell = f"{mean}" if stdev == "" else f"{mean} ± {stdev}"
        return cell if n >= expected_n else f"{cell} (n={n})"

    headers = ["Run", "Repeats", "Pass rate"] + numeric_cols + [f"classification_source[{k}]" for k in source_keys]
    lines = ["| " + " | ".join(headers) + " |", "|" + "---|" * len(headers)]
    for label in labels:
        statuses = status_by_label[label]
        expected_n = len(statuses)
        cells = [label, str(expected_n), f"{sum(1 for s in statuses if s == 'PASS')}/{expected_n}"]
        for col in numeric_cols:
            cells.append(fmt(mean_stdev(numeric_by_label[label][col]), expected_n))
        for key in source_keys:
            cells.append(fmt(_source_stats(classification_by_label[label], key), expected_n))
        lines.append("| " + " | ".join(cells) + " |")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
