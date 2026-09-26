# Design note: object delete, end to end, and where one OSD can divert its own copy

Source: Ceph v19.2.3, commit `c92aebb279828e9c3c1f5d24613efca272649e62` (`/data/ceph`, branch `replicavault-pilot`).
Paths are relative to `/data/ceph/src`. Written 2026-09-25 (Phase 3, first pass).
"Verified" means I read the code at the cited lines. "Inferred" means I reasoned about it but didn't read every step.

## 1. Delete path, primary side

1. **Client op dispatch.** `CEPH_OSD_OP_DELETE` in `PrimaryLogPG::do_osd_ops` (`osd/PrimaryLogPG.cc:6950–6957`) calls `_delete_oid(ctx, false, ctx->ignore_cache)`.
2. **`_delete_oid`** (`PrimaryLogPG.cc:8194`) runs on the primary only:
   - It whiteouts instead of plain-deleting if the pool is a cache tier, or if `should_whiteout(snapset, snapc)` says clones exist or will exist (`:8205–8226`).
   - It always calls `t->remove(soid)` on the `PGTransaction` (`:8233`).
   - In the whiteout case it then calls `t->create(soid)` and sets `FLAG_WHITEOUT` (`:8264–8270`). In the transaction, a whiteout is therefore "remove, then create an empty head".
   - Otherwise it decrements object counts and marks `obs.exists = false`.
3. **The log entry.** `finish_ctx` / `prepare_transaction` (`PrimaryLogPG.cc:8871`, `:8937`) builds the `pg_log_entry_t`, a DELETE for a plain delete. Snapshot handling in `make_writeable` (`:8528`) may add a clone *before* the delete if the snap context requires it. Not traced in detail.
4. **`PGTransaction::remove`** (`osd/PGTransaction.h:309–321`) resets the per-object operation to `delete_first = true` with init `None`. The comment at `:68–83` enumerates the delete, delete-and-recreate, and create cases.
5. **`ReplicatedBackend::submit_transaction`** (`osd/ReplicatedBackend.cc:465`) turns this into an ObjectStore transaction:
   - `generate_transaction` (`:311`) emits `t->remove(coll, goid)` for every `delete_first` op (`:350–352`). For a plain delete that's all; a whiteout adds a `create` after it.
   - **`issue_op` runs before the local transaction is queued** (`:514–526`). For each replica it calls `generate_subop`, which **encodes `op_t` into the `MOSDRepOp`** (`:950`, encode at `:981`). If `should_send_op` is false, e.g. a backfill target past `last_backfill`, it encodes an empty transaction instead (`:976–979`).
   - Only after that does it `log_operation(...)`, which appends the PG log and pg info writes to `op_t` (`:531–538`), and then `queue_transactions` (`:547`).

   **So the primary can rewrite its own copy of `op_t` after `issue_op` returns without changing what replicas receive (verified).** The PG log entry is separate data and isn't touched.

## 2. Delete path, replica side

`ReplicatedBackend::do_repop` (`ReplicatedBackend.cc:1063`):

- It decodes the shipped transaction into `rm->opt` (`:1100`) and the log entries into `log` (`:1117`).
- `log_operation` writes the log and info into `rm->localt` (`:1143–1151`). The shipped transaction `rm->opt` is queued *after* `localt` (`:1156–1160`).
- If the object is in this replica's missing set, the log entries become missing-set events (`:1132–1140`). The transaction may still be non-empty.

**A replica can rewrite its own `rm->opt` between decoding it (`:1100`) and queuing it (`:1160`) (verified).** The PG log entry in `log`/`localt` is unchanged, and nothing is sent back to the primary except the commit ack (`repop_commit`).

## 3. The hook: rewriting only this OSD's local remove

**Where.**
- Replica ranks (1, 2): in `do_repop`, just before `queue_transactions`.
- Primary (rank 0): in `submit_transaction`, after `issue_op`.

v1 retains at rank 1, so the only hook needed is `do_repop`. Rank 1 is never the primary unless the acting set changes, which is covered below.

**What.** The transaction is an encoded op list (`os/Transaction.h`). The hook has to:

