#!/usr/bin/env bash
# Phase 2, Phase 5: run scripts/cost-probe.py on the RelWithDebInfo vstart cluster
# (/data/ceph/build-rel, fsid below), once per build and repetition.
#
#   scripts/cost-probe.sh vanilla|p2|zc [reps]      (extra cost-probe.py args via PROBE_ARGS,
#                                                 e.g. PROBE_ARGS="--deletes 20 --threads 16")
#
# Installs build-rel/bin/ceph-osd.<build> as bin/ceph-osd (by rename), restarts the
# three OSDs one at a time, creates pool `rvcost` (size 3, min_size 2, 32 PGs,
# autoscale off) if missing, then runs the probe <reps> times (default 2), writing
# results/phase2/cost-probe-<build>-<timestamp>-r<i>.json. Numbers are indicative,
# single host.
set -euo pipefail
export CEPH_BUILD=/data/ceph/build-rel
export RV_EXPECTED_FSID=e6e34e84-822b-4fe5-859c-e245368dcab6
source "$(dirname "$0")/lib.sh"
export PYTHONPATH=$CEPH_BUILD/lib/cython_modules/lib.3${PYTHONPATH:+:$PYTHONPATH}
export CEPH_BIN=$CEPH_BUILD/bin

build=${1:-}; reps=${2:-2}
[[ $build == vanilla || $build == p2 || $build == zc ]] || die "usage: $0 vanilla|p2|zc [reps]"
rv_require_cluster
src=$CEPH_BUILD/bin/ceph-osd.$build
[[ -x $src ]] || die "$src not built"
cp "$src" "$CEPH_BUILD/bin/ceph-osd.new" && mv "$CEPH_BUILD/bin/ceph-osd.new" "$CEPH_BUILD/bin/ceph-osd"
printf '%s %s\n' "$build" "$(sha256sum "$src" | cut -c1-16)" > "$CEPH_BUILD/bin/ceph-osd.build"
if ! ceph osd pool ls | grep -qx rvcost; then
  ceph osd pool create rvcost 32 32 replicated --autoscale-mode=off >/dev/null
  ceph osd pool set rvcost size 3 >/dev/null
  ceph osd pool set rvcost min_size 2 >/dev/null
  ceph osd pool application enable rvcost rados >/dev/null
fi
for n in $(osd_ids); do kill_osd "$n" TERM; restart_osd "$n"; wait_clean 300 || die "not clean"; done
rv_check_osd_binaries || die "stale OSD binary"
OUTDIR=$RV_ROOT/results/${COST_RESULTS_SUBDIR:-phase2}
mkdir -p "$OUTDIR"
for i in $(seq 1 "$reps"); do
  TS=$(date +%Y%m%dT%H%M%S)
  out=$OUTDIR/cost-probe-$build-$TS-r$i.json
  log "probe $build rep $i -> $out"
  # shellcheck disable=SC2086
  python3 "$(dirname "$0")/cost-probe.py" --pool rvcost --out "$out.tmp" --tag "cp-$build-$TS" ${PROBE_ARGS:-}
  python3 - "$out.tmp" "$out" "$build" "$TS" "$(git -C /data/ceph rev-parse "$(case $build in p2) echo replicavault-p2 ;; zc) echo replicavault-zc ;; *) echo c92aebb2 ;; esac)")" <<'EOF'
import json, sys
tmp, out, build, ts, commit = sys.argv[1:6]
r = json.load(open(tmp))
r = {"build": build, "build_type": "RelWithDebInfo", "ceph_commit": commit, "timestamp": ts,
     "command": f"PROBE_ARGS='{__import__('os').environ.get('PROBE_ARGS', '')}' scripts/cost-probe.sh {build}", "cluster": "vstart /data/ceph/build-rel, 1 MON, 1 MGR, 3 OSDs, file-backed BlueStore, single host",
     "label": "single host, 3 OSDs sharing one disk; ratios only", **r}
json.dump(r, open(out, "w"), indent=1)
EOF
  rm -f "$out.tmp"
  wait_clean 300 || true
done
