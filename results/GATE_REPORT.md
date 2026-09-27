# ReplicaVault pilot — gate report

- **Date:** 2026-09-26
- **Pilot branch:** workspace `main`; Ceph `replicavault-pilot` at `17451c9`, on top of v19.2.3 `c92aebb2`.
- **Pre-registration:**
  - `PILOT_CRITERIA.md` committed 2026-09-25 17:22 (`0410763`) and never edited (one commit).
  - Revision 1, the copying-vault branch, committed 2026-09-26 13:33 (`90846fc`), **before** the first prototype commit (`ca2a5b2`, 13:44).
- **Testbed:** one CloudLab node, a `vstart.sh` cluster with 1 MON, 1 MGR and 5 BlueStore OSDs (file-backed), from a Debug build.
  - Pool `rvtest`: size 3, min_size 2, 32 PGs. Pool `rvsnap`: 8 PGs, for snapshots.

**Recommendation: pass with revised hypotheses.** Every gate condition was met on the prototype in all 75 runs across 12 scenarios, after the same 75 runs passed on vanilla Ceph. Step 1 left only a copying move (option a), so under the pre-registered decision rule this is the "pass with revised hypotheses" outcome. The revision (H1 restated as a bounded copy cost, Figure A reframed, B3 dropped) was committed before building, as the rule requires. The caveats in §3 are real and should be read before the defense. The call is yours.

---

## 1. Gate criteria, one by one

Criteria text is from `PILOT_CRITERIA.md`.

### 1.1 Pass conditions

"Pass if, across every scenario in step 5 …"

| Condition | Result | Evidence |
|---|---|---|
| **No deleted object reappears** | **Met.** 75/75 prototype runs, 75/75 vanilla runs. Every acknowledged-deleted object is `ENOENT` by `rados stat` and absent from an all-namespace listing. | Invariant 1 column in §2 |
| **Deep-scrub reports no inconsistency** | **Met.** A deep scrub of every PG completed after every run, with zero inconsistent PGs or objects and no `OSD_SCRUB_ERRORS` / `PG_DAMAGED`. The detector is shown to work: offline corruption of one replica is flagged. | Invariant 2 column; `results/negative-control-20260925T174145.json` |
| **The vault copy exists and is intact on the designated replica** | **Met, with one caveat (§3.1).** Every acknowledged delete on the prototype had at least one vault entry on the OSD whose log recorded it. Each entry's stored SHA-256 equalled the SHA-256 of its stored bytes and of the object at deletion time. 646 delete-to-vault checks, 0 misses. | Invariant 3 column |
| **… including after OSD restart** | **Met.** 6/6 restarts of the retaining OSD (3 SIGKILL, 3 SIGTERM, four different OSDs). BlueStore fsck is clean while the OSD is down. No assert at boot. The vault is not treated as a stray or temp collection. All entries intact. | `s08-restart-retainer-20260926T183712.json` |
| **… and PG split or merge** | **Met.** pg_num 32 → 64 → 32 with vault entries in every PG: 96/96 entries intact after the split, 128/128 after the merge (including every pre-split entry). | `s09-pg-split-merge-20260926T184811.json` |
| **A manual restore produces a new object version with matching content** | **Met.** 12/12 restores via `scripts/vault-inspect.sh restore` (including one object in a namespace and one with a locator). Every one reproduced the original bytes (SHA-256) and received a version newer than the vaulted one. | `s11-manual-restore-20260926T192132.json` |

### 1.2 Fail conditions

| Condition | Result |
|---|---|
| **Any scenario requires changing how peering decides authority** | **Not triggered.** No peering, PG log, scrub or backfill code was modified. The prototype adds `src/osd/ReplicaVault.{h,cc}` and two call sites (`ReplicatedBackend::do_repop`, `PrimaryLogPG::remove_missing_object`). Neither changes the PG log, the transaction sent to other replicas, or any PG-collection operation. |
| **Step 1 leaves extending BlueStore (option b) as the only viable mechanism** | **Not triggered.** Option (a) is viable and was built. |
| **The prototype is not passing within the three-week time box** | **Not triggered.** Passing on 2026-09-26, day 2 of the pilot. |

### 1.3 Pass with revised hypotheses

"if step 1 leaves only a copying move (option a)"

This is the applicable branch. Step 1 (`notes/step1-primitive.md`) found no supported copy-free move or clone into a collection outside the PG. Option (c), a hidden entry inside the PG collection, is destroyed by existing Ceph code at three points: boot temp cleanup, scrub rollback cleanup, and stray-PG removal. The revision was committed before building: `docs/revision-1-copying-vault.md`, `90846fc`.

