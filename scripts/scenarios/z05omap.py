#!/usr/bin/env python3
"""z05 helpers: omap-heavy objects (zero-copy pilot, Phase 5).

  z05omap.py write  <pool> <name> <nkeys> <datasize>   -> JSON {sha, omap_digest, ...}
  z05omap.py delete <pool> <name>                      -> JSON {rm_s}
  z05omap.py vault  <osd-data-path> <vname> <cot> <kvtool> [data-out-file]
        -> JSON {found, nid, header, omap: {key: hex}, omap_digest}   (OSD stopped)
  z05omap.py restore <pool> <name> <vault-json> <data-file>
        -> JSON {new_version, omap_digest_after, readback ...}

Vault omap is read straight from BlueStore's RocksDB (`ceph-kvstore-tool
bluestore-kv <path> dump p`): a renamed entry keeps its per-PG omap flag, so its keys
are `p` + u64 pool + u32 hash + u64 nid + ('-' header | '.' key | '~' tail)
(BlueStore.cc:4660-4706). ceph-objectstore-tool reads one omap value per process.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time


def digest(header, kv):
    h = hashlib.sha256()
    h.update(len(header).to_bytes(8, "big") + header)
    for k in sorted(kv):
        v = kv[k]
        kb = k.encode() if isinstance(k, str) else k
        h.update(len(kb).to_bytes(8, "big") + kb + len(v).to_bytes(8, "big") + v)
    return h.hexdigest()


def rados_cli(pool, *args):
    return subprocess.run([os.environ["CEPH_BUILD"] + "/bin/rados", "-c", os.environ["CEPH_CONF"],
                           "-p", pool, *args], check=True, capture_output=True)


def get_header(pool, name):
    f = f"/tmp/z05hdr.{os.getpid()}"
    rados_cli(pool, "getomapheader", name, f)
    h = open(f, "rb").read()
    os.unlink(f)
    return h


def ioctx(pool):
    import rados
    c = rados.Rados(conffile=os.environ["CEPH_CONF"])
    c.connect(timeout=30)
    return c, c.open_ioctx(pool)


def cmd_write(pool, name, nkeys, size):
    import rados
    nkeys, size = int(nkeys), int(size)
    c, io = ioctx(pool)
    data = os.urandom(size)
    # printable header: `rados setomapheader` takes it as a command-line string
    header = os.urandom(32).hex().encode()
    kv = {f"k{i:08d}-{os.urandom(4).hex()}": os.urandom(100 + i % 300) for i in range(nkeys)}
    io.write_full(name, data)
    keys = list(kv)
    for i in range(0, len(keys), 1000):
        with rados.WriteOpCtx() as op:
            io.set_omap(op, tuple(keys[i:i + 1000]), tuple(kv[k] for k in keys[i:i + 1000]))
            io.operate_write_op(op, name)
    rados_cli(pool, "setomapheader", name, header.decode())
    c.shutdown()
    print(json.dumps({"sha": hashlib.sha256(data).hexdigest(), "omap_digest": digest(header, kv),
                      "nkeys": nkeys, "size": size,
                      "omap_bytes": sum(len(k) + len(v) for k, v in kv.items())}))


def cmd_delete(pool, name):
    c, io = ioctx(pool)
    t = time.monotonic()
    io.remove_object(name)
    dt = time.monotonic() - t
    c.shutdown()
    print(json.dumps({"rm_s": round(dt, 5)}))


def unescape(s):
    out = bytearray()
    i = 0
    while i < len(s):
        if s[i] == "%" and i + 2 < len(s) + 1 and re.match(r"[0-9a-fA-F]{2}", s[i + 1:i + 3]):
            out.append(int(s[i + 1:i + 3], 16)); i += 3
        else:
            out += s[i].encode(); i += 1
    return bytes(out)


def cmd_vault(path, vname, cot, kvtool, datafile=None):
    p = subprocess.run([cot, "--data-path", path, "--op", "meta-list"], capture_output=True, text=True)
    spec = next((l for l in p.stdout.splitlines() if f'"oid":"{vname}"' in l), None)
    if spec is None:
        print(json.dumps({"found": False})); return
    d = json.loads(subprocess.run([cot, "--data-path", path, "--pgid", "meta", spec, "dump"],
                                  capture_output=True, text=True).stdout)
    nid = d["onode"]["nid"]
    f = f"/tmp/z05data.{os.getpid()}"
    if os.path.exists(f):
        os.unlink(f)
    subprocess.run([cot, "--data-path", path, "--pgid", "meta", spec, "get-bytes", f], capture_output=True)
    data = open(f, "rb").read() if os.path.exists(f) else b""
    if datafile:
        os.replace(f, datafile)         # keep the bytes for a restore
    elif os.path.exists(f):
        os.unlink(f)
    dump = subprocess.run([kvtool, "bluestore-kv", path, "dump", "p"], capture_output=True, text=True).stdout
    header, kv, tail = b"", {}, False
    key, val = None, bytearray()

    def flush():
        nonlocal header, tail
        if key is None or len(key) < 21 or int.from_bytes(key[12:20], "big") != nid:
            return
        kind, rest = key[20:21], key[21:]
        if kind == b"-":
            header = bytes(val)
        elif kind == b".":
            kv[rest.decode()] = bytes(val)
        elif kind == b"~":
            tail = True

    for line in dump.splitlines():
        if line.startswith("p\t"):
            flush()
            key, val = unescape(line[2:]), bytearray()
        elif re.match(r"^[0-9a-f]{8}  ", line):
            hexpart = line[10:].split("|")[0]
            val += bytes.fromhex("".join(hexpart.split()))
    flush()
    print(json.dumps({"found": True, "nid": nid, "tail_key": tail,
                      "data_sha": hashlib.sha256(data).hexdigest(), "nkeys": len(kv),
                      "header": header.hex(), "omap": {k: v.hex() for k, v in kv.items()},
                      "omap_digest": digest(header, kv)}))


def cmd_restore(pool, name, vjson, datafile):
    import rados
    v = json.load(open(vjson))
    data = open(datafile, "rb").read()
    header = bytes.fromhex(v["header"])
    kv = {k: bytes.fromhex(x) for k, x in v["omap"].items()}
    c, io = ioctx(pool)
    existed = True
    try:
        io.stat(name)
    except rados.ObjectNotFound:
        existed = False
    io.write_full(name, data)
    ver = io.get_last_version()
    keys = list(kv)
    for i in range(0, len(keys), 1000):
        with rados.WriteOpCtx() as op:
            io.set_omap(op, tuple(keys[i:i + 1000]), tuple(kv[k] for k in keys[i:i + 1000]))
            io.operate_write_op(op, name)
    rados_cli(pool, "setomapheader", name, header.decode())
    # read back everything from the live object
    back = io.read(name, len(data) + 1)
    got = {}
    start = ""
    while True:
        with rados.ReadOpCtx() as op:
            it, _ = io.get_omap_vals(op, start, "", 1000)
            io.operate_read_op(op, name)
            batch = list(it)
        for k, x in batch:
            got[k] = x
        if len(batch) < 1000:
            break
        start = batch[-1][0]
    hdr = get_header(pool, name)
    c.shutdown()
    print(json.dumps({"overwrote_existing": existed, "new_version": ver,
                      "data_readback_sha": hashlib.sha256(back).hexdigest(),
                      "omap_digest_after": digest(hdr, got), "nkeys_after": len(got)}))


if __name__ == "__main__":
    {"write": cmd_write, "delete": cmd_delete, "vault": cmd_vault,
     "restore": cmd_restore}[sys.argv[1]](*sys.argv[2:])
