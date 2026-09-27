#!/usr/bin/env python3
"""Aggregate scenario result files into a markdown evidence table.

For each scenario and mode (vanilla / rv) it uses the latest result file, and lists
earlier, superseded files separately so nothing is hidden.

  scripts/summarize-results.py [results_dir]
"""
import collections
import glob
import json
import os
import sys

d = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "results")
files = sorted(glob.glob(os.path.join(d, "s[0-9][0-9]-*.json")))
by = collections.defaultdict(list)
for f in files:
    r = json.load(open(f))
    by[(r["scenario"], r["mode"])].append((r["timestamp"], os.path.basename(f), r))

INV = ["1_no_resurrection", "2_no_inconsistency", "3_vault_intact", "4_live_intact"]


def cell(s, k):
    v = s[k]
    if v["skipped"] and not v["pass"] and not v["fail"]:
        return "skip"
    return f"{v['pass']}/{v['pass'] + v['fail']}"


def deletes_checked(r):
    return sum(x["invariants"]["1_no_resurrection"].get("checked", 0) for x in r["runs"])


def vault_checked(r):
    return sum(x["invariants"]["3_vault_intact"].get("checked", 0) or 0 for x in r["runs"]
               if x["invariants"]["3_vault_intact"].get("pass") is not None)


scen = sorted({s for s, _ in by})
print("| scenario | mode | runs passed | inv 1 | inv 2 | inv 3 | inv 4 | objects deleted at end of run (inv 1) | deletes checked against vault (inv 3) | result file |")
print("|---|---|---|---|---|---|---|---|---|---|")
superseded = []
for s in scen:
    for mode in ("vanilla", "rv"):
        rows = sorted(by.get((s, mode), []))
        if not rows:
            print(f"| {s} | {mode} | — | | | | | | | not run |")
            continue
        *old, (ts, fn, r) = rows
        superseded += [(s, mode, o[1], o[2]["summary"]["runs_passed"], o[2]["summary"]["runs"]) for o in old]
        sm = r["summary"]
        print(f"| {s} | {mode} | {sm['runs_passed']}/{sm['runs']} | " +
              " | ".join(cell(sm, k) for k in INV) +
              f" | {deletes_checked(r)} | {vault_checked(r) if mode == 'rv' else '—'} | `{fn}` |")
if superseded:
    print("\nSuperseded result files (earlier runs of the same scenario and mode):\n")
    for s, mode, fn, p, n in superseded:
        print(f"- {s} [{mode}]: {p}/{n} runs passed — `{fn}`")
