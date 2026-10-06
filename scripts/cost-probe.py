#!/usr/bin/env python3
"""Phase 2 cost probe (A3) — indicative, single host. Not the H1 evaluation.

A background workload of 4 KiB reads and writes runs in one pool while objects of
1, 4, 16, 64 and 128 MiB are deleted, one at a time, from a single target PG, so
one OSD (the retainer of that PG) does all the vault work. Reports p50/p99 of the
4 KiB ops that start while a delete is in flight vs a no-delete baseline, per
deleted-object size, overall and for 4 KiB ops whose primary is the retainer, plus
the delete latency itself and the retainer's `perf dump` op-latency counters.

  cost-probe.py --pool P --out results.json [--sizes-mib 1 4 16 64 128]
                [--deletes 6] [--threads 4] [--baseline-s 20]

Environment: CEPH_CONF of the cluster to probe; CEPH_BIN (dir with the `ceph` CLI).
"""
import argparse
import json
import os
import random
import statistics
import subprocess
import sys
import threading
import time

import rados

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pgmap  # noqa: E402

CHUNK = 64 << 20  # below osd_max_write_size (90 MiB default)


def ceph_json(*args):
    out = subprocess.run([os.path.join(os.environ["CEPH_BIN"], "ceph"), "-c", os.environ["CEPH_CONF"],
                          *args, "-f", "json"], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[min(len(xs) - 1, int(p / 100 * len(xs)))] * 1000, 3)  # ms


def summary(lat):
    return {"n": len(lat), "p50_ms": pct(lat, 50), "p99_ms": pct(lat, 99),
            "mean_ms": round(statistics.mean(lat) * 1000, 3) if lat else None}


DEV_KEYS = ["write_big_bytes", "write_small_bytes", "issued_deferred_write_bytes",
            "bytes_written_wal", "bytes_written_sst", "bytes_written_slow"]


def device_counters(osd):
    d = ceph_json("tell", f"osd.{osd}", "perf", "dump")
    bs, bf = d.get("bluestore", {}), d.get("bluefs", {})
    return {k: int(bs.get(k, bf.get(k, 0))) for k in DEV_KEYS}


def diskstats(dev):
    """sectors written to <dev> (/proc/diskstats field 10)."""
    for l in open("/proc/diskstats"):
        f = l.split()
        if f[2] == dev:
            return int(f[9])
    return 0


def osd_op_counters(osd):
    d = ceph_json("tell", f"osd.{osd}", "perf", "dump")["osd"]
    return {k: {"avgcount": d[k]["avgcount"], "sum": d[k]["sum"]}
            for k in ("op_latency", "op_r_latency", "op_w_latency")}


