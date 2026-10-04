#!/usr/bin/env bash
# a01 — rank 1 marked out (phase 2, adversarial).
# For a target PG with acting [P, R, N], hold backfill (`ceph osd set nobackfill`) so
# the window stays open, `ceph osd out R`, wait for the PG to peer (a new OSD X joins
# the up set as a backfill target that has received nothing), delete objects, then
# release backfill and bring R back in.
#
# Window control: the squid OSDs run mclock_scheduler, which overrides
# osd_max_backfills / osd_recovery_sleep unless osd_mclock_override_recovery_settings
# is set; the nobackfill flag holds the window deterministically instead.
# Records the up and acting sets at delete time, i.e. who the rule's rank 1 is.
source "$(dirname "$0")/common.sh"
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
scenario_init a01-rank1-out "$@"
trap 'ceph osd unset nobackfill >/dev/null 2>&1; ceph osd unset noout >/dev/null 2>&1; rm -rf "$WORK"' EXIT

for run in $(seq 1 "$RUNS"); do
  run_begin "$run"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  read -r -a acting <<<"$(acting_set "$POOL" "$seed")"
  R=${acting[1]}
  note pg "\"$pg\""
  note before "\"$(obj_up_acting "$POOL" "$seed")\""
  mapfile -t objs < <(names_in_pg "$RUN_PREFIX-o" "$pg" 12)
  for o in "${objs[@]}"; do put_obj "$o" $(( 65536 + RANDOM )); done

  ceph osd set nobackfill >/dev/null
  ceph osd out "$R" >/dev/null
  for i in $(seq 1 60); do [[ $(pg_state "$pg") == active* ]] && break; sleep 1; done
  sleep 2
  note at_delete "\"$(obj_up_acting "$POOL" "$seed")\""
  note state_at_delete "\"$(pg_state "$pg")\""
  for o in "${objs[@]:0:8}"; do del_obj "$o" || die "rm $o"; done
  ceph osd unset nobackfill >/dev/null
  wait_clean 1200 || die "not clean after backfill"
  ceph osd in "$R" >/dev/null
  wait_clean 1200 || die "not clean after in osd.$R"
  run_end "{\"out_osd\": $R, \"vault_copies\": $(vault_copies_json "${objs[@]:0:8}")}"
done
scenario_finish
