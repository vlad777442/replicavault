# Revision 1 to the ReplicaVault proposal (v2): copying vault

**Status:** APPROVED by Vlad on 2026-09-26, thresholds as proposed. This file is frozen like `PILOT_CRITERIA.md`. It was committed before any prototype code was built (proposal §6, "Pass with revised hypotheses": "The revision is committed before building").

- Date: 2026-09-26
- Ceph commit: `c92aebb279828e9c3c1f5d24613efca272649e62` (v19.2.3)
- Evidence: `notes/step1-primitive.md` (with its Phase 3 addendum) and `notes/design-note.md`

## 1. Trigger

Pilot step 1 found that BlueStore has **no supported zero-copy move or clone of an object into a collection outside its PG**:

- **Move-rename:** `OP_COLL_MOVE_RENAME` asserts `cid == dest_cid` (`os/bluestore/BlueStore.cc:15859`).
- **Clone:** `OP_CLONE` / `OP_CLONERANGE2` carry a single collection (`os/Transaction.h:120–122`).
- **Shared blobs:** the in-memory tables that track shared data blocks are kept per collection (`os/bluestore/BlueStore.h:582–620`, `:1636`).
- **Split/merge:** these move no data (`BlueStore.cc:18336–18431`).

Keeping the vault inside the PG collection (option c) fails the gate, because boot-time temp cleanup, scrub rollback cleanup and stray-PG removal all delete such entries (`step1-primitive.md` §2). Extending BlueStore (option b) was not taken.

The pilot therefore proceeds under option (a), the **"pass with revised hypotheses"** branch of the pre-registered gate. On 2026-09-26 Vlad chose option (a).

## 2. Mechanism as built (replaces §4.2 "Zero-copy by reuse, not invention")

On the retaining replica, the local delete is expanded in the same BlueStore transaction into two steps:

1. **Copy.** Write the object's data, xattrs and omap into a reserved namespace (`replicavault`) of that OSD's **meta collection**, under a hex-encoded name that identifies pool, PG, object name, namespace, locator, version and deletion time.
2. **Remove.** Remove the object from the PG collection, exactly as vanilla Ceph does.

One `queue_transactions` call is a single BlueStore transaction (`BlueStore.cc:15492–15513`), so the copy and the remove commit atomically.

The meta collection is never listed by peering, scrub, backfill, recovery, stray-PG removal, or PG split/merge (`step1-primitive.md` §3). So item 4 of the protected-delete contract (§4.1) holds as written.

**The copy is a local write on one OSD only.** No extra network traffic, no change to the PG log, and no change to what other replicas receive.

## 3. Revised hypothesis H1 (replaces §1 H1)

> **H1 (overhead, revised).** Retention costs one local copy of each deleted object on each retaining replica, and nothing else: no extra network traffic, no change to the PG log, and no cost on non-retaining replicas or on non-delete operations. That cost is bounded by object size, which RADOS caps at `osd_max_object_size` (128 MiB by default) and which RBD and RGW keep at 4 MiB by default. It is therefore small relative to the original write of the same data (one copy on one replica, against three replicated writes).

Testable predictions (thresholds confirmed by Vlad on 2026-09-26):

- **H1a — delete latency.** For a protected delete of an object of size *s*, p50 latency is at most vanilla delete latency plus the p50 latency of a local write of *s* bytes on the retaining OSD. For *s* ≤ 4 MiB, p99 is within **2×** vanilla p99.
- **H1b — scope of the cost.** Latency of non-delete operations is statistically indistinguishable from vanilla on a delete-free workload.
- **H1c — foreground throughput.** On trace replay with realistic delete ratios, foreground throughput loss is at most **10%** with one retaining replica.
- **H1d — bytes written.** Extra bytes written per protected delete, summed over all OSDs, equal *s* × (number of retaining replicas), measured with BlueStore perf counters.

If H1a or H1c fails, the paper reports the measured cost as the price of admin-proof retention. The contribution is the separated reclamation authority, not zero-copy, which v2 already did not claim.

## 4. Revised Figure A (replaces §5.5 Figure A)

> **Figure A — cost of retention.** Delete latency (p50, p99) against object size, 4 KiB to 128 MiB, for B0 (vanilla) and ReplicaVault with one and with two retaining replicas. A secondary axis or panel shows extra bytes written per delete. The figure shows the cost growing with object size, bounded by one local write of the object per retaining replica, with the 4 MiB RBD/RGW object size marked as the common operating point.

## 5. Baseline B3 dropped (§5.3)

B3 (copy-to-vault) is removed. It is now the design, so it no longer isolates anything. Baselines B0, B1, B2 and B4 are unchanged.

## 6. Consequential edits (keep the proposal consistent; no further change in scope)

- **§1 Summary, paragraph 3.** Replace "It moves it — without copying, using the same BlueStore clone machinery that backs RADOS snapshots — into a local vault outside the placement group" with "It copies it, in the same local transaction that removes it, into a local vault outside the placement group".
- **§4.2 "The assumption to check first".** Replace with a pointer to §1 of this revision and to `notes/step1-primitive.md`.
- **§4.2 "PG-level destruction".** Retaining a whole PG costs a per-object copy of the PG's contents. A collection-wide metadata move is not available: split/merge change key-range bits only and cannot target a non-PG collection (`BlueStore.cc:18336–18431`). This answers open question 1 in §10.
- **§4.4 / H3 (capacity).** Vault bytes are real, separately allocated bytes, not shared with live data. BlueStore charges them to the originating pool's per-OSD usage statistics at vault time (`BlueStore.cc:14126–14131`). Capacity accounting must therefore subtract vault bytes explicitly. H3's statement is unchanged, but its measurement must use vault-specific counters.
- **§10 Risks.** Close the "BlueStore does not support a zero-copy move or clone across collections" row as "confirmed; option (a) taken; see Revision 1".
- **New constraint** (for §4.2 or an implementation note): vault entry names must not contain `osdmap.`. The admin-socket command `trim stale osdmaps` deletes such meta objects (`osd/OSD.cc:8005–8050`).

## 7. What does not change

- The gate criteria for the rest of the pilot (`PILOT_CRITERIA.md`, unchanged).
- H2 and H3 as stated.
- The protected-delete contract (§4.1).
- The threat model (§3).
- Baselines B0, B1, B2 and B4, and Figures B–E.

## 8. Scope decisions recorded with this revision (Vlad, 2026-09-26)

- **Recovery-path deletes.** The retaining replica also vaults deletes it applies through recovery rather than live replication. The hook goes in `PrimaryLogPG::remove_missing_object` (`osd/PrimaryLogPG.cc:12406`), which both the primary's recovery (`:12337`) and replicas' `PGBackend::handle_recovery_delete` (`osd/PGBackend.cc:144`) call. It does **not** go in the shared helper `PG::remove_snap_mapped_object`, which backfill-remove also uses (`PrimaryLogPG.cc:4597`); backfill-remove stays unvaulted in v1. Same retention rule (acting-set rank 1). See `design-note.md` §4.
- **Snapshot whiteouts.** When a head is deleted in a pool with snapshots (remove plus whiteout create), the retaining replica vaults the head's pre-delete bytes. Snapshot semantics are unchanged: clones and SnapSet are untouched, and snap trim is not vaulted.
