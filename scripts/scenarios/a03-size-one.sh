#!/usr/bin/env bash
# a03 — pool size 1 (phase 2, adversarial). Uses its own pool `rvsz1` so rvtest keeps
# size 3. Per run: size 3 / min_size 2, write objects, set min_size 1 and size 1
# (needs mon_allow_pool_size_one = true, recorded, and --yes-i-really-mean-it), wait
# clean, delete objects, restore size 3 / min_size 2, wait clean.
# Only the deletes are checked: the replicas dropped by the size change are a PG-level
# path, out of scope in v1.
source "$(dirname "$0")/common.sh"
RUNS=3
RV_RESULTS_SUBDIR=phase2
scenario_init a03-size-one "$@"
SZ_POOL=rvsz1
POOL=$SZ_POOL
restore_size() {
  ceph osd pool set "$SZ_POOL" size 3 >/dev/null 2>&1 || true
  ceph osd pool set "$SZ_POOL" min_size 2 >/dev/null 2>&1 || true
}
trap 'restore_size; rm -rf "$WORK"' EXIT
size_one=$(ceph config get mon mon_allow_pool_size_one)

if ! ceph osd pool ls | grep -qx "$SZ_POOL"; then
  ceph osd pool create "$SZ_POOL" 8 8 replicated --autoscale-mode=off >/dev/null
  ceph osd pool application enable "$SZ_POOL" rados >/dev/null
fi
restore_size
wait_clean 600

for run in $(seq 1 "$RUNS"); do
  run_begin "$run" "{\"mon_allow_pool_size_one\": \"$size_one\"}"
  for i in $(seq 0 15); do put_obj "$RUN_PREFIX-$i" $(( 40000 + 997 * i )); done
  ceph osd pool set "$SZ_POOL" min_size 1 >/dev/null
  ceph osd pool set "$SZ_POOL" size 1 --yes-i-really-mean-it >/dev/null || die "size 1 refused"
  wait_clean 900 || die "not clean at size 1"
  note size_at_delete "$(ceph osd pool get "$SZ_POOL" size -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["size"])')"
  note example_acting "\"$(obj_up_acting "$SZ_POOL" "$RUN_PREFIX-0")\""
  names=()
  for i in $(seq 0 15); do (( i % 2 == 0 )) && { del_obj "$RUN_PREFIX-$i" || die "rm"; names+=("$RUN_PREFIX-$i"); }; done
  restore_size
  wait_clean 900 || die "not clean after restoring size 3"
  run_end "{\"vault_copies\": $(vault_copies_json "${names[@]}")}"
done
scenario_finish
