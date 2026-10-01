# ReplicaVault phase 2 — report

- **Date:** 2026-09-29.
- **Ceph:** v19.2.3 `c92aebb2`. Pilot prototype `17451c9` (branch `replicavault-pilot`). Phase 2 prototype **`ef0be10`** (branch `replicavault-p2`).
- **Pre-registration:** `PHASE2_CRITERIA.md`, committed 2026-09-28 (`1a01660`) before any phase 2 code and never edited.
- **Clusters:**
  - Correctness runs: the Debug vstart cluster from the pilot (1 MON, 1 MGR, 5 BlueStore OSDs).
  - Cost probe: a separate RelWithDebInfo vstart cluster (1 MON, 1 MGR, 3 OSDs).

**Summary.** All four pre-registered pass/fail criteria are met: coverage, crash consistency, read-after-queue, and the limits. Two findings qualify that:

1. **The pilot described the wrong coverage gap.** The attacks it named (`osd out`, upmap) open no gap. Size 1 and primary-temp do. The fix closes both.
2. **The client is acknowledged without a durable vault copy when the retainer crashes mid-delete.** The pre-delete bytes survive only on the crashed retainer's disk. So contract item 5 of Revision 1a is not enforced in that window, even though the post-restart criterion passes.

The cost probe flags H1b and H1e as at risk. A draft Revision 1b is in §7. The call is yours.

---

## 1. Criteria (`PHASE2_CRITERIA.md`)

| Criterion | Result | Evidence | Caveats |
|---|---|---|---|
| **Coverage (B1).** Every acknowledged delete has at least one intact vault entry, and invariants 1, 2 and 4 hold in every run, across s01–s12 and a01–a05 on the phase 2 prototype. | **Pass** | p2: 17 scenarios, **118/118 runs**. Invariant 3 matched **1,000/1,000** acknowledged deletes to an intact entry: copies made by 1,776 repop, 130 recovery and 24 fallback. Vanilla, same scripts: 118/118 (invariant 3 skipped). Result files: `results/phase2/{s01..s12,a01..a05}-20260928T2*/20260929T0*.json`, log `logs/phase3-full-20260928T*.log`. | Invariant 3 is checked after each run, not at acknowledgement time; see finding 2 (§4). The a01/a02 passes are the pilot mechanism working, not the fix (§3). |
| **Crash consistency (B3).** Across at least 100 crash runs (c01), no acknowledged delete lacks an intact vault entry after restart, and fsck is clean on every OSD. | **Pass** | `c01-crash-under-deletes-20260929T070332.json`: **100/100 runs**, 1,600/1,600 acknowledged deletes with an intact entry after restart. `ceph-bluestore-tool fsck` clean on the killed retainer in 100/100 runs. Modes: 60 default, 20 `bluestore_sync_submit_transaction`, 20 sync plus `bluestore_debug_randomize_serial_transaction=2`. | See finding 2. **Duplicates:** 19 deletes with 2 copies, 1,581 with 1. **Unacknowledged:** none; the client resent every in-flight remove, and 1,405 acks came after the kill. **Coverage gaps:** fsck was run on the killed OSD each run, not on all 5. No BlueStore option *stops* between KV submissions; the two used only change how submissions are grouped (`global.yaml.in:5180`, `:5354`; `BlueStore.cc:14192–14213`). The vanilla validation ran 20 runs, not 100, to save about 5 h. |
| **Read-after-queue (B3).** Across at least 200 runs (c02), the vault entry holds the last write acknowledged or queued before the delete. | **Pass** | `c02-read-after-queue-20260929T122307.json`: **200/200 cases** (10 harness runs × 20 cases), each checked individually by invariant 3. Sizes 4 KiB, 64 KiB, 1, 4 and 8 MiB (40 cases each); 1–4 in-flight `aio_write_full` (50 each); all write and remove rcs 0. Vanilla 200/200 (script validation). | A "run" here is one write/remove case. The full invariant check (scrub, restarts for inspection) ran once per 20 cases. |
| **Limits.** Fail if closing the gap requires changing peering authority, PG log contents, scrub or backfill logic. | **Not triggered** | `ef0be10` touches `ReplicaVault.{h,cc}`, `ReplicatedBackend.cc` and `PrimaryLogPG.cc` (+97/−35). No message, peering, PG log, scrub or backfill change. | Enforcing item 5 in finding 2's window would likely need a message change or a second copy (§4). |
| **Cost probe (A3).** Report only. | Reported (§5) | `cost-probe-*.json` | Indicative, single host. |

## 2. Design implemented

This is design (i) of `notes/b1-design.md`, primary fallback, as you approved it (acting[0] as retainer under primary-temp).

