# Zero-copy vault — Phase 1: reading the code

Ceph v19.2.3 `c92aebb2`. BlueStore is unmodified on `replicavault-zc` (= `05289b5`), so `src/os/bluestore` line numbers are those of v19.2.3. Paths are relative to `/data/ceph/src`. Written 2026-10-03.
**Verified** = I read the code at the cited lines. **Inferred** = reasoned from what I read, not followed end to end.

## Verdict

**Feasible as a metadata-only change, without an on-disk format change (inferred), for onodes that reference no shared blob.**

All the pieces are in-memory bookkeeping or rewrites of existing key types:

- **Keys.** Rewrite the onode key and the extent-shard keys (as `_rename` already does) and the object's omap keys.
- **Cache.** Re-home the onode and its blobs into the meta collection (as `split_cache` already does, per onode).
- **Statfs.** Move the object's statfs contribution from its pool's stat key to the meta pool's stat key.

Nothing allocates or frees a block, so the freelist and allocator are untouched.

**Three requirements are not optional:**

1. **One transaction for both pools' statfs.** A BlueStore transaction carries one pool's statfs delta today (Q5). A second delta is needed: an in-memory change that writes existing per-pool `PREFIX_STAT` keys.
2. **Rename and PG ops in the same transaction** (Q7). Unlike the copy, a separate transaction is not crash-safe. Requirement 1 is what makes merging possible.
3. **Omap costs O(number of keys).** The object's omap keys embed the collection's pool and must be rewritten (Q4); vanilla deletes omap with one range delete.

**Correction to the plan's premise (Q2).** In v19.2.3 an unshared blob has **no** `SharedBlob` object. `Blob::shared_blob` is set only "if any" (`os/bluestore/BlueStore.h:651`); the blob holds its own `collection` pointer and `BufferSpace` (`:639–649`).

**Estimated size:**

| Part | Lines |
|---|---|
| BlueStore move function and pre-check | ~250–350 |
| Two-pool statfs | ~40 |
| ReplicaVault integration | ~80 |
| Unit tests | ~300 |

**Risk to the time box:** the cache re-homing and locking (Q2) and fsck's omap checks (Q4) are where bugs would hide. The unit tests and z01 target exactly those.

---

## 1. Why the assert exists — **verified**

- **The assert.** `OP_COLL_MOVE_RENAME` / `OP_TRY_RENAME` assert `op->cid == op->dest_cid` (`BlueStore.cc:15859`), then call `_rename(txc, c, o, no, noid)` with the **source** collection only (`:15856–15866`).
- **What `_rename` does** (`BlueStore.cc:18171–18225`):
  1. `rmkey` the old onode key (`PREFIX_OBJ`).
  2. Fault in the whole extent map and `rmkey` every extent-shard key, marking each shard dirty so it is rewritten under the new onode key (`:18189–18201`).
  3. `newo = oldo; txc->write_onode(newo)`.
  4. `c->onode_space.rename(...)` (`:18213`).
- **What `OnodeSpace::rename` does** (`:2017–2050`): it moves the `Onode` to the new oid inside the **same** `onode_map`, installs a non-existent placeholder at the old oid, and updates `o->oid` / `o->key`.

Single-collection assumptions:

| Assumption | Where |
|---|---|
| The `OnodeSpace` is the source collection's | `:2017–2050` |
| The onode cache shard is the source collection's | `cache->_add` / `_trim` there |
| `o->c` stays the source collection | `Onode(o->c, …)`, `:2036` |
| Blobs keep their `collection` pointer and buffer-cache shard | — |
| The omap prefix, recomputed from `c->pool()`, stays valid only while the pool is unchanged | Q4 |
| `Collection::get_onode` on a PG collection requires the oid to match the PG's hash bits | `:5079–5093` |

The assert protects all of these at once.

## 2. In-memory re-parenting — **verified** (mechanism), **inferred** (reuse for one onode)

- **Where state lives.** Each collection owns an `OnodeSpace` and an onode-cache shard; each `Blob` holds a `CollectionRef collection` and its `BufferSpace bc`, accounted to the collection's buffer-cache shard (`BlueStore.h:639–649`, `get_cache()` at `:770`). A `SharedBlob` exists only for shared blobs (`:651`), held in the owning collection's `SharedBlobSet` (`:582–620`, member at `:1636`).
- **`Collection::split_cache(dest)`** (`BlueStore.cc:5126–5229`) already moves onodes between collections. For each onode matching the destination it:
  - moves the `onode_map` entry and the pinned cache entry (`_move_pinned`);
  - sets `o->c = dest`;
  - for every blob in `extent_map` **and** `spanning_blob_map`, moves its non-writing buffers to `dest->cache` (buffers still writing stay accounted where they are), moves the blob counters, sets `b->collection = dest`, and moves any `SharedBlob` between the two `SharedBlobSet`s (`rehome_blob`, `:5172–5197`).
  - It locks both onode-cache shards and both buffer-cache shards (`:5135–5139`). The caller holds both collections' locks (`_split_collection`, `:18343–18344`).