1. **Find the object.** Walk `rm->opt` with `Transaction::iterator` and find `OP_REMOVE` on `(coll, ghobject_t(soid, NO_GEN, NO_SHARD))` for the object in `m->poid`.
2. **Check it's a real delete.** Only if the matching log entry `is_delete()` (plain delete). A whiteout (`MODIFY` with remove+create) needs a decision; see §6.
3. **Read the object's current state.** Use `store->read` / `getattrs` / `omap_get` on `ch`. BlueStore updates the onode at queue time, so a read issued after earlier queued-but-uncommitted writes should see them. **Inferred, not verified: this needs a test with a write immediately followed by a delete.**
4. **Build the vault copy.** Construct a new transaction `vt`:
   - `touch`/`write` of the full data to `coll_t::meta()`, object `ghobject_t(hobject_t(<vault-name>, "", CEPH_NOSNAP, <hash>, POOL_META=-1, "replicavault"))`
   - `setattrs` with the original xattrs, including `_` (the object_info_t) and `snapset`
   - `omap_setkeys` / `omap_setheader` if the object has omap
   - an extra xattr with the checksum and the full original identity.
5. **Queue it.** Put `vt` first in `tls`, then `localt`, then `opt` unchanged. The `remove` stays in `opt`. The vault copy is a separate write that commits together with the remove, because BlueStore applies all transactions in one `queue_transactions` call as one txc (**verified**: `BlueStore::queue_transactions` creates a single `TransContext` at `os/bluestore/BlueStore.cc:15492`, adds every element of `tls` to it at `:15495–15497`, and commits one KV transaction at `:15513`). The pool-consistency assert over that txc only checks PG collections, so adding meta is allowed (`:15618–15625`).

**Why this leaves authority alone.** The PG log entry, pg info, the transaction the primary sent and the commit ack are all unchanged. The only extra effect is an object in a collection that peering, scrub, backfill and recovery never list (step 1 note §3). Rule 3 is respected: no peering, PG log, scrub or backfill code changes.

**Naming constraint (new, verified).** `OSD::trim_stale_maps` (`osd/OSD.cc:8017–8050`, reachable only through the admin-socket command `trim stale osdmaps`, `OSD.cc:3169–3180`) lists the *whole* meta collection. It removes any object whose name contains `"osdmap."` *anywhere* and parses the rest with `stoul` (`OSD.cc:8005–8014`). So:

- A vault entry must never contain `osdmap.` in its name. Otherwise it could be deleted, or `stoul` could throw and crash the OSD.
- **Rule for the prototype:** the vault oid name is `rv.` + hex of `(pool, pg, ns, key, name, version, deletion time)`. The raw user name is never used, so no user-chosen string reaches the meta name.
- The same listing also means a large vault makes that command slower. That's an H1/H3 footnote, not a gate issue.

**Rank at the time of apply.** A replica gets its role from the PG's current acting set. `do_repop` asserts `m->map_epoch >= same_interval_since` (`ReplicatedBackend.cc:1080`), so the replica's acting set matches the primary's for this op's interval. **Inferred:** to be confirmed by logging the acting set in the vault line and comparing it with `ceph osd map` in the scenarios.

## 4. Deletes that bypass `do_repop` (important for H2 and the scenarios)

These paths remove an object locally without going through the repop hook:

| Path | Code | When it fires |
|---|---|---|
| Recovery of a delete | `PrimaryLogPG::recover_missing` → `remove_missing_object` (`PrimaryLogPG.cc:12337`, `:12406–12436`) on the primary. On replicas: `PGBackend::handle_recovery_delete` → `remove_missing_object` (`osd/PGBackend.cc:134–144`). Both end in `PG::remove_snap_mapped_object` → `t.remove` (`osd/PG.cc:307–313`). | The OSD was down or behind when the delete happened and learns of it from the log during peering or recovery. |
| Backfill remove | The primary sends `MOSDPGBackfillRemove` (`PrimaryLogPG.cc:14054–14070`). The target runs `do_backfill_remove` → `remove_snap_mapped_object` (`PrimaryLogPG.cc:4554–4600`). | Backfill target holds an object the primary no longer has. |

**Consequence for the pilot.** In scenarios 1–3, if the rank-1 OSD misses the live delete (it was the one killed, or was down), it applies the delete later through **recovery-delete**, not `do_repop`. With a `do_repop`-only hook, that delete isn't vaulted anywhere.

