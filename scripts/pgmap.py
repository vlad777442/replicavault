#!/usr/bin/env python3
"""Local object -> PG mapping, identical to Ceph's for rjenkins pools, so scenarios can
find names that land in a given PG without one `ceph osd map` call per candidate.

Ceph v19.2.3 (c92aebb2): ceph_str_hash_rjenkins (src/common/ceph_hash.cc),
pg_pool_t::hash_key (src/osd/osd_types.cc:1785-1796), raw_hash_to_pg ->
ceph_stable_mod (src/osd/osd_types.cc:1798-1801, src/include/rados.h:96-102).

  pgmap.py map  <pool_id> <pg_num> [--ns NS] NAME...     -> "NAME <pool>.<seed hex>"
  pgmap.py find <pool_id> <pg_num> <pgid> <prefix> <count> [--start N] [--ns NS]
      -> first <count> names "<prefix>-<i>" (i >= start) whose PG is <pgid>
"""
import argparse

M = 0xFFFFFFFF


def _mix(a, b, c):
    a = (a - b - c) & M; a ^= c >> 13
    b = (b - c - a) & M; b ^= (a << 8) & M
    c = (c - a - b) & M; c ^= b >> 13
    a = (a - b - c) & M; a ^= c >> 12
    b = (b - c - a) & M; b ^= (a << 16) & M
    c = (c - a - b) & M; c ^= b >> 5
    a = (a - b - c) & M; a ^= c >> 3
    b = (b - c - a) & M; b ^= (a << 10) & M
    c = (c - a - b) & M; c ^= b >> 15
    return a, b, c


def rjenkins(data: bytes) -> int:
    k = data
    length = len(k)
    a = b = 0x9E3779B9
    c = 0
    i = 0
    n = length
    while n >= 12:
        a = (a + k[i] + (k[i+1] << 8) + (k[i+2] << 16) + (k[i+3] << 24)) & M
        b = (b + k[i+4] + (k[i+5] << 8) + (k[i+6] << 16) + (k[i+7] << 24)) & M
        c = (c + k[i+8] + (k[i+9] << 8) + (k[i+10] << 16) + (k[i+11] << 24)) & M
        a, b, c = _mix(a, b, c)
        i += 12
        n -= 12
    c = (c + length) & M
    t = k[i:]
    # fall-through switch of the C code
    if n >= 11: c = (c + (t[10] << 24)) & M
    if n >= 10: c = (c + (t[9] << 16)) & M
    if n >= 9:  c = (c + (t[8] << 8)) & M
    if n >= 8:  b = (b + (t[7] << 24)) & M
    if n >= 7:  b = (b + (t[6] << 16)) & M
    if n >= 6:  b = (b + (t[5] << 8)) & M
    if n >= 5:  b = (b + t[4]) & M
    if n >= 4:  a = (a + (t[3] << 24)) & M
    if n >= 3:  a = (a + (t[2] << 16)) & M
    if n >= 2:  a = (a + (t[1] << 8)) & M
    if n >= 1:  a = (a + t[0]) & M
    a, b, c = _mix(a, b, c)
    return c


def hash_key(key: str, ns: str = "") -> int:
    if not ns:
        return rjenkins(key.encode())
    return rjenkins(ns.encode() + b"\x1f" + key.encode())


def stable_mod(x, b, bmask):
    return x & bmask if (x & bmask) < b else x & (bmask >> 1)


def pg_of(pool_id, pg_num, name, ns=""):
    mask = (1 << (pg_num - 1).bit_length()) - 1
    return f"{pool_id}.{stable_mod(hash_key(name, ns), pg_num, mask):x}"


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("map")
    m.add_argument("pool_id", type=int); m.add_argument("pg_num", type=int)
    m.add_argument("--ns", default=""); m.add_argument("names", nargs="+")
    f = sub.add_parser("find")
    f.add_argument("pool_id", type=int); f.add_argument("pg_num", type=int)
    f.add_argument("pgid"); f.add_argument("prefix"); f.add_argument("count", type=int)
    f.add_argument("--start", type=int, default=0); f.add_argument("--ns", default="")
    a = ap.parse_args()
    if a.cmd == "map":
        for n in a.names:
            print(n, pg_of(a.pool_id, a.pg_num, n, a.ns))
    else:
        found, i = 0, a.start
        while found < a.count and i < a.start + 1_000_000:
            n = f"{a.prefix}-{i}"
            if pg_of(a.pool_id, a.pg_num, n, a.ns) == a.pgid:
                print(n)
                found += 1
            i += 1


if __name__ == "__main__":
    main()