## 2. Evidence

Each row is the latest result file for that scenario and build. Invariants are shown as runs passed / runs.
- **Invariant 3** (vault present and intact) only applies to the prototype. On vanilla it shows "skip".
- **"Objects deleted at end of run"** excludes names that were recreated or restored afterwards. That's why s07 shows 0 and s11 on the prototype shows 8.
- **"Deletes checked against vault"** counts every acknowledged delete matched to an intact vault entry.

| scenario | mode | runs passed | inv 1 | inv 2 | inv 3 | inv 4 | objects deleted at end of run (inv 1) | deletes checked against vault (inv 3) | result file |
|---|---|---|---|---|---|---|---|---|---|
| s01-kill-primary-before-delete | vanilla | 10/10 | 10/10 | 10/10 | skip | 10/10 | 10 | — | `s01-kill-primary-before-delete-20260926T150708.json` |
| s01-kill-primary-before-delete | rv | 10/10 | 10/10 | 10/10 | 10/10 | 10/10 | 10 | 10 | `s01-kill-primary-before-delete-20260926T164515.json` |
| s02-kill-primary-during-delete | vanilla | 20/20 | 20/20 | 20/20 | skip | 20/20 | 20 | — | `s02-kill-primary-during-delete-20260926T162152.json` |
| s02-kill-primary-during-delete | rv | 20/20 | 20/20 | 20/20 | 20/20 | 20/20 | 20 | 20 | `s02-kill-primary-during-delete-20260926T165857.json` |
| s03-kill-primary-after-delete | vanilla | 10/10 | 10/10 | 10/10 | skip | 10/10 | 10 | — | `s03-kill-primary-after-delete-20260926T153649.json` |
| s03-kill-primary-after-delete | rv | 10/10 | 10/10 | 10/10 | 10/10 | 10/10 | 10 | 10 | `s03-kill-primary-after-delete-20260926T172624.json` |
| s04-out-backfill | vanilla | 2/2 | 2/2 | 2/2 | skip | 2/2 | 30 | — | `s04-out-backfill-20260926T154601.json` |
| s04-out-backfill | rv | 2/2 | 2/2 | 2/2 | 2/2 | 2/2 | 30 | 30 | `s04-out-backfill-20260926T174004.json` |
| s05-deep-scrub-with-vault | vanilla | 3/3 | 3/3 | 3/3 | skip | 3/3 | 192 | — | `s05-deep-scrub-with-vault-20260926T155157.json` |
| s05-deep-scrub-with-vault | rv | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 192 | 192 | `s05-deep-scrub-with-vault-20260926T175443.json` |
| s06-recreate-after-delete | vanilla | 5/5 | 5/5 | 5/5 | skip | 5/5 | 20 | — | `s06-recreate-after-delete-20260926T155705.json` |
| s06-recreate-after-delete | rv | 5/5 | 5/5 | 5/5 | 5/5 | 5/5 | 20 | 60 | `s06-recreate-after-delete-20260926T181853.json` |
| s07-repeated-delete-recreate | vanilla | 2/2 | 2/2 | 2/2 | skip | 2/2 | 0 | — | `s07-repeated-delete-recreate-20260926T160044.json` |
| s07-repeated-delete-recreate | rv | 2/2 | 2/2 | 2/2 | 2/2 | 2/2 | 0 | 40 | `s07-repeated-delete-recreate-20260926T183153.json` |
| s08-restart-retainer | vanilla | 6/6 | 6/6 | 6/6 | skip | 6/6 | 24 | — | `s08-restart-retainer-20260926T160222.json` |
| s08-restart-retainer | rv | 6/6 | 6/6 | 6/6 | 6/6 | 6/6 | 24 | 24 | `s08-restart-retainer-20260926T183712.json` |
| s09-pg-split-merge | vanilla | 2/2 | 2/2 | 2/2 | skip | 2/2 | 224 | — | `s09-pg-split-merge-20260926T160911.json` |
| s09-pg-split-merge | rv | 2/2 | 2/2 | 2/2 | 2/2 | 2/2 | 224 | 224 | `s09-pg-split-merge-20260926T184811.json` |
| s10-snapshot-delete | vanilla | 3/3 | 3/3 | 3/3 | skip | 3/3 | 6 | — | `s10-snapshot-delete-20260926T164033.json` |
| s10-snapshot-delete | rv | 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 6 | 6 | `s10-snapshot-delete-20260926T191722.json` |
| s11-manual-restore | vanilla | 2/2 | 2/2 | 2/2 | skip | 2/2 | 20 | — | `s11-manual-restore-20260926T162017.json` |
| s11-manual-restore | rv | 2/2 | 2/2 | 2/2 | 2/2 | 2/2 | 8 | 20 | `s11-manual-restore-20260926T192132.json` |
| s12-retainer-misses-delete | vanilla | 10/10 | 10/10 | 10/10 | skip | 10/10 | 10 | — | `s12-retainer-misses-delete-20260926T193325.json` |
| s12-retainer-misses-delete | rv | 10/10 | 10/10 | 10/10 | 10/10 | 10/10 | 10 | 10 | `s12-retainer-misses-delete-20260926T194714.json` |