- **`retainer_osd()`** replaces `acting_rank()`. The retainer is element 1 of the acting set reordered primary-first, or the primary itself if the acting set has no other member. `RETAIN_RANK` is still 1.
- **Replicas** vault in `do_repop`, and **any OSD** in `remove_missing_object`, when it is the retainer. This is the pilot's behaviour, now through the new function.
- **New:** the primary vaults in `ReplicatedBackend::submit_transaction` when it is the retainer. The hook runs after `issue_op` has encoded the replicas' transaction and before `log_operation`. The vault copy is its own transaction, queued ahead of `op_t` on the same sequencer, and logged `path=fallback`.

**Differences from `b1-design.md`:**
- The CRUSH mapping inside `retainer_osd` now runs only for transactions whose op headers delete a head. The pilot mapped on every repop.
- The shared loop was factored into `vault_deleted_heads()`.

**Patch series:** `ceph-patch/p2/` (3 patches). On a fresh v19.2.3 clone it reproduces `ef0be10` exactly, commit hash and tree, and builds in 104 s incrementally.

## 3. Attack scenarios before and after the fix

Runs passed, and invariant 3 on the prototype.

| Scenario | Vanilla | Pilot `17451c9` | Phase 2 `ef0be10` | Mechanism |
|---|---|---|---|---|
| a01 rank-1 OSD marked out, backfill held (`nobackfill`) | 10/10 | 10/10, 80/80 vaulted | 10/10 | The out OSD stays in the acting set via `pg_temp` (rank 2); the next complete OSD is rank 1. The backfill target is never in acting (`PeeringState.cc:1742–1747`). |
| a02 upmap rank-1 slot to an empty OSD | 10/10 | 10/10, 80/80 | 10/10 | Same |
| a03 pool size 1 | 3/3 | **0/3, 24/24 unvaulted** | **3/3**, all `path=fallback` | G1: no rank 1. The primary is now the retainer. |
| a04 primary-temp (odd runs: primary at acting[1]) | 10/10 | **5/10**, 25/25 unvaulted on odd runs | **10/10** | G2: rank 1 was the unhooked primary. Now acting[0] vaults via `repop`. |
| a05 rank 1 toggled down/up (duplicate inflation) | 10/10 | 10/10; 2 copies per missed delete; retained/deleted bytes 2.00 | 10/10; 2 copies; 2.00 | Unchanged by design (i) |

`CLAUDE.md` expected a01–a03 to fail on the pilot. a01 and a02 pass because backfill and async-recovery targets are never in the acting set, and any other acting peer missing the object blocks the write until it is recovered (`b1-design.md` §1.2, verified in code and observed). That means the pilot's gap description was wrong (§7, item 1).

## 4. Crash and read-after-queue findings

**Finding 2: acknowledgement before a durable vault copy when the retainer crashes.**

- **What c01 showed.** For 993 of the 1,600 acknowledged deletes, the only intact vault copy was made by the killed retainer **through recovery after it restarted**. Its original staging was lost in the crash, and no other OSD vaulted those deletes.
- **Why, verified in code.** On the interval change, `apply_and_flush_repops` requeues the in-flight client ops (`PrimaryLogPG.cc:12825–12865`). The resent op is a duplicate (`check_in_progress_op`, `:2230–2244`) and is answered once `already_complete` holds (`:15453–15478`). That checks only repops queued in the new interval. The new acting set, primary plus the old rank 2, had applied the remove without vaulting.
- **Consequence.** At acknowledgement time the pre-delete bytes were durable only on the crashed retainer's disk: as its vault entry if that commit landed, otherwise as the not-yet-removed object (the ordering in Revision 1a A1 guarantees one of the two). If that OSD never returned, those deletes would have no copy.
- **Scope.** This affects only deletes in flight at the moment the retainer fails. Deletes issued while it is down are vaulted by the new retainer.
- **No fix attempted.** Options are in `b1-design.md`, "Future work".

**A `replicavault: vaulted` log line marks staging, not durability.** c01 left 148 logged-but-never-durable lines. The harness's invariant 3 already checks the on-disk entry, so no result is affected. But the log alone cannot serve as ground truth for durable copies.

**Read-after-queue holds.** The vault read sees writes queued before the delete in the same PG, including up to 4 in-flight `aio_write_full` of up to 8 MiB (200/200). This confirms the inference in `design-note.md` §7.

**Duplicates:**

| Where | Copies per delete |
|---|---|
| c01 | 1.012 (19 of 1,600 deletes have 2 copies) |
| a05 and s12, deliberately missed deletes | 2.0 |

No delete had more than 2 copies. The bound of one copy per distinct OSD that applies the delete as retainer, at most 3 at size 3, is inferred and untested.

## 5. Cost probe (A3) — indicative, single host

