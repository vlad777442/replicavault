# B1 design: making "acknowledged delete ⇒ durable vault copy" hold

Ceph v19.2.3 `c92aebb2`; pilot prototype `17451c9` (branch `replicavault-pilot`). Paths are relative to `/data/ceph/src`. Written 2026-09-28 (phase 2, Phase 2).
**Verified** = I read the code at the cited lines. **Inferred** = reasoned, not read end to end.

Status: complete for the Phase 2 STOP (2026-09-28). The recommendation in §3 awaits Vlad.

## 1. The three facts CLAUDE.md asks to verify

### 1.1 A primary never applies a client delete to an object it is itself missing — **verified**

`PrimaryLogPG::do_op` checks, before any write executes:

- `is_unreadable_object(head)` → `wait_for_unreadable_object` (`osd/PrimaryLogPG.cc:2160–2174`).
  - `is_unreadable_object` is `is_missing_object(oid) || !missing_loc.readable_with_acting(…)` (`osd/PrimaryLogPG.h:1848–1852`).
  - `is_missing_object` looks the object up in the primary's own missing set (`PrimaryLogPG.cc:594–597`).
- For write-ordered ops, `is_degraded_or_backfilling_object(head)` → `wait_for_degraded_object` (`PrimaryLogPG.cc:2178–2187`). That function (`:636–671`) returns true when:
  - the primary is missing the object;
  - or any peer in `acting_recovery_backfill` that is **not** an async-recovery target has the object in its `peer_missing`;
  - or the object is being backfilled right now.

So the primary recovers the object, or waits, before the delete runs. It also waits for every non-async peer that is missing it.

### 1.2 At issue time the primary knows which peers get an empty transaction — **verified**, with one refinement

`generate_subop` sends an empty transaction iff `should_send_op(peer, soid)` is false (`osd/ReplicatedBackend.cc:976–979`). `PrimaryLogPG::should_send_op` (`PrimaryLogPG.cc:549–576`) returns false only in two cases:

- **(a) Backfill target past `last_backfill`.** The object is beyond both `last_backfill_started` and the peer's `last_backfill`. The code asserts `is_backfill_target(peer)` here (`:559`).
- **(b) Async-recovery target missing the object** (`:568–574`).

This is exactly what the peer applies: it decodes and queues whatever it was sent (`ReplicatedBackend.cc:1100`, `:1156–1160`). So the primary's per-peer view at issue time equals what each peer applies.

**The refinement, which corrects `design-note.md` §§1 and 4.** Neither kind of peer is ever in the **acting** set. The rank rule is computed on the acting set, via `OSDMap::pg_to_up_acting_osds` (`osd/ReplicaVault.cc`, `acting_rank`).

- **Backfill targets:** `PeeringState::calc_replicated_acting` sends an up-set OSD that is incomplete, or too far behind, to `backfill` and not to `want` (`osd/PeeringState.cc:1742–1747`). The old, complete OSDs stay in the acting set through `pg_temp`.
- **Async-recovery targets:** `choose_async_recovery_replicated` removes them from `want` (`PeeringState.cc:2276–2285`).
- **Other acting peers missing the object:** the write blocks until they are recovered (§1.1).

**Consequence:** under the pilot rule, acting rank 1 always holds the object when it applies a delete. The pilot's coverage gap is **not** "rank 1 is a backfill target". It is these two cases:

- **G1: there is no rank 1.** The acting set has one OSD: pool `size 1`, or `min_size 1` with the other replicas down.
- **G2: rank 1 is the primary.** `primary_temp` changes the primary without reordering the acting set (`osd/OSDMap.cc:2870–2873`), so the primary can sit at acting rank 1. The pilot hooks only the replica path (`do_repop`) and recovery. The primary applies its own PG transaction through `submit_transaction` and never vaults.

Primary affinity does **not** cause G2: `_apply_primary_affinity` shifts the chosen primary to position 0 for replicated pools (`OSDMap.cc:2842–2847`).