Superseded result files (earlier runs of the same scenario and mode):

- s02-kill-primary-during-delete [vanilla]: 20/20 runs passed — `s02-kill-primary-during-delete-20260926T151626.json`
- s03-kill-primary-after-delete [vanilla]: 1/1 runs passed — `s03-kill-primary-after-delete-20260926T150350.json`
- s10-snapshot-delete [vanilla]: 0/3 runs passed — `s10-snapshot-delete-20260926T161747.json`

The superseded runs were:
- **s10 vanilla:** a script bug; `rados -s` printed `selected snap …` into the checksum.
- **s02 vanilla:** the kill delays were retuned into the in-flight window.
- **s03 vanilla:** a single harness debug run.

All are kept, and each is explained in `notes/log.md`.

**Other evidence:**
- **Smoke tests:** `scripts/smoke.sh` passes on vanilla (`results/smoke-20260925T*.json`) and after each prototype rebuild (`results/smoke-20260926T*.json`).
- **Final fsck:** after the whole suite, BlueStore fsck is clean on all 5 OSDs, which together hold 601 vault entries (`results/final-fsck-20260926T200639.json`).
- **Reproducibility:** every scenario is a script under `scripts/scenarios/`, and every result file records its command, timestamp, OSD build and Ceph commit.

**Scenario coverage relative to the proposal (§6 step 5, `CLAUDE.md` Phase 5):**
- Scenarios 1–11 are the pre-registered list.
- **Scenario 12 is an addition.** The rank-1 OSD misses a delete and learns it through log recovery. None of the 11 scenarios exercised the prototype's recovery-path hook, so I added it. It passes on both builds.
- **Scenario 2 hit the race.** In 10 of its 20 prototype runs the primary died while the delete was in flight: `rm` waited 1–3 s for the client to resend. The remaining runs killed before the op was sent (2) or after it completed (8). The vanilla run split 7 / 3 / 10.

## 3. Caveats

1. **The retainer is whichever OSD is at rank 1 when it applies the delete, so it moves under failure.** If the primary dies before the delete, the acting set shrinks and the old rank-2 OSD vaults (s01: 10/10). If the rank-1 OSD misses the delete, the temporary rank-1 OSD vaults through replication and the returning OSD vaults again through recovery, giving **two copies** (s12: 10/10). "The designated replica" in the gate is met in the sense of "the OSD the rule designates at apply time". It is not a fixed OSD per PG.
2. **Coverage gap not triggered but present in the code.** The rank-1 OSD vaults only what it has locally. If it is a backfill target past `last_backfill` (it receives an empty transaction), or is itself missing the object, the delete is not vaulted anywhere (`notes/design-note.md` §§1, 4). This never happened in the suite; every acknowledged delete had at least one copy. It is a real H2 exposure to measure in the full evaluation. Backfill-remove is also deliberately not vaulted in v1.
3. **The copy and the remove are ordered, not atomic.** The first build put both in one BlueStore transaction. That charged vault bytes to the PG's pool and failed BlueStore fsck on every retaining OSD. It was fixed by queuing the vault copy as its own transaction on the same sequencer (`17451c9`). BlueStore submits a sequencer's transactions to the KV store in order (`_txc_finish_io`), so the remove is never durable without the copy. A crash between them can leave a duplicate vault entry, but never a missing one.
4. **Scale and build.** One host, 5 OSDs, file-backed BlueStore with 1 GiB DB files (a harmless BlueFS spillover warning appeared), Debug build. Objects tested were 0 B to 8 MiB, mostly under 4 MiB. Run counts are 2–20 per scenario, meeting the "at least 10" rule for every timing-sensitive scenario. This shows feasibility, not robustness at scale.
5. **Not tested.**
   - A write immediately followed by a delete of the same object while both are in flight. The vault copy reads the object at queue time; I infer, but haven't verified, that this sees the preceding write.
   - Acting sets where the primary is not rank 0 (`primary_temp`).
   - Erasure-coded pools (out of scope).
   - Anything performance-related.