**Setup:**
- **Cluster:** RelWithDebInfo pair (vanilla, and p2 `ef0be10`), built in 34 min. A separate vstart cluster with 3 file-backed BlueStore OSDs on one host, pool `rvcost` (size 3, 32 PGs). The Debug correctness cluster ran idle alongside.
- **Workload:** 16 threads of 4 KiB reads and writes (50/50) over 64 objects. Deletes of 20 objects per size from one PG, one at a time, 2 s apart, so one retainer does all the vault work.
- **Measured:** 4 KiB ops *starting* while a delete is in flight, compared with a 20 s no-delete baseline.
- **Files:** `cost-probe-vanilla-20260929T132837-r1.json` and `cost-probe-p2-20260929T133743-r1.json`. Earlier 6-delete/4-thread runs, too small for p99, are kept alongside.

| Deleted size | Delete p50 vanilla → p2 | Delete p99 vanilla → p2 | 4 KiB p99 during deletes, vanilla → p2 | Ratio |
|---|---|---|---|---|
| 1 MiB | 210 → 287 ms | 269 → 384 ms | 312 → 340 ms | 1.1× |
| 4 MiB | 186 → 394 ms | 405 → 726 ms | 353 → 608 ms | **1.7×** |
| 16 MiB | 208 → 824 ms | 458 → 1,065 ms | 500 → 624 ms | 1.2× |
| 64 MiB | 241 → 1,731 ms | 443 → 2,176 ms | 348 → 1,231 ms | 3.5× |
| 128 MiB | 222 → 2,934 ms | 424 → 3,582 ms | 432 → 2,057 ms | 4.8× |

Baselines match: 4 KiB p99 340 ms on both builds, p50 167 vs 171 ms. 4 KiB ops whose primary was the retainer show the same ratios.

**Limits, plainly:**
- **Absolute numbers are inflated.** The mClock scheduler paces client ops to each OSD's startup-benchmarked HDD capacity (the OSD log shows the benchmark), and file-backed OSDs on one host benchmark low. A 4 KiB op taking 170 ms at p50 is an artefact of that.
- **Only ratios are meaningful.** Both builds ran on the same cluster, with the same settings, minutes apart.
- **Small samples.** Run-to-run variance in the small-sample runs was large (vanilla 1 MiB delete p50 161 vs 259 ms).
- **Not the H1 workloads.** Deletes are sequential, not up to 10% of a mixed stream, and there is no delete-only throughput test.

**What it suggests:**
- **H1b is at risk.** At 4 MiB, 4 KiB p99 is 1.7× vanilla, above the 1.5× threshold. The workload differs from H1b's, so this is not a result.
- **H1e is borderline.** Serial 4 MiB deletes run at about 0.47× vanilla's rate (394 vs 186 ms p50), just under the 50% threshold. This is indirect: H1e is a throughput test, which was not run.
- **Large objects visibly stall the retainer's other ops**, consistent with the synchronous full-object read and copy on the op path (Revision 1a A3). Mitigations, not implemented, are in `b1-design.md` "Future work": chunked copy, moving the read off the op shard, a two-stage vault, a size threshold.

## 6. What changes for the proposal

- **H1:**
  - The copy cost grows with object size: delete latency about 2× vanilla at 4 MiB and about 13× at 128 MiB.
  - Interference with other ops is real above 16 MiB.
  - H1b and H1e (Revision 1a) are at risk. The full evaluation should measure them before the paper commits to the thresholds. The apply-path mitigations are likely needed for the 64–128 MiB range.
- **H2:**
  - The coverage gap is closed for the attacker-triggerable cases found: size 1 and primary-temp.
  - A narrower gap remains. A delete in flight when the retainer fails is acknowledged while its bytes are durable only on that OSD.
  - An attacker who can crash or permanently remove the retainer at the right moment could exploit it. That probably needs host access or a failure, not admin credentials alone, but that is inferred.
- **H3:**
  - Duplicates are bounded at 2 copies per delete in every test, including attacker-induced ones (a05).
  - Retained bytes per deleted byte reached 2.00 under a05.
  - Unchanged from Revision 1a B2.

## 7. Draft Revision 1b (text only; the revision file was not created, per `CLAUDE.md`)

