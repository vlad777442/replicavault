#!/usr/bin/env bash
# Inspect and restore ReplicaVault entries on one OSD.
#
# Vault entries live in the OSD's meta collection, namespace "replicavault",
# so they are only reachable offline: each command sets noout, stops the OSD,
# runs ceph-objectstore-tool, restarts the OSD, and clears noout (also on error).
#
#   vault-inspect.sh dump    <osd>                  JSON line per entry: identity, stored
#                                                   sha256, sha256 of the stored bytes
#   vault-inspect.sh names   <osd>                  vault entry names only (one store open)
#   vault-inspect.sh check   <osd> <vname>...       JSON line per named entry (found, intact)
#   vault-inspect.sh list    <osd>                  human-readable table
#   vault-inspect.sh extract <osd> <vname> <file>   write the entry's bytes to <file>
#   vault-inspect.sh restore <osd> <vname> [name]   extract, verify checksum, write back
#                                                   to the original pool/ns/locator under
#                                                   the original name (or [name]); prints
#                                                   JSON with the new object version
#
# Several OSD names may be given as "0,3" for dump/list; each is stopped in turn.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
export PYTHONPATH=$CEPH_BUILD/lib/cython_modules/lib.3${PYTHONPATH:+:$PYTHONPATH}

COT=$CEPH_BUILD/bin/ceph-objectstore-tool
NS=replicavault
WORK=$(mktemp -d)
STOPPED=()

cleanup() {
  local n
  for n in "${STOPPED[@]:-}"; do
    [[ -n $n ]] && ! osd_pid "$n" >/dev/null && restart_osd "$n"
  done
  ceph osd unset noout >/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

stop_for_inspection() {
  rv_require_cluster
  ceph osd set noout >/dev/null
  STOPPED+=("$1")
  kill_osd "$1" TERM
}

resume() {
  restart_osd "$1"
  STOPPED=("${STOPPED[@]/$1}")
}

cot() {  # cot <osd> args...
  local n=$1; shift
  "$COT" --data-path "$CEPH_BUILD/dev/osd$n" "$@" 2>/dev/null
}

# meta-list lines for vault entries: ["meta",{...,"namespace":"replicavault",...}]
vault_entries() {
  cot "$1" --op meta-list | grep "\"namespace\":\"$NS\"" || true
}

entry_json() {  # entry_json <osd> <vname> -> the meta-list JSON spec for that entry
  vault_entries "$1" | grep -F "\"oid\":\"$2\"" | head -1
}

# Decode a vault name: rv1_<pool>_<pgid>_<epoch>-<version>_<sec>.<nsec>_<hex ns>_<hex key>_<hex name>
decode_name_py='
import sys, json
def unhex(h): return bytes.fromhex(h).decode("utf-8", "surrogateescape")
def decode(v):
    f = v.split("_")
    assert f[0] == "rv1" and len(f) == 8, v
    e, ver = f[3].split("-")
    return {"vname": v, "pool": int(f[1]), "pgid": f[2], "epoch": int(e),
            "version": int(ver), "vaulted_at": f[4], "nspace": unhex(f[5]),
            "key": unhex(f[6]), "oid": unhex(f[7])}
'

# emit_entry <osd> <spec> -> one JSON line (identity, stored and actual sha256)
emit_entry() {
  local n=$1 spec=$2 vname attr_sha data_sha size
  vname=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[1]["oid"])' "$spec")
  attr_sha=$(cot "$n" --pgid meta "$spec" get-attr rv.sha256 || echo MISSING)
  # get-bytes refuses (EEXIST, exit 0) to overwrite an existing file
  rm -f "$WORK/b"
  cot "$n" --pgid meta "$spec" get-bytes "$WORK/b" || true
  [[ -e $WORK/b ]] || : > "$WORK/b"
  data_sha=$(sha "$WORK/b")
  size=$(stat -c %s "$WORK/b")
  python3 -c "$decode_name_py
import json, sys
d = decode(sys.argv[1])
d.update(osd=int(sys.argv[2]), found=True, stored_sha256=sys.argv[3], data_sha256=sys.argv[4],
         size=int(sys.argv[5]), intact=sys.argv[3] == sys.argv[4])
print(json.dumps(d))" "$vname" "$n" "$attr_sha" "$data_sha" "$size"
}