- **Reuse:** the per-onode loop body can be factored into a `rehome_onode(o, dest)` and applied to one onode (**inferred**). Differences from split:
  - insert under the **new** oid in `dest`, and leave a non-existent placeholder under the old oid in the source, as `OnodeSpace::rename` does (pending txcs may still look up the old name);
  - skip the shared-blob branch, since such onodes are refused (Q3);
  - take both collections' `lock` in a fixed order (source, then meta). Meta-only transactions never lock a PG collection, so there is no inverse order (**inferred**).

## 3. Shared blobs — **verified**

- **Detection:** fault in the full extent map (`extent_map.fault_range(db, 0, onode.size)`, as `_rename` does at `:18189`), then test `blob.get_blob().is_shared()` (`FLAG_SHARED`, `bluestore_types.h:612`) for every blob in `extent_map` and in `spanning_blob_map`. Any shared blob means refuse.
- **Why a cross-collection move is unsafe for these:**
  - A shared blob's in-memory `SharedBlob` lives in **one** collection's `SharedBlobSet`, found by sbid lookup in the opening collection (`Collection::open_shared_blob`, `BlueStore.cc:4994–5014`).
  - Its persistent refcounts live in `PREFIX_SHARED_BLOB`, keyed by sbid alone (`load_shared_blob`, `:5016–5038`).
  - After a move, the clone still in the PG collection and the vault entry in meta would each open their own `SharedBlob` for the same sbid. Each would update the shared refcount record independently.
  - `_shutdown_cache` asserts that every `SharedBlobSet` is empty (`:18790–18795`).
- **Refuse cleanly, never inside the transaction.** An unexpected error code in `_txc_add_transaction` aborts the OSD (`:15918–15960`). And a refused move followed by the PG transaction's remove would drop the bytes. So the decision must be made **before** the transaction is built:
  - a pre-check `can_move_to_meta(ch, oid)` that the ReplicaVault hook calls;
  - `mode=copy` if it says no.
  - Inside the transaction, the move op re-checks. If the object became shared in between (impossible on the same sequencer, **inferred**: clones happen only in PG transactions ordered on that sequencer), it copies internally instead of failing.

## 4. Omap — **verified**; cost **inferred**

- **Flags.** Objects' omap flags are `FLAG_PERPOOL_OMAP | FLAG_PERPG_OMAP` (`set_omap_flags(per_pool_omap == OMAP_BULK)`, `bluestore_types.h:1037–1060`; set at `BlueStore.cc:17854`, `17899`, `18054`). That gives prefix `PREFIX_PERPG_OMAP` (`calc_omap_prefix`, `:4646–4658`).
- **Key layout:** `encode_u64(c->pool()) + encode_u32(hash) + encode_u64(nid) + '.' + user key`. The header and tail keys follow the same layout (`:4661–4705`). `rewrite_omap_key` rebuilds a key from the onode's **current** `c->pool()` and hash (`:4794–4806`).
- **The meta collection uses the same scheme.** It is not a special omap type, but `c->pool()` is the meta collection's pool, −1 (`Collection::pool()`, `BlueStore.h:1691–1693`). `PREFIX_PGMETA_OMAP` is only for the PG's pgmeta object.
- **What must be rekeyed when an object moves to meta:**
  - every omap entry, plus its header and tail keys, from `(pool P, hash, nid)` to `(pool −1, hash, nid)`;
  - the hash stays the same if the vault name keeps the original's hash, as `vault_object` does today.
  - That is a metadata-only rewrite: per key, one `set` under the new key. The old range goes with one `rm_range_keys` plus the old tail key.
  - The pattern already exists in `_clone`'s omap copy (`:18048–18080`).
- **Cost vs vanilla.** Vanilla delete removes the whole omap with `_do_omap_clear`: one `rm_range_keys` and one `rmkey` (`:17808–17820`), O(1) KV operations. The move is O(n) KV puts for n keys, plus the same range delete. Data blocks are not touched in either case. **For z05:** measure delete latency against omap size (for example 10, 1,000 and 100,000 keys) on vanilla and on rename.

## 5. Space accounting — **verified**

