#!/usr/bin/env python3
"""Invariant checks for one scenario run (invariants 1, 3, 4; invariant 2 is deep scrub,
done in bash by check_inconsistent).

Input: a state file of JSON lines appended by common.sh, one per client action:
  {"op": "put", "pool": P, "ns": NS, "loc": LOC, "name": N, "sha": SHA, "acked": true}
  {"op": "del", "pool": P, "ns": NS, "loc": LOC, "name": N, "acked": true|false}
  {"op": "unknown", ...}   # outcome not known (e.g. racy delete that failed); not checked
and a JSON map osd -> byte offset into out/osd.N.log at the start of the run.

Invariants:
  1 no_resurrection: every acknowledged-deleted object (not re-put since) is ENOENT
    by stat and absent from a listing of all namespaces.
  3 vault_intact (prototype only): every acknowledged delete has a
    "replicavault: vaulted" line whose vault entry exists on that OSD, is intact
    (stored sha256 == sha256 of stored bytes), and holds the bytes the object had
    when it was deleted.
  4 live_intact: every object whose last acknowledged action is a put reads back
    with that put's sha256.

Prints one JSON object; exit status 0 iff every checked invariant passes.
"""
import argparse
import collections
import hashlib
import json
import os
import re
import subprocess
import sys

import rados

VAULT_RE = re.compile(
    r"replicavault: vaulted pool=(?P<pool>-?\d+) pg=(?P<pg>\S+) oid=.* ns=.* "
    r"v=(?P<epoch>\d+)'(?P<ver>\d+) osd=(?P<osd>\d+) path=(?P<path>\w+) "
    r"acting=\[(?P<acting>[\d,]*)\] size=(?P<size>\d+) .*sha256=(?P<sha>[0-9a-f]+) "
    r"vname=(?P<vname>\S+)")


def unhex(h):
    return bytes.fromhex(h).decode("utf-8", "surrogateescape")


def decode_vname(v):
    f = v.split("_")
    return {"pool": int(f[1]), "pgid": f[2], "nspace": unhex(f[5]),
            "key": unhex(f[6]), "oid": unhex(f[7])}


def ident(r):
    return (r["pool"], r.get("ns", ""), r.get("loc", ""), r["name"])


def ident_str(i):
    pool, ns, loc, name = i
    s = f"{pool}:"
    if ns:
        s += f"{ns}/"
    s += name
    if loc:
        s += f"@{loc}"
    return s


def replay(state_path):
    """Returns (final status per ident, list of acked delete events with expected sha)."""
    last_sha = {}
    status = {}
    deletes = []
    for line in open(state_path):
        r = json.loads(line)
        i = ident(r)
        if r["op"] == "put" and r.get("acked", True):
            last_sha[i] = r["sha"]
            status[i] = "live"
        elif r["op"] == "del":
            if r["acked"]:
                deletes.append({"ident": i, "sha": last_sha.get(i)})
                status[i] = "deleted"
            else:
                status[i] = "unknown"
        elif r["op"] == "unknown":
            status[i] = "unknown"
    return status, last_sha, deletes