def counter_delta(a, b):
    out = {}
    for k in a:
        n = b[k]["avgcount"] - a[k]["avgcount"]
        out[k] = {"ops": n, "avg_ms": round((b[k]["sum"] - a[k]["sum"]) / n * 1000, 3) if n else None}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--sizes-mib", type=int, nargs="+", default=[1, 4, 16, 64, 128])
    ap.add_argument("--sizes-kib", type=int, nargs="+", default=None,
                    help="sizes in KiB (zc Phase 6: 4 1024 4096 16384 65536 131072); overrides --sizes-mib")
    ap.add_argument("--disk", default="sdb", help="block device holding the OSDs, for /proc/diskstats")
    ap.add_argument("--deletes", type=int, default=6)
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--baseline-s", type=float, default=20)
    ap.add_argument("--tag", default="probe")
    a = ap.parse_args()

    c = rados.Rados(conffile=os.environ["CEPH_CONF"])
    c.connect(timeout=60)
    io = c.open_ioctx(a.pool)
    pool_id = c.pool_lookup(a.pool)
    pg_num = ceph_json("osd", "pool", "get", a.pool, "pg_num")["pg_num"]

    seed = f"{a.tag}-seed"
    m = ceph_json("osd", "map", a.pool, seed)
    target_pg = m["pgid"]
    order = [m["acting_primary"]] + [o for o in m["acting"] if o != m["acting_primary"]]
    retainer = order[1] if len(order) > 1 else order[0]

    # 4 KiB workload objects, tagged by whether the retainer is their primary
    small = []
    for i in range(64):
        n = f"{a.tag}-4k-{i}"
        mm = ceph_json("osd", "map", a.pool, n)
        small.append((n, mm["acting_primary"] == retainer))
        io.write_full(n, os.urandom(4096))

    records = []   # (t_start, t_end, on_retainer_primary)
    stop = threading.Event()
    lock = threading.Lock()

    def worker(k):
        rnd = random.Random(k)
        buf = os.urandom(4096)
        while not stop.is_set():
            n, on_r = small[rnd.randrange(len(small))]
            t0 = time.monotonic()
            if rnd.random() < 0.5:
                io.read(n, 4096)
            else:
                io.write_full(n, buf)
            t1 = time.monotonic()
            with lock:
                records.append((t0, t1, on_r))

    threads = [threading.Thread(target=worker, args=(k,), daemon=True) for k in range(a.threads)]
    for t in threads:
        t.start()
    tb0 = time.monotonic()
    time.sleep(a.baseline_s)
    tb1 = time.monotonic()

    results = {"retainer": retainer, "target_pg": target_pg, "acting": m["acting"],
               "acting_primary": m["acting_primary"], "sizes": {}}
    sizes_kib = a.sizes_kib or [m << 10 for m in a.sizes_mib]
    osds = [int(x) for x in ceph_json("osd", "ls")]
    for kib in sizes_kib:
        mib = kib >> 10 if kib % 1024 == 0 else kib / 1024
        key = str(mib) if a.sizes_kib is None else f"{kib}KiB"
        names = [n for n in pgmap_names(pool_id, pg_num, target_pg, f"{a.tag}-{kib}k", a.deletes)]
        data = os.urandom(kib << 10)
        for n in names:  # setup, not measured
            for off in range(0, len(data), CHUNK):
                io.write(n, data[off:off + CHUNK], off)
        time.sleep(3)
        before = osd_op_counters(retainer)
        dev_before = {o: device_counters(o) for o in osds}
        disk_before = diskstats(a.disk)
        windows, del_lat = [], []
        for n in names:
            t0 = time.monotonic()
            io.remove_object(n)
            t1 = time.monotonic()
            windows.append((t0, t1))
            del_lat.append(t1 - t0)
            time.sleep(2)
        time.sleep(3)   # let deferred writes and the kv sync settle into the counters
        after = osd_op_counters(retainer)
        dev_after = {o: device_counters(o) for o in osds}
        disk_after = diskstats(a.disk)
        dev = {k: sum(dev_after[o][k] - dev_before[o][k] for o in osds) for k in DEV_KEYS}
        with lock:
            recs = list(records)
        during = [r for r in recs if any(w0 <= r[0] <= w1 for w0, w1 in windows)]
        n_del = len(names)
        results["sizes"][key] = {
            "size_kib": kib,
            "deletes": n_del,
            # summed over every OSD, per delete (BlueStore.cc:6352-6391, BlueFS.cc:261-269)
            "device_bytes_per_delete": {
                "bluestore_data": (dev["write_big_bytes"] + dev["write_small_bytes"]) / n_del,
                "bluestore_deferred": dev["issued_deferred_write_bytes"] / n_del,
                "bluefs_db_wal": (dev["bytes_written_wal"] + dev["bytes_written_sst"] + dev["bytes_written_slow"]) / n_del,
                "counters_total": dev,
                "disk_sectors_written_per_delete": (disk_after - disk_before) / n_del,
            },
            "delete_latency": summary(del_lat),
            "ops_4k_during_delete": summary([r[1] - r[0] for r in during]),
            "ops_4k_during_delete_retainer_primary": summary([r[1] - r[0] for r in during if r[2]]),
            "retainer_perf_delta": counter_delta(before, after),
        }
        print(f"{key}: {results['sizes'][key]['delete_latency']} "
              f"4k during: {results['sizes'][key]['ops_4k_during_delete']}", file=sys.stderr)
    stop.set()
    for t in threads:
        t.join()
    base = [r for r in records if tb0 <= r[0] <= tb1]
    results["baseline_4k"] = summary([r[1] - r[0] for r in base])
    results["baseline_4k_retainer_primary"] = summary([r[1] - r[0] for r in base if r[2]])
    for i in range(64):
        io.remove_object(f"{a.tag}-4k-{i}")
    io.close()
    c.shutdown()
    json.dump(results, open(a.out, "w"), indent=1)


def pgmap_names(pool_id, pg_num, pgid, prefix, count):
    found, i = [], 0
    while len(found) < count:
        n = f"{prefix}-{i}"
        if pgmap.pg_of(pool_id, pg_num, n) == pgid:
            found.append(n)
        i += 1
    return found


if __name__ == "__main__":
    main()
