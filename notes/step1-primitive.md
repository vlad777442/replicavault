# Step 1: can BlueStore move an object out of its PG without copying?

Source: Ceph v19.2.3, commit `c92aebb279828e9c3c1f5d24613efca272649e62`, checked out at `/data/ceph` (branch `replicavault-pilot`).
All `path:line` references are relative to `/data/ceph/src` at that commit. Written 2026-09-25.

## 1. Answer

**No, not with any operation BlueStore supports today.** Every zero-copy operation is confined to one collection:

- **Move-rename is same-collection only.** `OP_COLL_MOVE_RENAME` and `OP_TRY_RENAME` hit `ceph_assert(op->cid == op->dest_cid)` (`os/bluestore/BlueStore.cc:15859`). The older cross-collection ops are dead code: `OP_COLL_ADD` and `OP_COLL_REMOVE` abort with "not implemented", and `OP_COLL_MOVE` aborts with "deprecated" (`BlueStore.cc:15844–15854`).
- **Clone takes a single collection.** `OP_CLONE` and `OP_CLONERANGE2` have one `cid` field in the op itself (`os/Transaction.h:120–122`, builders at `:978–1011`). The destination onode is looked up in the source's collection (`BlueStore.cc:15815–15842`). `_clone` also rejects a destination whose hash differs from the source's (`BlueStore.cc:18017–18021`). The zero-copy path (`bluestore_clone_cow`, default `true`, `common/options/global.yaml.in:5299`) calls `extent_map.dup` / `dup_esb` with that single collection (`BlueStore.cc:18111–18115`).
- **Split and merge move no data.** They don't move objects at all. In BlueStore a collection is just a key range over (shard, pool, hash-prefix) (`get_coll_range`, `BlueStore.cc:286–330`). Object keys start with shard, pool and hash (`_key_encode_prefix`, `BlueStore.cc:353–358`). `_split_collection` and `_merge_collection` change `cnode.bits` and re-home in-memory cache entries (`split_cache`, `BlueStore.cc:5126`). No on-disk object key changes (`BlueStore.cc:18336–18430`). Both assert that source and destination are PG collections (`:18361–18364`, `:18416–18418`).
- **Shared blobs are tracked per collection in memory.** Each `Collection` owns a `SharedBlobSet`, keyed by sbid (`os/bluestore/BlueStore.h:582–620`, member at `:1636`). Each `SharedBlob` and `Blob` points back at its collection (`BlueStore.h:533`, `:639`). A shared blob is opened by looking it up in *the opening collection's* set only (`Collection::open_shared_blob`, `BlueStore.cc:4994–5014`). The persistent refcount record lives in `PREFIX_SHARED_BLOB` under the sbid, which is global. So if two collections opened the same sbid, they would each get their own in-memory `SharedBlob` and write conflicting refcount updates. That is what a cross-collection clone would break. BlueStore guards against a leftover at shutdown: `ceph_assert(shared_blob_set.empty())` (`BlueStore.cc:18790–18795`).
- **Omap keys depend on the collection.** With per-PG or per-pool omap, keys are prefixed with `o->c->pool()` and the object hash (`Onode::calc_omap_header/key/tail`, `BlueStore.cc:4661–4705`). An onode that ended up read through a different collection would look for its omap under the wrong prefix.

### The one loophole, and why I rejected it

`_rename` does not check that the new name falls inside the collection's key range (`BlueStore.cc:18171–18225`). The only assert is that source and destination collection are the same. So a same-collection rename to a name in pool `-1` would put the on-disk key in the **meta** collection's range. It would be zero-copy, and fsck would accept it, because fsck only requires every key to be owned by *some* collection (`BlueStore.cc:10447–10461`).

This relies on behaviour BlueStore doesn't intend, and I found concrete hazards:

