#!/usr/bin/env python3
"""librados AIO drivers for the phase 2 crash and read-after-queue scenarios.

  aio_ops.py delete-kill <pool> <objects-file> <kill-delay-s> <osd-pidfile>
      Issue aio_remove for every object named in <objects-file> (one per line) at
      once, sleep <kill-delay-s>, SIGKILL the process in <osd-pidfile>, then wait
      (up to 180 s) for every remove to complete. Prints one JSON object:
      {"kill_at": t, "objects": {name: {"rc": int|null, "done_s": float|null,
      "done_before_kill": bool}}}. rc 0 = acknowledged; null = never completed.

  aio_ops.py write-remove <pool> <name> <size> <writes> <out-dir>
      Issue <writes> aio_write_full calls with distinct random contents of <size>
      bytes, then aio_remove, without waiting in between. Waits for all to
      complete. Writes each content to <out-dir>/<name>.<i> and prints JSON:
      {"writes": [{"sha": s, "rc": int}], "remove_rc": int}.
"""
import hashlib
import json
import os
import signal
import sys
import threading
import time

import rados


def connect():
    c = rados.Rados(conffile=os.environ["CEPH_CONF"])
    c.connect(timeout=60)
    return c


def delete_kill(pool, objfile, delay, pidfile):
    names = [l.strip() for l in open(objfile) if l.strip()]
    c = connect()
    io = c.open_ioctx(pool)
    res = {n: {"rc": None, "done_s": None, "done_before_kill": False} for n in names}
    lock = threading.Lock()
    t0 = time.monotonic()
    kill_at = [None]

    def cb(name):
        def f(comp):
            with lock:
                res[name]["rc"] = comp.get_return_value()
                res[name]["done_s"] = round(time.monotonic() - t0, 4)
                res[name]["done_before_kill"] = kill_at[0] is None
        return f

    comps = [io.aio_remove(n, oncomplete=cb(n)) for n in names]
    time.sleep(delay)
    pid = int(open(pidfile).read().strip())
    with lock:
        kill_at[0] = round(time.monotonic() - t0, 4)
    os.kill(pid, signal.SIGKILL)
    deadline = time.monotonic() + 180
    for comp in comps:
        while not comp.is_complete() and time.monotonic() < deadline:
            time.sleep(0.05)
    io.close()
    c.shutdown()
    print(json.dumps({"kill_at": kill_at[0], "objects": res}))


def write_remove(pool, name, size, writes, outdir):
    c = connect()
    io = c.open_ioctx(pool)
    contents = [os.urandom(size) for _ in range(writes)]
    comps = [io.aio_write_full(name, data) for data in contents]
    rm = io.aio_remove(name)
    for comp in comps + [rm]:
        comp.wait_for_complete()
    out = {"writes": [], "remove_rc": rm.get_return_value()}
    for i, (data, comp) in enumerate(zip(contents, comps)):
        with open(os.path.join(outdir, f"{name}.{i}"), "wb") as f:
            f.write(data)
        out["writes"].append({"sha": hashlib.sha256(data).hexdigest(),
                              "rc": comp.get_return_value()})
    io.close()
    c.shutdown()
    print(json.dumps(out))


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "delete-kill":
        delete_kill(sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5])
    elif mode == "write-remove":
        write_remove(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6])
    else:
        sys.exit(__doc__)
