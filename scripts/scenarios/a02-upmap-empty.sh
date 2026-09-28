#!/usr/bin/env bash
# a02 — upmap the rank-1 slot to an empty OSD (phase 2, adversarial).
# For a target PG with acting [P, R, N], hold backfill (nobackfill), then
# `ceph osd pg-upmap-items <pg> R E` with E an OSD holding no copy of the PG, wait for
# the PG to peer, delete objects, release backfill, then remove the upmap.
# Requires require_min_compat_client >= luminous (the vstart cluster already has it;
# recorded per run).
source "$(dirname "$0")/common.sh"
RV_RESULTS_SUBDIR=phase2
scenario_init a02-upmap-empty "$@"
trap 'ceph osd unset nobackfill >/dev/null 2>&1; rm -rf "$WORK"' EXIT
compat=$(ceph osd dump | awk '/^require_min_compat_client/{print $2}')

for run in $(seq 1 "$RUNS"); do
  run_begin "$run" "{\"require_min_compat_client\": \"$compat\"}"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  read -r -a acting <<<"$(acting_set "$POOL" "$seed")"
  R=${acting[1]}
  E=$(for n in $(osd_ids); do [[ " ${acting[*]} " == *" $n "* ]] || echo "$n"; done | shuf -n1)
  note pg "\"$pg\""
  note before "\"$(pg_up_acting "$pg")\""
  mapfile -t objs < <(names_in_pg "$RUN_PREFIX-o" "$pg" 12)
  for o in "${objs[@]}"; do put_obj "$o" $(( 65536 + RANDOM )); done

  ceph osd set nobackfill >/dev/null
  ceph osd pg-upmap-items "$pg" "$R" "$E" >/dev/null || die "pg-upmap-items failed"
  for i in $(seq 1 60); do [[ $(pg_state "$pg") == active* ]] && break; sleep 1; done
  sleep 2
  note at_delete "\"$(pg_up_acting "$pg")\""
  note state_at_delete "\"$(pg_state "$pg")\""
  for o in "${objs[@]:0:8}"; do del_obj "$o" || die "rm $o"; done
  ceph osd unset nobackfill >/dev/null
  wait_clean 1200 || die "not clean after backfill"
  ceph osd rm-pg-upmap-items "$pg" >/dev/null
  wait_clean 1200 || die "not clean after removing upmap"
  run_end "{\"upmap\": [$R, $E], \"vault_copies\": $(vault_copies_json "${objs[@]:0:8}")}"
done
scenario_finish
