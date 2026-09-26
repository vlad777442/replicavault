#!/usr/bin/env bash
# Scenario 1: primary killed before a delete; the delete lands on the new primary.
# Per run: write a target plus live controls in the same PG, SIGKILL the primary, wait
# for the PG to go active on the survivors, delete the target, then restart the old
# primary (which learns the delete through log recovery).
source "$(dirname "$0")/common.sh"
scenario_init s01-kill-primary-before-delete "$@"

for run in $(seq 1 "$RUNS"); do
  run_begin "$run"
  target=$RUN_PREFIX-target
  put_obj "$target" $(( 8192 * run + 3 ))
  pg=$(pg_of "$POOL" "$target")
  read -r -a acting <<<"$(acting_set "$POOL" "$target")"
  note acting_before "[$(IFS=,; echo "${acting[*]}")]"
  note pg "\"$pg\""
  i=0; found=0
  while (( found < 3 && i < 400 )); do
    name=$RUN_PREFIX-live-$i
    if [[ $(pg_of "$POOL" "$name") == "$pg" ]]; then put_obj "$name" 65536; found=$((found + 1)); fi
    i=$((i + 1))
  done
  primary=${acting[0]}
  kill_osd "$primary" KILL
  wait_pg_active "$pg" || die "PG $pg not active after killing osd.$primary"
  read -r -a acting2 <<<"$(acting_set "$POOL" "$target")"
  note acting_at_delete "[$(IFS=,; echo "${acting2[*]}")]"
  del_obj "$target" || die "delete of $target not acknowledged"
  sleep 2
  restart_osd "$primary"
  note killed "$primary"
  run_end
done
scenario_finish