- **One pool per transaction.** A transaction carries **one** `volatile_statfs statfs_delta` and **one** `osd_pool_id` (`BlueStore.h:1914–1915`). `_txc_update_store_statfs` merges that delta into the single key `get_pool_stat_key(txc->osd_pool_id)` under `PREFIX_STAT`, and adds it to `osd_pools[txc->osd_pool_id]` (`BlueStore.cc:14110–14146`). `osd_pool_id` is set from the first PG collection the transaction touches, and an assert keeps all PG collections in one pool (`:15618–15625`).
- **So today's interface cannot express a move.** One transaction cannot debit pool P and credit the meta pool. A rename cannot be split across two transactions the way the copy was (Q7).
- **Fix without a format change (inferred):** add a second, optional `(pool, delta)` pair to `TransContext`, used only by the move, and apply it in `_txc_update_store_statfs` exactly like the first. The per-pool stat key for −1 already exists: the pilot's fsck reported "pool ffffffffffffffff".
- **What the delta is:** the onode's own contribution, computed the way fsck computes per-object expected statfs (`fsck_check_objects_shallow`, `:9721` onward):
  - `data_stored` += each logical extent's length (`~:9800`);
  - per blob, `data_compressed` and `data_compressed_original` if compressed (`~:9849–9852`);
  - `allocated` / `data_compressed_allocated` per physical extent (`~:9903–9913`).

  The amount is debited from P and credited to −1. Totals are unchanged.

## 6. Allocation rebuild after an unclean shutdown — **verified**

- **Which path applies.** v19.2.3 keeps allocation state in a BlueFS file (NCB, `bluestore_allocation_from_file`, default `true`, `common/options/global.yaml.in:5151–5152`), **only if the DB device is non-rotational** (`can_have_null_fm = !is_db_rotational() && …`, `BlueStore.cc:7100–7103`).
  - **Non-rotational DB, clean shutdown:** the allocator comes from the file (`restore_allocator`, `:7261`).
  - **Non-rotational DB, after a crash:** `read_allocation_from_drive_on_startup` (`:20366`) → `reconstruct_allocations` (`:20335`) → `read_allocation_from_onodes` (`:20207`). That walks **every** `PREFIX_SHARED_BLOB` and **every** `PREFIX_OBJ` key, onodes and extent shards, with **no collection filter**. **Meta-collection onodes are included**, so a moved vault entry's blocks are marked allocated.
  - **Rotational DB:** the allocator is loaded from the RocksDB freelist (`:7240–7248`). That freelist is updated in the same KV transaction as each allocation or release, so there is no rebuild walk at all.
- **fsck and repair** walk all `PREFIX_OBJ` keys and assign each to the collection that `contains()` it, meta included. A key in no collection is a "stray object" error (`:10447–10461`). Expected per-pool statfs uses `pool_id = c->cid.is_pg(&pgid) ? pgid.pool() : META_POOL_ID` (`:10464`). So a moved entry is checked like any meta object, and its bytes are expected under the meta pool (consistent with Q5).
- **Consequence for z01: important.** The zc cluster's OSDs report `bluefs_db_rotational: 1` (`ceph osd metadata`; the DB files sit on HDD `sdb`). Rotational detection for a file-backed device comes from the disk underneath the filesystem, and a device it cannot identify counts as rotational (`blk/kernel/KernelDevice.cc:274–282`). There is no override option. **As the cluster stands, z01's crash restart would never run the onode-walk rebuild.** To exercise it, the OSDs' `block.db` (and WAL) must sit on a non-rotational device. This node's root disk `sda` is an SSD (`lsblk` ROTA=0, 46 GB free on `/`). See "Decision for Vlad".

## 7. Deferred writes and in-flight I/O — **inferred** (mostly), **verified** where cited

- **Deferred writes are keyed by physical extent, not by object:** a `bluestore_deferred_transaction_t` under `PREFIX_DEFERRED`, keyed by a sequence number. A move changes no extents, so pending deferred I/O lands on the same blocks, which still belong to the same blobs.
- **Earlier transactions on the same sequencer** were already applied to the in-memory onode and extent map at queue time (`_txc_add_transaction`, `:15591` onward), and phase 2 c02 showed reads see them. The move faults in and rekeys the current in-memory state. It should call `o->flush()` first, as `_clone` does (`:18026`), so the onode isn't mid-write when its keys are rewritten.
- **Buffers still "writing"** stay accounted to the source buffer-cache shard after a move, exactly as in `split_cache` (`:5172–5181`). That is accounting only, settled when the write finishes.
- **Ordering versus the PG transaction: the move must be in the SAME BlueStore transaction as the PG log entry and the remove.**
  - Today's copy is queued as its own transaction ahead of the PG transaction. That is crash-safe because a crash between them leaves the object in place plus an extra copy.
  - With a move, the same crash would leave the store **without** the object while this OSD's PG log still records it as existing. If no other replica had committed the delete, the authoritative log would say the object exists. This OSD would then be missing it silently until scrub reports an inconsistency (**inferred**).
  - A single transaction removes that window. `queue_transactions` packs all of `tls` into one txc and one KV commit (`:15492–15513`).
  - The move op goes first. The PG transaction's own `OP_REMOVE` then finds no object, which is tolerated: ENOENT is "usually okay" and `OP_REMOVE` is not in the exception list (`:15918–15934`).
  - The single-pool assert covers only PG collections (`:15618–15625`), so a transaction touching a PG collection and meta is allowed, as in the pilot's first build. With Q5's two-pool delta, accounting is correct.

