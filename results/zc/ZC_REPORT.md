# ReplicaVault zero-copy vault pilot — report

Ceph v19.2.3 (`c92aebb2`) + ReplicaVault F1 (`05289b5`) + zero-copy (`5b0dac5`, `33b89ae`) on branch `replicavault-zc`. Patch series: `ceph-patch/zc/` (7 patches; they reproduce `33b89ae` exactly on a clean v19.2.3, and a fresh build from them, `/data/verify-ceph/build-zc`, Debug, compiles `ceph-osd` and `ceph_test_objectstore` and passes `RVMoveTest` 7/7). Gate: `ZC_CRITERIA.md` (frozen 2026-10-03). Running log: `notes/log.md`. Written 2026-10-06.

## Recommendation

**Adopt rename.** Every gate condition holds on the zero-copy build:
- no data corruption, missing vault entry or fsck error was found in any run;
- no on-disk format change was needed;
- device bytes per vaulted delete no longer depend on object size;
- delete latency and the latency of concurrent small ops return to vanilla levels at every size up to 128 MiB, where the copying vault was 33× slower at 128 MiB.

Keep the copying vault as the in-tree fallback, because it is still needed:
- for objects whose blobs are shared (snapshots, clones);
- as the off-path copy design (§4.8) for those objects, if they turn out to matter.

The decision is Vlad's. The caveats in "What to watch" below are real but none is a gate failure.

## Gate conditions

| Condition (`ZC_CRITERIA.md`) | Result | Evidence |
|---|---|---|
| New BlueStore unit tests pass | **pass**: `ObjectStore/RVMoveTest` 7/7, each with deep fsck and exact pool → meta statfs | `notes/zc/phase2.md` |
| Existing `ceph_test_objectstore` suite (BlueStore instance) passes | **pass**: 129 passed, 4 skipped by design (zero-block detection off by default), 0 failed | `notes/zc/phase2.md` |
| z01: zero corrupted or missing vault entries, clean deep fsck, every run, ≥ 30 runs | **pass**: 30/30 on the rename build; 5/5 on the copy-build control | `results/zc/z01-alloc-rebuild-20261004T100138.json`, `…20261005T001126.json` |
| Full suite with disk scan + regular fsck every run + deep fsck per batch | **pass**: smoke, s01–s12, a01–a05, c01 ×30, c03 ×10, c04 A/B ×10, all runs | `results/zc/*-2026100[5-6]*.json` (table below) |
| z02–z05 and z06 pass, deep fsck after every z06 run | **pass** | `results/zc/z0[2-6]-*.json`, `results/zc/z03/` |
| Bytes written to the device per vaulted delete independent of object size (unshared objects) | **pass**: about 0.6 MiB of data-device writes per delete at every size from 4 KiB to 128 MiB, the same as vanilla; the copying vault writes 2× the object size | `results/zc/cost/` (Phase 6) |
| No on-disk format change | **holds**: no new RocksDB prefix, no onode/blob encoding change, no format version bump | `notes/zc/phase2.md` |
| Within three working days of the end of Phase 1 | Phase 1 STOP: 2026-10-03; gate result: 2026-10-06 | `notes/log.md` |

### Scenario suite on the rename build (all with disk scan and per-run all-OSD fsck)

| Scenario | Runs passed | Copy-fallback share of vault entries |
|---|---|---|
| smoke | pass (no per-run fsck: smoke does not use the scenario harness) | 0% |
| s01, s02, s03, s04, s05, s06 | 10/10, 20/20, 10/10, 2/2, 3/3, 5/5 | 0% |
| s07 | 2/2 (rerun after a harness fix; the first attempt produced no result file) | 0% |
| s08, s09, s10, s11, s12 | 6/6, 2/2, 3/3, 2/2, 10/10 | s10 50% (snapshots), others 0% |
| a01–a05 | 10/10, 10/10, 3/3, 10/10, 10/10 | 0% |
| c01 ×30, c03 ×10, c04 A ×10, c04 B ×10 | 30/30, 10/10, 10/10, 10/10 | 0% |
| c01s ×30, c03s ×10, c04 A s ×10, c04 B s ×10 (kill at 0–40 ms; see below) | 30/30, 10/10, 10/10, 10/10 | 0% |
| z01 ×30 | 30/30 | 0% |
| z02 ×3 (shared-blob fallback) | 3/3 | 50% by design |
| z03 (compression forced: s01, s05, s06, c01 ×10) | 10/10, 3/3, 5/5, 10/10 | 0% |
| z04 ×2 (restore of 24 renamed entries) | 2/2 | 0% |
| z05 ×2 (omap 100/2,000/20,000 keys) | 2/2 | 0% |
| z06 (1 h soak, 14 OSD kills) | 1/1 | 13% (snapshot-pool partial overwrites) |

