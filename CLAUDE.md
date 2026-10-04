# ReplicaVault — zero-copy vault pilot (instructions for Claude Code)

You are helping Vlad (PhD student, GSU) with **ReplicaVault**, a Ceph prototype that keeps hidden, bounded-lifetime copies of deleted objects so that an attacker with Ceph admin credentials cannot destroy data irreversibly.

Today each delete **copies** the object into a vault in the OSD's meta collection: on the primary and on one retaining replica (fix F1, Ceph branch `replicavault-p2` at `05289b5`). Copying is correct and well tested, but it costs a full read and write per retaining OSD, and at 64–128 MiB it stalls unrelated operations.

**This pilot tests whether the vault can be zero-copy:** move the object's onode from its PG collection into the meta-collection vault as a metadata-only rename, leaving its data blocks in place.

The pilot found that BlueStore forbids this today (`OP_COLL_MOVE_RENAME` asserts `cid == dest_cid`, `BlueStore.cc:15859`). The question is whether that restriction is fundamental, or mostly in-memory bookkeeping that can be handled safely for objects with no shared blobs, with copying kept as the fallback for objects that have them.

Read first:
- `docs/ReplicaVault-proposal-v3.md` §§4.1, 4.2, 4.8.
- `docs/revision-1-copying-vault.md` §1.
- `notes/step1-primitive.md`.
- `notes/b1-design.md` §6.

**The main risk is different from before.** A bug here does not just lose a vault copy: it can corrupt BlueStore's view of which blocks are in use. Most of the testing therefore targets BlueStore's allocator, fsck, and crash recovery, not Ceph's PG machinery.

---

## Ground rules

1. **Dev cluster only.** Use only the vstart clusters in `notes/environment.md`. Never touch the cephadm cluster configured in `/etc/ceph`. Check the `fsid` before any destructive command.
2. **Frozen files stay frozen.**
   - `PILOT_CRITERIA.md`, `PHASE2_CRITERIA.md` and every `docs/revision-*.md` are frozen.
   - Pilot and phase 2 results are not to be edited.
   - New results go under `results/zc/`.
   - `ZC_CRITERIA.md` is frozen once committed.
3. **No on-disk format change.** Do not add RocksDB prefixes, change onode or blob encodings, or bump BlueStore's on-disk format version. If the rename needs any of these, stop and report: that is a fail signal for this pilot.
4. **No change to peering, the PG log, scrub, backfill, or replication messages.** The change lives in BlueStore and in the existing ReplicaVault hooks.
5. **Stop at every STOP.** Write findings to `notes/log.md` and wait for Vlad.
6. **Cite code.** Every claim about BlueStore carries a `path:line` into the pinned tree and is marked **verified** (you read it) or **inferred**.
7. **Git.**
   - Branch `replicavault-zc` from `replicavault-p2` (`05289b5`).
   - Small commits, no force-push.
   - Push the workspace `main` and `ceph-patch/` to `github.com/vlad777442/replicavault` when a phase completes. Push nothing else anywhere.
8. **Verify against the disk, never the log.** Use `rvcheck.py --disk-scan` and checksums recorded at write time. Phase 2 showed that log lines miss durable copies around crashes.
9. **Time box.** Three working days from the end of Phase 1 to a passing or failing gate. Report early if it is clearly going to run over.

---

## Phase 0 — setup (1 hour)

- Create branch `replicavault-zc` and the directories `results/zc/` and `notes/zc/`.
- Commit `ZC_CRITERIA.md` with the gate below, today's date and the base commit. Do not edit it afterwards.

```
Zero-copy pilot gate

Pass if all of the following hold on the zero-copy build:
- the new BlueStore unit tests and the existing ceph_test_objectstore suite
  (BlueStore instance) pass;
- the allocation-rebuild test (z01) shows zero corrupted or missing vault
  entries and a clean deep fsck in every run (at least 30 runs);
- the full scenario suite (smoke, s01-s12, a01-a05, c01 x30, c03 x10, c04 A/B x10)
  passes with disk-scan checks and a clean deep fsck after every run;
- z02-z05 and the soak test (z06) pass;
- for unshared objects, bytes written to the device per vaulted delete are
  independent of object size (metadata only).

Fail if any data corruption or fsck error cannot be explained and fixed within
the time box; if the change requires an on-disk format change; or if the gate is
not passing within three working days of the end of Phase 1.

Fallback on fail: keep the copying vault and proceed with the off-path copy
(proposal section 4.8).
```

