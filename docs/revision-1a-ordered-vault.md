# Revision 1a to the ReplicaVault proposal: ordered vault, corrected cost model, coverage requirement

**Status:** APPROVED by Vlad on 2026-09-28, both thresholds marked *proposed* in §A3 (H1b 1.5×, H1e 50%) confirmed as written. Frozen from this commit on, like `PILOT_CRITERIA.md` and Revision 1.

- Date: 2026-09-28
- Amends: `docs/revision-1-copying-vault.md` (`90846fc`), which stays unedited.
- Ceph commits: `c92aebb2` (v19.2.3); pilot prototype `ca2a5b2` and `17451c9` on branch `replicavault-pilot`.
- Evidence: `notes/design-note.md` §7, `notes/log.md` (2026-09-26), `results/GATE_REPORT.md` §§3–5.

## Why this addendum exists

Revision 1 was committed before the prototype was built, as the pilot's decision rule required. The prototype then departed from it in two places, and the pilot surfaced a coverage risk that Revision 1 does not address. This file records both. Everything in it is written **after** the pilot, so none of it is pre-registration. The pilot's gate result does not depend on it: the gate criteria in `PILOT_CRITERIA.md` do not name a transaction layout or an accounting scheme.

Part A corrects descriptions of what was built. Part B adds requirements for the work that follows.

---

## Part A — corrections to Revision 1

### A1. The copy and the remove are ordered, not atomic (replaces Revision 1 §2, paragraph 2)

Revision 1 says the copy and the remove go into one BlueStore transaction and commit atomically. The first build did that. It failed `ceph-bluestore-tool fsck` on every retaining OSD, because BlueStore charged the vault bytes to the PG's pool (`BlueStore.cc:14126–14131`), producing a per-pool statfs mismatch.

As built (`17451c9`), the vault copy is queued as its **own** transaction on the PG's collection handle, immediately before the PG transaction. Both share one OpSequencer, and `_txc_finish_io` (`BlueStore.cc:14266`) submits a sequencer's transactions to the KV store in queue order. After a crash, then, one of three states holds: both are durable, only the copy is, or neither is. The remove is never durable without the copy. If only the copy survives, the delete is redelivered through repop resend or recovery and vaulted again, which leaves a duplicate entry but loses nothing.

**Status of this claim:** argued from code, not tested under crash. The next phase tests it (Part B, B3).

### A2. Vault bytes are charged to the meta pool (replaces the §4.4 / H3 bullet in Revision 1 §6)

Revision 1 says BlueStore charges vault bytes to the originating pool's per-OSD statistics. That was the bug described in A1. As built, a meta-only transaction is charged to `META_POOL_ID` (`BlueStore.h:1915`). Consequences:

- Per-pool `ceph df` figures **exclude** vault bytes. Raw OSD usage **includes** them.
- H3 measurements must therefore use vault-specific counters, as Revision 1 already requires. Pool-level statistics cannot be used as a proxy.

### A3. The cost model has a read on the apply path (amends Revision 1 §3)

Revision 1's H1 says retention costs "one local copy … and nothing else". As built, the retaining OSD also reads the entire object — data, xattrs, omap — synchronously inside `ReplicatedBackend::do_repop`, before the delete is applied. Objects can be up to `osd_max_object_size` (128 MiB by default). That read runs on the OSD's op path, so it can delay other operations served by the same op shard, including those of other PGs.

Revision 1's H1b tests only "a delete-free workload", where this cost cannot appear. H1 is restated, and H1b and H1d are replaced:

> **H1 (overhead, revised in 1a).** On each OSD that retains a delete, retention costs one full read and one local write of the deleted object, both on that OSD's apply path. It adds no network traffic, does not change the PG log, and costs nothing on OSDs that do not retain the delete. The cost is bounded by object size.