- **Rename hazard 1 (inferred, not verified): stray-PG removal could abort the OSD.** The renamed onode stays in the PG collection's in-memory `onode_space` (`BlueStore.cc:18213`). `_remove_collection` returns `-ENOTEMPTY` if any cached onode `exists` (`BlueStore.cc:18276–18286`). That error is fatal, `ceph_abort_msg("unexpected error")` (`BlueStore.cc:15703–15710`), so stray-PG removal could abort the OSD whenever the vaulted onode is still cached.
- **Rename hazard 2 (verified in code): omap data would be orphaned after restart.** Once the object is read through meta, `c->pool()` changes, so the lookup uses the wrong omap prefix.
- **Rename hazard 3 (verified in code): space would be charged to the wrong pool.** Per-pool statfs is charged to the transaction's pool (`BlueStore.cc:14126–14131`). The meta collection is `META_POOL_ID`.

I'm treating this loophole as equivalent to **option (b)**: making it safe would take BlueStore changes. I do not recommend it for the pilot.

## 2. Which option follows

### Option (c): hidden entry inside the PG collection

**Verified in code: this can't meet the gate.** Anything in the PG collection's key range falls into one of these cases:

- **A normal or clone object.** Listed by scrub and backfill (`PGBackend::objects_list_partial` / `objects_list_range`, `osd/PGBackend.cc:346–446`). It would show up as an unexpected object, and the gate requires scrub to report no inconsistencies.
- **A temp object (`pool = -2 - P`).** These are filtered out of scrub and backfill listings (`PGBackend.cc:393`, `:437`), which is good. But the OSD deletes them at every boot (`OSD::clear_temp_objects`, `osd/OSD.cc:5011–5066`, temp match at `:5038`, removal at `:5054`). That breaks scenario 8.
- **A generation object (non-`NO_GEN`).** Also filtered from listings. But scrub itself deletes it once it is older than the rollback trim point (`PG::_scan_rollback_obs`, `osd/PG.cc:2168–2190`, called from `osd/scrubber/pg_scrubber.cc:1358`).
- **Any of the above, when the PG leaves the OSD.** Stray-PG removal lists *everything* in the collection, temp range included, and removes it before `remove_collection` (`PG::do_delete_work`, `osd/PG.cc:2716–2760`). That breaks the second half of scenario 4 (`osd out` of the retaining OSD).

Making option (c) work would mean editing scrub listing, backfill listing, or PG deletion. `CLAUDE.md` rule 3 forbids the first two, and the third is a PG-level path, out of scope for v1.

### Option (a): copying move into a hidden namespace in the meta collection (recommended)

This is option (a) with a specific destination. On the retaining OSD, the local transaction does two things:

1. **Write the vault copy into the meta collection** (`coll_t::meta()`, `TYPE_META`, `osd/osd_types.h:648–652`). It goes under a reserved namespace, e.g. `ghobject_t(hobject_t(<vault-name>, "", CEPH_NOSNAP, 0, POOL_META, "replicavault"))`. The copy is a write of the object's data, xattrs and omap.
2. **Remove the object from the PG collection** as before.

BlueStore allows one transaction to touch a PG collection and meta. The pool-consistency assert only checks PG collections (`BlueStore.cc:15618–15625`).

What this buys:

- **Boot.** `OSD::load_pgs` skips any collection that is not a PG: `"load_pgs ignoring unrecognized"` (`osd/OSD.cc:5309–5312`). `clear_temp_objects` only looks inside PG collections (`OSD.cc:5018–5019`). Nothing at boot enumerates or deletes unknown meta objects. That last point comes from reading these two functions; I haven't searched the whole OSD.
- **Scrub, backfill, recovery, stray removal.** All of them work on PG collections only, so none can see or delete meta objects (sources as above).
- **Split and merge.** They don't touch meta (`BlueStore.cc:18361–18364`).
- **fsck.** Meta owns pool `-1` keys, so the vault is not a "stray object" (`BlueStore.cc:10447–10461`).

The costs:

- **Delete cost grows with object size.** This is the pre-registered "pass with revised hypotheses" branch: H1 becomes a bounded copy cost, Figure A is reframed around it, and baseline B3 is dropped. §6 requires that revision to be committed *before building*.
- **One meta collection per OSD.** All vault writes land in it, so they can contend with OSD map writes (inferred; I'll measure it only if it's obviously slow).
- **Space accounting.** The vault bytes written in the PG's transaction are charged to the PG's pool in per-OSD statfs (`BlueStore.cc:14126–14131`). The originating pool's usage won't drop on delete. That is cosmetic for the gate but relevant to H3 accounting.
- **Snapshot clones.** A clone shares blobs with the head. Copying the head (not cloning it) avoids cross-collection shared blobs entirely.

