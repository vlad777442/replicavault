#!/usr/bin/env bash
# Scenario 10: delete of an object with snapshot clones (pool snapshots via
# `rados mksnap`), in a separate pool `rvsnap` so snapshots never affect other
# scenarios. Documents what the prototype does; snapshot semantics are not changed.
#
# Per run:
#   A: put a1; mksnap sA; overwrite a2; rm   (head differs from the clone)
#   B: put b1; mksnap sB; rm                 (head equals the clone)
#   check: head ENOENT (invariant 1), snapshot reads return a1 / b1,
#          vault (invariant 3) holds the head at delete time: a2 / b1
#   rmsnap sA, sB -> snap trim removes clones and whiteouts; wait clean
#   check: no vault line was written for any clone (snap trim is not vaulted)
source "$(dirname "$0")/common.sh"
RUNS=3
SNAP_POOL=rvsnap
scenario_init s10-snapshot-delete "$@"
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
  # `rados -s` prints "selected snap N 'name'" on stdout; keep it out of the result
  if rados -p "$SNAP_POOL" -s "$1" get "$2" "$f" >/dev/null; then sha "$f"; else echo ENOENT; fi
}

for run in $(seq 1 "$RUNS"); do
  run_begin "$run"
  a=$RUN_PREFIX-a b=$RUN_PREFIX-b sA=$RUN_PREFIX-sA sB=$RUN_PREFIX-sB
  put_obj "$a" 90001
  a1=$(tail -1 "$RUN_STATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')
  rados -p "$SNAP_POOL" mksnap "$sA" >/dev/null
  put_obj "$a" 90002
  del_obj "$a" || die "rm $a"
  put_obj "$b" 80001
  b1=$(tail -1 "$RUN_STATE" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')
  rados -p "$SNAP_POOL" mksnap "$sB" >/dev/null
  del_obj "$b" || die "rm $b"

  snapA=$(snap_sha "$sA" "$a") snapB=$(snap_sha "$sB" "$b")
  snaps_ok=$([[ $snapA == "$a1" && $snapB == "$b1" ]] && echo true || echo false)
  note snapshot_reads "{\"a_matches_a1\": $([[ $snapA == "$a1" ]] && echo true || echo false), \"b_matches_b1\": $([[ $snapB == "$b1" ]] && echo true || echo false)}"

  lines_before_trim=$( { vault_lines_for "$a"; vault_lines_for "$b"; } | wc -l)
  rados -p "$SNAP_POOL" rmsnap "$sA" >/dev/null
  rados -p "$SNAP_POOL" rmsnap "$sB" >/dev/null
  sleep 5
  wait_clean 900 || true
  lines_after_trim=$( { vault_lines_for "$a"; vault_lines_for "$b"; } | wc -l)
  trim_ok=$([[ $lines_after_trim == "$lines_before_trim" ]] && echo true || echo false)
  note vault_lines "{\"before_trim\": $lines_before_trim, \"after_trim\": $lines_after_trim}"

  run_end "{\"snapshot_reads\": {\"pass\": $snaps_ok}, \"snap_trim_not_vaulted\": {\"pass\": $trim_ok}}"
  python3 - "$RUNS_FILE" <<'EOF'
import json, sys
path = sys.argv[1]
runs = [json.loads(l) for l in open(path)]
r = runs[-1]
r["pass"] = r["pass"] and r["snapshot_reads"]["pass"] and r["snap_trim_not_vaulted"]["pass"]
open(path, "w").write("".join(json.dumps(x) + "\n" for x in runs))
EOF
done
scenario_finish
