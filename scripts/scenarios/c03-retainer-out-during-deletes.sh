#!/usr/bin/env bash
# c03 — retainer lost from the acting set during deletes (phase 2, finding 2).
# Per run, for a target PG with retainer R: write 16 objects (4 KiB to 8 MiB), issue
# aio_remove for all of them and SIGKILL R after a random delay (as in c01). Keep R
# down and mark it out, so its PGs remap and recover on the other OSDs; wait until
# every PG is active+clean without R. Then restart R (still out): its PG copies are
# strays, which the primaries purge (PeeringState::purge_strays -> MOSDPGRemove ->
# PG::do_delete_work, which removes every object directly, not through
# remove_missing_object). Wait until R holds no PGs, mark R back in, wait clean, and
# check invariants 1-4: does every acknowledged delete still have an intact vault
# copy anywhere?
source "$(dirname "$0")/common.sh"
RUNS=20
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
# --max-delay S: kill delay uniform in [0, S] (default 1.5); see c01. With the
# zero-copy rename the default never kills R mid-delete (zc c03 x10: 0 of 160).
MAX_DELAY=1.5
NAME=c03-retainer-out-during-deletes
args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --max-delay) MAX_DELAY=$2; NAME=c03s-retainer-out-during-deletes; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
scenario_init "$NAME" "${args[@]}"
SIZES=(4096 65536 1048576 4194304 8388608)
OUT_OSD=""
trap '[[ -n $OUT_OSD ]] && { osd_pid "$OUT_OSD" >/dev/null || restart_osd "$OUT_OSD"; ceph osd in "$OUT_OSD" >/dev/null 2>&1; }; rm -rf "$WORK"' EXIT

# PG states only: R is deliberately down, which wait_clean would treat as unclean
wait_pgs_clean() {
  local timeout=${1:-900} start=$SECONDS streak=0
  while (( SECONDS - start < timeout )); do
    if ceph pg stat -f json | python3 -c '
import json,sys
s=json.load(sys.stdin)["pg_summary"]; st=s["num_pg_by_state"]
sys.exit(0 if len(st)==1 and st[0]["name"]=="active+clean" and st[0]["num"]==s["num_pgs"] else 1)'; then
      (( ++streak >= 3 )) && { log "PGs clean after $((SECONDS - start)) s"; return 0; }
    else streak=0; fi
    sleep 2
  done
  return 1
}

osd_pg_count() {  # PGs loaded on OSD $1, strays included (the OSD's own `status`), or "down"
  ceph tell "osd.$1" status -f json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_pgs"])' 2>/dev/null || echo down
}

for run in $(seq 1 "$RUNS"); do
  delay=$(python3 -c "import random,sys; print(round(random.uniform(0.0, float(sys.argv[1])), 4))" "$MAX_DELAY")
  run_begin "$run" "{\"kill_delay_s\": $delay}"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  R=$(ceph osd map "$POOL" "$seed" -f json | python3 -c 'import json,sys
d=json.load(sys.stdin); p=d["acting_primary"]; o=[p]+[a for a in d["acting"] if a!=p]; print(o[1] if len(o)>1 else p)')
  note pg "\"$pg\""
  note acting_before "\"$(obj_up_acting "$POOL" "$seed")\""
  note retainer "$R"
  mapfile -t objs < <(names_in_pg "$RUN_PREFIX-o" "$pg" 16)
  printf '%s\n' "${objs[@]}" > "$WORK/objs-$run"
  for o in "${objs[@]}"; do put_obj "$o" "${SIZES[$(( RANDOM % ${#SIZES[@]} ))]}"; done

  pid=$(osd_pid "$R")
  OUT_OSD=$R
  aio=$(python3 "$SCEN_DIR/aio_ops.py" delete-kill "$POOL" "$WORK/objs-$run" "$delay" "$CEPH_BUILD/out/osd.$R.pid")
  for i in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  python3 - "$aio" "$RUN_STATE" "$POOL" <<'EOF'
import json, sys
aio, state, pool = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
with open(state, "a") as f:
    for n, r in aio["objects"].items():
        f.write(json.dumps({"op": "del" if r["rc"] == 0 else "unknown", "pool": pool, "ns": "", "loc": "",
                            "name": n, "acked": r["rc"] == 0}) + "\n")
EOF
  ceph osd out "$R" >/dev/null
  wait_pgs_clean 1800 || die "PGs not clean without osd.$R"
  note acting_without_r "\"$(obj_up_acting "$POOL" "$seed")\""
  pgs_before_restart=$(osd_pg_count "$R")
  restart_osd "$R"
  t0=$SECONDS
  for i in $(seq 1 300); do [[ $(osd_pg_count "$R") == 0 ]] && break; sleep 2; done
  pgs_after=$(osd_pg_count "$R")
  note stray_removal "{\"pgs_on_r_before_restart\": \"$pgs_before_restart\", \"pgs_on_r_after\": \"$pgs_after\", \"wait_s\": $((SECONDS - t0))}"
  ceph osd in "$R" >/dev/null
  OUT_OSD=""
  wait_clean 1800 || true
  summary=$(python3 - "$aio" "$pgs_after" <<'EOF'
import json, sys
aio = json.loads(sys.argv[1]); o = aio["objects"].values()
print(json.dumps({"kill_at_s": aio["kill_at"], "acked": sum(r["rc"] == 0 for r in o),
                  "acked_after_kill": sum(r["rc"] == 0 and not r["done_before_kill"] for r in o),
                  "not_acked": sum(r["rc"] != 0 for r in o), "strays_removed": sys.argv[2] == "0",
                  "done_s": sorted(r["done_s"] for r in o if r["done_s"] is not None)}))
EOF
)
  note outcome "$summary"
  run_end "{\"crash\": $summary, \"vault_copies\": $(vault_copies_json "${objs[@]}")}"
done
scenario_finish
