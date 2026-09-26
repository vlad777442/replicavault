#!/usr/bin/env bash
# Scenario 9: pg_num change (split, then merge) while vault entries exist for the
# affected PGs. pg_num is set directly (deterministic); the autoscaler stays off.
#
# run 1 (split): write objects over all PGs, delete half (vault entries in every PG),
#   pg_num 32 -> 64, wait until pg_num = pgp_num = 64 and clean, delete more objects
#   (now in child PGs), run_end.
# run 2 (merge): carries run 1's actions, so every run-1 vault entry is re-checked;
#   delete more, pg_num 64 -> 32, wait, delete more, run_end.
# The pool is always returned to pg_num 32.
source "$(dirname "$0")/common.sh"
RUNS=2
scenario_init s09-pg-split-merge "$@"
BASE_PG=32
SPLIT_PG=64

restore_pg_num() {
  ceph osd pool set "$POOL" pg_num "$BASE_PG" >/dev/null 2>&1 || true
}
trap 'restore_pg_num; ceph osd unset noout >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

# run 1: split
run_begin 1 "{\"pg_num\": [$BASE_PG, $SPLIT_PG]}"
for i in $(seq 0 127); do put_obj "$RUN_PREFIX-$i" $(( 20000 + 311 * i )); done
for i in $(seq 0 2 127); do del_obj "$RUN_PREFIX-$i"; done
note pgs_before "$(ceph osd pool get "$POOL" pg_num -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pg_num"])')"
ceph osd pool set "$POOL" pg_num "$SPLIT_PG" >/dev/null
wait_pg_num "$POOL" "$SPLIT_PG" 3600 || die "split did not complete"
for i in $(seq 1 4 127); do del_obj "$RUN_PREFIX-$i"; done
note pgs_after "$SPLIT_PG"
run_end

# run 2: merge
prefix1=$RUN_PREFIX
run_begin 2 "{\"pg_num\": [$SPLIT_PG, $BASE_PG]}"
carry_previous_run
for i in $(seq 3 8 127); do del_obj "$prefix1-$i"; done
ceph osd pool set "$POOL" pg_num "$BASE_PG" >/dev/null
wait_pg_num "$POOL" "$BASE_PG" 7200 || die "merge did not complete"
for i in $(seq 7 8 127); do del_obj "$prefix1-$i"; done
note pgs_after "$BASE_PG"
run_end
scenario_finish