Copy shares are counted from the `vaulted … mode=` log lines of each scenario's objects.

## The BlueStore change and why it is safe

**What it is** (`5b0dac5`): a cross-collection `OP_COLL_MOVE_RENAME`, accepted only when the destination is the meta collection. Details in `notes/zc/phase2.md`.
- The move rewrites the onode key, the extent-shard keys and the omap keys.
- It re-homes the onode and its blobs in memory, using the per-onode part of `Collection::split_cache`.
- It moves the object's statfs contribution from its pool to the meta pool, through a second delta per transaction (`TransContext::extra_statfs_delta`).
- It allocates and frees nothing.
- A request for an object with a shared blob is refused with `-EXDEV`, and nothing changes.
- Callers ask first through `ObjectStore::can_move_to_collection`.

**ReplicaVault integration** (`33b89ae`):
- **Mode.** `RV_VAULT_MODE=rename|copy` is a cmake option. A delete is renamed if the PG transaction's first use of the head is its remove and `can_move_to_collection` returns 0; otherwise it is copied.
- **Ordering.** The rename is queued in the same `queue_transactions` call as the PG transaction, ahead of it. So it commits in the same BlueStore txc and the same KV batch as the log entry and the remove. The remove then gets a tolerated ENOENT. The argument with citations is in `notes/zc/phase3.md`.
- **Unchanged.** F1, the log line from the commit callback, and the PG log, peering, scrub and backfill are all unchanged.

**Size:** 9 files, +971/−84 lines. That is BlueStore and the ObjectStore interface +374, ReplicaVault and its hooks +236/−84, and unit tests +370.

**Why the evidence says it is safe:**

| Risk | Evidence |
|---|---|
| Allocator: a vault block wrongly freed by the onode-walk rebuild after a crash | z01 30/30 runs on an OSD set with allocation-from-file. Each run: SIGKILL → rebuild confirmed in the log → fill (8 GiB; 70% in 6 runs) → no vault extent in the persisted free list → deep fsck and `qfsck` clean → every z01 entry on that OSD present with the client's bytes (up to 96 per OSD, cumulative). The checker was shown to catch an injected free-list overlap, a missing entry and a bad checksum. In this mode offline fsck does not compare used blocks with the free list (`BlueStore.cc:11487`), so the direct check was added. |
| Crash in the middle of a rename | c01s ×30, c03s ×10, c04 A s/B s ×10 with kills at 0–40 ms: 26 runs killed an OSD mid-delete (14 + 6 + 3 + 3), 398 deletes were acknowledged after the kill (216 + 86 + 48 + 48), 0 had unknown outcomes. Every acknowledged delete has an intact entry; killed-OSD fsck and per-run all-OSD fsck were clean. |
| Cache and locking bugs | 7 unit tests, including a move queued after uncommitted writes and 50 moves in one txn; z06: 1 h of mixed ops with 14 SIGKILLs, 19,659 entries scanned intact. |
| Statfs | Unit tests check pool → meta deltas exactly; deep fsck (which checks per-pool statfs) is clean in every run. |
| Shared blobs | Unit test SharedBlobRefused; z02 live: a partial overwrite after a snapshot gives `can_move=-18` (`EXDEV`) and a copy, and both the clone and the entry are intact. |
| Compression | Unit test CompressionForced; z03 with compressible data (140 MiB under compression in rvtest): all entries renamed and intact. |
| Recovery path | s12: 10 `path=recovery` deletes all renamed; c01s: 185 recovery-path renames. |

## Phase 6 — cost

Single host, 3 OSDs sharing one disk; ratios only. RelWithDebInfo, vstart release cluster (`/data/ceph/build-rel`, DB on HDD), pool `rvcost` size 3. Two interleaved repetitions per build (vanilla → copy → rename, twice); 20 deletes per size per repetition, from one PG; 4 threads of 4 KiB reads/writes in the background. Ranges are the two repetitions. Files: `results/zc/cost/cost-probe-{vanilla,p2,zc}-*-r1.json`.

**Delete latency, p50 / p99 (ms)**

