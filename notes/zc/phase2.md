# Zero-copy vault — Phase 2: the BlueStore change and unit tests

Ceph branch `replicavault-zc`, commit **`5b0dac5`** on `05289b5`. 4 files, +737/−7 (code +374, tests +370). Written 2026-10-04.

## Choice: option (a), a relaxed `OP_COLL_MOVE_RENAME`

Vlad approved (a) on 2026-10-04. `OP_COLL_MOVE_RENAME` with `cid != dest_cid` is accepted when the destination is the meta collection. The same-collection path (`_rename`) is unchanged.

Why (a): the move rides the normal transaction path. It gets the same op ordering, the same collection locks, the same `endop` error handling and the same txc commit. That is what lets the ReplicaVault hook put the move in the **same** transaction as the PG log entry and remove, which `step1.md` Q7 requires for crash safety. A separate internal entry point would need its own transaction plumbing to get that.

## What changed

| Where | Change |
|---|---|
| `os/ObjectStore.h` | New virtual `can_move_to_collection(ch, oid, dest)`, default `-EOPNOTSUPP`. Callers ask before staging a move and copy instead if the answer is not 0. |
| `BlueStore.h` | `TransContext::extra_statfs_delta` / `extra_pool_id`, a second per-pool statfs delta used only by a move. `Collection::move_onode_to`. `BlueStore::_onode_blobs_unshared`, `_onode_statfs`, `_move_to_collection`, `can_move_to_collection`. |
| `_txc_add_transaction` | `OP_COLL_MOVE_RENAME` with `cid != dest_cid`: take the destination collection's lock (the source's is already held), look up the destination oid there, and call `_move_to_collection`. |
| `endop` | `-EXDEV` from a cross-collection move is tolerated as a no-op: the refused, shared-blob case. |
| `_move_to_collection` | 1. Destination must be meta, else `-EINVAL`. 2. Destination must not exist, else `-EEXIST`. 3. `oldo->flush()`, as `_clone` does. 4. Refuse with `-EXDEV` if any blob is shared. 5. Move the statfs contribution (source pool debit via `statfs_delta`, meta credit via `extra_statfs_delta`). 6. `rmkey` the old onode and extent-shard keys, marking the shards dirty (as `_rename`). 7. Read the omap under the old collection. 8. `move_onode_to`. 9. Rewrite the omap under the meta pool: `rm_range_keys` of the old range and tail, `set` of each rewritten key and the new tail (as `_clone`'s omap copy). 10. `write_onode`. 11. Keep the placeholder pinned until commit. |
| `move_onode_to` | The per-onode part of `split_cache`: both onode-cache and buffer-cache shard locks (recursive mutexes, so shared shards are fine), a placeholder at the old oid, insertion under the new oid in meta, `_move_pinned`, `o->c = dest`, and blobs re-homed (buffers, blob and extent counters, `collection`). |
| `_onode_statfs` | Per-object statfs, computed exactly as fsck computes its expectation: stored per logical extent; compressed, compressed-original, allocated and compressed-allocated once per blob. |
| `_txc_update_store_statfs` | Merges the extra delta into the meta pool's existing `PREFIX_STAT` key and `osd_pools[]`. Store-wide perf counters get the net delta, which is zero for a move. In legacy global-statfs mode the two deltas are summed (also zero). |

**No on-disk format change:** no new RocksDB prefix, no change to onode or blob encoding, no format-version bump. No block is allocated or released.

## Unit tests: `ObjectStore/RVMoveTest` (bluestore only), 7/7 pass

Run: `ceph_test_objectstore --gtest_filter='ObjectStore/RVMoveTest.*' --plugin-dir /data/ceph/build/lib`. About 62 s.

Every test checks:
- the source returns `ENOENT`;
- data, xattrs, omap header and omap keys are intact in meta;
- the same after an unmount and remount;
- a **deep** fsck returns 0;
- per-pool statfs: what left the PG's pool (allocated, stored) is exactly what the meta pool gained.

| Test | Covers |
|---|---|
| SmallAndLarge | 4 KiB (deferred path), 64 KiB, 4 MiB (direct), with xattrs and omap; one move followed by the PG-style `remove` in the same txn (ENOENT tolerated) |
| FragmentedShardedExtentMap | 1 MiB object plus 300 scattered overwrites, with small shard sizes. The debug log confirms a resharded extent map (shards at 0x10000, 0x20000, …) and 587 spanning-blob log entries. |
| LargeOmapAndXattrs | 20,000 omap keys, header, 50 xattrs |
| CompressionForced | snappy, `bluestore_compression_mode=force`. Checks the write really was compressed in the source pool, and that compressed, compressed-original and compressed-allocated bytes move between pools in equal amounts. |
| MoveQueuedAfterUncommittedWrite | 20 objects: an overwrite plus omap key, queued without waiting, then immediately the move and remove. The vault holds the last write and key. |
| ManyMovesThenRemoveSourceCollection | 50 moves in one txn, then `remove_collection` of the now-empty PG collection succeeds. Entries are intact after remount and deep fsck. |
| SharedBlobRefused | After a clone, `can_move_to_collection` returns `-EXDEV`. A move issued anyway is a no-op: the object and the clone are intact, nothing appears in meta, deep fsck is clean. |

Harness note: run outside the build directory, `ceph_test_objectstore` cannot find the compressor plugins (`/usr/local/lib/ceph/...`), and "force" compression silently does nothing. Pass `--plugin-dir /data/ceph/build/lib`. The first CompressionForced run caught this.

## Existing suite

The QA filters from `qa/suites/rados/objectstore/backends/objectstore-bluestore-{a,b}.yaml`:
- `--gtest_filter='*/1:-*SyntheticMatrixC*'`
- `--gtest_filter='*SyntheticMatrixC*/2'`

Run with `ulimit -Sn 16384` and `--plugin-dir`, on the Debug build at `5b0dac5`. The run shared the HDD with z01, so timings are slow.

- **Job a** (`*/1:-*SyntheticMatrixC*`): **125 passed, 4 skipped, 0 failed** of 129, in 21,948 s. The 4 skips are `StoreTestSpecificAUSize.ZeroBlockDetection{SmallAppend,SmallOverwrite,BigAppend,BigOverwrite}/1`, which skip themselves when `bluestore_zero_block_detection=false`, the default (`store_test.cc:8339`, verified). This is not caused by the change. Output: `/data/zc-ostest/a/gtest.out`.
- **Job b: the QA filter is stale for v19.2.3.** In this binary the test instances are `/0` memstore, `/1` bluestore, `/2` kstore (`--gtest_list_tests`). The yaml's `*SyntheticMatrixC*/2` therefore ran the 4 **kstore** tests, which pass trivially (0 ms), and does not test BlueStore. The BlueStore instance is `*SyntheticMatrixC*/1`, rerun in `/data/zc-ostest/b1`: **4/4 passed** (CsumAlgorithm 4,207 s, CsumVsCompression 12,181 s, Compression 9,369 s, CompressionAlgorithm 4,975 s; 30,732 s in total, sharing the disk with z01).

**Existing BlueStore suite: 129 passed, 4 skipped by design, 0 failed. Phase 2 gate condition met.**