**Observed on vanilla** (a01 run 1): after `ceph osd out` of rank-1 osd.0, up = [3, 1, 2] and acting = [3, 1, 0]. The out OSD stayed in the acting set through `pg_temp`, now at rank 2, and backfill target osd.2 was not in the acting set at all. With primary-temp set to acting[1] (a04), the acting set stayed [1, 3, 0] and the primary became osd.3.

### 1.3 The client ack waits for the primary's own local transactions — **verified**

- **Who must commit.** `ReplicatedBackend::submit_transaction` puts every shard in `acting_recovery_backfill`, the primary included, into `waiting_for_commit` (`ReplicatedBackend.cc:510–512`). The primary registers `C_OSD_OnOpCommit` on its own PG transaction (`:540–542`).
- **When the ack fires.** `op_commit` removes the primary from that set (`:569`) and calls `on_all_commit` only when it is empty (`:571–573`). That leads to `repop_all_committed` → `eval_repop` → the client reply (`PrimaryLogPG.cc:11321–11348`).
- **Ordering.** A vault transaction queued on the same collection handle before the PG transaction is on the same OpSequencer. `_txc_finish_io` submits that sequencer's transactions to the KV store in order (`os/bluestore/BlueStore.cc:14266`), so the PG transaction's commit implies the vault copy's. The PG transaction's `on_commit` fires only after its own KV commit; that last step is **inferred**, and c01 tests it.
- **Replicas.** A replica acks after its `rm->opt` commits (`repop_commit`), with the same ordering argument.

So, wherever the vault copy is made, primary or retaining replica, the client ack implies it is durable.

## 2. Designs

| | (i) Primary fallback | (ii) Retainer confirmation | (iii) Vault on every replica |
|---|---|---|---|
| **Rule** | Retainer = first acting OSD that is not the primary; if none, the primary. The primary vaults locally iff it is the retainer. | Retainers set a flag in `MOSDRepOpReply`; with no flag, the primary vaults (or delays the ack) | Every acting OSD holding the object vaults, primary included |
| **Contract item 5 under G1 (acting size 1)** | Yes: the primary is the retainer and vaults before its own commit | Only with a primary fallback as well, since there are no replies | Yes, if the primary is included |
| **… under G2 (primary-temp)** | Yes: the retainer is the other replica at the front of the acting set, vaulted by the existing replica hook | Yes | Yes |
| **… under s01–s12** | Unchanged from the pilot: retainer = acting[1] whenever acting[0] is the primary, which is always the case without primary-temp | Unchanged, plus flags | Yes, three copies |
| **Duplicates** | Same as pilot: a missed delete is vaulted again through recovery (s12, a05). None added. | Same as (i), plus a fallback copy whenever a flag is lost or late | Every delete, ×(acting size) |
| **Message / peering change** | None | New field in `MOSDRepOpReply`, needs your approval | None |
| **H1/H3 cost** | Unchanged (one copy per delete) | Unchanged, plus reply bytes | ×3 at size 3 |
| **Files touched** | `ReplicaVault.{h,cc}` (retainer function), `ReplicatedBackend::submit_transaction` (primary hook, after `issue_op`), `do_repop` and `remove_missing_object` (use the retainer function) | Those, plus `messages/MOSDRepOpReply.h` encode/decode and version, `ReplicatedBackend::do_repop_reply` and `repop_commit` | `ReplicaVault.cc` (rule), plus the primary hook as in (i) |
| **Rough size** | ~60–90 lines | ~150–250 lines, plus compatibility handling | ~40 lines |

### 2.1 (i) in detail

**The retainer function.** `retainer_osd(osdmap, pgid)` takes the acting set from `pg_to_up_acting_osds`, puts `acting_primary` first, and returns element 1 if it exists, else the primary. Every OSD computes the same answer from the same map epoch: a repop is only applied in the interval it was issued in, `ReplicatedBackend.cc:1080`.

- Without primary-temp this is exactly the pilot's acting rank 1.
- `RETAIN_RANK` stays 1, now meaning "rank in the primary-first acting order".

**The hooks:**

