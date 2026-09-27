#!/usr/bin/env bash
# Scenario 12 (added in Phase 5; not in the proposal's list): the rank-1 OSD misses a
# delete and learns it later through log recovery, which exercises the prototype's
# recovery-path hook (PrimaryLogPG::remove_missing_object, path=recovery).
#
# Per run: write a target plus live controls in one PG (acting [P, R, N]); SIGKILL R;
# wait for the PG to go active on [P, N] (N is now rank 1 and vaults through repop);
# delete the target; restart R. When R rejoins at rank 1 it applies the missed delete
# through recovery and, on the prototype, vaults it again (expected: two vault lines,
# one path=repop on N, one path=recovery on R).
source "$(dirname "$0")/common.sh"
scenario_init s12-retainer-misses-delete "$@"

for run in $(seq 1 "$RUNS"); do
  run_begin "$run"
  target=$RUN_PREFIX-target
  put_obj "$target" $(( 16384 * run + 5 ))
  pg=$(pg_of "$POOL" "$target")
  read -r -a acting <<<"$(acting_set "$POOL" "$target")"
  note acting_before "[$(IFS=,; echo "${acting[*]}")]"
  note pg "\"$pg\""
  for name in $(names_in_pg "$RUN_PREFIX-live" "$pg" 3); do put_obj "$name" 65536; done
  R=${acting[1]}
  kill_osd "$R" KILL
  wait_pg_active "$pg" || die "PG $pg not active after killing osd.$R"
  note acting_at_delete "[$(IFS=,; acting_set "$POOL" "$target" | tr ' ' ',')]"
  del_obj "$target" || die "delete of $target not acknowledged"
  sleep 2
  restart_osd "$R"
  wait_clean 600 || true
  paths=$(vault_lines_for "$target" | while read -r o v; do grep -h "vname=$v" "$CEPH_BUILD/out/osd.$o.log" | sed -E 's/.* osd=([0-9]+) path=([a-z]+) .*/\1:\2/'; done | sort -u | tr '\n' ' ')
  note vault_paths "\"$paths\""
  recovery_seen=$([[ $paths == *":recovery"* ]] && echo true || echo false)
  [[ $MODE == rv ]] || recovery_seen=null
  run_end "{\"retainer_killed\": $R, \"recovery_path_vaulted\": {\"pass\": $recovery_seen, \"paths\": \"$paths\"}}"
  python3 - "$RUNS_FILE" <<'EOF'
import json, sys
path = sys.argv[1]
runs = [json.loads(l) for l in open(path)]
r = runs[-1]
r["pass"] = r["pass"] and r["recovery_path_vaulted"]["pass"] in (True, None)
open(path, "w").write("".join(json.dumps(x) + "\n" for x in runs))
EOF
done
scenario_finish
