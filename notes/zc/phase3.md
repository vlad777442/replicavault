# Zero-copy vault — Phase 3: ReplicaVault integration

Ceph branch `replicavault-zc`, commit **`33b89ae`** on `5b0dac5`. 5 files under `src/osd/`. Written 2026-10-04. Line numbers refer to `33b89ae`; all citations below were **verified** by reading the code unless marked otherwise.

## What changed

- **`RV_VAULT_MODE`** is a cmake cache variable, `rename` (default) or `copy` (`src/osd/CMakeLists.txt`). `copy` defines `RV_VAULT_MODE_COPY` for `ReplicaVault.cc` only, so switching modes recompiles one file.
  - Binaries in `/data/zc/bin`: `ceph-osd.zc` (rename, sha256 `be70c6eb…`) and `ceph-osd.zccopy` (copy).
  - Rebuilding rename after copy produced a byte-identical binary.
- **Choosing the mode per object** (`vault_object`, `osd/ReplicaVault.cc`). A delete is renamed only if all three hold:
  1. the build is rename mode;
  2. the PG transaction's **first use of the head is its `OP_REMOVE`** (`remove_is_first_use`);
  3. `store->can_move_to_collection(ch, oid, meta) == 0`, i.e. BlueStore finds no shared blob.

  Otherwise the delete is copied, as before.
  - Rule 2 exists because a delete of a head whose snapshot context is newer than its last clone **clones the head in the same transaction, before the remove**. If the move went first, that `OP_CLONE` would hit ENOENT, which `_txc_add_transaction` treats as fatal ("ENOENT on clone suggests osd bug", `BlueStore.cc` endop, after `:16047`).
  - s10 confirms it: case B (snapshot, then delete) is copied; case A (snapshot, overwrite, delete) is renamed.
- **A rename entry** keeps the object's own xattrs (`_`, `snapset`, user attrs) and omap, and gains the rv.* attrs. It records `rv.sha256=lazy` and `rv.mode=rename`, plus `rv.size` from `stat`. **The data is never read.**
- **A copy entry** is unchanged: full read, SHA-256, `rv.mode=copy`.
- **The log line** is still emitted from the commit callback of the transaction that carries the entry. It now reads `... path=P mode=rename|copy acting=[..] size=N omap_keys=K|- sha256=HEX|lazy vname=...`.
- **F1 is unchanged.** The primary vaults every delete (`path=primary`/`fallback`), and the retainer vaults on `repop`/`recovery`.

## Ordering and crash safety

**Staging.** `vault_object` stages into one of two transactions (`replicavault::Staging`):
- `copy_t` is queued as its **own txc**, before the PG transaction and on the same sequencer, as in `05289b5`. A copy writes new data that must be charged to the meta pool, and one txc carries one pool's delta besides a move's. Crash safety is as in phase 2: a crash between the two txcs leaves the object in place plus an extra copy.
- `move_t` goes into the **same `queue_transactions` call** as the PG transaction, at the front of `tls`.

**Where `move_t` is queued:**

| Path | Code | tls passed to the store |
|---|---|---|
| Primary | `ReplicatedBackend::submit_transaction`, `ReplicatedBackend.cc:466`; queued at `:581` | `[vault_move_t, op_t]`. `op_t` now also holds the log ops from `log_operation`. |
| Replica | `ReplicatedBackend::do_repop`, `:1097`; queued at `:1225` | `[vault_move_t, rm->localt, rm->opt]` |
| Recovery delete | `PrimaryLogPG::remove_missing_object`, `PrimaryLogPG.cc:12407` | The move is staged into `t` itself, before `remove_snap_mapped_object(t, soid)`, which is `t.remove` plus the snap-mapper cleanup (`PG.cc:307–314`). |

**Why the result is crash-safe:**

1. **One txc, one KV commit.** `PrimaryLogPG::queue_transactions` passes `tls` straight to `osd->store->queue_transactions(ch, tls, …)` (`PrimaryLogPG.h:369–372`). `BlueStore::queue_transactions` (`BlueStore.cc:15583`):
   - creates **one** `TransContext` (`:15601`);
   - applies each `Transaction` of `tls` into it in order (`:15604–15606`);
   - writes the nodes and finalizes **one** KV transaction (`:15610`, `:15622`).

   The vault key writes, the PG collection deletes, and the PG log / info omap updates all land in a single RocksDB batch: all or nothing. No crash point leaves the object gone from the PG collection while the log still says it exists, or vice versa.
