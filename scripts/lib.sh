#!/usr/bin/env bash
# Cluster helpers for the ReplicaVault pilot. Source this file; do not execute it.
#
# Every helper talks only to the vstart cluster in $CEPH_BUILD. rv_require_cluster
# checks the fsid against the value recorded in notes/environment.md and aborts
# otherwise; call it before anything destructive.

CEPH_BUILD=${CEPH_BUILD:-/data/ceph/build}
RV_EXPECTED_FSID=${RV_EXPECTED_FSID:-224f2f2c-33fd-48ea-9d19-61f5c2df962f}
RV_ROOT=${RV_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
export CEPH_CONF=$CEPH_BUILD/ceph.conf
export LD_LIBRARY_PATH=$CEPH_BUILD/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}

# Wrappers: explicit -c so /etc/ceph/ceph.conf (the node0 cluster) is never used.
# stderr carries only vstart's developer-mode banners unless something fails.
ceph()  { "$CEPH_BUILD/bin/ceph"  -c "$CEPH_CONF" "$@" 2>/dev/null; }
rados() { "$CEPH_BUILD/bin/rados" -c "$CEPH_CONF" "$@" 2>/dev/null; }

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

rv_require_cluster() {
  local fsid
  fsid=$(ceph fsid) || die "cannot reach vstart cluster at $CEPH_CONF"
  [[ $fsid == "$RV_EXPECTED_FSID" ]] || die "fsid $fsid != expected $RV_EXPECTED_FSID; refusing"
}

# Git hash of the Ceph tree the running binaries were built from, with -dirty if modified.
# Before scripts/use-build.sh has been used, the source tree HEAD is the best we know.
rv_ceph_git() {
  local f=$CEPH_BUILD/bin/ceph-osd.build h
  if [[ -s $f ]]; then
    cut -d' ' -f2 "$f"
  else
    h=$(git -C "$CEPH_BUILD/.." rev-parse HEAD)
    git -C "$CEPH_BUILD/.." diff --quiet HEAD -- src || h="$h-dirty"
    echo "$h"
  fi
}

# "vanilla" or "rv" (the OSD build installed by scripts/use-build.sh), or "unknown".
rv_build() {
  local f=$CEPH_BUILD/bin/ceph-osd.build
  if [[ -s $f ]]; then cut -d' ' -f1 "$f"; else echo unknown; fi
}

osd_ids() {
  ceph osd ls
}

# True iff every running ceph-osd was started from the currently installed binary
# (a daemon started before the binary was replaced shows "(deleted)" in /proc).
rv_check_osd_binaries() {
  local n pid exe rc=0
  for n in $(osd_ids); do
    pid=$(osd_pid "$n") || { log "osd.$n not running"; rc=1; continue; }
    exe=$(readlink "/proc/$pid/exe")
    if [[ $exe == *"(deleted)"* ]]; then log "osd.$n runs a replaced binary: $exe"; rc=1; fi
  done
  return $rc
}

# acting_set <pool> <obj> -> space-separated OSD ids, primary first
acting_set() {
  ceph osd map "$1" "$2" -f json | python3 -c 'import json,sys; print(*json.load(sys.stdin)["acting"])'
}

# pg_of <pool> <obj> -> pgid
pg_of() {
  ceph osd map "$1" "$2" -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["pgid"])'
}

_osd_up() {  # _osd_up N -> prints 1 or 0 per the current osdmap
  ceph osd dump -f json | python3 -c "import json,sys; print([o['up'] for o in json.load(sys.stdin)['osds'] if o['osd']==$1][0])"
}

osd_pid() {
  local f=$CEPH_BUILD/out/osd.$1.pid
  [[ -s $f ]] && kill -0 "$(cat "$f")" 2>/dev/null && cat "$f"
}

# kill_osd N [signal]: SIGKILL by default; waits until the MON marks it down.
kill_osd() {
  local n=$1 sig=${2:-KILL} pid i
  pid=$(osd_pid "$n") || die "osd.$n is not running"
  kill -"$sig" "$pid"
  # Wait for both: the MON marking it down (a SIGTERM'd OSD announces this before it
  # exits) and the process being gone (so the store is unlocked for offline tools).
  for i in $(seq 1 120); do
    if [[ $(_osd_up "$n") == 0 ]] && ! kill -0 "$pid" 2>/dev/null; then
      log "osd.$n (pid $pid) down and exited"; return 0
    fi
    sleep 1
  done
  die "osd.$n not down and exited after 120 s"
}

