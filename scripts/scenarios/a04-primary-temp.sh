#!/usr/bin/env bash
# a04 — primary-temp (phase 2, adversarial). `ceph osd primary-temp <pg> <osd>` makes
# an OSD other than acting[0] the primary without reordering the acting set
# (OSDMap::_get_temp_osds, src/osd/OSDMap.cc:2870-2873). Runs alternate:
#   odd runs:  primary := acting[1]  -> the rule's rank 1 is the primary itself
#   even runs: primary := acting[2]  -> rank 1 is still a replica
# Delete objects, clear the primary-temp (-1), wait clean. Records who vaulted.
# primary-temp needs require_min_compat_client >= firefly (src/mon/OSDMonitor.cc).
source "$(dirname "$0")/common.sh"
RV_RESULTS_SUBDIR=phase2
scenario_init a04-primary-temp "$@"

for run in $(seq 1 "$RUNS"); do
  slot=$(( run % 2 == 1 ? 1 : 2 ))
  run_begin "$run" "{\"primary_temp_slot\": $slot}"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  read -r -a acting <<<"$(acting_set "$POOL" "$seed")"
  target=${acting[$slot]}
  note pg "\"$pg\""
  note before "\"$(pg_up_acting "$pg")\""
  mapfile -t objs < <(names_in_pg "$RUN_PREFIX-o" "$pg" 8)
  for o in "${objs[@]}"; do put_obj "$o" $(( 50000 + RANDOM )); done
  ceph osd primary-temp "$pg" "$target" >/dev/null || die "primary-temp refused"
  for i in $(seq 1 60); do
    [[ $(pg_up_acting "$pg") == *"primary=$target"* && $(pg_state "$pg") == active* ]] && break
    sleep 1
  done
  note at_delete "\"$(pg_up_acting "$pg")\""
  for o in "${objs[@]:0:5}"; do del_obj "$o" || die "rm $o"; done
  ceph osd primary-temp "$pg" -1 >/dev/null
  wait_clean 900 || die "not clean after clearing primary-temp"
  run_end "{\"primary_temp\": $target, \"vault_copies\": $(vault_copies_json "${objs[@]:0:5}")}"
done
scenario_finish