Options:
- (i) Hook `remove_snap_mapped_object` as well, gated by the same rank rule. This is recovery code, not peering-authority code: it only changes what this OSD does with its local bytes.
- (ii) Accept the gap and have invariant 3 ("at least one vault entry") record it as a coverage miss.

**Vlad to decide**; I recommend (i). The recovery-delete removes exactly the same object version the log says was deleted, so vaulting it is the same operation.

## 5. Who else can see or remove objects

- **Scrub.** `PgScrubber::build_scrub_map_chunk` (`osd/scrubber/pg_scrubber.cc:1327`) → `PGBackend::objects_list_range` (`PGBackend.cc:406–446`) lists the PG collection only and skips pgmeta and temp objects. Generation objects go to `_scan_rollback_obs`, which deletes stale ones (`osd/PG.cc:2168–2190`). Per-object scan: `be_scan_list` (`PGBackend.cc:609`). **Meta is never listed (verified).**
- **Backfill.** `recover_backfill` (`PrimaryLogPG.cc:13807`) → `scan_range` (`:14269`) → `objects_list_partial` (`PGBackend.cc:346–404`). PG collection only (verified).
- **Snap trim.** `SnapTrimmer` → `trim_object` (`PrimaryLogPG.cc:4603`, called at `:15711`) removes clones with `t->remove(coid)` plus a DELETE log entry (`:4746–4757`). It removes the head/whiteout when the last clone goes (`:4843`). Both are ordinary PG transactions, so on replicas they go through `do_repop` too. **If the hook matches every `OP_REMOVE` of a NO_GEN object in `rm->opt`, it would also vault trimmed clones.** v1 should match only `m->poid` with a DELETE log entry for a head object (`snap == CEPH_NOSNAP`) and leave snap trim alone. Scenario 10 will show what happens to data held only by clones.
- **Stray PG removal.** The primary's `PeeringState::purge_strays` (`osd/PeeringState.cc:241–270`) sends `MOSDPGRemove`. `OSD::handle_fast_pg_remove` (`OSD.cc:9360–9375`) posts `DeleteStart` → `ToDelete` → `do_delete_work` (`PeeringState.cc:6751` → `PG.cc:2675`), which lists and removes every object, then removes the collection (`PG.cc:2716–2780`). A deleted pool takes the same path: `Stray` entry sees `!have_pg_pool` and posts `DeleteStart` (`PeeringState.cc:6566–6568`). **Meta is untouched either way (verified).**
- **Split / merge.** Split: `PrimaryLogPG.h:1566` (`t.split_collection`) via `PG::split_into` (`PG.cc:538`) and `OSD::split_pgs` (`OSD.cc:9156`). Merge: `PG::merge_from` → `merge_collection` (`PG.cc:563–588`). Both are PG-collection-only in BlueStore (`BlueStore.cc:18361–18364`, `:18416–18418`). Vault entries in meta don't move. The PG id recorded in the vault name becomes historical after a split or merge, so restore must use pool + object name, not the PG id.
- **OSD boot.** `load_pgs` ignores non-PG collections (`OSD.cc:5309–5312`). `clear_temp_objects` only visits PG collections (`OSD.cc:5018`).
- **Other meta listers.** Every `collection_list` caller in `osd/` is PG-scoped (`PG.cc:2717`, `PGBackend.cc:370/417`, `OSD.cc:5030/5087`) except `trim_stale_maps` (`OSD.cc:8021`), handled by the naming rule in §3. `ceph-objectstore-tool` can list and remove meta objects offline (`tools/ceph_objectstore_tool.cc`). That's a host-level action; see the inventory.

## 6. Open questions for Vlad

1. **Recovery-delete hook** (§4): vault on that path too (recommended), or record the gap?
2. **Whiteouts** (pool has snapshots and the head is deleted): the head's data is removed and an empty whiteout head is created. Should v1 vault the head's pre-delete bytes in this case? The clones still hold snapshot data, but the head may have changed since the last snapshot. My suggestion: vault the head too (same code path, the log entry is a `MODIFY`). `CLAUDE.md` says "document, don't change snapshot semantics", and vaulting a copy doesn't change them.
3. ~~Transaction atomicity~~: resolved. One `queue_transactions` call is one BlueStore txc (§3 step 5).