# restart_osd N: start the daemon and wait until the MON marks it up.
restart_osd() {
  local n=$1 i
  if osd_pid "$n" >/dev/null; then die "osd.$n already running"; fi
  (cd "$CEPH_BUILD" && bin/ceph-osd -i "$n" -c "$CEPH_CONF" >/dev/null 2>&1) \
    || die "ceph-osd -i $n failed to start; see $CEPH_BUILD/out/osd.$n.log"
  for i in $(seq 1 180); do
    [[ $(_osd_up "$n") == 1 ]] && { log "osd.$n up (pid $(osd_pid "$n"))"; return 0; }
    sleep 1
  done
  die "osd.$n not marked up after 180 s"
}

# wait_clean [timeout_s]: all PGs active+clean, all OSDs that exist are up, and that
# holds for 3 consecutive polls (the mgr's PG stats lag the osdmap by a few seconds).
# RV_ALLOW_DOWN=1 drops the "all OSDs up" part (an OSD deliberately kept down).
wait_clean() {
  local timeout=${1:-600} start=$SECONDS streak=0
  local unclean='PG_DEGRADED|PG_AVAILABILITY|OSD_DOWN|recovery|backfill'
  [[ -n ${RV_ALLOW_DOWN:-} ]] && unclean='PG_DEGRADED|PG_AVAILABILITY|recovery|backfill'
  while (( SECONDS - start < timeout )); do
    if ceph pg stat -f json | python3 -c '
import json,sys
s=json.load(sys.stdin)["pg_summary"]
st=s["num_pg_by_state"]
ok = len(st)==1 and st[0]["name"]=="active+clean" and st[0]["num"]==s["num_pgs"]
sys.exit(0 if ok else 1)' && ! ceph health detail | grep -qE "$unclean"; then
      (( ++streak >= 3 )) && { log "clean after $((SECONDS - start)) s"; return 0; }
    else
      streak=0
    fi
    sleep 2
  done
  log "not clean after $timeout s: $(ceph pg stat)"
  return 1
}

_pg_deep_stamps() {  # pgid<TAB>last_deep_scrub_stamp for every PG in pool
  ceph pg ls-by-pool "$1" -f json | python3 -c '
import json,sys
for s in json.load(sys.stdin)["pg_stats"]:
    print(s["pgid"], s["last_deep_scrub_stamp"], sep="\t")'
}

# deep_scrub_all <pool> [timeout_s]: request a deep scrub of every PG and wait until
# every PG's last_deep_scrub_stamp has advanced past the value it had before the request.
deep_scrub_all() {
  local pool=$1 timeout=${2:-900} start=$SECONDS
  local -A before
  local pg stamp pending
  while IFS=$'\t' read -r pg stamp; do before[$pg]=$stamp; done < <(_pg_deep_stamps "$pool")
  (( ${#before[@]} > 0 )) || die "no PGs found for pool $pool"
  for pg in "${!before[@]}"; do ceph pg deep-scrub "$pg" >/dev/null; done
  while (( SECONDS - start < timeout )); do
    pending=0
    while IFS=$'\t' read -r pg stamp; do
      [[ -z ${before[$pg]+x} || $stamp > ${before[$pg]} ]] || (( ++pending ))
    done < <(_pg_deep_stamps "$pool")
    (( pending == 0 )) && { log "deep-scrubbed ${#before[@]} PGs in $((SECONDS - start)) s"; return 0; }
    sleep 3
  done
  log "deep scrub incomplete after $timeout s: $pending PGs pending"
  return 1
}

# check_inconsistent <pool>: prints findings; returns 0 iff there are none.
check_inconsistent() {
  local pool=$1 pgs health rc=0
  pgs=$(rados list-inconsistent-pg "$pool")
  if [[ $pgs != "[]" ]]; then
    log "inconsistent PGs in $pool: $pgs"; rc=1
  fi
  health=$(ceph health detail)
  if grep -qE 'OSD_SCRUB_ERRORS|PG_DAMAGED|inconsistent' <<<"$health"; then
    log "health: $health"; rc=1
  fi
  return $rc
}

# sha256 of a file
sha() { sha256sum "$1" | cut -d' ' -f1; }

# get_sha <pool> <obj>: sha256 of the object's content, or "ENOENT"
get_sha() {
  local tmp; tmp=$(mktemp)
  if rados -p "$1" get "$2" "$tmp"; then sha "$tmp"; else echo ENOENT; fi
  rm -f "$tmp"
}

# stat_enoent <pool> <obj>: true iff `rados stat` fails with ENOENT
stat_enoent() {
  local out
  out=$("$CEPH_BUILD/bin/rados" -c "$CEPH_CONF" -p "$1" stat "$2" 2>&1) && return 1
  grep -q 'No such file or directory' <<<"$out"
}
