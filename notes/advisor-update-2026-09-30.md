# ReplicaVault — progress update, 2026-09-30

Since the pilot gate passed (2026-09-26, "pass with revised hypotheses"), phase 2 has fixed the problems the pilot exposed. It also found a serious coverage bug, now fixed (F1). With F1, all earlier scenarios pass again, and so does losing the primary instead of the retaining replica (c04). *(Revised 2026-10-01: corrected loss counts, F1 regression and cost added. Revised 2026-10-02: c04 added.)*

## Results

**1. The pilot's coverage gap was misdiagnosed. The real gaps are fixed.**
- **Not a gap:** the pilot assumed the retaining replica could be an OSD that is being backfilled. That cannot happen: Ceph keeps backfill targets out of the acting set. So `ceph osd out` and `pg-upmap` attacks do not open a gap (scenarios a01 and a02 passed even on the pilot).
- **The real gaps:** pool size 1 (no second replica) and `primary-temp` (the retaining rank becomes the primary). On the pilot they left 24/24 and 25/25 acknowledged deletes unvaulted.
- **Fix:** the retainer is chosen in primary-first order, and the primary vaults when it is the retainer. Both attacks now pass.

**2. A serious finding: acknowledged deletes could be lost. Fixed (F1).**
- **The failure:** if the retaining OSD crashed mid-delete and stayed out long enough for its PGs to recover elsewhere (Ceph's default is 10 minutes), the other replicas acknowledged the delete without any vault copy. When the OSD came back, its leftover copy was purged as a stray.
- **Measured:** 164 of 320 acknowledged deletes lost, in 18 of 20 runs (scenario c03).
  - An earlier count of 261 also included 97 deletes whose retaining replica *had* durably vaulted them, but was killed before writing the log line our checker relied on. The checker now scans the disks directly.
- **Fix (F1):** the primary also vaults every delete, so the client's acknowledgement implies a durable copy on the primary.
- **After the fix:** c03 lost 0 of 320 in 20 runs. 230 deletes survived only because of the primary's copy.
- **Regression:** with F1, every earlier scenario (s01–s12 and a01–a05) passes again: 118/118 runs, 1,000/1,000 deletes retained.
- **Scope:** no change to Ceph's replication messages, peering, PG log, scrub or backfill.

**3. Crash consistency and read-after-queue were tested, not just argued.**
- **c01, retainer killed under a delete stream:** 100/100 runs, 1,600/1,600 acknowledged deletes retained, BlueStore fsck clean.
- **c02, write immediately followed by delete:** 200/200 cases. The vault held the last queued write.

**4. Cost: an early, single-host signal (with F1).**

| Deleted object | Delete latency vs vanilla | Small-op (4 KiB) p99 during deletes vs vanilla |
|---|---|---|
| 1 MiB | 1.3× | 1.1× |
| 4 MiB | 2.3× | 1.2× |
| 16 MiB | 5.0× | 1.6× |
| 64 MiB | 11.5× | 7.5× |
| 128 MiB | 22× | 11× |

- **Before F1, at 128 MiB:** 13× and 4.8×.
- **Cause:** the primary and the retainer each read the whole object synchronously on their op paths.
- **Caveat: this overstates F1's cost.** The probe's 3 OSDs are file-backed and share one physical disk, so F1's second copy competes for the same device as the first. On a multi-host cluster the two copies go to different disks, and the extra cost should be smaller. Only the ratios to vanilla on this host mean anything.
- **Implication:** large-object deletes need a mitigation (for example moving the copy off the op path) before the full H1 evaluation.

## Consequences for the proposal

- **H1 (overhead):** with F1, retention costs two copies per delete, not one. The cost grows with object size.
- **H2 (coverage):** the pilot's gap description is corrected. With F1, in every single-OSD failure tested, each acknowledged delete still had an intact copy on a surviving OSD after recovery:
  - retainer killed and back in the acting set (c01): 1,600/1,600;
  - retainer killed and returning as a stray (c03): 320/320;
  - primary killed, returning as a stray (c04): 320/320;
  - primary killed, never returning (c04): 320/320.

  Untested: the third replica, two or more failures, device loss, other pool sizes.
- **H3 (capacity):** retained bytes are about 2× deleted bytes, and 3× when a replica is deliberately made to miss deletes (scenario a05). The proposal's asymmetric retention windows could give the primary's copy a short window.

All of this is recorded in Revision 1b (`docs/revision-1b-coverage-and-ack-window.md`), now approved.

## In progress / next

- Revision 1b is approved, with item 5 limited to the tested cases.
- Decide on a mitigation for the large-object copy cost before the full H1 evaluation.

## Where to read more

All in the project repository:

| File | What it is |
|---|---|
| `results/phase2/PHASE2_REPORT.md` | Phase 2 report |
| `notes/b1-design.md` | Coverage analysis, fix options, and results (§§1, 5, 6) |
| `docs/revision-1b-coverage-and-ack-window.md` | Revision 1b draft |
| `ceph-patch/` | The Ceph patch series, verified to rebuild from a clean v19.2.3 checkout |