## 8. The vault-time checksum — proposal

- **Today:** `vault_object` reads the whole object to compute `rv.sha256` (`osd/ReplicaVault.cc`). A zero-copy vault must not read the data.
- **Proposal:**
  1. **At vault time:** record no SHA-256 for `mode=rename` entries. Store `rv.sha256 = "lazy"` and keep the size and the source version. BlueStore's per-blob checksums (`bluestore_csum_type`, crc32c by default) are kept by the move, because the blobs are unchanged, and are verified on every read.
  2. **At restore or reclaim time:** compute SHA-256 when the entry is read (`vault-inspect.sh check` / `restore` already read the bytes).
  3. **In the harness:** verify vault contents against the **client-side** checksums recorded at write time (`rvcheck.py` already does this). It should also stop requiring `stored_sha256 == data_sha256` for lazy entries.
- **`mode=copy`** (the shared-blob fallback) keeps the current SHA-256, since it reads the data anyway.

---

## Code changes

1. **BlueStore** (`os/bluestore/BlueStore.{h,cc}`): no format change.
   - `can_move_to_meta(ch, oid)`: faults in the full extent map and checks that no blob is shared.
   - Choose one of:
     - (a) relax `OP_COLL_MOVE_RENAME` when `cid != dest_cid` and the destination is the meta collection;
     - (b) a new internal entry point, used only by ReplicaVault.

     (a) keeps everything inside the normal transaction path (ordering, locking, error handling), so I lean to (a). The choice is recorded in Phase 2.
   - The move itself:
     1. lock both collections;
     2. fault in the full extent map;
     3. `rmkey` the old onode and shard keys and mark the shards dirty (as `_rename`);
     4. rekey omap;
     5. re-home the onode and its blobs into meta under the new oid (factored from `split_cache`), with a placeholder in the source;
     6. set the two-pool statfs delta;
     7. `write_onode`.
   - `TransContext`: a second `(pool, statfs delta)`, applied in `_txc_update_store_statfs`.
2. **ReplicaVault** (`osd/ReplicaVault.{h,cc}`, hooks unchanged in place):
   - `RV_VAULT_MODE` = `rename` | `copy`;
   - pre-check, then rename or copy;
   - the rename is staged in the **same** `tls` as the PG transaction (vault ops first);
   - `mode=` in the log line (still from the commit callback);
   - `rv.sha256 = lazy` for rename.
3. **Tests:** `src/test/objectstore/store_test.cc`, as listed in CLAUDE.md Phase 2.

## What would change the verdict

- **fsck's omap checks reject rekeyed keys.** It walks the per-pool and per-PG omap prefixes against the onodes it saw (`:11275–11357`). Its check for per-PG omap is **inferred** to accept keys under pool −1 for a meta onode; the deep-fsck unit test settles it.
- **A cache or locking interaction** that `split_cache` gets away with only because PGs never split concurrently with ops. To find in the unit tests and z01.
- **An on-disk format change turns out to be needed** (none is foreseen). Per `CLAUDE.md`, that is a fail.

## Decision for Vlad

**z01 on a non-rotational DB.** On the current zc cluster (DB on HDD) a crash restart loads the transactional freelist, which a move never touches. z01 would pass without testing the rebuild walk it was written for. Options:

- **(A) Recreate the zc cluster** with every OSD's `block.db` and `block.wal` files on the SSD root filesystem (about 2 GiB per OSD, 10 GiB total of 46 GiB free). The block data stays on `sdb`. Every crash restart then runs the onode-walk rebuild. **Recommended:** the zc cluster holds nothing yet.
- **(B) Keep the cluster, and add a sixth OSD** with its DB on the SSD, for z01 only.
- **(C) Run z01 as written.** It then tests only the freelist path, and the report must say so.