### Other mechanisms considered

- **Vault as its own collection.** A new `coll_t` type would mean changing the `coll_t` encoding and parsing in `osd_types.h`. A PG-typed collection for a fake pool would go through `load_pgs` → `_make_pg`, which can call `recursive_remove_collection` when that fails (`OSD.cc:5345–5347`). Neither is better than meta, and the fake-pool variant is risky.
- **Reusing snapshot clones inside the PG.** Clones are PG objects, listed by scrub and tracked in the SnapSet. They are exactly what peering, scrub and snap trim manage, so this puts the vault under PG authority. Rejected under rule 3.

## 3. Recommended mechanism: expected behaviour and what is verified

| Situation | Expected behaviour with vault entries in meta | Status |
|---|---|---|
| OSD boot | Meta isn't a PG, so `load_pgs` skips it (`OSD.cc:5309–5312`). `clear_temp_objects` skips it (`OSD.cc:5018`). | Verified for these two functions. Rest of the boot path unverified. |
| Scrub | Lists the PG collection only (`pg_scrubber.cc:1344` → `PGBackend.cc:406`). Vault never listed. | Verified |
| Backfill / recovery | Lists the PG collection only (`PrimaryLogPG.cc:14279` → `PGBackend.cc:346`). Vault never pushed. | Verified for the listing. Push path not traced (Phase 3). |
| Stray PG removal | `do_delete_work` touches only `coll` (`PG.cc:2716–2760`). | Verified |
| Split / merge | Asserted to be PG collections only (`BlueStore.cc:18361–18364`, `:18416–18418`). | Verified |
| BlueStore fsck | Pool `-1` keys belong to meta (`BlueStore.cc:10447–10461`). | Verified in code. Will be confirmed by running `ceph-bluestore-tool fsck` on a vstart OSD. |
| Mixed PG + meta transaction | BlueStore allows it (`BlueStore.cc:15597–15625`). The transaction is ordered on the PG's sequencer. | Allowed: verified. Ordering relative to other meta writers: inferred. |
| Where the rewrite hooks in | The replica applies the transaction in `ReplicatedBackend::do_repop`; the primary applies its local copy in `submit_transaction`. | Unverified. Phase 3 will trace it. |

## 4. Confidence, and what would change the answer

- **High confidence** that BlueStore has no supported cross-collection zero-copy move or clone. The assert and the op format are unambiguous.
- **High confidence** that a vault inside the PG collection fails the gate (boot temp cleanup, scrub rollback cleanup, stray-PG deletion).
- **Medium-high confidence** that a copy into meta is safe for the gate scenarios. The main unknowns are:
  - something outside `load_pgs` / `clear_temp_objects` that scans meta, such as OSD superblock or map trimming. I'll check in Phase 3 by grepping for `collection_list` on `meta_ch`.
  - the cost of the copy for large objects.

What would change the answer:

- **Toward zero-copy.** You could decide that a small BlueStore patch counts as (b)-lite. For example: a supported cross-collection rename that also moves the cached onode and omap prefix, or restricted to objects with no shared blobs. It could probably be written, but the gate says option (b) as the only viable path means fail. That's your call, not mine.
- **Against option (a).** Evidence that some OSD path scans or trims unknown meta objects.

## Addendum (2026-09-25, Phase 3): other code that lists meta

I searched every `collection_list` caller in `osd/`. All are scoped to PG collections except `OSD::trim_stale_maps` (`osd/OSD.cc:8017–8050`), which lists the whole meta collection. It removes any object whose name contains `osdmap.` with a parsed epoch below `oldest_map`, and parses with `stoul`, which can throw on a bad suffix (`OSD.cc:8005–8014`). It runs only from the admin-socket command `trim stale osdmaps` (`OSD.cc:3169–3180`).

Consequence: vault entry names must never contain `osdmap.`. The design note fixes this with a hex-encoded name (`design-note.md` §3). No other automatic path scans meta, so the recommendation (option a) stands, now at high confidence for the boot, scrub, backfill, stray and split/merge paths.