| Size | vanilla | copy (05289b5) | rename (33b89ae) |
|---|---|---|---|
| 4 KiB | 141–151 / 167–647 | 167–181 / 234–344 | 153–174 / 275–303 |
| 1 MiB | 143–167 / 254–317 | 278–292 / 390–415 | 134–149 / 235 |
| 4 MiB | 157–158 / 226–384 | 425–448 / 703–789 | 160–164 / 341–352 |
| 16 MiB | 159–166 / 457–487 | 938–971 / 1152–1216 | 151–157 / 276–414 |
| 64 MiB | 142–153 / 258–259 | 2790–2975 / 3244–3366 | 164–173 / 210–234 |
| 128 MiB | 158–160 / 260–267 | 5168–5223 / 5987–6009 | 140–178 / 225–256 |

**p99 of concurrent 4 KiB ops while a delete is in flight (ms)** (no-delete baseline in each file: `baseline_4k`)

| Size | vanilla | copy (05289b5) | rename (33b89ae) |
|---|---|---|---|
| 4 KiB | 224–497 | 295–370 | 222–333 |
| 1 MiB | 225–244 | 266–349 | 221–248 |
| 4 MiB | 246–256 | 428–576 | 253–266 |
| 16 MiB | 438–457 | 887–900 | 263–278 |
| 64 MiB | 226–253 | 2568–3111 | 220–232 |
| 128 MiB | 233–277 | 4637–4919 | 266–583 |

**Device bytes written per vaulted delete (MiB), summed over the 3 OSDs** — BlueStore data device `bluestore.write_big_bytes + write_small_bytes` (`BlueStore.cc:6352, 6365`) / DB+WAL `bluefs.bytes_written_wal + bytes_written_sst + bytes_written_slow` (`BlueFS.cc:261–269`) / whole HDD (`/proc/diskstats` sectors × 512). Includes the background 4 KiB workload (about 0.6 MiB of data per delete interval in every build).

| Size | vanilla | copy (05289b5) | rename (33b89ae) |
|---|---|---|---|
| 4 KiB | 0.6–0.7 / 1.1–1.2 / 4.4–4.9 | 0.7–0.7 / 1.2–1.3 / 2.6–3.2 | 0.6–0.7 / 1.0–1.2 / 3.2–3.7 |
| 1 MiB | 0.6–0.7 / 1.1–1.2 / 3.5–3.6 | 2.7–2.7 / 1.2–1.2 / 6.8–8.5 | 0.7–0.7 / 1.2–1.2 / 2.6–4.4 |
| 4 MiB | 0.6–0.6 / 1.1–1.1 / 2.3–2.8 | 8.6–8.6 / 1.1–1.2 / 10.8–12.7 | 0.6–0.6 / 1.1–1.1 / 2.5–4.3 |
| 16 MiB | 0.6–0.6 / 1.1–1.2 / 4.4–4.9 | 32.7–32.7 / 1.2–1.3 / 35.4–36.0 | 0.6–0.6 / 1.1–1.2 / 2.4–3.3 |
| 64 MiB | 0.6–0.6 / 1.2–1.2 / 2.8–3.2 | 128.7–128.7 / 1.5–1.5 / 133.6–133.8 | 0.6–0.6 / 1.3–1.4 / 3.0–4.8 |
| 128 MiB | 0.6–0.7 / 1.1–1.3 / 2.6–4.4 | 256.7–256.7 / 1.7–1.8 / 260.8–263.9 | 0.6–0.6 / 1.5–1.5 / 3.5–4.7 |

**Reading:**
- **Delete latency.** The rename build's delete p50 stays at 134–178 ms from 4 KiB to 128 MiB, the same as vanilla's 141–167 ms. The copying vault grows to 5.2 s at 128 MiB, 33× vanilla.
- **Concurrent 4 KiB p99.** The rename build stays at vanilla levels up to 64 MiB. At 128 MiB one repetition reached 583 ms (the other 266 ms, vanilla 233–277 ms); the copying vault reached 4.6–4.9 s.
- **Device bytes.** The data-device bytes per delete are the same about 0.6 MiB for rename and vanilla at every size; that is the background workload. The copying vault writes 2× the object size, one copy each on the primary and the retainer.
- **DB/WAL bytes** rise slightly with size for both vaulting builds (rename 1.0 → 1.5 MiB, copy 1.2 → 1.8 MiB). **Inferred:** a larger object has more extent-map shard keys to rewrite. This is metadata, not data.

## Surprises and findings