# check <osd> <vname>...: JSON line per requested entry; found=false if absent
check_entries() {
  local n=$1 vname spec; shift
  stop_for_inspection "$n"
  vault_entries "$n" > "$WORK/entries"
  for vname in "$@"; do
    spec=$(grep -F "\"oid\":\"$vname\"" "$WORK/entries" | head -1 || true)
    if [[ -n $spec ]]; then
      emit_entry "$n" "$spec"
    else
      python3 -c 'import json,sys; print(json.dumps({"vname": sys.argv[1], "osd": int(sys.argv[2]), "found": False}))' "$vname" "$n"
    fi
  done
  resume "$n"
}

dump_one_osd() {
  local n=$1 spec
  stop_for_inspection "$n"
  while IFS= read -r spec; do
    emit_entry "$n" "$spec"
  done < <(vault_entries "$n")
  resume "$n"
}

cmd=${1:-}; shift || true
case $cmd in
  dump)
    [[ $# -eq 1 ]] || die "usage: $0 dump <osd>[,<osd>...]"
    IFS=, read -r -a osds <<<"$1"
    for n in "${osds[@]}"; do dump_one_osd "$n"; done
    ;;
  names)
    [[ $# -eq 1 ]] || die "usage: $0 names <osd>"
    stop_for_inspection "$1"
    vault_entries "$1" | python3 -c 'import json,sys
for l in sys.stdin: print(json.loads(l)[1]["oid"])'
    resume "$1"
    ;;
  check)
    [[ $# -ge 2 ]] || die "usage: $0 check <osd> <vname>..."
    check_entries "$@"
    ;;
  list)
    [[ $# -eq 1 ]] || die "usage: $0 list <osd>[,<osd>...]"
    "$0" dump "$1" | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin if l.strip()]
fmt = "%3s %4s %-7s %10s %9s %-6s %s"
print(fmt % ("osd", "pool", "pgid", "version", "size", "intact", "oid"))
for r in rows:
    ns = r["nspace"] + "/" if r["nspace"] else ""
    ver = "%d'"'"'%d" % (r["epoch"], r["version"])
    print(fmt % (r["osd"], r["pool"], r["pgid"], ver, r["size"], r["intact"], ns + r["oid"]))
print("%d entries" % len(rows))'
    ;;
  extract)
    [[ $# -eq 3 ]] || die "usage: $0 extract <osd> <vname> <file>"
    n=$1 vname=$2 out=$3
    [[ ! -e $out ]] || die "$out already exists"
    stop_for_inspection "$n"
    spec=$(entry_json "$n" "$vname")
    [[ -n $spec ]] || die "no vault entry $vname on osd.$n"
    cot "$n" --pgid meta "$spec" get-bytes "$out"
    stored=$(cot "$n" --pgid meta "$spec" get-attr rv.sha256)
    resume "$n"
    [[ $(sha "$out") == "$stored" ]] || die "checksum mismatch: stored $stored, bytes $(sha "$out")"
    log "extracted $vname from osd.$n to $out ($(stat -c %s "$out") bytes, sha256 ok)"
    ;;
  restore)
    [[ $# -ge 2 ]] || die "usage: $0 restore <osd> <vname> [name]"
    n=$1 vname=$2 target=${3:-}
    "$0" extract "$n" "$vname" "$WORK/data"
    stored=$(sha "$WORK/data")
    python3 - "$vname" "$WORK/data" "$target" "$stored" "$n" <<EOF
$decode_name_py
import json, os, sys, rados
vname, path, target, sha, osd = sys.argv[1:6]
d = decode(vname)
c = rados.Rados(conffile=os.environ["CEPH_CONF"])
c.connect(timeout=30)
pool_name = c.pool_reverse_lookup(d["pool"])
io = c.open_ioctx(pool_name)
io.set_namespace(d["nspace"])
if d["key"]:
    io.set_locator_key(d["key"])
name = target or d["oid"]
existed = True
try:
    io.stat(name)
except rados.ObjectNotFound:
    existed = False
data = open(path, "rb").read()
io.write_full(name, data)
new_version = io.get_last_version()
back = io.read(name, len(data) + 1)
import hashlib
print(json.dumps({
    "vname": vname, "from_osd": int(osd), "pool": pool_name, "nspace": d["nspace"],
    "key": d["key"], "restored_as": name, "overwrote_existing": existed,
    "vaulted_version": d["version"], "vaulted_epoch": d["epoch"],
    "new_version": new_version, "new_version_is_newer": new_version > d["version"],
    "sha256": sha, "readback_matches": hashlib.sha256(back).hexdigest() == sha,
}))
c.shutdown()
EOF
    ;;
  *)
    sed -n '2,19p' "$0"; exit 2
    ;;
esac
