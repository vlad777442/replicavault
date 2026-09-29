#!/usr/bin/env bash
# Phase 2 smoke test on the vstart cluster. Must pass on vanilla Ceph before any
# scenario result means anything, and is rerun after every prototype rebuild.
#
# put objects of several sizes -> read back with checksums -> delete some ->
# kill -9 and restart the primary of a surviving object -> wait clean ->
# deep-scrub every PG -> assert zero inconsistencies, deleted objects ENOENT and
# absent from `rados ls`, survivors intact.
#
# Usage: scripts/smoke.sh [pool]      (default pool: rvtest)
# Writes results/phase2/smoke-<timestamp>.json; exit status 0 iff every check passes.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

POOL=${1:-rvtest}
TS=$(date +%Y%m%dT%H%M%S)
RUN_ID=smoke-$TS
OUT=$RV_ROOT/results/${RV_RESULTS_SUBDIR:-phase2}/$RUN_ID.json   # pilot results/ is frozen
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$(dirname "$OUT")"

rv_require_cluster
CEPH_GIT=$(rv_ceph_git)
log "run $RUN_ID, ceph $CEPH_GIT, pool $POOL"
wait_clean 300 || die "cluster not clean before start"

# name:size pairs; sizes straddle min_alloc_size, the 64 KiB blob size, and 4 MiB.
SIZES=(0 1 4095 4096 65537 1048576 4194304 8388608)
declare -A WANT          # obj -> sha256
declare -a LIVE DELETED
for i in "${!SIZES[@]}"; do
  for rep in 0 1; do
    obj=smoke-$TS-$i-$rep
    head -c "${SIZES[$i]}" /dev/urandom > "$WORK/$obj"
    rados -p "$POOL" put "$obj" "$WORK/$obj" || die "put $obj failed"
    WANT[$obj]=$(sha "$WORK/$obj")
    # rep 1 of each size is deleted later
    if (( rep == 1 )); then DELETED+=("$obj"); else LIVE+=("$obj"); fi
  done
done
log "wrote ${#WANT[@]} objects"

check_fail=()
fail() { check_fail+=("$1"); log "FAIL: $1"; }

for obj in "${!WANT[@]}"; do
  [[ $(get_sha "$POOL" "$obj") == "${WANT[$obj]}" ]] || fail "readback-before $obj"
done

for obj in "${DELETED[@]}"; do
  rados -p "$POOL" rm "$obj" || fail "rm $obj"
done
log "deleted ${#DELETED[@]} objects"

# Kill the primary of a surviving object, so the failover path is exercised.
victim_obj=${LIVE[5]}
read -r -a acting <<<"$(acting_set "$POOL" "$victim_obj")"
victim=${acting[0]}
acting_json=$(IFS=,; echo "[${acting[*]}]")
log "killing osd.$victim (primary of $victim_obj, acting ${acting[*]})"
kill_osd "$victim"
sleep 5
restart_osd "$victim"
wait_clean 600 || fail "wait_clean after restart"

deep_scrub_all "$POOL" 900 || fail "deep_scrub_all timeout"
check_inconsistent "$POOL" || fail "inconsistency after deep scrub"

ls_out=$(rados -p "$POOL" ls)
for obj in "${DELETED[@]}"; do
  stat_enoent "$POOL" "$obj" || fail "resurrected (stat) $obj"
  grep -qxF "$obj" <<<"$ls_out" && fail "resurrected (ls) $obj"
done
for obj in "${LIVE[@]}"; do
  [[ $(get_sha "$POOL" "$obj") == "${WANT[$obj]}" ]] || fail "readback-after $obj"
done

# Clean up this run's live objects so repeated runs don't accumulate.
for obj in "${LIVE[@]}"; do rados -p "$POOL" rm "$obj" || true; done

result=$([[ ${#check_fail[@]} -eq 0 ]] && echo pass || echo fail)
python3 - "$OUT" <<EOF
import json, sys
json.dump({
  "run_id": "$RUN_ID",
  "timestamp": "$TS",
  "ceph_git": "$CEPH_GIT",
  "command": "scripts/smoke.sh $POOL",
  "pool": "$POOL",
  "objects_written": ${#WANT[@]},
  "objects_deleted": ${#DELETED[@]},
  "killed_osd": $victim,
  "acting_before_kill": $acting_json,
  "failures": $(printf '%s\n' "${check_fail[@]:-}" | python3 -c 'import json,sys; print(json.dumps([l for l in sys.stdin.read().splitlines() if l]))'),
  "result": "$result",
}, open(sys.argv[1], "w"), indent=2)
EOF
log "result: $result -> $OUT"
[[ $result == pass ]]
