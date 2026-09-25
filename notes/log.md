# Pilot log

## 2026-09-25
- Phase 0: found no source build or vstart cluster; `/etc/ceph` points at a separate cephadm cluster on node0 (left alone). With Vlad's OK: formatted `sdb` → `/data`, cloned Ceph v19.2.3 (`c92aebb2`), installed deps, started Debug build.
- Committed proposal and `PILOT_CRITERIA.md` (pre-registration, frozen).
- Phase 1: wrote `notes/step1-primitive.md`. Verdict: no supported zero-copy move/clone out of a PG collection. Recommend option (a) — copy into a hidden namespace in the meta collection. **STOP: waiting for Vlad's decision on mechanism.**
- Build done (10 min). vstart up: 1 MON, 1 MGR, 5 OSD BlueStore, fsid 224f2f2c-…; osd.2/3 mkfs raced, fixed by hand. Pool `rvtest` created. OSD kill/restart verified. Incremental ceph-osd rebuild 59 s. Phase 0 complete.
