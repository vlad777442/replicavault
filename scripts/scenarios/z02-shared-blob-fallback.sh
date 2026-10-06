#!/usr/bin/env bash
# z02 — shared-blob fallback (zero-copy pilot, Phase 5). Pool `rvsnap`, as s10.
# Per run, four objects, each deleted once:
#   A  put; mksnap; rm                   the delete clones the head in its own txn
#                                        -> first use of the head is not its remove
#                                        -> mode=copy expected
#   B  put 1 MiB; mksnap; write 4 KiB at offset 4096 (partial overwrite: the head is
#      cloned, then only part of it rewritten, so head and clone share blobs); rm
#                                        -> can_move_to_collection -EXDEV
#                                        -> mode=copy expected
#   C  put; mksnap; write_full; rm       head blobs unshared -> mode=rename expected
#   D  mksnap; put; rm                   written after the snapshot -> mode=rename
# Checks: every vault line for A-D has the expected mode (prototype builds); the
# clones of A, B and C read back their pre-snapshot bytes; invariants 1-4 (the vault
# holds the head's bytes at delete time, checked against client-side sha256).
source "$(dirname "$0")/common.sh"
RUNS=3
SNAP_POOL=rvsnap
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
scenario_init z02-shared-blob-fallback "$@"
POOL=$SNAP_POOL
EXTRA_POOLS=()

if ! ceph osd pool ls | grep -qx "$SNAP_POOL"; then
  ceph osd pool create "$SNAP_POOL" 8 8 replicated --autoscale-mode=off >/dev/null
  ceph osd pool set "$SNAP_POOL" size 3 >/dev/null
  ceph osd pool set "$SNAP_POOL" min_size 2 >/dev/null
  ceph osd pool application enable "$SNAP_POOL" rados >/dev/null
  wait_clean 300
fi

snap_sha() {  # snap_sha SNAP NAME -> sha256 of the object as of SNAP, or ENOENT
  local f=$WORK/snapread
  rm -f "$f"
  if rados -p "$SNAP_POOL" -s "$1" get "$2" "$f" >/dev/null; then sha "$f"; else echo ENOENT; fi
}
last_sha() { tail -1 "$RUN_STATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])'; }

for run in $(seq 1 "$RUNS"); do
  run_begin "$run"
  a=$RUN_PREFIX-A b=$RUN_PREFIX-B c=$RUN_PREFIX-C d=$RUN_PREFIX-D s=$RUN_PREFIX-snap

  put_obj "$a" 90001;   a0=$(last_sha)
  put_obj "$b" 1048576; b0=$(last_sha)
  rados -p "$SNAP_POOL" get "$b" "$WORK/b-orig" >/dev/null
  put_obj "$c" 70001;   c0=$(last_sha)
  rados -p "$SNAP_POOL" mksnap "$s" >/dev/null

  # B: partial overwrite after the snapshot; record the head's new content
  head -c 4096 /dev/urandom > "$WORK/b-patch"
  # rados put at a nonzero offset is a plain write (offset 0 would be write_full,
  # src/tools/rados/rados.cc do_put)
  rados -p "$SNAP_POOL" put "$b" "$WORK/b-patch" --offset 4096 || die "partial write $b"
  { head -c 4096 "$WORK/b-orig"; cat "$WORK/b-patch"; tail -c +8193 "$WORK/b-orig"; } > "$WORK/b-new"
  _state put "$SNAP_POOL" "" "" "$b" 1 "$(sha "$WORK/b-new")"
  put_obj "$c" 70002            # C: write_full after the snapshot
  put_obj "$d" 60001            # D: created after the snapshot

  # debug_osd 10 only around the deletes: ReplicaVault's "staged ... renamable= can_move="
  # line (level 10) says why each entry took its mode
  ceph tell 'osd.*' config set debug_osd 10 >/dev/null 2>&1 || true
  for o in "$a" "$b" "$c" "$d"; do del_obj "$o" || die "rm $o"; done
  sleep 2
  ceph tell 'osd.*' config set debug_osd 1/5 >/dev/null 2>&1 || true
  why=$(for n in $(osd_ids); do
    tail -c +"$(( $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], 0))' "$WORK/offsets-$RUN.json" "$n") + 1 ))" \
      "$CEPH_BUILD/out/osd.$n.log" 2>/dev/null | grep 'replicavault: staged' || true
  done | python3 -c '
import json, re, sys
out = {}
for l in sys.stdin:
    m = re.search(r"staged (\S+) mode=(\w+) renamable=(\d) can_move=(-?\d+)", l)
    if not m: continue
    oid = bytes.fromhex(m.group(1).split("_")[-1]).decode()
    if not oid.startswith(sys.argv[1]): continue
    out.setdefault(oid.rsplit("-", 1)[-1], []).append(
        {"mode": m.group(2), "renamable": m.group(3) == "1", "can_move": int(m.group(4))})
print(json.dumps(out))' "$RUN_PREFIX")
  note staged_reasons "$why"

  snapA=$(snap_sha "$s" "$a") snapB=$(snap_sha "$s" "$b") snapC=$(snap_sha "$s" "$c")
  clones_ok=$([[ $snapA == "$a0" && $snapB == "$b0" && $snapC == "$c0" ]] && echo true || echo false)

  modes=$(for o in "$a" "$b" "$c" "$d"; do
    for n in $(osd_ids); do
      tail -c +"$(( $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], 0))' "$WORK/offsets-$RUN.json" "$n") + 1 ))" \
        "$CEPH_BUILD/out/osd.$n.log" 2>/dev/null | grep 'replicavault: vaulted' | grep -F " oid=$o " \
        | sed -E "s/.* path=([a-z]+) mode=([a-z]+) .*/${o##*-} $n \1 \2/" || true
    done
  done | python3 -c '
import json, sys
want = {"A": "copy", "B": "copy", "C": "rename", "D": "rename"}
seen = {k: [] for k in want}
for l in sys.stdin:
    case, osd, path, mode = l.split()
    seen[case].append({"osd": int(osd), "path": path, "mode": mode})
ok = all(seen[k] and all(e["mode"] == want[k] for e in seen[k]) for k in want)
print(json.dumps({"pass": ok, "expected": want, "seen": seen}))')
  if ! vault_mode; then modes='{"pass": null, "skipped": "vanilla"}'; fi
  note clone_reads "{\"A\": $([[ $snapA == "$a0" ]] && echo true || echo false), \"B\": $([[ $snapB == "$b0" ]] && echo true || echo false), \"C\": $([[ $snapC == "$c0" ]] && echo true || echo false)}"

  rados -p "$SNAP_POOL" rmsnap "$s" >/dev/null
  run_end "{\"clones_intact\": {\"pass\": $clones_ok}, \"vault_modes\": $modes}"
  python3 - "$RUNS_FILE" <<'EOF'
import json, sys
path = sys.argv[1]
runs = [json.loads(l) for l in open(path)]
r = runs[-1]
r["pass"] = r["pass"] and r["clones_intact"]["pass"] and r["vault_modes"]["pass"] in (True, None)
open(path, "w").write("".join(json.dumps(x) + "\n" for x in runs))
EOF
done
scenario_finish
