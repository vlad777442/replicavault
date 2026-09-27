#!/usr/bin/env bash
# Run scenarios in order on the currently installed build (see scripts/use-build.sh).
#   scripts/scenarios/run-all.sh [s01 s03 ...]     default: all eleven
# Each scenario writes its own results/<scenario>-<ts>.json; this prints a summary.
set -uo pipefail
cd "$(dirname "$0")"
want=("$@")
[[ ${#want[@]} -gt 0 ]] || want=(s01 s02 s03 s04 s05 s06 s07 s08 s09 s10 s11 s12)
declare -A rc
for s in "${want[@]}"; do
  script=$(ls "$s"-*.sh)
  echo "===== $script ($(date +%T))"
  ./"$script"
  rc[$s]=$?
done
echo "===== summary"
for s in "${want[@]}"; do echo "$s: $([[ ${rc[$s]} == 0 ]] && echo pass || echo "FAIL (rc=${rc[$s]})")"; done