> # Revision 1b to the ReplicaVault proposal: coverage corrected, acknowledgement window, early cost signal
>
> **Status:** DRAFT. Amends Revision 1a (`43cdc17`) and corrects `results/GATE_REPORT.md` §3 caveat 2 and `notes/design-note.md` §§1, 4, all left unedited.
>
> **1b-1. The coverage gap (corrects Revision 1a B1 and GATE_REPORT caveat 2).** The pilot's retention rule could leave a delete unvaulted in exactly two cases:
>
> - **G1:** the acting set had no rank 1 (pool size 1, or min_size 1 with the other replicas down).
> - **G2:** `primary_temp` placed the primary at acting rank 1, and the primary never vaulted.
>
> It could **not** leave a delete unvaulted because rank 1 was a backfill target or missing the object. Backfill and async-recovery targets never enter the acting set, and a write blocks until every other acting peer holds the object. The attacks listed in Revision 1a B1 therefore change as follows:
>
> - Remove: "mark the rank-1 OSD out, or remap its PGs with pg-upmap-items or pg-temp, so rank 1 becomes a backfill target" (phase 2 a01/a02: no gap).
> - Keep: "reduce pool size to 1" (a03) and "shape acting sets with primary-temp" (a04).
> - Primary affinity does not create G2, because it moves the primary to acting[0].
>
> The mechanism (phase 2 prototype `ef0be10`): the retainer is element 1 of the acting set ordered primary-first, or the primary when it is alone, and the primary vaults when it is the retainer.
>
> **1b-2. Contract item 5 under a retainer crash (amends Revision 1a B1).** When the retaining OSD fails while a delete is in flight, the new acting set acknowledges the delete without any OSD holding a durable vault copy. The pre-delete bytes are then durable only on the failed retainer, as its vault entry or as the unremoved object, and are vaulted when it returns (phase 2 c01: 993 of 1,600 deletes). Item 5 is restated as:
>
> > **5.** An acknowledged delete implies that its pre-delete state is durable on the retaining OSD, as a vault copy or as the not-yet-removed object that the retainer vaults when it applies the delete. If the retaining OSD is lost permanently between applying and vaulting, deletes in flight at that moment are not retained.
>
> The stronger form, a durable vault copy before the acknowledgement on every path, needs either a second copy staged before the non-retainers remove, or an acknowledgement that waits for the retainer's confirmation. It is left as an option for the full design (`notes/b1-design.md`, "Future work").
>
> **1b-3. Log lines are not durability.** A `replicavault: vaulted` log line is written when the copy is staged, before it commits. Evaluations must count vault copies from the store, not the log.
>
> **1b-4. Early cost signal (informs Revision 1a A3; thresholds unchanged).** A single-host indicative probe measured, relative to vanilla:
>
> - **4 KiB p99 interference:** 1.7× at 4 MiB deletes.
> - **Delete latency:** 2.1× at 4 MiB, 13× at 128 MiB.
> - **Serial 4 MiB delete rate:** 0.47×.
>
> H1b (1.5×) and H1e (50%) are at risk. The full evaluation measures them on the multi-host testbed with the RelWithDebInfo build. The design adds a mitigation for the synchronous full-object read before objects above 16 MiB are evaluated.


---

## Addendum, 2026-09-30: c03, F1, and reruns

Written after Vlad's decisions on this report. Sections 1–7 above are left as written.

**c03** (retainer killed during deletes, marked out, PGs recovered elsewhere, then purged as a stray on return) **lost data on the phase 2 build**: 261 of 320 acknowledged deletes, 19 of 20 runs (`c03-…-20260929T153224.json`). That is finding 2 in its strongest form.

The cause is verified in code. A returning OSD whose PGs moved away is a stray: it receives no log, and its copy is removed by `do_delete_work` without any vault (`notes/b1-design.md` §6).

**F1** (`05289b5`, Vlad's choice): the primary also vaults every delete.

| | Result |
|---|---|
| c03 | **20/20 runs, 0 of 320 lost**; 253 deletes survived only through the primary's copy |
| c01 (rerun) | 100/100 runs; fsck clean 100/100; **0 of 3,282 `vaulted` lines without a durable copy** |
| Log fix (`25b9d8d`) | Confirmed by the c01 rerun above; before the fix, 148 lines had no copy |
| Full regression (s01–s12, a01–a05) | **118/118 runs, 1,000/1,000 deletes vaulted** |

Costs of F1:

- **Copies:** 2 per delete in steady state; 3 per deliberately missed delete (a05: retained / deleted bytes 3.00, against 2.00 before F1).
- **Latency (indicative):**

| Deleted object | Delete p50, F1 ÷ vanilla | 4 KiB p99 during deletes, F1 ÷ vanilla |
|---|---|---|
| 1 MiB | 1.3× | 1.1× |
| 4 MiB | 2.3× | 1.2× |
| 16 MiB | 5.0× | 1.6× |
| 64 MiB | 11.5× | 7.5× |
| 128 MiB | 22× | 11× |

**Patch series.** `ceph-patch/p2/` (5 patches) reproduces `05289b5` exactly on a fresh v19.2.3 clone, and builds in 110 s incrementally.

**Revision 1b:** contract item 5 carries a proposed restatement (F1 guarantees a durable copy at acknowledgement under any single OSD failure; that is inferred, and tested by c03 and c01). It awaits Vlad.
