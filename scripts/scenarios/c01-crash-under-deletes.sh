#!/usr/bin/env bash
# c01 — crash under deletes (phase 2, B3). At least 100 runs.
# Per run, for a target PG: write 16 objects of 4 KiB to 8 MiB, find the retainer R
# (retainer rule: element 1 of the acting set, primary first), issue aio_remove for
# all 16 at once and SIGKILL R after a random delay, wait for every remove, run
# `ceph-bluestore-tool fsck` on R while it is down, restart R, wait clean, then
# check invariants 1-4 (run_end). Removes the client never saw acknowledged are
# recorded as "unknown" and excluded from invariants 1 and 3, but reported.
#
# Submission modes, set on R through `ceph config set osd.R` for the run:
#   default     BlueStore batches kv submissions in its kv_sync thread
#   sync        bluestore_sync_submit_transaction=true: each txc is applied to
#               RocksDB in the queuing thread (src/os/bluestore/BlueStore.cc:14192-14213),
#               so the vault copy and the remove are separate submissions
#   sync+rand   sync plus bluestore_debug_randomize_serial_transaction=2, which
#               randomly forces txcs through the kv thread instead (same lines)
# No BlueStore option stops between kv submissions; these two change how they are
# grouped (src/common/options/global.yaml.in:5180, :5354).
source "$(dirname "$0")/common.sh"
RUNS=100
RV_RESULTS_SUBDIR=phase2
scenario_init c01-crash-under-deletes "$@"
SIZES=(4096 65536 1048576 4194304 8388608)
R_CFG=""
clear_cfg() {
  if [[ -n $R_CFG ]]; then
    ceph config rm "osd.$R_CFG" bluestore_sync_submit_transaction >/dev/null 2>&1 || true
    ceph config rm "osd.$R_CFG" bluestore_debug_randomize_serial_transaction >/dev/null 2>&1 || true
    R_CFG=""
  fi
}
trap 'clear_cfg; ceph osd unset noout >/dev/null 2>&1; rm -rf "$WORK"' EXIT

for run in $(seq 1 "$RUNS"); do
  if (( run <= RUNS * 6 / 10 )); then mode=default
  elif (( run <= RUNS * 8 / 10 )); then mode=sync
  else mode=sync+rand; fi
  delay=$(python3 -c "import random; print(round(random.uniform(0.0, 1.5), 3))")
  run_begin "$run" "{\"submit_mode\": \"$mode\", \"kill_delay_s\": $delay}"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  R=$(ceph osd map "$POOL" "$seed" -f json | python3 -c 'import json,sys
d=json.load(sys.stdin); p=d["acting_primary"]; o=[p]+[a for a in d["acting"] if a!=p]; print(o[1] if len(o)>1 else p)')
  note pg "\"$pg\""
  note acting "\"$(obj_up_acting "$POOL" "$seed")\""
  note retainer "$R"
  mapfile -t objs < <(names_in_pg "$RUN_PREFIX-o" "$pg" 16)
  printf '%s\n' "${objs[@]}" > "$WORK/objs-$run"
  for o in "${objs[@]}"; do put_obj "$o" "${SIZES[$(( RANDOM % ${#SIZES[@]} ))]}"; done

  if [[ $mode != default ]]; then
    R_CFG=$R
    ceph config set "osd.$R" bluestore_sync_submit_transaction true >/dev/null
    [[ $mode == sync+rand ]] && ceph config set "osd.$R" bluestore_debug_randomize_serial_transaction 2 >/dev/null
  fi
  ceph osd set noout >/dev/null
  pid=$(osd_pid "$R")
  aio=$(python3 "$SCEN_DIR/aio_ops.py" delete-kill "$POOL" "$WORK/objs-$run" "$delay" "$CEPH_BUILD/out/osd.$R.pid")
  for i in $(seq 1 60); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
  # record client outcomes: acknowledged (rc 0) or unknown
  python3 - "$aio" "$RUN_STATE" "$POOL" <<'EOF'
import json, sys
aio, state, pool = json.loads(sys.argv[1]), sys.argv[2], sys.argv[3]
with open(state, "a") as f:
    for n, r in aio["objects"].items():
        op = "del" if r["rc"] == 0 else "unknown"
        f.write(json.dumps({"op": op, "pool": pool, "ns": "", "loc": "", "name": n, "acked": r["rc"] == 0}) + "\n")
EOF
  fsck=$("$CEPH_BUILD/bin/ceph-bluestore-tool" fsck --path "$CEPH_BUILD/dev/osd$R" 2>&1 | grep -E 'fsck (success|status)' | tail -1)
  clear_cfg
  restart_osd "$R"
  ceph osd unset noout >/dev/null
  wait_clean 900 || true
  summary=$(python3 - "$aio" "$fsck" <<'EOF'
import json, sys
aio, fsck = json.loads(sys.argv[1]), sys.argv[2]
o = aio["objects"].values()
print(json.dumps({
  "fsck": {"pass": "fsck success" in fsck, "output": fsck},
  "kill_at_s": aio["kill_at"],
  "acked": sum(r["rc"] == 0 for r in o),
  "acked_before_kill": sum(r["rc"] == 0 and r["done_before_kill"] for r in o),
  "acked_after_kill": sum(r["rc"] == 0 and not r["done_before_kill"] for r in o),
  "not_acked": [{"rc": r["rc"]} for r in o if r["rc"] != 0],
}))
EOF
)
  note outcome "$summary"
  run_end "{\"crash\": $summary, \"vault_copies\": $(vault_copies_json "${objs[@]}")}"
  python3 - "$RUNS_FILE" <<'EOF'
import json, sys
path = sys.argv[1]
runs = [json.loads(l) for l in open(path)]
r = runs[-1]
r["pass"] = r["pass"] and r["crash"]["fsck"]["pass"]
open(path, "w").write("".join(json.dumps(x) + "\n" for x in runs))
EOF
done
scenario_finish
