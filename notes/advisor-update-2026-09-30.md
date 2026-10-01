# ReplicaVault — progress update, 2026-09-30

Since the pilot gate passed (2026-09-26, "pass with revised hypotheses"), phase 2 has fixed the problems the pilot exposed. It also found a serious coverage bug, which is now fixed. Two runs, the F1 regression set and the cost probe on F1, are still in progress and finish tonight.

## Results

**1. The pilot's coverage gap was misdiagnosed. The real gaps are fixed.**
- **Not a gap:** the pilot assumed the retaining replica could be an OSD that is being backfilled. That cannot happen: Ceph keeps backfill targets out of the acting set. So `ceph osd out` and `pg-upmap` attacks do not open a gap (scenarios a01 and a02 passed even on the pilot).
- **The real gaps:** pool size 1 (no second replica) and `primary-temp` (the retaining rank becomes the primary). On the pilot they left 24/24 and 25/25 acknowledged deletes unvaulted.
- **Fix:** the retainer is chosen in primary-first order, and the primary vaults when it is the retainer. Both attacks now pass.

**2. A serious finding: acknowledged deletes could be lost. Fixed (F1).**
- **The failure:** if the retaining OSD crashed mid-delete and stayed out long enough for its PGs to recover elsewhere (Ceph's default is 10 minutes), the other replicas acknowledged the delete without any vault copy. When the OSD came back, its leftover copy was purged as a stray.
- **Measured:** 261 of 320 acknowledged deletes lost, in 19 of 20 runs (scenario c03).
- **Fix (F1):** the primary also vaults every delete, so the client's acknowledgement implies a durable copy on the primary.
- **After the fix:** c03 lost 0 of 320 in 20 runs. 253 deletes survived only because of the primary's copy.
- **Scope:** no change to Ceph's replication messages, peering, PG log, scrub or backfill.

**3. Crash consistency and read-after-queue were tested, not just argued.**
- **c01, retainer killed under a delete stream:** 100/100 runs, 1,600/1,600 acknowledged deletes retained, BlueStore fsck clean.
- **c02, write immediately followed by delete:** 200/200 cases. The vault held the last queued write.

**4. Cost: an early, single-host signal.** Measured before F1; F1 roughly doubles the per-delete copy work.
- **Delete latency vs vanilla:** about 2× at 4 MiB, about 13× at 128 MiB.
- **Small-op interference:** 4 KiB p99 during deletes is 1.7× vanilla at 4 MiB deletes and 4.8× at 128 MiB.
- **Cause:** the retainer reads the whole object synchronously on the op path.
- **Implication:** large-object deletes need a mitigation (for example moving the copy off the op path) before the full H1 evaluation.

## Consequences for the proposal

- **H1 (overhead):** with F1, retention costs two copies per delete, not one. The cost grows with object size.
- **H2 (coverage):** the pilot's gap description is corrected. Under any single OSD failure, an acknowledged delete keeps a durable copy. That claim rests on reasoning plus c03 and c01; it is not proven in general.
- **H3 (capacity):** retained bytes are about 2× deleted bytes. The proposal's asymmetric retention windows could give the primary's copy a short window.

All of this is drafted as Revision 1b (`docs/revision-1b-coverage-and-ack-window.md`). The restated contract item 5 is pending my confirmation.

## In progress / next

- F1 regression run of all earlier scenarios, and the cost probe on F1 (tonight).
- Confirm Revision 1b's item 5.
- Decide on a mitigation for the large-object copy cost before the full H1 evaluation.

## Where to read more

All in the project repository:

| File | What it is |
|---|---|
| `results/phase2/PHASE2_REPORT.md` | Phase 2 report |
| `notes/b1-design.md` | Coverage analysis, fix options, and results (§§1, 5, 6) |
| `docs/revision-1b-coverage-and-ack-window.md` | Revision 1b draft |
| `ceph-patch/` | The Ceph patch series, verified to rebuild from a clean v19.2.3 checkout |
