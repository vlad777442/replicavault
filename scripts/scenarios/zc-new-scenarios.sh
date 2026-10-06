#!/usr/bin/env bash
# Zero-copy pilot, Phase 5, new scenarios. Vanilla first where meaningful (z02, z05,
# z06 short), then the zc build: z02, z03 (s01, s05, s06, c01 x10 with
# bluestore compression forced on rvtest), z04, z05, z06 (1 h).
#   scripts/scenarios/zc-new-scenarios.sh [vanilla|zc|zc-from-z03|both]   default: both
set -uo pipefail
cd "$(dirname "$0")"
source ../lib.sh
what=${1:-both}
export RV_DISK_SCAN=all

step() { echo "===== $* ($(date +%T))"; }

if [[ $what == vanilla || $what == both ]]; then
  step use-build vanilla; ../use-build.sh vanilla 2>&1 | tail -1
  step "z02 vanilla";  RV_RESULTS_SUBDIR=zc/vanilla ./z02-shared-blob-fallback.sh --runs 1
  step "z05 vanilla";  RV_RESULTS_SUBDIR=zc/vanilla ./z05-omap-heavy.sh --runs 2
  step "z06 vanilla";  RV_RESULTS_SUBDIR=zc/vanilla SOAK_S=900 ./z06-soak.sh
  step use-build zc;   ../use-build.sh zc 2>&1 | tail -1
fi

if [[ $what == zc || $what == both || $what == zc-from-z03 ]]; then
  [[ $(rv_build) == zc ]] || { step use-build zc; ../use-build.sh zc 2>&1 | tail -1; }
  [[ $what == zc-from-z03 ]] || { step z02; ./z02-shared-blob-fallback.sh --runs 3; }
  step "z03 compression on"
  ceph osd pool set rvtest compression_mode force >/dev/null
  ceph osd pool set rvtest compression_algorithm snappy >/dev/null
  ceph df detail -f json > "../../results/zc/logs/z03-df-before-$(date +%Y%m%dT%H%M%S).json"
  for s in s01-kill-primary-before-delete s05-deep-scrub-with-vault s06-recreate-after-delete; do
    step "z03 $s"; RV_COMPRESSIBLE=1 RV_RESULTS_SUBDIR=zc/z03 ./"$s".sh
  done
  step "z03 c01 x10"; RV_COMPRESSIBLE=1 RV_RESULTS_SUBDIR=zc/z03 ./c01-crash-under-deletes.sh --runs 10 --max-delay 0.04
  ceph df detail -f json > "../../results/zc/logs/z03-df-after-$(date +%Y%m%dT%H%M%S).json"
  ceph osd pool set rvtest compression_mode none >/dev/null 2>&1
  step "z03 compression off"
  step z04; ./z04-restore.sh --runs 2
  step z05; ./z05-omap-heavy.sh --runs 2
  step z06; SOAK_S=3600 ./z06-soak.sh
fi
step done