## 7. Prototype as built (Phase 4, 2026-09-26)

Ceph branch `replicavault-pilot`: `ca2a5b2` (prototype) and `17451c9` (accounting fix), on top of `c92aebb2`.

**New module `src/osd/ReplicaVault.{h,cc}`:**
- `RETAIN_RANK = 1` and `VAULT_LOG_LEVEL = 1` are compile-time constants.
- `acting_rank()` uses `OSDMap::pg_to_up_acting_osds` on the PG's own map. That is the same acting set that `ceph osd map` prints.
- `deleted_heads()` reads only the op headers of the shipped transaction, never data payloads. It returns a head as deleted when it is removed and either the log has a DELETE entry for it, or it is recreated with no data written (a whiteout).
- `vault_object()` reads the object with `stat`, `getattrs`, `read` and `omap_get`, and skips heads that are already whiteouts. It then stages `touch`, `write`, `setattrs` and `omap_setheader`/`omap_setkeys` on `coll_t::meta()`, object `rv1_<pool>_<pgid>_<epoch>-<ver>_<sec>.<nsec>_<hex ns>_<hex key>_<hex name>` in namespace `replicavault`. The xattrs are the originals plus `rv.sha256`, `rv.size`, `rv.pool`, `rv.pgid`, `rv.oid`, `rv.nspace`, `rv.key`, `rv.version`, `rv.vaulted_at`, `rv.osd`, `rv.path` and `rv.acting`.
- It logs `replicavault: vaulted pool=… pg=… oid=… ns=… v=… osd=… path=repop|recovery acting=[…] size=… omap_keys=… sha256=… vname=…` at debug level 1.

**Hooks:**
- `ReplicatedBackend::do_repop`: after decoding the log, before `log_operation`.
- `PrimaryLogPG::remove_missing_object`: recovery-delete, head objects only.

**Transaction layout (after the fix):** the vault copy is queued as its **own** BlueStore txc on the PG's collection handle, immediately before the PG transaction.

- **First version.** It put the copy into the PG's txc. The vault bytes were then charged to the PG's pool (`BlueStore.cc:14126–14131`), and every retaining OSD failed `ceph-bluestore-tool fsck` with a per-pool statfs mismatch (pool 1 stored 0x611002 bytes with 0 expected, and meta the reverse). This is a prototype bug, not a design problem.
- **Why a separate txc is safe.**
  - A meta-only txc is charged to `META_POOL_ID`, the default (`BlueStore.h:1915`).
  - The two txcs share one OpSequencer, and `_txc_finish_io` (`BlueStore.cc:14266`) submits a sequencer's txcs to the KV store in queue order. A txc with no AIO still goes through `_txc_finish_io` (`_txc_state_proc`, PREPARE → AIO_WAIT → `_txc_finish_io`, `BlueStore.cc:14155–14182`).
  - So after a crash, either both are durable, only the vault copy is, or neither is. The remove is never durable without the copy.
  - If only the copy survives, the delete is redelivered, through repop resend or recovery, and vaulted again. That leaves a duplicate entry but loses nothing.
- **After the fix.** I repaired all 5 OSDs' stats with `ceph-bluestore-tool repair`. Then I vaulted 6 deletes and fsck'd each retaining OSD (0, 2, 4): all `fsck success`.

**Verification so far:**
- A probe delete was vaulted only on the rank-1 OSD (osd.3 in `[1,3,0]`), with a matching SHA-256.
- `smoke.sh` passes on both builds (`results/smoke-20260926T134712.json`, `results/smoke-20260926T135516.json`).
- `vault-inspect.sh list 3` showed 10 entries, all intact, sizes 0 B to 4 MiB.
- A manual restore of `rvprobe-1` produced a new version (13, above the vaulted 6) with byte-identical content.

**Still to test** (Phase 5):
- The recovery-delete path (`path=recovery`) and the whiteout path. Nothing has hit them yet.
- Read-after-queue: a write immediately followed by a delete of the same object, both still in flight. **Inferred** from how BlueStore updates in-memory onodes at queue time, but not verified.
- Behaviour when the acting set changes between the primary's op and the replica's apply.