---

## Phase 1 — read the code (half a day to a day) — **STOP after this phase**

Write `notes/zc/step1.md`. Answer each question with citations, and mark each answer verified or inferred.

1. **Why the assert exists.**
   - What does `_rename` do: onode key rewrite, extent-map shard keys, `OnodeSpace`, cache?
   - Which of those steps assume a single collection?
2. **In-memory re-parenting.**
   - Each onode lives in its collection's `OnodeSpace`. Each blob has a `SharedBlob` cache object holding a collection pointer and a cache shard, even when it is not shared.
   - Does `Collection::split_cache` (used by `_split_collection`) already move onodes and blobs between collections? Can that logic be applied to a single onode?
3. **Shared blobs.**
   - How do you detect that an onode references any shared blob (clones, clone-range)?
   - Confirm that the per-collection `SharedBlobSet` makes cross-collection moves unsafe for such onodes. These take the copy fallback.
4. **Omap.**
   - BlueStore keys omap by pool and by PG, according to onode flags (per-pool / per-PG omap).
   - Moving an object to the meta collection changes its pool, and possibly the omap key scheme. What must be rekeyed, and is that a metadata-only rewrite of omap entries?
   - How does the meta collection's own omap scheme differ?
5. **Space accounting.**
   - The pilot's first build failed fsck because vault bytes were charged to the wrong pool.
   - How are per-pool statfs deltas attached to a transaction? Can one transaction debit the source pool and credit the meta pool, including compressed and allocated bytes?
   - If a transaction can carry only one pool's delta, say so. Rename cannot be split across two transactions the way the copy was.
6. **Allocation rebuild after an unclean shutdown.**
   - On v19.2.3, how does BlueStore rebuild its free-space map after a crash? Find the code: allocation file versus a walk over onodes and shared blobs.
   - Does that walk include meta-collection onodes?
   - Do fsck and repair include them? This decides whether renamed vault entries are protected after a crash.
7. **Deferred writes and in-flight I/O.** Is a rename safe when the object has deferred or not-yet-committed writes queued earlier on the same sequencer?
8. **The vault-time checksum.**
   - The prototype computes SHA-256 by reading the object at vault time, which a zero-copy design must not do.
   - Propose a replacement: rely on BlueStore's per-blob checksums, compute the SHA-256 lazily at restore or reclaim time, and have the harness use client-side checksums.

**Conclude with a verdict:** feasible as a metadata-only change without an on-disk format change, feasible only with a format change (which is a fail), or infeasible. Include the list of code changes and a size estimate.

**STOP.** Wait for Vlad before writing BlueStore code.

---

## Phase 2 — the BlueStore change and unit tests (about one day)

**Implement** a cross-collection move for onodes with no shared blobs, inside BlueStore, without changing the on-disk format. Either relax `OP_COLL_MOVE_RENAME` for this case, or add an internal path used only by ReplicaVault; record which you chose and why. Requests for onodes with shared blobs must be refused cleanly, never asserted on, so the caller can fall back.

**Add tests** to `src/test/objectstore/store_test.cc`, run through `ceph_test_objectstore` against BlueStore. Each test does the following:

1. Write the object in a PG-style collection.
2. Move it into a meta-style collection.
3. Check that it is `ENOENT` in the source.
4. Read it back from the destination: data, xattrs and omap all intact.
5. Unmount, remount and read again.
6. Run a deep fsck.
7. Check per-pool statfs.

Cover:
- small objects (deferred-write path) and large ones (direct writes);
- objects built from many small overwrites, so the extent map shards and spanning blobs exist;
- xattrs and large omap;
- compression forced on;
- a move queued immediately after uncommitted writes to the same object;
- many moves in one transaction, and a move followed by removing the now-empty source collection;
- a cloned object (shared blobs), which must be refused and must leave both objects intact.

**Then run the existing `ceph_test_objectstore` suite for BlueStore.** Find the right gtest filter in the source; do not guess. It must pass unchanged.

---

## Phase 3 — integrate into ReplicaVault (half a day)

