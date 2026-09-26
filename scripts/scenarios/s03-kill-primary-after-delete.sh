#!/usr/bin/env bash
# Scenario 3: primary killed after a delete, then restarted.
# Per run: write a target object plus live controls in the same PG, delete the target
# (acknowledged), SIGKILL the PG's primary, keep it down a varying time, restart it.
source "$(dirname "$0")/common.sh"
scenario_init s03-kill-primary-after-delete "$@"

DOWN_TIMES=(0 1 2 3 5 8 0 1 2 3 5 8)
for run in $(seq 1 "$RUNS"); do
  down=${DOWN_TIMES[$(( (run - 1) % ${#DOWN_TIMES[@]} ))]}
  run_begin "$run" "{\"down_s\": $down}"
  target=$RUN_PREFIX-target
  put_obj "$target" $(( 4096 * run + 1 ))
  pg=$(pg_of "$POOL" "$target")
  read -r -a acting <<<"$(acting_set "$POOL" "$target")"
  note acting_before "[$(IFS=,; echo "${acting[*]}")]"
  note pg "\"$pg\""
  # live controls: first three names landing in the same PG
  i=0; found=0
  while (( found < 3 && i < 400 )); do
    name=$RUN_PREFIX-live-$i
    if [[ $(pg_of "$POOL" "$name") == "$pg" ]]; then put_obj "$name" 65536; found=$((found + 1)); fi
    i=$((i + 1))
  done
  del_obj "$target" || die "delete of $target not acknowledged"
  primary=${acting[0]}
  kill_osd "$primary" KILL
  sleep "$down"
  restart_osd "$primary"
  note killed "$primary"
  run_end
done
scenario_finish
