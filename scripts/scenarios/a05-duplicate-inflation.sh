#!/usr/bin/env bash
# a05 — duplicate inflation (phase 2, adversarial; B2). No pass/fail of its own:
# reports vault copies per delete and retained bytes per deleted byte; the pilot
# invariants are still checked.
# Per run, for a target PG with acting [P, R, N]: three rounds of
#   SIGKILL R, wait for the PG to go active on [P, N], delete 4 objects, restart R,
#   wait for the PG to be clean
# so every delete is missed by R and later reaches it through recovery.
source "$(dirname "$0")/common.sh"
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
scenario_init a05-duplicate-inflation "$@"
ROUNDS=3
PER_ROUND=4

for run in $(seq 1 "$RUNS"); do
  run_begin "$run" "{\"rounds\": $ROUNDS, \"deletes_per_round\": $PER_ROUND}"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  read -r -a acting <<<"$(acting_set "$POOL" "$seed")"
  R=${acting[1]}
  note pg "\"$pg\""
  note before "\"$(obj_up_acting "$POOL" "$seed")\""
  mapfile -t objs < <(names_in_pg "$RUN_PREFIX-o" "$pg" $(( ROUNDS * PER_ROUND )))
  deleted_bytes=0
  for o in "${objs[@]}"; do sz=$(( 131072 + RANDOM )); put_obj "$o" "$sz"; done
  for r in $(seq 0 $(( ROUNDS - 1 ))); do
    kill_osd "$R" KILL
    wait_pg_active "$pg" || die "PG $pg not active"
    for o in "${objs[@]:$(( r * PER_ROUND )):$PER_ROUND}"; do
      deleted_bytes=$(( deleted_bytes + $(rados -p "$POOL" stat "$o" | sed -E 's/.* size ([0-9]+).*/\1/') ))
      del_obj "$o" || die "rm $o"
    done
    restart_osd "$R"
    wait_clean 600 || die "not clean after restarting osd.$R"
  done
  vc=$(vault_copies_json "${objs[@]}")
  stats=$(python3 -c 'import json,sys
v=json.loads(sys.argv[1]); d=int(sys.argv[2]); c=list(v["copies"].values())
print(json.dumps({"deletes": len(c), "copies_total": sum(c), "copies_per_delete": {str(k): c.count(k) for k in sorted(set(c))},
 "deleted_bytes": d, "vaulted_bytes": v["bytes"], "retained_per_deleted_byte": round(v["bytes"]/d, 3) if d else None}))' "$vc" "$deleted_bytes")
  note inflation "$stats"
  run_end "{\"retainer_killed\": $R, \"inflation\": $stats}"
done
scenario_finish
