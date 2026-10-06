#!/usr/bin/env python3
"""z06 soak driver (zero-copy pilot, Phase 5).

  z06soak.py <pool> <snap-pool> <seconds> <state-file> <prefix> <kill-every-s> <osd-pid-dir> <osd-ids>

For <seconds>, a pool of names in <pool> sees random writes (write_full, 1 B-8 MiB),
partial overwrites, deletes and recreates of deleted names; <snap-pool> sees the same
plus pool snapshot creation and removal. Every <kill-every-s> seconds a random OSD
is SIGKILLed and restarted by the caller (this script only kills; the shell restarts
the OSD and waits for it). Every client action is appended to <state-file> as the
JSON lines rvcheck.py reads ({"op": put|del|unknown, ...}); a delete or write whose
outcome is unknown (error during an OSD kill) is recorded as "unknown".
Prints a JSON summary.
"""
import hashlib
import json
import os
import random
import signal
import subprocess
import sys
import time

import rados

pool, snap_pool, seconds, state, prefix, kill_every, piddir, osds = sys.argv[1:9]
seconds, kill_every = float(seconds), float(kill_every)
osds = osds.split(",")
SIZES = [1, 4096, 12345, 65536, 1048577, 4194304, 8388608]

c = rados.Rados(conffile=os.environ["CEPH_CONF"])
c.conf_set("rados_osd_op_timeout", "60")
c.connect(timeout=30)
io = {pool: c.open_ioctx(pool), snap_pool: c.open_ioctx(snap_pool)}
st = open(state, "a")
contents = {}           # (pool, name) -> current bytes, for partial overwrites
live, deleted = set(), set()
counts = {"write_full": 0, "partial": 0, "delete": 0, "recreate": 0, "mksnap": 0, "rmsnap": 0,
          "kills": 0, "unknown": 0}
snaps = []
kills = []


def rec(op, p, name, acked, sha=None):
    r = {"op": op, "pool": p, "ns": "", "loc": "", "name": name, "acked": acked}
    if sha:
        r["sha"] = sha
    st.write(json.dumps(r) + "\n")
    st.flush()


def write_full(p, name):
    data = os.urandom(random.choice(SIZES))
    try:
        io[p].write_full(name, data)
    except rados.Error:
        rec("unknown", p, name, False); counts["unknown"] += 1
        contents.pop((p, name), None); live.discard((p, name)); deleted.discard((p, name))
        return
    contents[(p, name)] = data
    rec("put", p, name, True, hashlib.sha256(data).hexdigest())
    live.add((p, name)); deleted.discard((p, name))


def partial(p, name):
    cur = contents[(p, name)]
    off = random.randrange(0, max(1, len(cur)))
    patch = os.urandom(random.choice([1, 512, 4096, 65536]))
    try:
        io[p].write(name, patch, off)
    except rados.Error:
        rec("unknown", p, name, False); counts["unknown"] += 1
        contents.pop((p, name), None); live.discard((p, name))
        return
    new = bytearray(cur)
    if off + len(patch) > len(new):
        new.extend(b"\0" * (off + len(patch) - len(new)))
    new[off:off + len(patch)] = patch
    contents[(p, name)] = bytes(new)
    rec("put", p, name, True, hashlib.sha256(new).hexdigest())


def delete(p, name):
    try:
        io[p].remove_object(name)
    except rados.ObjectNotFound:
        rec("unknown", p, name, False); counts["unknown"] += 1
        live.discard((p, name)); contents.pop((p, name), None)
        return
    except rados.Error:
        rec("unknown", p, name, False); counts["unknown"] += 1
        live.discard((p, name)); contents.pop((p, name), None)
        return
    rec("del", p, name, True)
    live.discard((p, name)); deleted.add((p, name)); contents.pop((p, name), None)


t0 = time.monotonic()
next_kill = t0 + kill_every
i = 0
while time.monotonic() - t0 < seconds:
    now = time.monotonic()
    if now >= next_kill:
        osd = random.choice(osds)
        try:
            pid = int(open(f"{piddir}/osd.{osd}.pid").read())
            os.kill(pid, signal.SIGKILL)
            kills.append({"t": round(now - t0, 1), "osd": int(osd)})
            counts["kills"] += 1
            # the shell watcher restarts it; keep issuing ops meanwhile
            open(f"{state}.kill", "a").write(f"{osd}\n")
        except (OSError, ValueError):
            pass
        next_kill = now + kill_every
    p = snap_pool if random.random() < 0.3 else pool
    r = random.random()
    if r < 0.03 and p == snap_pool:
        s = f"{prefix}-s{i}"
        if subprocess.run(
                [os.environ["CEPH_BUILD"] + "/bin/rados", "-c", os.environ["CEPH_CONF"], "-p", snap_pool,
                 "mksnap", s], capture_output=True).returncode == 0:
            snaps.append(s); counts["mksnap"] += 1
    elif r < 0.05 and p == snap_pool and snaps:
        s = snaps.pop(0)
        subprocess.run([os.environ["CEPH_BUILD"] + "/bin/rados", "-c", os.environ["CEPH_CONF"], "-p",
                        snap_pool, "rmsnap", s], capture_output=True)
        counts["rmsnap"] += 1
    elif r < 0.35:
        cands = [x for x in live if x[0] == p]
        if cands:
            delete(*random.choice(cands)); counts["delete"] += 1
            i += 1; continue
        write_full(p, f"{prefix}-o{random.randrange(40)}"); counts["write_full"] += 1
    elif r < 0.45:
        cands = [x for x in deleted if x[0] == p]
        if cands:
            write_full(*random.choice(cands)); counts["recreate"] += 1
    elif r < 0.65:
        cands = [x for x in live if x[0] == p and (x[0], x[1]) in contents]
        if cands:
            partial(*random.choice(cands)); counts["partial"] += 1
    else:
        write_full(p, f"{prefix}-o{random.randrange(40)}"); counts["write_full"] += 1
    i += 1
    time.sleep(random.uniform(0.0, 0.4))

for s in snaps:
    subprocess.run([os.environ["CEPH_BUILD"] + "/bin/rados", "-c", os.environ["CEPH_CONF"], "-p",
                    snap_pool, "rmsnap", s], capture_output=True)
    counts["rmsnap"] += 1
c.shutdown()
print(json.dumps({"seconds": seconds, "ops": i, "counts": counts, "kills": kills}))
