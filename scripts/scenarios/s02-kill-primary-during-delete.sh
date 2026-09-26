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

# rados needs ~150-250 ms to start and connect before it sends the op, so the kills
# are concentrated there; the first vanilla run showed delays <= 0.1 s always kill
# before the op is sent (rm then waits ~10 s and lands on the new primary).
DELAYS=(0.05 0.12 0.15 0.18 0.2 0.22 0.25 0.28 0.3 0.35 0.4 0.5)
for run in $(seq 1 "$RUNS"); do
  delay=${DELAYS[$(( (run - 1) % ${#DELAYS[@]} ))]}
  run_begin "$run" "{\"kill_delay_s\": $delay}"
  target=$RUN_PREFIX-target
  put_obj "$target" $(( 1048576 + run ))
  pg=$(pg_of "$POOL" "$target")
  read -r -a acting <<<"$(acting_set "$POOL" "$target")"
  note acting_before "[$(IFS=,; echo "${acting[*]}")]"
  note pg "\"$pg\""
  for name in $(names_in_pg "$RUN_PREFIX-live" "$pg" 3); do put_obj "$name" 65536; done
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
