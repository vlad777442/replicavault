#!/usr/bin/env bash
# c04 — primary failure during deletes (phase 2, finding 2 under F1).
# Per run, for a target PG with primary P: write 16 objects (4 KiB to 8 MiB), issue
# aio_remove for all of them and SIGKILL P after a random delay. Keep P down and mark
# it out, so its PGs remap and recover on the other OSDs; wait until every PG is
# active+clean without P. Then:
#   --variant A  restart P (still out): its PG copies are strays and get purged
#                (PeeringState::purge_strays -> PG::do_delete_work); wait until P holds
#                no PGs, then mark it in and wait clean.
#   --variant B  never restart P during the check. Its vault entries are inaccessible,
#                so invariant 3 only counts copies on surviving OSDs (P is excluded from
#                the disk scan and its log lines are ignored). P is restarted and marked
#                in only after the check, to restore the cluster for the next run.
# For each acknowledged delete, the result records which OSD(s) hold an intact vault
# copy and by which path (repop, recovery, primary, fallback, or unlogged).
# The vault check scans every surviving OSD's disk (RV_DISK_SCAN=all), not just log
# lines, because a kill between a vault txc's kv commit and its on_commit callback
# leaves a durable entry without a log line.
source "$(dirname "$0")/common.sh"
RUNS=20
RV_RESULTS_SUBDIR=${RV_RESULTS_SUBDIR:-zc}
export RV_DISK_SCAN=all
VARIANT=A
# --max-delay S: kill delay uniform in [0, S] (default 1.5); see c01. With the
# zero-copy rename the default never kills P mid-delete (zc c04 A/B x10: 0 of 320).
MAX_DELAY=1.5
SUFFIX=""
args=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --variant) VARIANT=$2; shift 2 ;;
    --max-delay) MAX_DELAY=$2; SUFFIX=s; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
[[ $VARIANT == A || $VARIANT == B ]] || die "--variant A|B"
scenario_init "c04${VARIANT,,}${SUFFIX}-primary-failure" "${args[@]}"
SIZES=(4096 65536 1048576 4194304 8388608)
OUT_OSD=""
restore_out_osd() {
  [[ -n $OUT_OSD ]] || return 0
  osd_pid "$OUT_OSD" >/dev/null || restart_osd "$OUT_OSD"
  ceph osd in "$OUT_OSD" >/dev/null 2>&1
  OUT_OSD=""
}
trap 'restore_out_osd; rm -rf "$WORK"' EXIT

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
osd_pg_count() {
  ceph tell "osd.$1" status -f json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_pgs"])' 2>/dev/null || echo down
}

for run in $(seq 1 "$RUNS"); do
  delay=$(python3 -c "import random,sys; print(round(random.uniform(0.0, float(sys.argv[1])), 4))" "$MAX_DELAY")
  run_begin "$run" "{\"variant\": \"$VARIANT\", \"kill_delay_s\": $delay}"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  read -r P R <<<"$(ceph osd map "$POOL" "$seed" -f json | python3 -c 'import json,sys
d=json.load(sys.stdin); p=d["acting_primary"]; o=[p]+[a for a in d["acting"] if a!=p]; print(p, o[1] if len(o)>1 else p)')"
  note pg "\"$pg\""
  note acting_before "\"$(obj_up_acting "$POOL" "$seed")\""
  note primary "$P"
  note retainer "$R"
  mapfile -t objs < <(names_in_pg "$RUN_PREFIX-o" "$pg" 16)
  printf '%s\n' "${objs[@]}" > "$WORK/objs-$run"
  for o in "${objs[@]}"; do put_obj "$o" "${SIZES[$(( RANDOM % ${#SIZES[@]} ))]}"; done

  pid=$(osd_pid "$P")
  OUT_OSD=$P
  aio=$(python3 "$SCEN_DIR/aio_ops.py" delete-kill "$POOL" "$WORK/objs-$run" "$delay" "$CEPH_BUILD/out/osd.$P.pid")
  for i in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  python3 - "$aio" "$RUN_STATE" "$POOL" <<'EOF'
import json, sys
aio, state, pool = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
with open(state, "a") as f:
    for n, r in aio["objects"].items():
        f.write(json.dumps({"op": "del" if r["rc"] == 0 else "unknown", "pool": pool, "ns": "", "loc": "",
                            "name": n, "acked": r["rc"] == 0}) + "\n")
EOF
  ceph osd out "$P" >/dev/null
  wait_pgs_clean 1800 || die "PGs not clean without osd.$P"
  note acting_without_p "\"$(obj_up_acting "$POOL" "$seed")\""
  if [[ $VARIANT == A ]]; then
    restart_osd "$P"
    t0=$SECONDS
    for i in $(seq 1 300); do [[ $(osd_pg_count "$P") == 0 ]] && break; sleep 2; done
    note stray_removal "{\"pgs_on_p_after\": \"$(osd_pg_count "$P")\", \"wait_s\": $((SECONDS - t0))}"
    restore_out_osd
    wait_clean 1800 || true
    run_end "{\"crash\": $(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); o=a["objects"].values(); print(json.dumps({"kill_at_s": a["kill_at"], "acked": sum(r["rc"]==0 for r in o), "acked_after_kill": sum(r["rc"]==0 and not r["done_before_kill"] for r in o), "not_acked": sum(r["rc"]!=0 for r in o), "done_s": sorted(r["done_s"] for r in o if r["done_s"] is not None)}))' "$aio"), \"failed_osd\": $P}"
  else
    # Variant B: check while P is down and out; exclude P's log lines from the
    # offsets (it stays down, so vault-inspect cannot open its store either).
    python3 - "$WORK/offsets-$run.json" "$P" <<'EOF'
import json, sys
p, osd = sys.argv[1], sys.argv[2]
o = json.load(open(p)); o.pop(osd, None); json.dump(o, open(p, "w"))
EOF
    RV_ALLOW_DOWN=1 RV_EXCLUDE_OSD=$P run_end "{\"crash\": $(python3 -c 'import json,sys; a=json.loads(sys.argv[1]); o=a["objects"].values(); print(json.dumps({"kill_at_s": a["kill_at"], "acked": sum(r["rc"]==0 for r in o), "acked_after_kill": sum(r["rc"]==0 and not r["done_before_kill"] for r in o), "not_acked": sum(r["rc"]!=0 for r in o), "done_s": sorted(r["done_s"] for r in o if r["done_s"] is not None)}))' "$aio"), \"failed_osd\": $P, \"failed_osd_never_returned\": true}"
    restore_out_osd
    wait_clean 1800 || true
  fi
done
scenario_finish
