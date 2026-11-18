#!/usr/bin/env python3
"""Regenerate result/use-case/LATEST-RESULTS.md: which repeated-run folder is the valid / most recent
evaluation for each setup (experiment x arm) of the n1000 campaign.

Source of truth: the campaign logs (~/campaign-n1000-logs-*/sweep-<n>_<total>_<desc>__<arm>_arm_.log). Each sweep log
names its "Stats output: .../repeated-run-...-<timestamp>" folder. Logs are processed oldest first, so a later sweep of
the same setup supersedes an earlier one. A sweep counts as VALID only if it finished (no "FAILED") and its stats.md
shows every repeat passed (Pass rate N/N). The newest VALID sweep is the setup's "current" folder; if the newest sweep is
invalid it is listed as well so nothing is hidden.

Usage: update-latest-results.py [--logs-glob '~/campaign-n1000-logs-*'] [--results DIR] [--out FILE]
"""
import argparse, csv, glob, os, re, sys
from datetime import datetime, timezone

# KLASTOS-arm sweeps from campaign log dirs >= this stamp ran with the UCSS gated-scan fix (PR #104: scan memo +
# rebuild skip). Earlier KLASTOS sweeps ran with the pre-fix image. Other arms don't use UCSS.
UCSS_FIX_FROM = "20261108-012529"
# KLASTOS-arm sweeps from campaign log dirs >= this stamp ran with the image built from main after PR #106 (UCSS v1.8.0),
# which does NOT contain the PR #104 scan fixes (PR #104 is unmerged).
UCSS_106_FROM = "20261109-121834"
# KLASTOS-arm setups left out of the table. Empty since 2026-11-18 (decided by the experiment owner): the reactive
# KLASTOS arm of the anti-affinity use cases (3, 4, 8, 9), hidden until then "until the UCSS interclass release path
# is fixed", is reported again, next to the pre-compiled arm (klastospc) of 8 and 9.
EXCLUDED_KLASTOS = set()
# Setups left out for every arm, by sweep name: the first design of experiment 14 ("many appgroups", 2026-11-16/17:
# the interclass-queue benchmark's intra-group spreading rule, not tenant isolation). It was replaced by
# "multi-tenancy many-tenants" (experiment 9's rule, G tenants x 2000/G pods), which IS reported.
EXCLUDED_SETUPS = {"multi-tenancy many-appgroups CONCURRENT"}
# Variant sweeps of an arm (run-campaign-n1000.sh ARM_SUFFIX, e.g. "klastospc-nosticky": the arm with one setting
# changed) are not reported: this file holds the latest result of each setup, not its variants. Their sweeps stay in
# the result folders and campaign logs.
def variant_arm(arm):
    return "-" in arm


# Outlier repeats are decided by a person, not by this script. A repeated-run folder lists them in outliers.txt, one
# per line: "<repeat number> <reason>" ('#' starts a comment), next to stats-NOTE.txt (the explanation), stats.md /
# stats.csv recomputed over the remaining repeats, and stats.with-outlier.md / .csv (the originals over all repeats).
# The Pass column then reads <non-outlier repeats>/<all repeats>, e.g. 4/5, and Notes names the excluded repeat.
def outliers(folder):
    f = os.path.join(a.results, folder or "", "outliers.txt")
    out = []
    if folder and os.path.exists(f):
        for line in open(f, errors="replace"):
            line = line.split("#", 1)[0].strip()
            if line:
                n, _, why = line.partition(" ")
                out.append((int(n), why.strip()))
    return out

ap = argparse.ArgumentParser()
ap.add_argument("--logs-glob", default="~/campaign-n1000-logs-*")
here = os.path.dirname(os.path.abspath(__file__))
ap.add_argument("--results", default=os.path.join(here, "result", "use-case"))
ap.add_argument("--out", default=None)
ap.add_argument("--include-real", action="store_true",
                help="also read campaign logs from real-cluster runs (default: skip them). "
                     "LATEST-RESULTS.md reports the n1000 KWOK campaign; a real-cluster sweep "
                     "of the same experiment+arm would otherwise supersede its row.")
