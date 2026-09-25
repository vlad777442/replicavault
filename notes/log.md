# Pilot log

## 2026-09-25
- Phase 0: found no source build or vstart cluster; `/etc/ceph` points at a separate cephadm cluster on node0 (left alone). With Vlad's OK: formatted `sdb` → `/data`, cloned Ceph v19.2.3 (`c92aebb2`), installed deps, started Debug build.
- Committed proposal and `PILOT_CRITERIA.md` (pre-registration, frozen).
- Phase 1: wrote `notes/step1-primitive.md`. Verdict: no supported zero-copy move/clone out of a PG collection. Recommend option (a) — copy into a hidden namespace in the meta collection. **STOP: waiting for Vlad's decision on mechanism.**
- Build done (10 min). vstart up: 1 MON, 1 MGR, 5 OSD BlueStore, fsid 224f2f2c-…; osd.2/3 mkfs raced, fixed by hand. Pool `rvtest` created. OSD kill/restart verified. Incremental ceph-osd rebuild 59 s. Phase 0 complete.
- Phase 2: `scripts/lib.sh`, `scripts/smoke.sh` pass on vanilla (results/smoke-20260925T173923.json, smoke-20260925T174318.json; ~70 s/run). Added `scripts/negative-control.sh`: offline-corrupts one replica via ceph-objectstore-tool; deep scrub + check_inconsistent detected it (PG 1.1d) and repair restored clean (results/negative-control-20260925T174145.json).
- Harness bug found and fixed: SIGTERM'd OSD is marked down before it exits → offline tool hit a locked store. `kill_osd` now waits for down *and* process exit. First negative-control attempt aborted with `noout` set; cleaned up by hand, script now clears it via trap.
- Standing HEALTH_WARN "12 mgr modules have failed dependencies" (python deps for mgr modules in the dev build). Harmless for the pilot; check_inconsistent ignores it.