| Path | Who vaults | Change from the pilot |
|---|---|---|
| Live delete on a replica (`do_repop`) | The OSD itself, if it is the retainer | Now uses `retainer_osd` |
| Live delete on the primary (`submit_transaction`) | The primary, if it is the retainer | **New.** Runs `deleted_heads` on `op_t` after `issue_op` has encoded the replica copies. The vault copy is queued as its own transaction on `ch` before `queue_transactions`. Logged `path=fallback`. |
| Recovery-delete (`remove_missing_object`, primary and replicas) | The OSD, if it is the retainer | Now uses `retainer_osd` |
| Whiteout (remove + create) | Same hooks, same retainer | None; `deleted_heads` already recognises the pattern |

**The G1 recovery case.** A primary alone in its acting set that learns of a missed delete through recovery now vaults, because it is the retainer.

**Side effect under primary-temp:** the retainer is acting[0], not acting[1]. This is still one copy per delete, on a replica.

### 2.2 Why not (ii)

Given §1.2, acting rank 1 never lacks the object. The only failures are G1 (no replica, so no reply to carry a flag) and G2 (the retainer is the primary). (ii) needs the primary fallback for G1 anyway, and fixes G2 with a message change that (i) avoids. Its one advantage is robustness if §1.2 were wrong. c01 and the a-scenarios test that instead.

### 2.3 Why not (iii)

It closes the gap with no reasoning about acting sets at all. But it triples the H1 read-and-write cost and the H3 capacity at size 3, which the proposal's asymmetric-retention story (rank 1: 30 minutes, rank 2: 24 hours) never intended.

## 3. Recommendation

**(i), with the primary-first retainer function.**
- **Coverage:** closes G1 and G2 with no message, peering, PG log, scrub or backfill change.
- **Cost:** keeps one copy per delete.
- **Size:** about a day of work, within the Phase 3 estimate.

Expected Phase 3 outcome: a03 and a04 pass invariant 3; a01, a02 and s01–s12 are unchanged; a05's duplicate profile is unchanged.

## 4. Open points for Vlad

1. **The retainer under primary-temp** becomes acting[0] rather than acting[1]. Acceptable, or should the retainer stay acting[1], meaning the primary vaults under primary-temp?
2. **`design-note.md` §§1 and 4, and `GATE_REPORT.md` caveat 2** state the gap as "rank 1 is a backfill target". That is wrong (§1.2). `GATE_REPORT.md` is frozen, so the correction belongs in the phase 2 report and, if you agree, a Revision 1b note. Revision 1a B1 lists "mark the rank-1 OSD out, or remap its PGs … so rank 1 becomes a backfill target" as attacks. The a01/a02 results in §5 show whether they open a gap.

## 5. Attack results on the pilot prototype

Every attack script passed first on vanilla (invariant 3 skipped), and was then run on the pilot prototype `17451c9`. Results are in `results/phase2/`.

| Scenario | Vanilla | Pilot `17451c9` | Invariant 3 on pilot | What happened |
|---|---|---|---|---|
| a01 rank 1 marked out (`nobackfill` held the window) | 10/10 | **10/10 pass** | 80/80 deletes vaulted | The out OSD stayed in the acting set through `pg_temp`, moved to rank 2. The old rank-2 OSD became rank 1 and vaulted every delete via `repop`. The backfill target was in up, never in acting. Run 1: up [0, 2, 4], acting [0, 2, 1]; osd.2 vaulted 8/8. |
| a02 upmap rank-1 slot to an empty OSD | 10/10 | **10/10 pass** | 80/80 | Same mechanism: the upmapped OSD is a backfill target outside the acting set. |
| a03 pool size 1 (`rvsz1`) | 3/3 | **0/3 fail** | **24/24 unvaulted** | Acting is a single OSD (e.g. `acting=[4] primary=4`): no rank 1, no `vaulted` line anywhere. Invariants 1, 2 and 4 held. Gap **G1**. |
| a04 primary-temp | 10/10 | **5/10** | Slot 1: **25/25 unvaulted**. Slot 2: 25/25 vaulted | Slot 1 moves the primary to acting[1] (e.g. `acting=[0, 4, 1] primary=4`): the rule's retainer is the primary, which the pilot never hooks. Slot 2 (`acting=[0, 1, 2] primary=2`): rank 1 is a replica and vaults. Gap **G2**. |
| a05 duplicate inflation (3 rounds × 4 deletes, rank 1 killed each round) | 10/10 | 10/10 | 120/120 vaulted | Every missed delete got **exactly 2 copies**: the temporary rank 1 via `repop`, and the returning OSD via recovery. Retained / deleted bytes = **2.00** in every run. It does not compound. The upper bound is one copy per distinct OSD that applies the delete while it is the retainer, so at most 3 at size 3. **Inferred, not tested.** |

