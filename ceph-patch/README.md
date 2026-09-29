# ReplicaVault Ceph patches

These patches reproduce the ReplicaVault prototype from this repository alone. Each series applies to a clean Ceph **v19.2.3** checkout (`c92aebb279828e9c3c1f5d24613efca272649e62`).

| Series | Commits | Result | What it is |
|---|---|---|---|
| `pilot/` | 2 | `17451c9003d3e9b5e72d1d1a09b2397cf33eab1f` | Pilot prototype, evaluated in `results/GATE_REPORT.md` |
| `p2/` | 3 | `ef0be10b667cfdfd15512eb2f8e79128de0d537f` | Phase 2: the pilot's two commits, then the primary-first retainer and primary fallback (`notes/b1-design.md`, design (i)) |

`p2/0001` and `p2/0002` have the same content as `pilot/0001` and `pilot/0002`; only the `[PATCH n/3]` numbering in the subject differs. Apply either series to a clean v19.2.3, not one on top of the other. `p2/0003` (`ef0be10`) replaces the acting-rank rule with `retainer_osd` and adds the primary's vault hook in `ReplicatedBackend::submit_transaction`, logged `path=fallback`. Build the phase 2 binary from branch `replicavault-p2` and save it as `bin/ceph-osd.p2`, which `scripts/use-build.sh p2` expects.

`pilot/0001` (`ca2a5b2`) adds `src/osd/ReplicaVault.{h,cc}` and the two hooks, in `ReplicatedBackend::do_repop` and `PrimaryLogPG::remove_missing_object`. `pilot/0002` (`17451c9`) queues the vault copy as its own transaction on the PG's sequencer.

## Apply

```sh
git clone --branch v19.2.3 --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/ceph/ceph.git ceph
cd ceph
git checkout -b replicavault-pilot
git am --committer-date-is-author-date /path/to/ceph-patch/pilot/*.patch
git rev-parse HEAD          # 17451c9003d3e9b5e72d1d1a09b2397cf33eab1f
```

`--committer-date-is-author-date` makes the commit hashes match the originals exactly, provided git's `user.name` and `user.email` are the patch author's. With any other identity, only the tree matches: `git rev-parse HEAD^{tree}` gives `601bacda641bb0446a6c31a8b7ed00c07f4e040e`.

## Build

The pilot ran on Ubuntu 24.04, g++ 13.3, and cmake 3.28.

```sh
sudo ./install-deps.sh
./do_cmake.sh -DCMAKE_BUILD_TYPE=Debug -DWITH_PYTHON3=3.12 -DENABLE_GIT_VERSION=OFF \
    -DWITH_RADOSGW=OFF -DWITH_MGR_DASHBOARD_FRONTEND=OFF -DWITH_TESTS=OFF \
    -DWITH_MANPAGE=OFF -DWITH_SPDK=OFF -G Ninja
cd build
ninja vstart-base ceph-objectstore-tool ceph-bluestore-tool
```

Two of these flags are required:

- **`-DWITH_PYTHON3=3.12`.** On Ubuntu 24.04, `do_cmake.sh` otherwise asks for Python 3.10 and configuration fails.
- **`-DENABLE_GIT_VERSION=OFF`.** Every binary and plugin then reports the fixed version `Development`. Without it, the version comes from `git describe` at configure time. The vanilla and prototype OSD binaries then disagree with the shared plugins in `build/lib`, and one of them refuses to start: `load plugin … version 19.2.3-2-g17451c9 != expected 19.2.3`.

## Both OSD binaries from one build directory

The scenarios run on vanilla first and then on the prototype, switching with `scripts/use-build.sh`. That script expects `bin/ceph-osd.vanilla` and `bin/ceph-osd.rv` to exist:

```sh
cd build
git checkout c92aebb279828e9c3c1f5d24613efca272649e62 && ninja ceph-osd && cp bin/ceph-osd bin/ceph-osd.vanilla
git checkout replicavault-pilot                        && ninja ceph-osd && cp bin/ceph-osd bin/ceph-osd.rv
```

Checking out the other commit changes `src/osd/CMakeLists.txt`, so cmake reconfigures on each switch. With `ENABLE_GIT_VERSION=OFF` that is harmless.

## Cluster

See `notes/environment.md`: a vstart cluster with 1 MON, 1 MGR and 5 BlueStore OSDs, a known `--mkfs` race on some OSDs, and the verified kill and restart commands. Then run `scripts/use-build.sh vanilla|rv` and `scripts/scenarios/run-all.sh`.

## Verification

For the result of rebuilding from these patches on a fresh clone, see `notes/log.md` (2026-09-28).
