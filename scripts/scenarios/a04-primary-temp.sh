#!/usr/bin/env bash
# a04 — primary-temp (phase 2, adversarial). `ceph osd primary-temp <pg> <osd>` makes
# an OSD other than acting[0] the primary without reordering the acting set
# (OSDMap::_get_temp_osds, src/osd/OSDMap.cc:2870-2873). Runs alternate:
#   odd runs:  primary := acting[1]  -> the rule's rank 1 is the primary itself
#   even runs: primary := acting[2]  -> rank 1 is still a replica
# Delete objects, clear the primary-temp (`ceph osd rm-primary-temp`), wait clean.
# Records who vaulted.
# primary-temp needs require_min_compat_client >= firefly (src/mon/OSDMonitor.cc).
source "$(dirname "$0")/common.sh"
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
scenario_init a04-primary-temp "$@"
PT_PG=""
trap '[[ -n $PT_PG ]] && ceph osd rm-primary-temp "$PT_PG" >/dev/null 2>&1; rm -rf "$WORK"' EXIT

for run in $(seq 1 "$RUNS"); do
  slot=$(( run % 2 == 1 ? 1 : 2 ))
  run_begin "$run" "{\"primary_temp_slot\": $slot}"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  read -r -a acting <<<"$(acting_set "$POOL" "$seed")"
  target=${acting[$slot]}
  note pg "\"$pg\""
  note before "\"$(obj_up_acting "$POOL" "$seed")\""
  mapfile -t objs < <(names_in_pg "$RUN_PREFIX-o" "$pg" 8)
  for o in "${objs[@]}"; do put_obj "$o" $(( 50000 + RANDOM )); done
  PT_PG=$pg
  ceph osd primary-temp "$pg" "$target" >/dev/null || die "primary-temp refused"
  for i in $(seq 1 60); do
    [[ $(obj_up_acting "$POOL" "$seed") == *"primary=$target"* && $(pg_state "$pg") == active* ]] && break
    sleep 1
  done
  note at_delete "\"$(obj_up_acting "$POOL" "$seed")\""
  for o in "${objs[@]:0:5}"; do del_obj "$o" || die "rm $o"; done
  ceph osd rm-primary-temp "$pg" >/dev/null; PT_PG=""
  wait_clean 900 || die "not clean after clearing primary-temp"
  run_end "{\"primary_temp\": $target, \"vault_copies\": $(vault_copies_json "${objs[@]:0:5}")}"
done
scenario_finish
