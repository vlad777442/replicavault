#!/usr/bin/env python3
"""z01 offline checks on one stopped OSD (zero-copy pilot, Phase 4).

For every vault entry z01 has created on this OSD so far (cumulative over runs):
  - the entry exists (meta-list, namespace replicavault);
  - its bytes (ceph-objectstore-tool get-bytes) match the client-side sha256;
  - entries from the current run have the expected mode on disk (rv.mode; "rename",
    or "copy" for the copy-build control);
  - none of its physical extents (ceph-objectstore-tool dump: BlueStore::dump_onode
    faults in the whole extent map, BlueStore.cc:13263) overlaps a free extent of
    the persisted allocator (ceph-bluestore-tool free-dump). In allocation-from-file
    mode offline fsck does not compare used blocks with the free list
    (BlueStore.cc:11487-11488), so this is the direct check for a vault block that
    the allocation rebuild wrongly marked free.

  z01check.py --osd N --data-path DIR --cot PATH --free-dump FILE
              --entries FILE.jsonl --run R [--expect-mode rename|copy]
entries: JSON lines {"vname", "sha", "run", "size"}. Prints one JSON object;
exit 0 iff every check passes.
"""
import argparse
import bisect
import hashlib
import json
import os
import subprocess
import sys
import tempfile

INVALID = 0xFFFFFFFFFFFFFFF0   # blob extents >= this are holes (bluestore_pextent_t::INVALID_OFFSET)


def cot(a, *args, binary=False):
    p = subprocess.run([a.cot, "--data-path", a.data_path, *args],
                       capture_output=True, text=not binary)
    return p.returncode, p.stdout


def parse_free_dump(path):
    """free-dump prints '<name>:' then a JSON object, per allocator. Returns the
    sorted free extents of the 'block' allocator and its capacity."""
    s = open(path).read()
    i = s.index("block:")
    obj, _ = json.JSONDecoder().raw_decode(s[s.index("{", i):])
    ext = sorted((int(e["offset"], 16), int(e["length"], 16)) for e in obj["extents"])
    return ext, obj["capacity"], obj["alloc_unit"]


def overlaps(free, starts, off, length):
    """free extents (sorted, non-overlapping) intersecting [off, off+length)."""
    out = []
    j = bisect.bisect_right(starts, off) - 1
    j = max(j, 0)
    while j < len(free) and free[j][0] < off + length:
        fo, fl = free[j]
        if fo + fl > off:
            out.append((fo, fl))
        j += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--osd", required=True)
    ap.add_argument("--data-path", required=True)
    ap.add_argument("--cot", required=True)
    ap.add_argument("--free-dump", required=True)
    ap.add_argument("--entries", required=True)
    ap.add_argument("--run", type=int, required=True)
    ap.add_argument("--expect-mode", default="rename", choices=["rename", "copy"])
    a = ap.parse_args()

    free, capacity, au = parse_free_dump(a.free_dump)
    starts = [f[0] for f in free]
    entries = [json.loads(l) for l in open(a.entries) if l.strip()]

    rc, out = cot(a, "--op", "meta-list")
    specs = {}
    for line in out.splitlines():
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if j[1].get("namespace") == "replicavault":
            specs[j[1]["oid"]] = line

    res = {"osd": int(a.osd), "entries_checked": len(entries),
           "entries_this_run": sum(e["run"] == a.run for e in entries),
           "vault_entries_on_osd": len(specs), "missing": [], "sha_mismatch": [],
           "wrong_mode": [], "free_overlap": [], "dump_errors": [],
           "vault_bytes_allocated": 0, "max_vault_extent_end": 0,
           "free_extents": len(free), "free_bytes": sum(l for _, l in free),
           "capacity": capacity}
    with tempfile.TemporaryDirectory() as tmp:
        for e in entries:
            v = e["vname"]
            spec = specs.get(v)
            if spec is None:
                res["missing"].append(v)
                continue
            # bytes vs the client-side checksum
            f = os.path.join(tmp, "b")
            if os.path.exists(f):
                os.unlink(f)
            rc, _ = cot(a, "--pgid", "meta", spec, "get-bytes", f)
            data = open(f, "rb").read() if os.path.exists(f) else b""
            got = hashlib.sha256(data).hexdigest()
            if rc != 0 or got != e["sha"]:
                res["sha_mismatch"].append({"vname": v, "run": e["run"], "rc": rc,
                                            "want": e["sha"], "got": got, "size": len(data)})
            if e["run"] == a.run:
                rc, mode = cot(a, "--pgid", "meta", spec, "get-attr", "rv.mode")
                if mode.strip() != a.expect_mode:
                    res["wrong_mode"].append({"vname": v, "rv.mode": mode.strip()})
            # physical extents vs the persisted free list
            rc, d = cot(a, "--pgid", "meta", spec, "dump")
            try:
                onode = json.loads(d)["onode"]
            except (ValueError, KeyError) as ex:
                res["dump_errors"].append({"vname": v, "error": str(ex)})
                continue
            seen = set()
            for le in onode.get("extents", []):
                for pe in le["blob"]["extents"]:
                    off, ln = int(pe["offset"]), int(pe["length"])
                    if off >= INVALID or (off, ln) in seen:
                        continue
                    seen.add((off, ln))
                    res["vault_bytes_allocated"] += ln
                    res["max_vault_extent_end"] = max(res["max_vault_extent_end"], off + ln)
                    for fo, fl in overlaps(free, starts, off, ln):
                        res["free_overlap"].append({"vname": v, "run": e["run"],
                                                    "extent": [hex(off), hex(ln)],
                                                    "free": [hex(fo), hex(fl)]})
    # how much free space remains below the highest vault block: the fill's reach
    m = res["max_vault_extent_end"]
    res["free_bytes_below_max_vault_extent"] = sum(
        max(0, min(fo + fl, m) - fo) for fo, fl in free if fo < m)
    res["pass"] = not (res["missing"] or res["sha_mismatch"] or res["wrong_mode"]
                       or res["free_overlap"] or res["dump_errors"])
    print(json.dumps(res))
    sys.exit(0 if res["pass"] else 1)


if __name__ == "__main__":
    main()
