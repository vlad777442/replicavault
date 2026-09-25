# ReplicaVault pilot — pre-registered criteria

Date: 2026-09-25
Ceph commit: c92aebb279828e9c3c1f5d24613efca272649e62 (v19.2.3)
Source: docs/ReplicaVault-proposal-v2.md §6, copied verbatim. This file is frozen after its first commit.

**Gate.**
- **Pass** if, across every scenario in step 5, no deleted object reappears, deep-scrub reports no inconsistency, the vault copy exists and is intact on the designated replica — including after OSD restart and PG split or merge — and a manual restore produces a new object version with matching content.
- **Fail** if any scenario requires changing how peering decides authority; if step 1 leaves extending BlueStore (option b) as the only viable mechanism; or if the prototype is not passing within the three-week time box.
- **Pass with revised hypotheses** if step 1 leaves only a copying move (option a). H1 is restated as a bounded copy cost, Figure A is reframed around that cost, and baseline B3 is dropped because it becomes the design. The revision is committed before building.

**Decision rule.** Pass: proceed as written. Pass with revised hypotheses: proceed with the committed revisions. Fail: switch to EXODUS, the approved fallback, and run its pilot immediately.