2. **The later remove is a no-op, not an error.**
   - After the move, the source `OnodeSpace` holds a non-existent placeholder at the old oid (`Collection::move_onode_to`).
   - The PG transaction's `OP_REMOVE` is not a creating op (`:15828–15834`). It therefore finds `!o->exists`, sets `r = -ENOENT` and jumps to `endop` (`:15843–15848`).
   - `endop` accepts ENOENT for every op outside the clone and collection-add list. `OP_REMOVE` is not in that list (`:16047` onward), so the transaction continues.
   - Its `_remove` never runs, so it releases no extents. The blobs now belong to the vault onode.
3. **The same holds for ops after the remove in the same transaction.** A recreate (`OP_TOUCH`/`OP_CREATE`, e.g. a whiteout) creates a fresh onode at the placeholder. Ops that do not create get the same tolerated ENOENT. Ops before the remove are excluded by rule 2.
4. **Callbacks.**
   - The vault line's `on_commit` and the PG's `C_OSD_OnOpCommit` / `C_OSD_RepModifyCommit` are registered on transactions of the same txc. BlueStore runs them all after the one KV commit (`_txc_committed_kv`, `:14566`).
   - A client ack therefore implies the rename entry is durable on the primary, which is F1's argument, now with no separate copy txc.
   - A SIGKILL after the KV commit and before the callbacks leaves a durable entry with no log line. `rvcheck.py --disk-scan` finds those, as before.
5. **Pre-check vs. apply.** `can_move_to_collection` runs at staging time, under the PG lock that every caller holds, and against BlueStore's in-memory state. That state already includes every earlier txc queued on this collection, because `_txc_add_transaction` runs synchronously in `queue_transactions`.

   Nothing else changes this PG's objects before `move_t` is queued, so the move at apply time sees the same blobs (**inferred** from the PG lock discipline). If it did find a shared blob, `_move_to_collection` would return `-EXDEV` and change nothing (Phase 2, SharedBlobRefused). The remove would then delete the object, and no entry would exist, although the log line would say `mode=rename`. The disk scan in every scenario would catch that as a missing entry.

**Not yet exercised (Phases 4–5):** a crash *inside* the combined txc (z01, c01), and recovery deletes under rename (s12). The recovery path is covered only by the reasoning above.

## Harness changes (workspace)

- `use-build.sh`: new builds `zc` and `zccopy` (commit = `replicavault-zc`).
- `common.sh`: `vault_mode` includes `zc` and `zccopy`.
- `summarize-results.py`: adds the `zc` and `zccopy` columns.
- `rvcheck.py`:
  - `VAULT_RE` accepts an optional `mode=` and `sha256=lazy`;
  - per-candidate records carry `mode`;
  - `log_sha_match` is `null` for lazy lines.

  The vault invariant already compared **disk bytes against the client-side checksum**, which is unchanged.
- `vault-inspect.sh`:
  - `check` reports `lazy: true` for lazy entries, and `intact` = the bytes read back without error (BlueStore verifies blob checksums on read);
  - `extract` skips the stored-checksum comparison for lazy entries and prints the SHA-256 computed at extract time.
  - Bug found and fixed: the first version wrote `"lazy"` inside a bash double-quoted `python3 -c`. Result file `s06-recreate-after-delete-20261004T090604.json` (0/2) is that **script bug**; it is kept.

## Checks run on the zc cluster (fsid `4c038ade-…`, build `zc 33b89ae`)

| Check | Result | File |
|---|---|---|
| `smoke.sh` | pass. 16 deletes, 32 vault lines (16 `path=primary`, 16 `path=repop`), all `mode=rename` | `results/zc/smoke-20261004T090441.json` |
| s06 recreate after delete, 2 runs, `RV_DISK_SCAN=all` | 2/2. Per run, 12 deletes, each with 2 renamed entries found and intact, bytes = client sha256; 0 unlogged | `results/zc/s06-recreate-after-delete-20261004T091320.json` |
| s10 snapshot delete, 3 runs, `RV_DISK_SCAN=all` | 3/3. Case A renamed, case B copied (clone in the delete's own txn), on primary and retainer; no asserts in any OSD log | `results/zc/s10-snapshot-delete-20261004T092244.json` |

**Ordering deviation:** CLAUDE.md says z01 runs "before anything else on the cluster". s06 and s10 above ran before it, as Phase 3 sanity checks (smoke alone never reads a vault entry). They are not counted as Phase 5 results. z01's per-run deep fsck still guards everything that follows. The full regression (Phase 5) runs after z01.
