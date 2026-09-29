#!/usr/bin/env bash
# Switch every OSD of the vstart cluster to the vanilla, pilot (rv) or phase 2 (p2) ceph-osd.
#
#   scripts/use-build.sh vanilla|rv|p2   (pilot = rv, phase 2 = p2)
#
# Installs bin/ceph-osd.<build> as bin/ceph-osd (by rename, so running daemons are
# unaffected until restarted), records the build in bin/ceph-osd.build, then restarts
# the OSDs one at a time and waits for clean after each. rv_build (lib.sh) reports
# the recorded build, and every result file carries it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

build=${1:-}
case $build in
  vanilla) commit=c92aebb279828e9c3c1f5d24613efca272649e62 ;;
  rv)      commit=$(git -C "$CEPH_BUILD/.." rev-parse replicavault-pilot) ;;
  p2)      commit=$(git -C "$CEPH_BUILD/.." rev-parse replicavault-p2) ;;
  *) die "usage: $0 vanilla|rv|p2" ;;
esac
src=$CEPH_BUILD/bin/ceph-osd.$build
[[ -x $src ]] || die "$src not built"

rv_require_cluster
wait_clean 300 || die "cluster not clean before switching"
cp "$src" "$CEPH_BUILD/bin/ceph-osd.new"
mv "$CEPH_BUILD/bin/ceph-osd.new" "$CEPH_BUILD/bin/ceph-osd"
printf '%s %s %s\n' "$build" "$commit" "$(sha256sum "$src" | cut -c1-16)" > "$CEPH_BUILD/bin/ceph-osd.build"
log "installed $build ($commit)"

for n in $(osd_ids); do
  kill_osd "$n" TERM
  restart_osd "$n"
  wait_clean 300 || die "not clean after restarting osd.$n"
done
rv_check_osd_binaries || die "some OSD still runs a stale binary"
log "all OSDs running $(rv_build)"
