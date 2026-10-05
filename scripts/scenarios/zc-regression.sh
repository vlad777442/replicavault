#!/usr/bin/env bash
# Zero-copy pilot, Phase 5: full regression on the installed build (normally zc).
#   smoke, s01-s12, a01-a05 (default run counts), c01 x30, c03 x10, c04 A x10, c04 B x10.
# Every scenario run: disk scan of every OSD (RV_DISK_SCAN=all) and a regular fsck of
# every OSD; every scenario: a deep fsck of every OSD at the end (ZC_CRITERIA.md, fsck
# rule as amended by Vlad). Stops at the first fsck failure (possible corruption: a
# STOP for Vlad); other failures are recorded and the batch continues.
#   scripts/scenarios/zc-regression.sh [step...]     default: all steps in order
set -uo pipefail
cd "$(dirname "$0")"
export RV_DISK_SCAN=all
steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(smoke s01 s02 s03 s04 s05 s06 s07 s08 s09 s10 s11 s12
                                   a01 a02 a03 a04 a05 c01 c03 c04A c04B)
declare -A rc out
for st in "${steps[@]}"; do
  echo "===== $st ($(date +%T))"
  case $st in
    smoke) ../smoke.sh; rc[$st]=$? ;;
    c01)   ./c01-crash-under-deletes.sh --runs 30; rc[$st]=$? ;;
    c03)   ./c03-retainer-out-during-deletes.sh --runs 10; rc[$st]=$? ;;
    c04A)  ./c04-primary-failure.sh --variant A --runs 10; rc[$st]=$? ;;
    c04B)  ./c04-primary-failure.sh --variant B --runs 10; rc[$st]=$? ;;
    *)     ./"$(ls "$st"-*.sh)"; rc[$st]=$? ;;
  esac
  [[ $st == smoke ]] && continue
  # the newest result file for this step; stop on any fsck failure in it
  f=$(ls -t ../../results/zc/"${st,,}"*-*.json 2>/dev/null | head -1)
  out[$st]=$f
  if [[ -n $f ]] && python3 - "$f" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
bad = [x["run"] for x in r["runs"] if x.get("fsck_all", {}).get("pass") is False]
deep = r.get("batch_deep_fsck", {}).get("pass")
sys.exit(0 if bad or deep is False else 1)
EOF
  then
    echo "===== FSCK FAILURE in $st ($f): STOP"
    break
  fi
done
echo "===== summary ($(date +%T))"
for st in "${steps[@]}"; do
  [[ -n ${rc[$st]+x} ]] || { echo "$st: not run"; continue; }
  echo "$st: $([[ ${rc[$st]} == 0 ]] && echo pass || echo "FAIL (rc=${rc[$st]})") ${out[$st]:-}"
done