- **H1a — delete latency.** Unchanged from Revision 1, except that "a local write of *s* bytes" becomes "a local read and a local write of *s* bytes".
- **H1b — interference (replaces Revision 1 H1b).** On a mixed workload in which deletes of objects of at most 4 MiB are at most 10% of operations, p99 latency of non-delete operations on retaining OSDs is within ***1.5×*** *(proposed)* of vanilla. For larger deleted objects (16, 64, 128 MiB) the paper reports the interference curve without a threshold.
- **H1c — foreground throughput.** Unchanged.
- **H1d — bytes written (replaces Revision 1 H1d).** Extra bytes written per protected delete, summed over all OSDs, equal *s* × (number of vault copies made for that delete). The number of copies is at least one and is reported as a distribution, because missed-delete recovery (pilot scenario s12) and the fallback in B1 can each produce more than one.
- **H1e — delete-heavy stress (new).** On a delete-only workload of 4 MiB objects, retaining OSDs sustain at least ***50%*** *(proposed)* of vanilla delete throughput. If not, the paper reports the measured ceiling.

### A4. "The designated replica" in the pilot gate

The pilot gate requires the vault copy to exist "on the designated replica". The prototype designates the OSD at acting-set rank 1 **at the time it applies the delete**. Under failure that OSD changes (pilot scenarios s01 and s12). The pilot report used this reading, and it is recorded here so the gate result is read with it. It does not mean a fixed OSD per PG.

---

## Part B — requirements added after the pilot

### B1. Acknowledged delete implies a vault copy (new invariant, amends §4.1)

The pilot's retention rule vaults a delete only if the rank-1 OSD holds the object when it applies the delete. When rank 1 is a backfill target past `last_backfill`, is missing the object, or does not exist, the delete is acknowledged and vaulted nowhere (`notes/design-note.md` §§1, 4).

Under the threat model in §3.1, an attacker can create each of those conditions deliberately:

- mark the rank-1 OSD out, or remap its PGs with `ceph osd pg-upmap-items` or `pg-temp`, so rank 1 becomes a backfill target, then delete during backfill;
- reduce pool size to 1, so no rank 1 exists, then delete;
- shape acting sets with `primary-temp` or primary affinity.

This is an attack on H2, not a rare failure. The protected-delete contract gains an item:

> **5. An acknowledged delete implies at least one durable vault copy.** The client's acknowledgement is not sent until some OSD's vault copy of the deleted object's pre-delete state is durable.

The mechanism is chosen in the next phase. The leading candidate needs no message or peering change: the **primary** vaults the object locally whenever its own view says the rule's retainer will not apply the delete with the object present — a backfill target past `last_backfill`, a peer missing the object, or no such rank. Two facts need verifying in code first: that a primary never applies a delete to an object it is itself missing, and that the primary's per-peer backfill and missing state at issue time matches what the peer actually applies. Alternatives are a retainer flag in `MOSDRepOpReply`, or vaulting on every replica that holds the object.

### B2. Duplicate vault copies are attacker-inducible (amends §4.4 / H3)

A missed delete is vaulted twice (pilot scenario s12). By repeatedly marking a rank-1 OSD down and up during deletes, an attacker can drive this path on purpose and inflate retained capacity. H3's evaluation adds a workload that does this and reports retained bytes per deleted byte under it. The retention mechanism must still never *drop* a copy to make room. How capacity pressure is handled is §4.4's policy and is unchanged.

### B3. Crash consistency is tested, not argued

A1's ordering argument is tested by crash injection before the full evaluation: repeatedly killing a retaining OSD with SIGKILL under a delete stream, then checking with fsck and the vault that no acknowledged delete lacks a copy. Duplicates are counted, not treated as failures.

### B4. The prototype is published with the evidence

The Ceph changes live on a local branch, and the pilot's notes cite code no one else can see. The patch series against `c92aebb2` is committed to the workspace repository under `ceph-patch/`, so the pilot is reproducible from the repository alone.

---

## What does not change

- The pilot gate result: pass with revised hypotheses.
- `PILOT_CRITERIA.md` and Revision 1, both still frozen. This file amends Revision 1; it does not edit it.
- The threat model (§3), H2 and H3 as stated, and baselines B0, B1, B2 and B4.
- Items 1–4 of the protected-delete contract.
