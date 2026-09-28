# ReplicaVault phase 2 — pre-registered criteria

- Date: 2026-09-28
- Ceph commit at registration: `17451c9003d3e9b5e72d1d1a09b2397cf33eab1f` (pilot prototype, branch `replicavault-pilot`, on v19.2.3 `c92aebb279828e9c3c1f5d24613efca272649e62`). Phase 2 work goes on branch `replicavault-p2`, based on it.
- Source: `CLAUDE.md` (phase 2), Phase 0 step 3, copied verbatim. This file is frozen after its first commit.

```
Phase 2 criteria

Coverage (B1): pass if, on the phase 2 prototype, across pilot scenarios s01–s12
and adversarial scenarios a01–a05, every acknowledged delete has at least one
intact vault entry, and pilot invariants 1, 2 and 4 hold in every run.

Crash consistency (B3): pass if, across at least 100 crash runs (c01), no
acknowledged delete lacks an intact vault entry after restart, and BlueStore
fsck is clean on every OSD. Duplicate entries are counted and reported, not
failures.

Read-after-queue (B3): pass if, across at least 200 runs (c02), the vault
entry's content always equals the last write acknowledged or queued before the
delete.

Limits: fail if closing the coverage gap requires changing how peering decides
authority, PG log contents, scrub, or backfill logic.

Cost probe (A3): no pass/fail. Report only.
```