a = ap.parse_args()
out = a.out or os.path.join(a.results, "LATEST-RESULTS.md")

def admission(path):
    """Parse the sweep's admission report (written by run-campaign-n1000.sh from apiserver metrics, all steps and
    repeats of the sweep). Returns (post_mean_ms, post_calls, [(webhook, type, mean_ms)]) or None. Only CREATE-op
    webhooks called about once per pod POST are kept; that drops the policy/namespace webhooks (few calls) and the
    DELETE/UPDATE rows."""
    if not os.path.exists(path):
        return None
    txt = open(path, errors="replace").read()
    pm = re.search(r"POST pods request.*?calls=(\d+) mean=([\d.]+)ms", txt)
    if not pm:
        return None
    calls, mean = int(pm.group(1)), float(pm.group(2))
    hooks = []
    for row in re.finditer(r"^(\S+)\s+(admit|validating)\s+CREATE\s+\S+\s+(\d+)\s+([\d.]+)ms", txt, re.M):
        if int(row.group(3)) >= 0.9 * calls:
            hooks.append((row.group(1), "mutating" if row.group(2) == "admit" else "validating", float(row.group(4))))
    return mean, calls, hooks

def adm_cols(s):
    if not s["adm"]:
        return "-", "-"
    mean, calls, hooks = s["adm"]
    return "%.1f ms" % mean, ("; ".join("%s (%s) %.1f ms" % h for h in hooks) or "none")

NAME = re.compile(r"sweep-(\d+)_(\d+)_(.+?)__(.+?)_arm_\.log$")


def real_cluster_log(d):
    """Was this campaign run against a real cluster rather than kind+KWOK?

    Two signals, either sufficient. CLUSTER.txt is written by run-campaign-n1000.sh and
    is explicit. node-labels-baseline.json is implicit but older and covers log dirs
    that predate the marker: the campaign only snapshots node labels when
    CLUSTER_BACKEND=real, so its presence alone identifies a real-cluster run.
    """
    marker = os.path.join(d, "CLUSTER.txt")
    if os.path.exists(marker):
        head = open(marker, errors="replace").read(400)
        if re.search(r"^backend:\s*real\b", head, re.M):
            return True
        if re.search(r"^backend:\s*kind-kwok\b", head, re.M):
            return False
    return os.path.exists(os.path.join(d, "node-labels-baseline.json"))


sweeps = []
skipped_real = []
for d in sorted(glob.glob(os.path.expanduser(a.logs_glob))):
    stamp = d.rsplit("campaign-n1000-logs-", 1)[-1]
    if real_cluster_log(d) and not a.include_real:
        if glob.glob(os.path.join(d, "sweep-*.log")):
            skipped_real.append(os.path.basename(d))
        continue
    for f in sorted(glob.glob(os.path.join(d, "sweep-*.log"))):
        m = NAME.search(os.path.basename(f))
        if not m:
            continue
        if m.group(3).replace("_", " ") in EXCLUDED_SETUPS or variant_arm(m.group(4)):
            continue
        txt = open(f, errors="replace").read()
        so = re.search(r"Stats output: (\S+)", txt)
        folder = os.path.basename(so.group(1)) if so else None
        failed = bool(re.search(r"^\s*FAILED", txt, re.M))
        pass_rate = None
        if folder:
            sm = os.path.join(a.results, folder, "stats.md")
            if os.path.exists(sm):
                pr = re.search(r"\|\s*(\d+)/(\d+)\s*\|", open(sm, errors="replace").read())
                if pr:
                    pass_rate = (int(pr.group(1)), int(pr.group(2)))
        exists = bool(folder) and os.path.isdir(os.path.join(a.results, folder))
        valid = exists and not failed and pass_rate is not None and pass_rate[0] == pass_rate[1]
        why = []
        if not folder: why.append("no stats folder")
        elif not exists: why.append("folder missing")
        if failed: why.append("sweep FAILED")
        if pass_rate and pass_rate[0] != pass_rate[1]: why.append("pass rate %d/%d" % pass_rate)
        if folder and exists and pass_rate is None and not failed: why.append("no stats.md")
        sweeps.append({"num": int(m.group(1)), "desc": m.group(3).replace("_", " "), "arm": m.group(4),
                       "stamp": stamp, "folder": folder, "valid": valid, "why": ", ".join(why),
                       "pass": pass_rate, "outliers": outliers(folder),
                       "repeats": len(glob.glob(os.path.join(a.results, folder or "", "repeat-*.log"))),
                       "adm_path": os.path.join(d, "admission-" + os.path.basename(f)[len("sweep-"):-len(".log")] + ".txt")})
        sweeps[-1]["adm"] = admission(sweeps[-1]["adm_path"])

