# B1 design: making "acknowledged delete ⇒ durable vault copy" hold

Ceph v19.2.3 `c92aebb2`; pilot prototype `17451c9` (branch `replicavault-pilot`). Paths are relative to `/data/ceph/src`. Written 2026-09-28 (phase 2, Phase 2).
**Verified** = I read the code at the cited lines. **Inferred** = reasoned, not read end to end.

Status: DRAFT. §5 (the attack results on the pilot prototype) is filled in after the a01–a05 runs.

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

To be filled in after the a01–a05 runs.

## Future work

(filled in after the Phase 5 cost probe)