**CLAUDE.md expected a01–a03 to fail.** a01 and a02 pass, for the reason in §1.2: backfill targets, and async-recovery targets, never enter the acting set (`PeeringState.cc:1742–1747`, `:2276–2285`). Any other acting peer missing the object blocks the write until it is recovered (`PrimaryLogPG.cc:636–671`, `:2178–2187`). So under the pilot rule, acting rank 1 always holds the object.

The model in `design-note.md` §§1 and 4, and `GATE_REPORT.md` caveat 2, was wrong on this point. It is right that a backfill target past `last_backfill` gets an empty transaction. It is wrong that such an OSD can be rank 1. The real gaps are G1 (a03) and G2 (a04, odd runs), and both are attacker-triggerable with admin credentials:

- G1: `ceph osd pool set <pool> size 1 --yes-i-really-mean-it`, which needs `mon_allow_pool_size_one`, itself settable by the same admin.
- G2: `ceph osd primary-temp <pg> <acting[1]>`, which needs `require_min_compat_client` of firefly or later.

Design (i) closes both without any message change.

## 6. Finding 2: loss of the retainer mid-delete (phase 2 c01, c03) — fix proposals, NOT implemented

### What happens (verified in code; observed)

1. The primary sends a delete to both replicas. Each OSD applies it in its own transaction; only the retainer R vaults first.
2. R is killed after the other two have applied the remove, but before R's vault copy commits.
3. On the interval change, the primary requeues the in-flight client op (`apply_and_flush_repops`, `PrimaryLogPG.cc:12825–12865`). The resent op is a duplicate (`:2230–2244`) and is acknowledged once `already_complete` holds (`:15453–15478`). The new acting set does not include R, and nobody in it vaulted.
4. At that moment the pre-delete bytes are durable only on R, as its unremoved object.
   - **R returns as an acting member** (c01, noout): it applies the delete through log recovery, `remove_missing_object` vaults it (`path=recovery`), and nothing is lost (c01: 993 of 1,600 deletes).
   - **R's PGs were remapped** (`out`, or down past `mon_osd_down_out_interval`): R returns as a stray. It receives no log (`activate` sends logs only to `acting_recovery_backfill`, `PeeringState.cc:2748–2850`). It is added to `stray_set` (`:340–346`) and purged (`purge_strays`, `:241–270`, then `MOSDPGRemove`, then `do_delete_work`, `PG.cc:2716–2762`). That removes every object directly, so **the bytes are gone** (c03, §6.1).

So contract item 5 fails in the strongest sense: an acknowledged delete with no copy anywhere. It needs a single OSD failure plus the OSD staying out long enough for recovery to finish, which is the default after 10 minutes down.

### 6.1 c03 evidence

`results/phase2/c03-retainer-out-during-deletes-20260929T153224.json` (p2 `25b9d8d`, 20 runs) and `…-20260929T150311.json` (vanilla, 5 runs, script validation):

- **p2: 1/20 runs pass by the log-based check. 164 of 320 acknowledged deletes have no vault copy anywhere after the run; 18 of 20 runs lost data.**
  - *Correction 2026-10-01:* the log-based check first reported 261 lost.
  - 97 of those had an intact vault entry on the retainer, holding exactly the pre-delete bytes. It was durable but never logged: the retainer was killed after the vault txc's kv commit and before its on_commit callback wrote the `vaulted` line (`BlueStore.cc:14457–14467`, `os/Transaction.h:46–49`).
  - Verified by listing every OSD's vault entries and checksumming them; see §6.4.