if skipped_real:
    print("NOTE: skipped %d real-cluster campaign log dir(s); LATEST-RESULTS.md reports the KWOK "
          "n1000 campaign. Use --include-real to read them:" % len(skipped_real), file=sys.stderr)
    for n in skipped_real:
        print("        " + n, file=sys.stderr)

# Copy each sweep's admission report into its repeated-run folder's stats.md, between markers so a rerun replaces it.
BEGIN, END = "<!-- admission:begin (written by update-latest-results.py) -->", "<!-- admission:end -->"
stamped = csv_stamped = 0
for s in sweeps:
    sm = os.path.join(a.results, s["folder"] or "", "stats.md")
    if not s["folder"] or not os.path.exists(sm) or not os.path.exists(s["adm_path"]):
        continue
    body = open(sm, errors="replace").read()
    body = re.sub(r"\n*" + re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", "\n", body, flags=re.S).rstrip("\n")
    section = "\n".join([
        BEGIN, "", "## Admission (apiserver-side)", "",
        "Not part of the e2e latency above: the watcher first sees a pod after admission. Source: `%s` (apiserver "
        "metrics over all steps and repeats of this sweep). The POST pods mean is exact and covers all webhooks plus "
        "persistence; exact mean request-to-scheduled = that mean + the mean e2e above (means add, percentiles do not). "
        "Webhook percentiles are histogram bucket upper bounds." % s["adm_path"].replace(os.path.expanduser("~"), "~"),
        "", "```", open(s["adm_path"], errors="replace").read().rstrip("\n"), "```", "", END])
    open(sm, "w").write(body + "\n\n" + section + "\n")
    stamped += 1
    # stats.csv: sweep-level admission columns appended to every row (the report covers all runs of the sweep).
    # Existing admission_* columns are dropped first so a rerun replaces them.
    sc = os.path.join(a.results, s["folder"], "stats.csv")
    if os.path.exists(sc) and s["adm"]:
        with open(sc, newline="", errors="replace") as fh:
            rows = list(csv.reader(fh))
        if rows:
            keep = [i for i, h in enumerate(rows[0]) if not h.startswith("admission_")]
            mean, calls, hooks = s["adm"]
            extra_h = ["admission_post_pods_mean_ms", "admission_post_pods_calls", "admission_pod_create_webhooks"]
            extra_v = ["%.1f" % mean, str(calls), ";".join("%s:%s:%.1fms" % h for h in hooks)]
            out_rows = [[r[i] for i in keep if i < len(r)] + (extra_h if n == 0 else extra_v) for n, r in enumerate(rows)]
            with open(sc, "w", newline="") as fh:
                csv.writer(fh).writerows(out_rows)
            csv_stamped += 1
print("added the admission section to %d stats.md and %d stats.csv files" % (stamped, csv_stamped))

setups = {}
for s in sweeps:
    setups.setdefault((s["num"], s["arm"]), []).append(s)

def note(s):
    n = []
    if s["arm"] == "klastos":
        if s["stamp"] >= UCSS_106_FROM:
            n.append("UCSS image from main after PR #106 (no #104)")
        else:
            n.append("post UCSS fix (PR #104)" if s["stamp"] >= UCSS_FIX_FROM else "pre UCSS fix")
    for r, why in s["outliers"]:
        n.append("outlier repeat %d excluded%s" % (r, (": " + why) if why else ""))
    return "; ".join(n)


def pass_col(s):
    if s["outliers"] and s["repeats"]:
        return "%d/%d" % (s["repeats"] - len(s["outliers"]), s["repeats"])
    return "%d/%d" % s["pass"]

lines = ["# Latest evaluation per setup", "",
         "Generated by `test/update-latest-results.py` on %s from the campaign logs `%s`. Do not edit by hand; rerun the "
         "script after a campaign." % (datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"), a.logs_glob), "",
         "A setup is an experiment x arm. **Current** = the newest sweep that finished and passed every repeat; a newer "
         "invalid sweep is shown in the last column. Folders are in this directory; `stats.md` has the aggregate table. "
         "Experiment numbers follow `run-campaign-n1000.sh` (the `/N` total in the log names changed from 10 to 12 to 13 "
         "over time and is ignored).", "",
         ("The KLASTOS arm of experiments %s is left out." % ", ".join(str(n) for n in sorted(EXCLUDED_KLASTOS))
          if EXCLUDED_KLASTOS else "No KLASTOS arm is left out."), "",
         "**Admission** is not in `stats.md`: the e2e latency there starts when the watcher first sees the pod, i.e. "
         "after admission. The two admission columns come from the sweep's `admission-*.txt` in the campaign log dir "
         "(apiserver metrics, all steps and repeats of the sweep). *Pod POST mean* is the exact apiserver-side mean of "
         "a pod CREATE (all webhooks + persistence); every arm has an admission webhook (the baseline arm runs "
         "Gatekeeper), so there is no webhook-free reference. Exact mean request-to-scheduled = pod POST mean + the watcher's mean e2e (means add, "
         "percentiles do not). *Pod CREATE webhooks* lists each webhook called on (about) every pod CREATE with its "
         "mean; mutating webhooks run in sequence, validating ones in parallel.", "",
         "**Pass** = repeats that are not outliers / all repeats of the sweep. An outlier repeat (decided by a person, "
         "listed in the folder's `outliers.txt` with its reason, explained in `stats-NOTE.txt`) is left out of "
         "`stats.md` and of every figure and table derived from this file; `stats.with-outlier.md` keeps the original. "
         "Variant sweeps of an arm (`ARM_SUFFIX`, e.g. `klastospc-nosticky`) are not listed.", "",
         "| Exp | Setup | Arm | Current folder | Campaign | Pass | Pod POST mean | Pod CREATE webhooks | Notes | Newer invalid sweep |",
         "|---|---|---|---|---|---|---|---|---|---|"]
for (num, arm) in sorted(setups):
    if arm == "klastos" and num in EXCLUDED_KLASTOS:
        continue
    lst = setups[(num, arm)]
    valid = [s for s in lst if s["valid"]]
    cur = valid[-1] if valid else None
    newer_bad = [s for s in lst if not s["valid"] and (cur is None or s["stamp"] > cur["stamp"])]
    nb = "; ".join("%s (%s)" % (s["folder"] or "-", s["why"]) for s in newer_bad[-1:]) or ""
    desc = lst[-1]["desc"]
    if cur:
        pm, wh = adm_cols(cur)
        lines.append("| %d | %s | %s | `%s` | %s | %s | %s | %s | %s | %s |" % (
            num, desc, arm, cur["folder"], cur["stamp"], pass_col(cur), pm, wh, note(cur), nb))
    else:
        lines.append("| %d | %s | %s | **none valid** | - | - | - | - | - | %s |" % (num, desc, arm, nb))
open(out, "w").write("\n".join(lines) + "\n")
print("wrote %s (%d setups from %d sweeps)" % (out, len(setups), len(sweeps)))
