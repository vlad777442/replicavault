#!/usr/bin/env bash
# Scenario 6: the same object name recreated after deletion. The new object's content
# must be correct and independent of the vault; deleting it again must vault the new
# content separately. Names include a namespace and an object locator, to exercise the
# vault name encoding.
#
# Per run, for each (namespace, locator) variant:
#   put v1; rm; put v2 (different size and content); [read-back checked as live]
#   for half the names: rm again -> second vault entry holding v2
source "$(dirname "$0")/common.sh"
RUNS=5
scenario_init s06-recreate-after-delete "$@"

VARIANTS=("|" "tenant-a|" "|loc-x" "tenant-b|loc-y")
for run in $(seq 1 "$RUNS"); do
  run_begin "$run"
  k=0
  for v in "${VARIANTS[@]}"; do
    ns=${v%%|*} loc=${v#*|}
    for j in 0 1; do
      name=$RUN_PREFIX-v$k-$j
      put_obj "$name" $(( 70000 + 1000 * j )) "$ns" "$loc"
      del_obj "$name" "$ns" "$loc" || die "rm $name"
      put_obj "$name" $(( 150000 + 7 * run + j )) "$ns" "$loc"
      if (( j == 1 )); then del_obj "$name" "$ns" "$loc" || die "rm2 $name"; fi
    done
    k=$((k + 1))
  done
  run_end
done
scenario_finish
