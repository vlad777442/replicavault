#!/usr/bin/env bash
# Negative control for the scrub/inconsistency detector used by smoke.sh and the
# scenarios: corrupt one replica of an object offline with ceph-objectstore-tool,
# deep-scrub, and require check_inconsistent to report it. Then repair and clean up.
#
# Usage: scripts/negative-control.sh [pool]
# Writes results/negative-control-<timestamp>.json; exit 0 iff the corruption was detected
# and the cluster was returned to a clean, consistent state.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

POOL=${1:-rvtest}
TS=$(date +%Y%m%dT%H%M%S)
RUN_ID=negative-control-$TS
OUT=$RV_ROOT/results/${RV_RESULTS_SUBDIR:-zc}/$RUN_ID.json   # pilot results/ is frozen
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$(dirname "$OUT")"

rv_require_cluster
CEPH_GIT=$(rv_ceph_git)
wait_clean 300 || die "cluster not clean before start"

obj=negctl-$TS
head -c 65536 /dev/urandom > "$WORK/orig"
rados -p "$POOL" put "$obj" "$WORK/orig"
read -r -a acting <<<"$(acting_set "$POOL" "$obj")"
pg=$(pg_of "$POOL" "$obj")
victim=${acting[2]}            # corrupt a non-primary replica
log "object $obj pg $pg acting ${acting[*]}; corrupting replica on osd.$victim"

# Keep the cluster from rebalancing while the OSD is down for offline surgery.
ceph osd set noout >/dev/null
trap 'ceph osd unset noout >/dev/null; rm -rf "$WORK"' EXIT
kill_osd "$victim" TERM
head -c 65536 /dev/urandom > "$WORK/bad"
"$CEPH_BUILD/bin/ceph-objectstore-tool" --data-path "$CEPH_BUILD/dev/osd$victim" \
  --pgid "$pg" "$obj" set-bytes "$WORK/bad" >/dev/null 2>&1 \
  || { restart_osd "$victim"; die "set-bytes failed"; }
restart_osd "$victim"
ceph osd unset noout >/dev/null
wait_clean 300 || die "not clean after restart"

detected=false
deep_scrub_all "$POOL" 900 || die "deep scrub timeout"
if ! check_inconsistent "$POOL" 2>"$WORK/findings"; then detected=true; fi
findings=$(cat "$WORK/findings")
inconsistent_pgs=$(rados list-inconsistent-pg "$POOL")
log "detected=$detected inconsistent_pgs=$inconsistent_pgs"

# Repair from the authoritative copies, re-verify, then remove the test object.
ceph pg repair "$pg" >/dev/null
sleep 5
wait_clean 300 || true
deep_scrub_all "$POOL" 900 || true
restored=false
check_inconsistent "$POOL" && restored=true
[[ $(get_sha "$POOL" "$obj") == $(sha "$WORK/orig") ]] || restored=false
rados -p "$POOL" rm "$obj"

result=$([[ $detected == true && $restored == true ]] && echo pass || echo fail)
python3 - "$OUT" "$findings" <<EOF
import json, sys
json.dump({
  "run_id": "$RUN_ID", "timestamp": "$TS", "ceph_git": "$CEPH_GIT",
  "command": "scripts/negative-control.sh $POOL",
  "object": "$obj", "pg": "$pg", "acting": [$(IFS=,; echo "${acting[*]}")],
  "corrupted_osd": $victim,
  "detected": $([[ $detected == true ]] && echo True || echo False),
  "inconsistent_pgs": $inconsistent_pgs,
  "findings": sys.argv[2],
  "repaired_and_clean": $([[ $restored == true ]] && echo True || echo False),
  "result": "$result",
}, open(sys.argv[1], "w"), indent=2)
EOF
log "result: $result -> $OUT"
[[ $result == pass ]]
