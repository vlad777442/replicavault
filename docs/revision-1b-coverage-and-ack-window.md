# Revision 1b to the ReplicaVault proposal: coverage corrected, acknowledgement window, measured cost ratios

**Status:** APPROVED by Vlad on 2026-10-02, including the restated contract item 5 (limited to the tested cases: c01, c03, c04). Frozen from this commit on, like Revisions 1 and 1a.

- Date: 2026-09-29
- Amends: Revision 1a (`docs/revision-1a-ordered-vault.md`, `43cdc17`). It corrects `results/GATE_REPORT.md` §3 caveat 2 and `notes/design-note.md` §§1 and 4, all left unedited.
- Ceph commits: v19.2.3 `c92aebb2`; pilot `17451c9`; phase 2 `ef0be10` (primary-first retainer and primary fallback), `25b9d8d` (log line at commit) and `05289b5` (F1: the primary also vaults every delete).
- Scenarios behind item 5: c01, c03, c04 (`results/phase2/c01-…-20260929T222223`, `c03-…-20260929T194803`, `c04a-…-20261001T200538`, `c04b-…-20261001T235554`).
- Evidence:
  - `results/phase2/PHASE2_REPORT.md`
  - `notes/b1-design.md` §§1 and 5
  - `results/phase2/{a01..a05,c01,c02,cost-probe}-*.json`

Everything here is written after the phase 2 runs. None of it is pre-registration.

---

## 1b-1. The coverage gap (corrects Revision 1a B1 and GATE_REPORT §3 caveat 2)

The pilot's retention rule (acting-set rank 1) could leave an acknowledged delete unvaulted in exactly two cases:

- **G1:** the acting set has no rank 1. This happens with pool size 1, or with min_size 1 when the other replicas are down.
- **G2:** `primary_temp` places the primary at acting rank 1. It changes the primary without reordering the acting set (`src/osd/OSDMap.cc:2870–2873`), and the pilot never vaulted on the primary.

It could **not** leave a delete unvaulted because rank 1 was a backfill target or was missing the object:

- **Backfill targets** never enter the acting set (`src/osd/PeeringState.cc:1742–1747`).
- **Async-recovery targets** never enter it either (`:2276–2285`).
- **A write blocks** until every other acting peer holds the object (`src/osd/PrimaryLogPG.cc:636–671`, `:2178–2187`).

Phase 2 attack results on the pilot prototype:

| Scenario | Result on pilot | Gap |
|---|---|---|
| a01 (rank-1 OSD marked out) | 10/10 pass | none |
| a02 (upmap to an empty OSD) | 10/10 pass | none |
| a03 (size 1) | 24/24 deletes unvaulted | G1 |
| a04 (primary-temp at acting[1]) | 25/25 deletes unvaulted | G2 |

The attacks listed in Revision 1a B1 change as follows:

- **Remove:** "mark the rank-1 OSD out, or remap its PGs with `ceph osd pg-upmap-items` or `pg-temp`, so rank 1 becomes a backfill target, then delete during backfill".
- **Keep:** "reduce pool size to 1".
- **Keep, made precise:** "shape acting sets with `primary-temp`", meaning the case where primary-temp moves the primary to acting rank 1. Primary affinity does not cause G2: `_apply_primary_affinity` moves the primary to position 0 (`OSDMap.cc:2842–2847`).

**Mechanism (phase 2, `ef0be10`).** The retainer is element 1 of the acting set ordered primary-first, or the primary itself when the acting set has no other member. The primary vaults locally when it is the retainer (log `path=fallback`). There is no message, peering, PG log, scrub or backfill change. On the phase 2 prototype, a01–a04 pass 33/33 runs, and s01–s12 still pass 75/75.

## 1b-2. Contract item 5 under a single-OSD failure (amends Revision 1a B1)

**Observed (phase 2 c01, 100 runs).** When the retaining OSD crashes while deletes are in flight, the new acting set acknowledges them without any OSD holding a durable vault copy.

