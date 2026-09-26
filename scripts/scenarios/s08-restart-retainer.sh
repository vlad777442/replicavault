#!/usr/bin/env bash
# Scenario 8: restart of the retaining OSD with vault entries on disk.
# Per run: delete objects in one PG (vaulted on its rank-1 OSD R), stop R (alternating
# SIGKILL and SIGTERM), run BlueStore fsck while it is down, restart it, and check that
# it booted without asserts, that the vault was not deleted or treated as a stray/temp
# collection, and (run_end) that the entries are intact.
source "$(dirname "$0")/common.sh"
RUNS=6
scenario_init s08-restart-retainer "$@"

for run in $(seq 1 "$RUNS"); do
  sig=$([[ $((run % 2)) == 1 ]] && echo KILL || echo TERM)
  run_begin "$run" "{\"signal\": \"$sig\"}"
  seed=$RUN_PREFIX-seed
  put_obj "$seed" 4096
  pg=$(pg_of "$POOL" "$seed")
  read -r -a acting <<<"$(acting_set "$POOL" "$seed")"
  R=${acting[1]}
  note acting "[$(IFS=,; echo "${acting[*]}")]"
  i=0; found=0
  while (( found < 8 && i < 1000 )); do
    name=$RUN_PREFIX-o$i
    if [[ $(pg_of "$POOL" "$name") == "$pg" ]]; then
      put_obj "$name" $(( 200000 + i ))
      (( found % 2 == 0 )) && del_obj "$name"
      found=$((found + 1))
    fi
    i=$((i + 1))
  done
  logsz=$(stat -c %s "$CEPH_BUILD/out/osd.$R.log")
  ceph osd set noout >/dev/null
  kill_osd "$R" "$sig"
  fsck=$("$CEPH_BUILD/bin/ceph-bluestore-tool" fsck --path "$CEPH_BUILD/dev/osd$R" 2>&1 | grep -E 'fsck (success|status)' | tail -1)
  restart_osd "$R"
  ceph osd unset noout >/dev/null
  wait_clean 600 || true
  boot_log=$(tail -c +$((logsz + 1)) "$CEPH_BUILD/out/osd.$R.log")
  asserts=$(grep -cE 'FAILED ceph_assert|Caught signal|ceph_abort' <<<"$boot_log" || true)
  removing=$(grep -cE 'load_pgs .*removing|recursive_remove_collection|clear_temp.*replicavault|removing.*replicavault' <<<"$boot_log" || true)
  fsck_ok=$([[ $fsck == *"fsck success"* ]] && echo true || echo false)
  boot_ok=$([[ $asserts == 0 && $removing == 0 ]] && echo true || echo false)
  note retainer "$R"
  run_end "{\"retainer\": $R, \"fsck\": {\"pass\": $fsck_ok, \"output\": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$fsck")}, \"boot\": {\"pass\": $boot_ok, \"asserts\": $asserts, \"removal_lines\": $removing}}"
  python3 - "$RUNS_FILE" <<'EOF'
import json, sys
path = sys.argv[1]
runs = [json.loads(l) for l in open(path)]
r = runs[-1]
r["pass"] = r["pass"] and r["fsck"]["pass"] and r["boot"]["pass"]
open(path, "w").write("".join(json.dumps(x) + "\n" for x in runs))
EOF
done
scenario_finish
