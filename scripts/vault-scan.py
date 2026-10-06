#!/usr/bin/env python3
"""Bulk vault scan of one stopped OSD through FuseStore.

  vault-scan.py <ceph-objectstore-tool> <osd-data-path> <osd-id> <mountpoint>

Mounts the store read-only through `ceph-objectstore-tool --op fuse` (FuseStore:
<coll>/all/<object>/{data,attr/,omap/,omap_header}), and prints one JSON line per
vault entry (meta collection, namespace replicavault): its rv.* attributes, the
sha256 of its bytes, and whether those bytes were read without error (BlueStore
verifies blob checksums on read). Unmounts on exit. One mount reads every entry, where
vault-inspect.sh starts ceph-objectstore-tool twice per entry.
"""
import hashlib
import json
import os
import subprocess
import sys
import time

cot, path, osd, mnt = sys.argv[1:5]
os.makedirs(mnt, exist_ok=True)
proc = subprocess.Popen([cot, "--data-path", path, "--op", "fuse", "--mountpoint", mnt],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for _ in range(60):
        if os.path.ismount(mnt):
            break
        time.sleep(0.5)
    else:
        print(json.dumps({"osd": int(osd), "error": "fuse mount failed"}))
        sys.exit(1)
    base = os.path.join(mnt, "meta", "all")
    n = 0
    for d in os.listdir(base):
        if ":replicavault::" not in d:
            continue
        e = os.path.join(base, d)
        rec = {"osd": int(osd), "vname": d.split("::", 1)[1].rsplit(":", 1)[0]}
        attrs = {}
        for a in os.listdir(os.path.join(e, "attr")):
            if a.startswith("rv."):
                attrs[a] = open(os.path.join(e, "attr", a), "rb").read().decode(errors="replace")
        rec["rv"] = attrs
        try:
            h = hashlib.sha256()
            with open(os.path.join(e, "data"), "rb") as f:
                while True:
                    b = f.read(1 << 20)
                    if not b:
                        break
                    h.update(b)
            rec["data_sha256"] = h.hexdigest()
            rec["read_ok"] = True
        except OSError as ex:
            rec["read_ok"] = False
            rec["error"] = str(ex)
        lazy = attrs.get("rv.sha256") == "lazy"
        rec["intact"] = rec["read_ok"] and (lazy or attrs.get("rv.sha256") == rec.get("data_sha256"))
        print(json.dumps(rec))
        n += 1
finally:
    subprocess.run(["fusermount", "-u", mnt], capture_output=True)
    try:
        proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        proc.kill()