6. **Offline-only access.** Vault entries can only be read with `ceph-objectstore-tool` while the OSD is stopped. Every inspection and restore therefore restarts an OSD (noout set). That is fine for a pilot. For §4.6 (restore) and §4.5 (detection and freeze) it means the eventual restore path needs an online, authority-separated reader.

## 4. Mechanism used, and how it differs from proposal §4.2

| Proposal v2 §4.2 | As built |
|---|---|
| Move without copying into a per-OSD vault collection, reusing snapshot-clone shared blobs | **Copy** (data, xattrs, omap) into a reserved namespace (`replicavault`) of the OSD's existing **meta collection**. BlueStore has no supported cross-collection move or clone (`BlueStore.cc:15859`, `Transaction.h:120–122`, per-collection `SharedBlobSet`). A new collection type or a fake-pool PG collection is riskier than meta (`notes/step1-primitive.md` §2). |
| The remove is rewritten as a move | The remove is **kept unchanged**. A separate vault-copy transaction is queued immediately before it on the same sequencer (caveat 3). |
| Keyed by pool, PG, object name, version, deletion time | As proposed, plus namespace and locator. All user-controlled fields are hex-encoded, because `trim stale osdmaps` deletes any meta object whose name contains `osdmap.` (`OSD.cc:8005–8050`). |
| Retainers chosen per object from the policy file | Fixed rank 1, compile-time constant (pilot scope). |
| Hook where the replica applies the delete | Two hooks: live replication (`do_repop`) and log recovery (`remove_missing_object`). The second was added because a retainer that misses a delete otherwise never vaults it. |

The protected-delete contract (§4.1) holds as written. The PG log records the delete. Peering, recovery, backfill and scrub never list meta (verified in code, `notes/step1-primitive.md` §3, and in s04/s05). A vault copy never became authoritative: 0 resurrections in 75 runs.

## 5. Surprises and consequences for the proposal

1. **H1 (overhead)** is now a copy cost, as pre-registered in revision 1. **Not measured in the pilot.** Two new cost terms for the evaluation:
   - Each retained delete now costs an extra BlueStore transaction on the retaining OSD, plus a synchronous read of the object before the remove.
   - Missed deletes are vaulted twice (caveat 1).
2. **H2 (coverage):** caveat 2 is the main new risk. Coverage under failure depends on the rank-1 OSD having the object when it applies the delete. The attack workloads in §5.2 (host failures mid-attack) should include backfill in progress, because that is exactly where the gap is.
3. **H3 (capacity):**
   - **Duplicates:** retention can hold more than one copy per delete (s12), so retained bytes are not simply deleted bytes × retaining replicas.
   - **Accounting:** vault bytes now land in the meta pool's per-OSD statistics, not the originating pool's. `ceph df` will under-report the capacity held by retention unless it is reported separately. Revision 1 §6 already calls for vault-specific counters.
4. **§10 open question 1** (can a whole PG be moved into the vault as one operation?) **is answered: no.** BlueStore split and merge only change key-range bits and cannot target a non-PG collection. PG-level retention will be a per-object copy of the PG's contents, which matters for pool-deletion and size-reduction retention at scale.
5. **Detection and freeze (§4.5) and restore (§4.6)** need an online vault reader, because the pilot's reader is offline-only (caveat 6).
6. **Engineering notes**, not proposal issues:
   - **Plugin version string:** building two OSD binaries from different commits against shared plugins breaks Ceph's plugin version check. Both builds use `-DENABLE_GIT_VERSION=OFF`.
   - **Silent tool failure:** `ceph-objectstore-tool get-bytes` refuses to overwrite a file but still exits 0.

## 6. Recommendation

**Pass with revised hypotheses**, per the pre-registered decision rule. Proceed with the committed revision 1. Before the full evaluation, I'd add three items:
1. **Close or measure the rank-1 coverage gap** (caveat 2), for example by letting the rank-1 OSD fall back to rank 2 when it lacks the object, or by vaulting on backfill-remove.
2. **An online vault reader** for detection and restore.
3. **Measurements** of the H1a–d thresholds from revision 1 on the real multi-host testbed.

Vlad makes the call.