- Add a compile-time switch, `RV_VAULT_MODE` = `copy` | `rename`. The default for this branch is `rename`, with copy as the fallback for shared-blob onodes.
- Extend the `replicavault: vaulted` log line with `mode=rename|copy`. Keep logging from the commit callback.
- Replace the vault-time SHA-256 read as decided in Phase 1.
- Keep F1 intact: the primary and the retaining replica each vault.
- **Rename removes the object, so a node holds only one vault entry for it.** That is fine. But check that the remove the PG transaction issues after the rename does not fail on a now-missing object. Order or merge the two operations correctly, and cite why the result is crash-safe.
- Rebuild and run `smoke.sh`.

---

## Phase 4 — the allocator test (z01) — run this before anything else on the cluster

`scripts/scenarios/z01-alloc-rebuild.sh`. Each run does the following:

1. Write N objects of 4 KiB to 16 MiB, with client-side checksums, and delete them so they are vaulted by rename. Confirm `mode=rename` on disk.
2. SIGKILL one retaining OSD, forcing the unclean-shutdown allocation rebuild at its next start. Restart it.
3. Fill that OSD to roughly 70% with new writes (`rados bench … write --no-cleanup` or similar), so that any vault block wrongly marked free gets overwritten.
4. Stop the OSD. Run `ceph-bluestore-tool fsck --deep`. Use `ceph-objectstore-tool` to verify every vault entry's bytes against the client-side checksums. Restart it.

At least 30 runs, varying object sizes and which OSD is killed. Also run it on the copy build as a control.

**Any corrupted or missing vault entry, or any fsck error: STOP and report** with the run's artifacts. Do not attempt a fix without Vlad.

---

## Phase 5 — full regression and new scenarios (one to two days)

**Full suite on the rename build:**
- `smoke.sh`, s01–s12 and a01–a05;
- c01 ×30, c03 ×10, and c04 A and B ×10 each;
- every run followed by a disk scan and a deep fsck on every OSD.

Vanilla is already validated; rerun vanilla only for new scenarios.

**New scenarios** (run on vanilla first where meaningful):

- **z02 — shared-blob fallback.** In a pool with snapshots, write and snapshot an object, then delete the head. Show which path each vault entry took (`mode=copy` expected wherever shared blobs exist), and that both the clone and the vault entry are intact.
- **z03 — compression.** Run the suite subset s01, s05, s06 and c01 ×10 with `bluestore_compression_mode=force` on the test pool.
- **z04 — restore.** Restore at least 20 renamed entries with `vault-inspect.sh`, adapted if needed. Bytes must match and each restore must get a new version.
- **z05 — omap-heavy objects.** Delete objects with large omap, then restore them, comparing omap contents.
- **z06 — soak.** One hour of random writes, overwrites, deletes, snapshot creation and removal, and recreation of deleted names, with an OSD SIGKILL every few minutes. Finish with a deep fsck on every OSD and a checksum check of every vault entry.

---

## Phase 6 — measure the payoff (half a day)

Use the release-build cluster, on vanilla, the copy build (`05289b5`) and the rename build. Object sizes are 4 KiB, 1, 4, 16, 64 and 128 MiB.

- Delete latency p50 and p99.
- p99 of concurrent 4 KiB operations during deletes.
- **Device bytes written per vaulted delete**, from BlueStore perf counters (cite the counter names you use) or `iostat`.

Expected for unshared objects: bytes written and delete latency roughly flat in object size, and close to vanilla.

Label all numbers "single host, 3 OSDs sharing one disk; ratios only".

---

## Phase 7 — report

Write `results/zc/ZC_REPORT.md` covering:

- each gate condition, with its evidence (result files and run counts);
- the BlueStore change: files touched, size, and why it is safe;
- the share of deletes that took the copy fallback in each scenario;
- the Phase 6 table;
- anything that changes the proposal (§§4.2, 4.5, 4.8, H1, Figure A);
- a recommendation: adopt rename, or keep copying.

Export the patch series to `ceph-patch/zc/` and verify that it rebuilds from a clean v19.2.3 checkout. Push.

---

## Out of scope

- Pool deletion, size reduction and stray retention. If the rename works, note in the report how it would apply to them, but do not build it.
- The reclaimer, the retention policy and asymmetric windows.
- The off-path copy.
- Multi-host evaluation.