- **The losses are among the deletes acknowledged after the retainer was killed:** 164 of those 263 have no copy anywhere, and none acknowledged before the kill was lost.
  - The kill landed 0.29–1.41 s into a stream of 16 simultaneous removes. Most were still queued behind the retainer's vault copies of objects up to 8 MiB.
  - The one clean run (run 6) had all 16 acknowledged before the kill.
- **Strays were purged in 20/20 runs**, and invariants 1, 2 and 4 held in 20/20.
- **Run 1 in detail:** retainer osd.0 killed at 1.08 s; 11 of 16 deletes acknowledged after the kill; 10 of 16 without any copy. The 6 that survived were vaulted by osd.0 before the crash. With the log fix, `vaulted` lines are durable copies, and none exists for the lost deletes.
- **Vanilla:** 5/5 pass, but vanilla deletes all finish before the kill (no vault work), so vanilla does not exercise the window.

### 6.2 Fix options

The root cause: between the non-retainers applying the remove and the retainer's vault commit, one OSD holds the only copy, and the acknowledgement does not wait for it. Any fix must keep a second durable copy until the retainer's copy is durable, or make the acknowledgement wait for it.

| | Mechanism | Closes c03? | Copies per delete (steady state) | Message / peering change | Rough size |
|---|---|---|---|---|---|
| **F1** | **Primary also vaults every delete** (two retainers: the primary and `retainer_osd`). Uses the same `path=fallback` hook in `submit_transaction` with the condition dropped; the primary's copy is queued ahead of its `op_t`, and the ack waits for the primary's commit (§1.3). | Yes, for any single OSD failure (**inferred, not tested**). If R dies, the primary's copy is durable before the ack. If the primary dies after R received the repop, R's copy is durable before R's commit. If the primary dies before R received it, R later applies the delete through recovery and vaults; until then its unremoved object is the only copy. That window needs a second failure (R lost too) to lose data. | 2 | None | ~10 lines on top of `ef0be10` |
| **F2** | **Rank 2 also vaults** (two replica retainers). | Yes for acting size 3. With acting size 2 (one OSD already down) it falls back to one copy. | 2 | None | ~10 lines |
| **F3** | **Provisional copy on the primary, released on confirmation.** Primary vaults as in F1; R sets a "vaulted" flag in `MOSDRepOpReply`; the primary drops its provisional copy when the flag arrives. | Yes | 1 (2 transiently) | **Yes**: a new `MOSDRepOpReply` field, plus an internal release of the provisional copy, which must be kept distinct from vault release (no admin-reachable release path). | ~150–250 lines |
| **F4** | **Vault on stray purge.** In `do_delete_work`, vault the objects being removed. | Only this path; not a primary loss, and not any other way the only copy disappears. | 1 | None, but every stray purge vaults the whole PG. That is PG-level retention, out of v1 scope, at a cost of the whole PG per remap. | Large |
| **F5** | **Replay deletes to strays before purging.** The primary sends the stray its log delta so it applies the deletes through `remove_missing_object` (and vaults) before `MOSDPGRemove`. | This path | 1 | **Yes: peering/stray handling.** Outside the phase 2 limits. | Large |

**Recommendation: F1 (primary plus retainer).**
- **Coverage:** closes c03 under any single OSD failure.
- **Scope:** no message, peering, PG log, scrub or backfill change, and it reuses the phase 2 hook.
- **Cost:** doubles H1's copy cost and H3's retained bytes.

It also fits the proposal's asymmetric retention (§4.2: "rank 0 reclaims immediately, rank 1 retains 30 minutes, rank 2 retains 24 hours"). The primary's copy can have a short window, just long enough to cover the retainer's commit, and the retainer keeps the long one. The window is a reclaimer-policy question, not a v1 one. F3 is the steady-state 1-copy version, if the doubled cost matters more than a message change. F4 and F5 are listed for completeness; neither fits the limits.

### 6.3 F1 implemented and tested (Vlad approved F1, 2026-09-29)

`05289b5` on `replicavault-p2`: the primary vaults every head a transaction deletes (`path=primary`; `path=fallback` when it is the retainer), and the recovery path vaults on the primary as well as on the retainer. 4 files, +30/−21.