1. **The pre-registered crash scenarios stopped hitting their window.** c01, c03 and c04 kill an OSD after a random 0–1.5 s delay. With rename, all 16 deletes complete in 21–26 ms, so in 0 of 60 runs (960 deletes) was any delete acknowledged after the kill; on the copy build, 94–100% of runs had some. The pre-registered runs pass as specified but would not have caught a mid-rename crash bug. I added `--max-delay` and per-delete completion times, and reran all three at 0–40 ms (the `s` variants above), which did hit the window. **For the proposal:** crash-timing parameters have to scale with the operation's duration, and each run should record whether it hit the window.
2. **Vault omap keys are filed under pool 0, not the meta pool's id.** `coll_t::pool()` is `pgid.pool()`, which is 0 for the meta collection (`osd_types.h:748`). Renamed entries therefore keep the per-PG omap prefix with pool field 0 (seen on disk with `ceph-kvstore-tool`). There is no collision, since nids are unique store-wide, and fsck is clean. **Inferred:** with a real pool 0, per-pool omap usage estimates could include vault omap. `notes/zc/step1.md` Q4 said "pool −1"; that is corrected here.
3. **Omap-heavy deletes cost more, as predicted.** At 20,000 keys a rename delete took 801–895 ms against vanilla's 578–588 ms (+37–53%); at 2,000 keys +16–24%; at 100 keys no difference (z05). The rename rewrites every omap key, where vanilla does one range delete.
4. **z03 as written could not test compression.** Scenario data is random, and BlueStore never stores random data compressed. The first z03 attempt was stopped and rerun with compressible contents (`RV_COMPRESSIBLE=1`).
5. **Harness gaps found and fixed:**
   - s11 enforced its restore check only on the pilot build (`rv`). The zc rows were correct anyway; phase 2 `p2` s11 results should be read row by row.
   - s07's check output exceeded the 128 KiB argument limit; `run_end` now passes JSON through files.
   - The Phase 6 probe's 4 KiB delete set collided with its 4 KiB workload names.
6. **The first z01 fill plan was too slow on this HDD** (about 35 min per 70% fill). Vlad approved 8 GiB fills in every run, 70% in 6 runs, plus the direct free-list check, which is stronger than relying on an overwrite.
7. **The existing objectstore suite's QA filter for job b (`*SyntheticMatrixC*/2`) selects kstore in v19.2.3.** The BlueStore instance is `/1`; it was rerun and passed.

## What changes in the proposal

- **§4.2 (mechanism):** describe the rename. It is a metadata-only move into the meta-collection vault for unshared heads, in the PG transaction's own txc, with the copy kept for heads whose transaction uses them before the remove (snapshot clones) or whose blobs are shared. The "primitive not available" statement from the first pilot is superseded: it is available with about 370 lines of BlueStore change and no format change.
- **H1 (overhead):** for unshared objects, retention cost no longer grows with object size. Device bytes per delete equal vanilla's, and delete latency and concurrent 4 KiB p99 are at vanilla levels up to 128 MiB. The remaining size-dependent cost is in omap: +37–53% delete latency at 20,000 keys. Snapshot and clone workloads keep the copy cost for the share of deletes that fall back (13% of entries in the z06 mix).
- **§4.8 (off-path copy):** now needed only for the copy fallback. Whether to build it depends on how much of a real workload has shared blobs at delete time. The z06 mix is synthetic.
- **§4.5 (PG-level destruction; not built):** the same move could re-home a whole PG's unshared onodes into the vault instead of letting stray-PG removal delete them. That would be O(objects + omap keys) in metadata, with no data copy. **Inferred**, not tested.
- **Figure A:** the rename build's delete latency and interference curves lie on vanilla's for 4 KiB–128 MiB, and the copy build's curves grow with size (Phase 6 table).
- **§6.3 / guarantee wording:** the crash evidence now includes mid-rename kills (the `s` variants).

## Reproduce

- **Build.** Apply `ceph-patch/zc/*.patch` to v19.2.3 (`ceph-patch/README.md`). Build `ceph-osd` twice: with `-DRV_VAULT_MODE=rename` → `bin/ceph-osd.zc`, and with `-DRV_VAULT_MODE=copy` → `bin/ceph-osd.zccopy`.
- **Cluster.** `notes/environment.md`: the zc cluster, 5 OSDs, DB/WAL on SSD.
- **Scenarios.**
  - `scripts/use-build.sh zc`;
  - `scripts/scenarios/z01-alloc-rebuild.sh`;
  - `scripts/scenarios/zc-regression.sh`;
  - c01/c03/c04 with `--max-delay 0.04`;
  - `scripts/scenarios/zc-new-scenarios.sh`.
- **Cost.** `COST_RESULTS_SUBDIR=zc/cost PROBE_ARGS="--sizes-kib 4 1024 4096 16384 65536 131072 --deletes 20 --threads 4 --baseline-s 30" scripts/cost-probe.sh vanilla|p2|zc 1`, on the release cluster.
