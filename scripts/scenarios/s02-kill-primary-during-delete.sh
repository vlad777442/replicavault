#!/usr/bin/env bash
# Scenario 2: primary killed during a delete (racy; default 20 runs).
# Per run: write a target plus live controls in the same PG, start `rados rm` in the
# background, SIGKILL the primary after a varying delay, collect the rm exit status
# (the client resends to the new primary), restart the old primary.
# An rm that exits 0 is an acknowledged delete; one that does not is recorded as
# "unknown" and excluded from the resurrection check (the client never learned the
# outcome), but reported.
source "$(dirname "$0")/common.sh"
RUNS=20
scenario_init s02-kill-primary-during-delete "$@"

DELAYS=(0 0.002 0.005 0.01 0.02 0.03 0.05 0.08 0.1 0.2)
for run in $(seq 1 "$RUNS"); do
  delay=${DELAYS[$(( (run - 1) % ${#DELAYS[@]} ))]}
  run_begin "$run" "{\"kill_delay_s\": $delay}"
  target=$RUN_PREFIX-target
  put_obj "$target" $(( 1048576 + run ))
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
  pid=$(osd_pid "$primary")
  ( rados -p "$POOL" rm "$target"; echo $? > "$WORK/rc-$run" ) &
  bg=$!
  sleep "$delay"
  kill -KILL "$pid"
  t0=$SECONDS
  wait "$bg" || true
  rc=$(cat "$WORK/rc-$run")
  note rm_exit "$rc"
  note rm_wait_s "$((SECONDS - t0))"
  record_del_result "$target" "$rc"
  kill_osd_wait_down() { local i; for i in $(seq 1 120); do [[ $(_osd_up "$primary") == 0 ]] && ! kill -0 "$pid" 2>/dev/null && return 0; sleep 1; done; return 1; }
  kill_osd_wait_down || die "osd.$primary not down"
  sleep 1
  restart_osd "$primary"
  note killed "$primary"
  run_end
done
scenario_finish