- **Smoke:** 16 deletes gave 16 `primary` + 16 `repop` copies, two per delete.
- **c03 on F1** (`c03-retainer-out-during-deletes-20260929T194803.json`): **20/20 runs pass; 0 of 320 acknowledged deletes lost.** 319 of the 320 were acknowledged after the retainer was killed.
  - 230 survived **only** through the primary's copy (the logged count was 253; 23 of those also have an unlogged retainer copy, §6.4).
  - 32 more have the primary's and the retainer's logged copies.
  - 23 have the primary's plus a `repop` copy from the OSD that became retainer after the interval change.
  - 12 have the primary's plus a `recovery` copy.
  - Strays were purged in 20/20; invariants 1, 2 and 4 held in 20/20.
- **Before F1** (`…T153224`): 164 of 320 lost (corrected from 261, §6.4).

### 6.4 Durable but unlogged vault copies (2026-10-01)

Since `25b9d8d`, the `vaulted` log line is written by the vault txc's on_commit context. BlueStore queues that context to the PG shard's commit queue, or its finisher, **after** the kv commit (`_txc_committed_kv`, `os/bluestore/BlueStore.cc:14457–14467`; queue set per PG at `osd/OSD.cc:5368`; `on_commit` semantics in `os/Transaction.h:46–49`). A SIGKILL between the two leaves a durable vault entry with no log line. The harness found copies only through log lines, so it undercounted.

- **c01 on F1** (`…T222223`): 69 deletes appeared to have one copy, held by the primary (`path=primary`).
  - Each also has an intact entry on the retainer that holds its pre-delete bytes, checksum-verified (69/69).
  - The retainer did not re-vault them through recovery because its PG transaction, with the remove and the log entry, had committed too. Its log already held the delete, so there was nothing to recover.
  - These deletes have 2 copies, not 1.
- **c03 before F1** (`…T153224`): of the 261 reported lost, 97 have such an entry on the retainer: 97/97 intact, each with the expected pre-delete checksum.
  - **True loss: 164 of 320, in 18 of 20 runs.**
- **c03 on F1** (`…T194803`): 23 of the 253 "primary only" deletes also have an unlogged retainer copy, so 230 are primary-only.
- **Harness fix:** `rvcheck.py --disk-scan` lists every OSD's vault entries by name and checksum-verifies those without a log line, recording them as `path=unlogged`. The default scans only deletes without a verified logged copy; c04 scans every delete. Pre-fix result files are left as written; these corrections live here.

### 6.5 c04: primary failure (2026-10-01/02)

`scripts/scenarios/c04-primary-failure.sh`. The primary P of the target PG is killed during 16 concurrent removes (4 KiB–8 MiB), marked out, and its PGs recover on the other OSDs. Two variants:

- **A:** P is restarted and its strays are purged.
- **B:** P never returns during the check. Its store and log lines are excluded, so only surviving OSDs count.

The vault check scans every reachable OSD's disk (`--disk-scan all`).

| Variant | Vanilla (script validation) | F1 `05289b5` | Acked after kill (F1) | Lost (F1) |
|---|---|---|---|---|
| A (P returns as a stray) | 20/20 | **20/20** | 305 of 320 | **0 of 320** |
| B (P never returns) | 20/20 | **20/20** | 300 of 320 | **0 of 320** |

Result files: `c04a-…-20261001T155717` / `…T200538`, `c04b-…-20261001T181737` / `…T235554`.

Copies found per delete (P = killed primary, R = retainer; "R:primary" is R vaulting after it became the new primary):

- **A:** R:primary + other:repop (213); R:repop only (52); P:unlogged + R:repop (30); P:primary + R:repop (25).
- **B:** R:primary + other:repop (183); R:repop only (137).

**Reading:**
- A delete that had reached the retainer survives on the retainer's own copy, committed before the retainer's acknowledgement to the primary.
- A delete resent by the client after the interval change is vaulted again by the new primary and the new retainer.
- 30 of P's copies in variant A were durable but unlogged (§6.4), and were found only by the disk scan.