def vault_lines(build_dir, offsets):
    out = []
    for osd, off in offsets.items():
        path = os.path.join(build_dir, "out", f"osd.{osd}.log")
        try:
            with open(path, "rb") as f:
                f.seek(int(off))
                data = f.read().decode("utf-8", "replace")
        except FileNotFoundError:
            continue
        for line in data.splitlines():
            m = VAULT_RE.search(line)
            if m:
                d = m.groupdict()
                d.update(decode_vname(d["vname"]))
                out.append(d)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--offsets", required=True)
    ap.add_argument("--mode", required=True, choices=["vanilla", "rv", "p2", "unknown"])
    ap.add_argument("--inspect", required=True, help="path to vault-inspect.sh")
    ap.add_argument("--no-vault-inspect", action="store_true",
                    help="check vault log lines only, not the on-disk entries")
    ap.add_argument("--disk-scan", choices=["missing", "all", "off"], default="missing",
                    help="also look for vault entries by name on every OSD's disk, not only via "
                         "'vaulted' log lines: a SIGKILL between the vault txc's kv commit and its "
                         "on_commit callback leaves a durable entry with no log line. 'missing' = "
                         "only for deletes without a verified logged copy; 'all' = every delete")
    a = ap.parse_args()

    build = os.environ.get("CEPH_BUILD", "/data/ceph/build")
    status, last_sha, deletes = replay(a.state)
    offsets = json.load(open(a.offsets))

    c = rados.Rados(conffile=os.environ["CEPH_CONF"])
    c.connect(timeout=60)
    pool_ids = {}

    def ioctx(pool, ns="", loc=""):
        io = c.open_ioctx(pool)
        io.set_namespace(ns)
        if loc:
            io.set_locator_key(loc)
        return io

    result = {}

    # 1: no resurrection
    listed = collections.defaultdict(set)
    for pool in {i[0] for i in status}:
        pool_ids[pool] = c.pool_lookup(pool)
        io = c.open_ioctx(pool)
        io.set_namespace(rados.LIBRADOS_ALL_NSPACES)
        for o in io.list_objects():
            listed[pool].add((o.nspace, o.key))
        io.close()
    bad = []
    checked = 0
    for i, st in status.items():
        if st != "deleted":
            continue
        checked += 1
        pool, ns, loc, name = i
        io = ioctx(pool, ns, loc)
        try:
            io.stat(name)
            bad.append({"object": ident_str(i), "problem": "stat succeeded"})
        except rados.ObjectNotFound:
            pass
        io.close()
        if (ns, name) in listed[pool]:
            bad.append({"object": ident_str(i), "problem": "present in listing"})
    result["no_resurrection"] = {"pass": not bad, "checked": checked, "failures": bad}

    # 4: live data unaffected
    bad = []
    checked = 0
    for i, st in status.items():
        if st != "live":
            continue
        checked += 1
        pool, ns, loc, name = i
        io = ioctx(pool, ns, loc)
        try:
            size = io.stat(name)[0]
            data = io.read(name, size + 1) if size else b""
            got = hashlib.sha256(data).hexdigest()
            if got != last_sha[i]:
                bad.append({"object": ident_str(i), "problem": "sha mismatch",
                            "want": last_sha[i], "got": got})
        except rados.ObjectNotFound:
            bad.append({"object": ident_str(i), "problem": "ENOENT"})
        io.close()
    result["live_intact"] = {"pass": not bad, "checked": checked, "failures": bad}
    c.shutdown()

    # 3: vault present and intact
    if a.mode not in ("rv", "p2"):
        result["vault_intact"] = {"pass": None, "skipped": f"mode={a.mode}"}
    else:
        lines = vault_lines(build, offsets)
        # candidate vault lines per deletion, matched by exact identity from the vault name
        cands = {}
        for n, d in enumerate(deletes):
            pool, ns, loc, name = d["ident"]
            cands[n] = [l for l in lines
                        if l["pool"] == pool_ids.get(pool) and l["nspace"] == ns
                        and l["key"] == loc and l["oid"] == name]
        entries = {}
        if not a.no_vault_inspect:
            by_osd = collections.defaultdict(set)
            for ls in cands.values():
                for l in ls:
                    by_osd[l["osd"]].add(l["vname"])
            for osd, vnames in sorted(by_osd.items()):
                if osd == os.environ.get("RV_EXCLUDE_OSD", ""):
                    continue  # deliberately down (c04 variant B): its store is not reachable
                p = subprocess.run([a.inspect, "check", osd, *sorted(vnames)],
                                   capture_output=True, text=True)
                for line in p.stdout.splitlines():
                    if line.startswith("{"):
                        e = json.loads(line)
                        entries[(str(e["osd"]), e["vname"])] = e
                if p.returncode != 0:
                    result["vault_inspect_error"] = p.stderr[-2000:]
        # Disk scan: vault entries present on an OSD but never logged.
        disk = {}   # n -> list of (osd, vname) for entries matching deletion n's identity
        if a.disk_scan != "off" and not a.no_vault_inspect:
            def logged_ok(n, d):
                for l in cands[n]:
                    e = entries.get((l["osd"], l["vname"]))
                    if e and e.get("found") and e.get("intact") and e.get("data_sha256") == d["sha"]:
                        return True
                return False
            scope = [n for n, d in enumerate(deletes) if a.disk_scan == "all" or not logged_ok(n, d)]
            if scope:
                excluded = os.environ.get("RV_EXCLUDE_OSD", "")
                osds = [o for o in subprocess.run([os.path.join(build, "bin", "ceph"), "-c", os.environ["CEPH_CONF"], "osd", "ls"],
                                                  capture_output=True, text=True).stdout.split() if o != excluded]
                on_disk = collections.defaultdict(list)   # identity -> [(osd, vname)]
                for osd in osds:
                    p = subprocess.run([a.inspect, "names", osd], capture_output=True, text=True)
                    for v in p.stdout.split():
                        try:
                            dv = decode_vname(v)
                        except Exception:
                            continue
                        on_disk[(dv["pool"], dv["nspace"], dv["key"], dv["oid"])].append((osd, v))
                want = collections.defaultdict(set)
                for n in scope:
                    pool, ns, loc, name = deletes[n]["ident"]
                    logged = {(l["osd"], l["vname"]) for l in cands[n]}
                    for osd, v in on_disk.get((pool_ids.get(pool), ns, loc, name), []):
                        if (osd, v) not in logged:
                            disk.setdefault(n, []).append((osd, v))
                            want[osd].add(v)
                for osd, vnames in sorted(want.items()):
                    p = subprocess.run([a.inspect, "check", osd, *sorted(vnames)], capture_output=True, text=True)
                    for line in p.stdout.splitlines():
                        if line.startswith("{"):
                            e = json.loads(line)
                            entries[(str(e["osd"]), e["vname"])] = e
        bad = []
        details = []
        used = set()
        for n, d in enumerate(deletes):
            ok = False
            seen = []
            for l in cands[n]:
                key = (l["osd"], l["vname"])
                e = entries.get(key)
                rec = {"osd": int(l["osd"]), "path": l["path"], "v": f"{l['epoch']}'{l['ver']}",
                       "acting": l["acting"], "log_sha_match": l["sha"] == d["sha"]}
                if a.no_vault_inspect:
                    good = l["sha"] == d["sha"] and key not in used
                else:
                    rec.update(found=bool(e and e.get("found")),
                               intact=bool(e and e.get("intact")),
                               data_sha_match=bool(e and e.get("data_sha256") == d["sha"]))
                    good = rec["found"] and rec["intact"] and rec["data_sha_match"] \
                        and key not in used
                seen.append(rec)
                if good and not ok:
                    ok = True
                    used.add(key)
            for osd, v in disk.get(n, []):
                key = (osd, v)
                e = entries.get(key)
                rec = {"osd": int(osd), "path": "unlogged", "vname": v,
                       "found": bool(e and e.get("found")), "intact": bool(e and e.get("intact")),
                       "data_sha_match": bool(e and e.get("data_sha256") == d["sha"])}
                seen.append(rec)
                if rec["found"] and rec["intact"] and rec["data_sha_match"] and key not in used and not ok:
                    ok = True
                    used.add(key)
            details.append({"object": ident_str(d["ident"]), "vault": seen, "ok": ok})
            if not ok:
                bad.append({"object": ident_str(d["ident"]), "expected_sha": d["sha"],
                            "candidates": seen,
                            "problem": "no vault line" if not seen else "no matching intact entry"})
        result["vault_intact"] = {"pass": not bad, "checked": len(deletes),
                                  "failures": bad, "entries": details,
                                  "vault_lines_in_run": len(lines), "disk_scan": a.disk_scan,
                                  "unlogged_copies": sum(1 for x in details for y in x["vault"]
                                                         if y["path"] == "unlogged" and y.get("found"))}

    print(json.dumps(result))
    ok = all(v.get("pass") in (True, None) for k, v in result.items() if isinstance(v, dict))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
