#!/usr/bin/env bash
# Scenario 5: deep-scrub every PG with vault entries present.
# Per run: write objects spread over all PGs, delete two thirds of them (vault entries
# on many OSDs and PGs), then run_end deep-scrubs every PG and checks the invariants.
# A second deep scrub after the vault inspection (which restarts the retaining OSDs)
# must also be clean.
source "$(dirname "$0")/common.sh"
RUNS=3
scenario_init s05-deep-scrub-with-vault "$@"

for run in $(seq 1 "$RUNS"); do
  run_begin "$run" '{"objects": 96, "deleted": 64}'
  for i in $(seq 0 95); do put_obj "$RUN_PREFIX-$i" $(( (i % 8) * 131072 + i )); done
  for i in $(seq 0 95); do (( i % 3 == 0 )) || del_obj "$RUN_PREFIX-$i"; done
  run_end
  # second scrub after the OSD restarts done by vault inspection
  second=true
  deep_scrub_all "$POOL" 1200 || second=false
  check_inconsistent "$POOL" || second=false
  log "second deep scrub clean: $second"
  python3 - "$RUNS_FILE" "$second" <<'EOF'
import json, sys
path, ok = sys.argv[1], sys.argv[2] == "true"
runs = [json.loads(l) for l in open(path)]
runs[-1]["second_deep_scrub_clean"] = ok
runs[-1]["pass"] = runs[-1]["pass"] and ok
open(path, "w").write("".join(json.dumps(r) + "\n" for r in runs))
EOF
done
scenario_finish