**F1 regression** (`results/phase2/*-20260930T1*/2*.json`, build marker `05289b5`): s01–s12 and a01–a05 pass, 17 scenarios, **118/118 runs**, 1,000/1,000 deletes with an intact copy. Copies per delete: 1 (25, single-OSD acting sets), 2 (832), 3 (143). a05 under F1: **3 copies per missed delete; retained / deleted bytes 3.00** (2.00 before F1).

**F1 cost** (indicative, single host; `cost-probe-p2-20260930T231922-r1.json` vs vanilla `…20260929T132837`; baselines match, 4 KiB p99 about 340 ms):

| Deleted object | Delete p50, F1 ÷ vanilla | 4 KiB p99 during deletes, F1 ÷ vanilla |
|---|---|---|
| 1 MiB | 1.3× | 1.1× |
| 4 MiB | 2.3× | 1.2× |
| 16 MiB | 5.0× | 1.6× |
| 64 MiB | 11.5× | 7.5× |
| 128 MiB | 22× | 11× |

Before F1, at 128 MiB: 13× and 4.8×. The primary now also reads and copies each deleted object on its op path. The 4 MiB interference ratio (1.2× with F1, 1.7× without) is within this probe's run-to-run noise. The primary's vault read and write sit on the same op path as the retainer's, so the §5 cost ratios would apply on two OSDs per delete.

## Future work

### Apply-path read cost (Phase 5 cost probe; not implemented)

The phase 2 probe (RelWithDebInfo, single host, indicative only; `results/phase2/cost-probe-*.json`, larger-sample run `…T132837` vanilla and `…T133743` p2, 20 deletes per size, 16 threads) shows that 64 and 128 MiB deletes visibly stall other ops.

- **128 MiB:** a p2 delete takes 2.9 s at p50 (vanilla 0.22 s). 4 KiB ops that start during it reach p99 2.06 s (vanilla 0.43 s).
- **64 MiB:** 1.73 s vs 0.24 s; 4 KiB p99 1.23 s vs 0.35 s.
- **4 MiB:** 4 KiB p99 is 1.7× vanilla (608 vs 353 ms). The cause is inferred: `vault_object` reads the whole object and stages a copy of the same size synchronously on the retainer's op path, in `do_repop` or `submit_transaction`. The op shard is busy for the whole read, and BlueStore then has to write the whole copy.

Possible mitigations, in rough order of effort:

1. **Chunked copy.** Read and write the object in bounded chunks (for example 4 MiB) inside the same vault transaction. This bounds memory. It does not shorten the time the op shard is busy, so it only matters combined with 2 or 3.
2. **Move the read off the op shard.** Queue the vault read to a separate thread pool. Hold only this OSD's local apply of the delete (not the client op on the primary) until the vault copy is staged, then queue both transactions in order on the same sequencer as today. The shard is freed; the delete's latency is unchanged.
3. **Two-stage vault.** Take a zero-copy BlueStore clone inside the PG collection as the staging step, then copy it to meta in the background and remove the clone. This makes the apply path O(1). But the staging object sits in the PG collection, so it must survive boot temp cleanup, scrub and stray-PG removal (`step1-primitive.md` §2). That is the same obstacle that ruled out option (c), so it needs design work first.
4. **Size-dependent policy.** Vault synchronously up to a threshold, for example 4 MiB (the RBD/RGW default object size), and via 2 above that.

### Contract item 5 under a retainer crash (Phase 4 finding)

c01 showed that a delete in flight when the retainer crashes is acknowledged by the new acting set (primary plus the old rank 2) without any durable vault copy. The pre-delete bytes survive only on the crashed retainer's disk, as its vault entry or as the not-yet-removed object, and are vaulted when it returns (`notes/log.md`, 2026-09-29). To enforce item 5 in this window, a second OSD must hold the bytes before the non-retainers remove them. Options, none chosen:

- **(a)** The primary also vaults every delete: 2 copies, doubling H1 and H3.
- **(b)** The primary delays its own remove until the retainer's commit is known. That needs the confirmation of design (ii), and a message change.
- **(c)** The non-retainers stage a vault copy and release it once the retainer commits. This leaves a transient second copy, and the release needs its own protocol.