- **Why:** on the interval change, `apply_and_flush_repops` requeues the in-flight client ops (`PrimaryLogPG.cc:12825–12865`). The resent op is a duplicate (`check_in_progress_op`, `:2230–2244`), and it is answered once `already_complete` holds (`:15453–15478`). The remaining acting members had removed the object without vaulting it.
- **Where the bytes are:** at acknowledgement they are durable only on the crashed retainer, as its vault entry or as the not-yet-removed object (Revision 1a A1's ordering guarantees one of the two).
- **Scale:** in c01, 993 of 1,600 acknowledged deletes were vaulted only when the retainer returned and applied them through recovery.

**Open question, answered by c03.** Does that hold when the retainer returns *not* as an acting member but as a stray, after its PGs were remapped and recovered elsewhere?

- **Code, verified:** a returning OSD that is neither up nor acting is placed in `stray_set` (`PeeringState.cc:340–346`). It receives no log, because `activate` sends logs only to `acting_recovery_backfill` (`:2748–2850`). `purge_strays` sends `MOSDPGRemove` (`:241–270`), and `do_delete_work` removes every object directly (`PG.cc:2716–2762`), not through `remove_missing_object`.
- **Prediction, inferred:** deletes whose only durable pre-delete bytes were the retainer's unremoved object are lost.

**c03 result** (`results/phase2/c03-retainer-out-during-deletes-*.json`). Per run, the retainer is killed during a stream of 16 deletes, marked out, recovered around, then restarted and purged as a stray.

- **Before the fix** (`25b9d8d`): **164 of 320 acknowledged deletes lost** (18 of 20 runs; corrected after an on-disk recheck). The log-based check first reported 261; the other 97 had durable but unlogged retainer copies (`notes/b1-design.md` §6.4). All the losses are among the 263 deletes acknowledged after the kill.
- **With fix F1** (`05289b5`, the primary also vaults every delete): **0 of 320 lost** (20 of 20 runs). 230 survived only through the primary's copy.

Restatement:

> **5.** On the phase 2 prototype with F1 (`05289b5`), in the single-OSD failures tested, every acknowledged delete had an intact vault copy, holding its pre-delete bytes, on an OSD that survived. The check was made after recovery. Pool size 3, min_size 2; 16 concurrent deletes of 4 KiB–8 MiB objects in one PG:
> - retainer killed, returning into the acting set (c01): 1,600/1,600, 100 runs;
> - retainer killed, marked out, returning as a stray (c03): 320/320, 20 runs. Before F1: 164/320 lost, 18 of 20 runs;
> - primary killed, marked out, returning as a stray (c04 A): 320/320, 20 runs;
> - primary killed, never returning, surviving OSDs only (c04 B): 320/320, 20 runs.
>
> Not tested: failure of the third replica; two or more OSD failures; device loss; other pool sizes; erasure-coded pools; other workloads. The tests check for a copy *after recovery*, not at the moment of acknowledgement. A durable copy *at* acknowledgement, and coverage of every single-OSD failure, follow from the code's ordering (the ack waits for the primary's commit; each vault copy is queued ahead of its OSD's remove) but are not shown.

The copy-count consequences for H1 and H3 (two copies per delete) are a proposal-level decision. The proposal's asymmetric retention (§4.2) would let the primary's copy carry a short window.

## 1b-3. The vault log line records durability

A `replicavault: vaulted` line was written when the vault copy was staged, before it committed. c01 left 148 lines for copies that a crash lost. From `25b9d8d` on, the line is emitted from the vault transaction's commit callback. Evaluations should still count vault copies from the store, not the log.

## 1b-4. Measured cost ratios (informs Revision 1a A3; no thresholds applied)

Indicative, single host. RelWithDebInfo build; 3 file-backed BlueStore OSDs; mClock scheduling; 16 threads of 4 KiB reads and writes; 20 sequential deletes per size from one PG. This is not the H1b or H1e workload.

| Deleted object size | Delete latency p50, phase 2 ÷ vanilla | Delete latency p99, ratio | 4 KiB op p99 during deletes, ratio |
|---|---|---|---|
| 1 MiB | 1.4× (287 / 210 ms) | 1.4× | 1.1× (340 / 312 ms) |
| 4 MiB | 2.1× (394 / 186 ms) | 1.8× | 1.7× (608 / 353 ms) |
| 16 MiB | 4.0× (824 / 208 ms) | 2.3× | 1.2× (624 / 500 ms) |
| 64 MiB | 7.2× (1,731 / 241 ms) | 4.9× | 3.5× (1,231 / 348 ms) |
| 128 MiB | 13× (2,934 / 222 ms) | 8.4× | 4.8× (2,057 / 432 ms) |

Baselines without deletes matched: 4 KiB p99 340 ms on both builds. Serial 4 MiB deletes ran at 0.47× the vanilla rate. Absolute latencies are inflated by mClock pacing to each file-backed OSD's benchmarked HDD capacity; only the ratios carry information. The full evaluation measures H1b and H1e on the multi-host testbed.

## What does not change

- The pilot gate result.
- `PILOT_CRITERIA.md`, `PHASE2_CRITERIA.md`, and Revisions 1 and 1a (all frozen).
- The threat model, H2 and H3 as stated, and contract items 1–4.
