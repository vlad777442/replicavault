#!/usr/bin/env bash
# Scenario 7: repeated delete-and-recreate of one object name (20 cycles per run).
# Each cycle writes different content and deletes it; the prototype must leave one
# distinct, intact vault entry per cycle (rvcheck matches each delete to a separate
# entry holding that cycle's bytes). The name ends live with a final put.
source "$(dirname "$0")/common.sh"
RUNS=2
CYCLES=20
scenario_init s07-repeated-delete-recreate "$@"

for run in $(seq 1 "$RUNS"); do
  run_begin "$run" "{\"cycles\": $CYCLES}"
  name=$RUN_PREFIX-hot
  read -r -a acting <<<"$(acting_set "$POOL" "$name")"
  note acting "[$(IFS=,; echo "${acting[*]}")]"
  for c in $(seq 1 "$CYCLES"); do
    put_obj "$name" $(( 10000 + 997 * c ))
    del_obj "$name" || die "rm cycle $c"
  done
  put_obj "$name" 12345
  distinct=$(vault_lines_for "$name" | awk '{print $2}' | sort -u | wc -l)
  note distinct_vault_lines "$distinct"
  run_end "{\"distinct_vault_lines\": $distinct, \"expected\": $CYCLES}"
done
scenario_finish
