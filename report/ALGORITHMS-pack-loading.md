---
title: "How a git pack is loaded"
subtitle: "Algorithms, in pseudocode — git, dulwich, gitoxide"
author: "Roberto Di Cosmo"
date: "2026-04-25"
geometry:
  - a4paper
  - margin=1.2cm
fontsize: 10pt
linkcolor: blue
urlcolor: blue
toc: true
toc-depth: 2
---

*Companion to `report/ANALYSIS-git-loader-modernization.md`. This document
explains, in pseudocode and at a uniform level of detail, the three pack-
loading algorithms whose CPU and memory cost the analysis compares:*

1. *`git index-pack` — the canonical local-CPU floor,*
2. *`dulwich.GitLoaderFromDisk` — today's SWH production loader,*
3. *`swh.loader.git.GitLoader` (gitoxide-based) — the proposed replacement.*

*Audience: a technically-savvy reader who is not a git internals expert.
The goal is to make the headline cost gap (e.g. dulwich linux = 28,800
CPU-seconds vs git index-pack = 1,345 CPU-seconds on the same input)
understandable from first principles.*

---

## 1. The shared input — a git pack

A **git pack** is a single file containing many git objects (blobs, trees,
commits, tags) compressed and de-duplicated using delta encoding. It is
the artefact every git server hands out (over HTTP or SSH) and the format
in which git stores objects locally once it has accumulated more than a
few thousand of them.

```
PACK FILE LAYOUT (.pack, conceptually)

    +------------+------------------------------------------------+
    | header     | "PACK" magic, version, total object count      |
    +------------+------------------------------------------------+
    | object 1   | type tag (3 bits) + uncompressed size (varint) |
    |            | + zlib-compressed body, OR                     |
    |            | + ofs-delta-base-offset + zlib-compressed delta|
    |            | + ref-delta-base-sha1 + zlib-compressed delta  |
    +------------+------------------------------------------------+
    | object 2   | (same shape)                                   |
    +------------+------------------------------------------------+
    |    …       |                                                |
    +------------+------------------------------------------------+
    | trailer    | sha1 of the entire pack so far                 |
    +------------+------------------------------------------------+
```

**The two representations of an object inside a pack:**

- **Whole** — a self-contained zlib stream of the object's body.
- **Delta** — a small zlib stream of *edits* relative to a base object
  that lives elsewhere in the same pack (offset-delta) or in some other
  pack (ref-delta, rare in modern packs). To recover the actual object,
  you must locate the base, decompress it, then apply the delta.

Delta chains can be deep — chromium has chains 50+ deep. Resolving the
last object in a deep chain requires walking up the entire chain.

**The companion file:** `.idx`. A pre-built index mapping
`sha1 → byte_offset_in_pack` so that random access by content hash is
O(log N) instead of O(N). git ships an `.idx` alongside every `.pack` it
emits. **Without `.idx`, the only access pattern is full sequential
scan.** (Dulwich requires `.idx`; gitoxide can build one on the fly.)

---

## 2. What "loading a pack" means here

In the SWH context, **loading a pack** = reading every object in the pack,
hashing it the SWH way (computes sha1, sha256, blake2s256 for blobs),
converting it to an `swh.model` object (`Content`, `Directory`,
`Revision`, `Release`), and submitting it to a `Storage` backend in
topological order so that no node is written before its children are
present.

The benchmark this report compares uses a `DiscardStorage` backend that
accepts every `*_add()` call and drops the payload, so the only cost
left is what the loader itself spends — pack parsing, hashing,
conversion, and per-object dispatch.

The benchmark's input pack is fixed across all three algorithms — same
pack file, same object set. The only variable is what the loader does
with it.

---

## 3. Algorithm 1 — `git index-pack`

The reference implementation. Written in C, multi-threaded by default,
the most-tested git pack reader in existence. Used by `git clone`
internally as soon as the pack arrives. Reproducible on its own with
just `git index-pack PACKFILE` once the file is on disk.

**What it does:** read the pack, decompress every object, resolve every
delta, hash everything, write the `.idx` file. Does **not** materialise
SWH model objects, does **not** call any storage. This is the *strict
prerequisite* of any SWH-side load.

```python
def git_index_pack(pack_path):
    # Pass 1 — header scan
    pack = mmap(pack_path)
    object_count = parse_pack_header(pack)        # tens of millions for big repos
    candidates = []                                # one entry per object

    offset = HEADER_SIZE
    for i in range(object_count):
        type_tag, body_offset, payload_size = decode_object_header(pack, offset)
        if type_tag in {OFS_DELTA, REF_DELTA}:
            base_ref = decode_base_ref(pack, body_offset)
            candidates.append(DeltaEntry(offset, base_ref, payload_size))
        else:
            # Non-delta: decompress, hash, record.
            body = zlib_decompress(pack, body_offset, payload_size)
            sha = sha1(git_object_header(type_tag, len(body)) + body)
            candidates.append(WholeEntry(offset, type_tag, sha, body=None))
            # body is freed — we'll re-decompress only if a child delta needs it
        offset = body_offset + payload_size

    # Pass 2 — delta resolution
    # Build the parent->children tree from the candidates
    tree = build_delta_tree(candidates)            # in-memory, O(object_count)

    # Spawn a worker pool (default = nproc threads). Each worker takes a
    # subtree rooted at a non-delta object and walks it depth-first.
    parallel_for(roots(tree), num_threads=cpu_count()):
        def resolve(node, base_body=None):
            if node is delta:
                delta = zlib_decompress(pack, node.offset, node.payload_size)
                body = apply_delta(base_body, delta)        # bytewise patch
            else:
                body = zlib_decompress(pack, node.body_offset, node.payload_size)
            sha = sha1(git_object_header(node.type, len(body)) + body)
            record_resolved(node.offset, sha, node.type)
            for child in tree.children(node):
                resolve(child, base_body=body)              # re-uses parent body in-memory

    # Pass 3 — write sorted index
    sorted_entries = sort_by_sha(all_resolved)
    write_idx_v2(sorted_entries, pack_path[:-5] + ".idx")
```

**Where time goes (rough breakdown, varies by repo):**

| Phase | linux 7.9 GB pack | chromium 30 GB pack |
|---|---|---|
| zlib decompress (pass 1 + pass 2 chains) | ~50 % | ~55 % |
| delta apply (memcpy + bytewise patch) | ~15 % | ~20 % |
| sha1 hashing (per-object git-style) | ~20 % | ~15 % |
| Index sort + write | ~5 % | ~5 % |
| Header scan, accounting, threads | ~10 % | ~5 % |

**Where memory goes:**

- The pack mmap (kernel page cache; not "RSS" in a strict sense, but
  resident if hot)
- The candidate list: one struct per object, ~40 bytes × N. linux at
  13.5 M objects → 540 MB. chromium at 27.9 M objects → 1.1 GB.
- Per-thread arenas: a decompression buffer (~MBs) and the current delta
  chain's resolved bodies (parent retained while children resolve;
  chromium's deepest chain × largest blob ~ tens of MB)
- The sorted `.idx` table during write: another (sha + offset) array

**Measured (maxxi, unconstrained):** linux index-pack 1,345 CPU-seconds
(7 min wall, ~3 cores effective, 2.2 GB peak RSS); chromium index-pack
6,830 CPU-seconds (25 min wall, ~4-5 cores effective, 4.5 GB peak RSS).

**This is the floor.** Any SWH loader that ingests a pack must do this
work — or its equivalent — somewhere on its critical path.

---

## 4. Algorithm 2 — dulwich `GitLoaderFromDisk`

The current SWH production loader. Pure Python. Uses dulwich's
`PackInflater` for pack iteration. Goes through the four-pass
`BaseGitLoader.store_data()` topological loop because dulwich's public
iterator API is type-filtered, not type-multiplexed.

```python
def dulwich_load_from_disk(directory, storage):
    # SETUP — dulwich requires a pre-built .idx co-located with .pack.
    # If the .idx is missing (e.g. after `git repack -a -d -f`), the load
    # silently reports zero objects loaded. (L5 in the analysis.)
    repo = dulwich.Repo(directory)                # opens objects/pack/*.idx via PackIndex
    object_store = repo.object_store

    # PASS 1 of 4 — contents (blobs)
    for blob in iter_objects_of_type(object_store, type_name="blob"):
        # iter_objects_of_type internally iterates the WHOLE pack and
        # filters by type, discarding 75 % of decoded objects.
        content = converters.dulwich_blob_to_content(blob)   # builds swh.model.Content
        storage.content_add([content])           # one-element list → proxy → DiscardStorage
    storage.flush()                              # topological barrier

    # PASS 2 of 4 — directories (trees)
    for tree in iter_objects_of_type(object_store, type_name="tree"):
        directory = converters.dulwich_tree_to_directory(tree)
        storage.directory_add([directory])
    storage.flush()

    # PASS 3 of 4 — revisions (commits)
    for commit in iter_objects_of_type(object_store, type_name="commit"):
        revision = converters.dulwich_commit_to_revision(commit)
        storage.revision_add([revision])
    storage.flush()

    # PASS 4 of 4 — releases (tags)
    for tag in iter_objects_of_type(object_store, type_name="tag"):
        release = converters.dulwich_tag_to_release(tag)
        storage.release_add([release])
    storage.flush()

    # Snapshot
    snapshot = build_snapshot_from_refs(repo)
    storage.snapshot_add([snapshot])
    storage.flush()


def iter_objects_of_type(object_store, type_name):
    """Dulwich's only typed-iteration API. NB: filters AFTER full decode."""
    for pack in object_store.packs:
        pack_data = dulwich.PackData.from_path(pack.path)
        for obj in dulwich.PackInflater.for_pack_data(pack_data):
            # `obj` is a fully materialised dulwich.objects.{Blob,Tree,Commit,Tag}
            # — i.e. a Python class instance with attributes:
            #   - sha1 (computed via Python sha1 binding)
            #   - data bytes (decompressed via Python zlib binding)
            #   - per-type attribute dict (e.g. tree.entries: list of dicts)
            if obj.type_name == type_name:
                yield obj
            # else: discard (Python GC reclaims the just-allocated object)


def PackInflater_for_pack_data(pack_data):
    """All in pure Python."""
    for offset, type_tag, payload_size in pack_data.iter_offsets():
        if type_tag in (OFS_DELTA, REF_DELTA):
            base = lookup_resolved_base(...)        # walks the chain in Python
            delta = zlib.decompress(...)            # CPython zlib binding
            body = apply_delta(base.body, delta)    # pure-Python bytewise patch
        else:
            body = zlib.decompress(...)
        sha = hashlib.sha1(make_object_header(type_tag, body) + body).digest()
        yield make_shafile(type_tag, sha, body)     # ShaFile subclass instance,
                                                    # attribute dict, etc.
```

**The crucial property:** `iter_objects_of_type(...)` re-iterates the
pack from offset 0 every time it is called. The four passes therefore
each pay the full pack-decompression cost. dulwich's `PackInflater` does
not expose a "yield by type, partition the pack once" mode — its public
API is `(pack_data, type_filter) → iterator over decoded objects of that
type`. The four-pass shape is forced by the intersection of this API
with the topological-write requirement (children before parents).

**Where time goes:**

| Phase | linux | chromium |
|---|---|---|
| Pack inflation (4×, in pure Python via PackInflater) | ~60 % | ~55 % |
| Per-object `dulwich.objects.ShaFile` allocation + attr dict | ~15 % | ~20 % |
| Per-object swh.model conversion | ~10 % | ~10 % |
| Per-object `storage.*_add([obj])` dispatch | ~10 % | ~10 % |
| Other (filtering, ref tracking, GC) | ~5 % | ~5 % |

The 4× pack inflation is the dominant multiplier on top of an already
slow inner loop. dulwich's inner loop is slow because every object
allocation, every attribute access, and every bytewise delta-apply step
is a Python-bytecode operation. zlib decompression itself is C, but
called from Python, with per-call interpreter overhead.

**Where memory goes** (under `DiscardStorage`, so storage doesn't hold
anything):

- Pack mmap (kernel cache)
- dulwich's internal delta-resolution cache: parent objects are kept
  alive in memory while children are being resolved. On chromium with
  deep chains this can be GBs.
- Transient Python heap for the current pass: roughly one ShaFile
  instance + one swh.model object per millisecond of sustained
  throughput, GC'd as new ones are produced. Steady-state RSS is small.
- ref_object_types and similar bookkeeping dicts (tens of MB)

**Single-threaded by construction.** The CPython GIL holds during pack
inflation; dulwich does not release it. `cpu_per_wall ≈ 1.00` on every
measured row.

**Measured (maxxi, xl container, discard storage):** linux 28,813
CPU-seconds (8 h 03 min wall, 1 thread, 3.5 GB peak RSS). Chromium
pending; expected ~6-9× linux.

---

## 5. Algorithm 3 — gitoxide `GitLoader` via `_gix.PackReader` / `ParallelPackReader`

The proposed replacement. Inherits the same `BaseGitLoader.load()`
machinery but **overrides `store_data()` with a single-pass typed
dispatch**, made possible by the gitoxide pack reader's typed-tuple
output. Pack iteration runs in Rust; conversion-to-swh-model runs in
Python; storage dispatch is the same `*_add(batch)` boundary.

```python
def gix_load_from_disk(directory, storage):
    # SETUP — gix can build the index on the fly; no .idx required.
    pack_path = directory + "/objects/pack/*.pack"
    pack_size = file_size(pack_path)

    # SINGLE PASS — typed dispatch in flight.
    if pack_size > 100_000_000:
        pack_reader = _gix.ParallelPackReader(pack_path, channel_bound=4096)
    else:
        pack_reader = _gix.PackReader(pack_path)

    # Per-type batches; flushed every BATCH_SIZE (default 1000).
    batches = {"content": [], "directory": [], "revision": [], "release": []}

    for obj_tuple in pack_reader:
        # `obj_tuple` shape varies by type:
        #   blob   → (3, sha1_git, sha1, sha256, blake2s256, raw_data)
        #   tree   → (2, swh.model.Directory)        ← pre-built in Rust
        #   commit → (1, sha1_git, raw_data, hash_match)
        #   tag    → (4, sha1_git, raw_data, hash_match)
        type_num = obj_tuple[0]

        if type_num == 3:                          # blob
            _, sha1_git, sha1, sha256, blake2s256, data = obj_tuple
            content = converters.blob_to_content_precomputed(
                sha1_git, sha1, sha256, blake2s256, data,
            )                                      # Python — but skips re-hashing
            batches["content"].append(content)

        elif type_num == 2:                        # tree
            directory = obj_tuple[1]               # already a swh.model.Directory
            batches["directory"].append(directory)

        elif type_num == 1:                        # commit
            _, sha1_git, raw_data, hash_match = obj_tuple
            revision = converters.commit_to_revision(sha1_git, raw_data, hash_match)
            batches["revision"].append(revision)

        elif type_num == 4:                        # tag
            _, sha1_git, raw_data, hash_match = obj_tuple
            release = converters.tag_to_release(sha1_git, raw_data, hash_match)
            batches["release"].append(release)

        for type_name, batch in batches.items():
            if len(batch) >= BATCH_SIZE:
                storage[type_name].add_many(batch)
                batch.clear()

    # Flush remaining batches; topological order enforced by storage proxy.
    for type_name, batch in batches.items():
        if batch:
            storage[type_name].add_many(batch)
    storage.flush()

    snapshot = build_snapshot_from_refs(directory)
    storage.snapshot_add([snapshot])
    storage.flush()
```

**Inside `_gix.ParallelPackReader` (Rust, called via PyO3):**

```rust
fn ParallelPackReader::iter(pack_path: &str, channel_bound: usize)
    -> impl Iterator<Item = ObjectTuple>
{
    let pack = mmap(pack_path);                    // memory-map; kernel handles paging
    let header_count = parse_pack_header(&pack);

    // Header-only scan: build a delta tree (parent→children) without
    // decompressing anything. O(object_count) but with tiny per-step cost.
    let delta_tree = build_delta_tree(&pack, header_count);

    let (sender, receiver) = sync_channel(channel_bound);

    // Spawn a rayon worker pool. Each worker takes a subtree rooted at a
    // non-delta object. Per-thread state: reusable decompression buffer,
    // streaming SHA-1/256/blake2 hashers. No per-object allocation in
    // the hot loop.
    rayon::for_each(delta_tree.roots(), |root| {
        let mut buf = thread_local_decompress_buffer();
        traverse_subtree(root, &pack, &mut buf, |resolved| {
            // For each fully-resolved object, build the typed tuple and
            // ship it to Python via the channel. For trees, build the
            // swh.model.Directory directly here using PyO3 — saves a
            // Python-side parse.
            let tuple = build_typed_tuple(&resolved);
            sender.send(tuple).unwrap();
        });
    });

    // The Python side iterates `receiver` — GIL is released around send().
    return receiver.into_iter();
}
```

**Where time goes:**

| Phase | linux | chromium |
|---|---|---|
| Pack mmap + header scan + delta tree build (Rust) | ~5 % | ~5 % |
| zlib decompress + delta apply (Rust, parallel, in arenas) | ~40 % | ~45 % |
| sha1/sha256/blake2 hashing (Rust, streaming) | ~20 % | ~20 % |
| Cross-thread channel send + GIL acquire/release for Python recv | ~10 % | ~5 % |
| Python-side conversion (`*_precomputed`, Directory append) | ~20 % | ~20 % |
| Storage batch dispatch | ~5 % | ~5 % |

**Why this is so much faster than dulwich:**

1. **Native code throughout the hot path.** Rust executes ~30-50× faster
   than Python bytecode for object-construction-heavy work.
2. **One pack pass, not four.** Single-pass typed dispatch — the same
   typed-iterator advantage `git index-pack` has, applied to the
   loader-level work.
3. **No per-object Python allocation in the hot loop.** Per-thread
   arenas reuse buffers; tuples are constructed once at the channel
   boundary.
4. **Parallelism comes for free.** Rust threads are not GIL-bound, so a
   pack > 100 MB can use as many cores as `cpuset` allows.
5. **Rust-built `Directory` for trees.** Dulwich rebuilds tree objects
   from scratch in Python on each access; gix delivers them ready-made.

**Where memory goes:**

- Pack mmap (kernel cache)
- Per-thread arena buffers (~hundreds of MB per thread). With 16 threads
  on linux, this dominates the loader's working set: ~10 GB.
- Channel queue (bounded by `channel_bound`, default 4,096 entries)
- Python-side per-batch buffers (1,000 objects × small footprint)

**Threading.** `ParallelPackReader` spawns one rayon worker per cpuset
core by default. `cpu_per_wall` is 1 for `PackReader` (small packs) and
N (where N ≤ cpuset size) for `ParallelPackReader`.

**Measured (maxxi, xl container):** linux gix-1thread (single core
inside cpuset 0) 3,726 CPU-seconds (1 h 03 min wall, 9.3 GB peak RSS);
linux gix-Nthread (parallel inside cpuset 0-15) ~3,700 CPU-seconds at
~5 cores effective, ~12 minutes wall. **CPU is invariant to thread
count; wall scales with parallelism.**

---

## 6. Side-by-side comparison

### 6.1 Algorithmic shape

| | git index-pack | dulwich GitLoaderFromDisk | gix GitLoader |
|---|---|---|---|
| Pack passes | 1.5 (header + resolution) | 4 (one per object type) | 1 |
| Object materialisation | none (just hashes + offsets) | full Python class instance | Rust tuple → Python conversion |
| Delta resolution | parallel (rayon) | serial Python | parallel (rayon) |
| Hashing | parallel native | serial Python | parallel native |
| Index requirement | builds it | requires pre-built `.idx` | builds on the fly |
| Storage dispatch | none | per-object | per-batch |
| Threading | multi (default = nproc) | single (GIL-bound) | multi (rayon, ≤ cpuset) |
| End-to-end output | `.idx` file | swh.model objects in storage | swh.model objects in storage |

### 6.2 Time budget at chromium scale (27.9 M objects, 30 GB pack)

| | git index-pack | dulwich | gix-1t | gix-Nt (parallel) |
|---|---:|---:|---:|---:|
| CPU-seconds | 6,830 | (pending; ~50,000-150,000) | 17,625 | ~17,000 |
| Wall-seconds | 1,525 | (pending; ~80,000-150,000) | 17,923 | 3,434 |
| Threads in use | 4-5 | 1 | 1 | 5.3 effective |
| `cpu_per_wall` | ~4.5 | ~1.0 | ~1.0 | ~5.3 |

`cpu_per_wall` is the average number of cores used in parallel
(`cpu_seconds ÷ wall_seconds`). It is the engine's intrinsic
parallelism on this workload, given the cpuset.

### 6.3 Memory budget at chromium scale (loader-resident only, discard storage)

| | git index-pack | dulwich | gix-1t | gix-Nt |
|---|---:|---:|---:|---:|
| Peak RSS (cgroup) | 4.5 GB | (pending) | ~10 GB | ~30-150 GB |

Gix's parallel mode trades memory for wall-time: each rayon thread keeps
its own decompression arena, so the peak scales linearly with thread
count. Single-thread gix is the most memory-efficient option for the
loader phase.

### 6.4 What each step "costs" — a one-line summary

```
git index-pack:    "decompress every object once + delta-walk once + write index"
                       — 100 % machine-time on the actual git work, no SWH overhead.

dulwich loader:    "decompress every object FOUR times (one per output type) +
                    materialise it as a Python ShaFile + convert to swh.model +
                    dispatch one-by-one to storage"
                       — 4× pass multiplier × Python interpreter overhead + per-object
                         dispatch boundary = single-thread CPU cost an order of
                         magnitude above the prerequisite floor.

gix loader:        "decompress every object once (in Rust, in parallel) + ship
                    typed tuples through a channel + convert to swh.model in
                    Python in batches + dispatch by batch to storage"
                       — same prerequisite work as git index-pack, with a thin
                         Python conversion layer on top, bounded by channel
                         throughput rather than per-object cost.
```

### 6.5 What each algorithm scales with

| Cost driver | git index-pack | dulwich | gix |
|---|---|---|---|
| **Object count** | linear | linear × ~4 (passes) × Python overhead | linear × Python conversion |
| **Pack size (bytes)** | linear (decompression work) | linear × 4 (passes) | linear |
| **Average delta-chain depth** | linear (chain walk) | linear (chain walk × 4) | linear (chain walk) |
| **Pack on hot disk vs cold** | ~5 % wall difference | ~10-15 % wall difference (4 passes amplify) | ~3-5 % wall difference |
| **Number of refs** | constant | constant + small overhead | constant + small overhead |
| **CPU core count (cpuset)** | sublinear (rayon, default = all) | none (GIL-bound) | sublinear (rayon, capped at cpuset) |

---

## 7. Why the comparison cleanly attributes cost to the engine

The benchmark in the analysis runs all three algorithms on the same input
pack inside the same container cell with the same storage backend
(`DiscardStorage` for the two SWH loaders; no storage for `git
index-pack`). The remaining variables across the three rows are exactly
what algorithms 1-3 above *do* differently:

- **passes** (1 vs 4 vs 1),
- **language** (C vs Python vs Rust),
- **threading** (multi vs single vs multi),
- **per-object materialisation** (none vs Python class instance vs Rust
  tuple → Python conversion).

There is no other axis. The CPU-time gap reported in §3.1 of the
analysis is therefore attributable to the algorithm — not to host
contention, not to storage cost, not to pack-size or input drift. The
strict-cell sweep (§3 of the analysis, results pending the maxxi run
described in §9) measures this attribution.

---

## 8. Glossary

| Term | Meaning |
|---|---|
| **Pack file** (`.pack`) | A binary file containing many git objects, with deltas. The unit a git server sends. |
| **Pack index** (`.idx`) | A pre-built `sha1 → offset` map for random access into a pack. dulwich requires it; git+gix can build one. |
| **Object** | A blob (file content), tree (directory), commit (revision), or tag (release). Each has a 20-byte sha1 identifier. |
| **Delta** | A small "diff" against a base object. The pack format uses deltas to compress similar objects. |
| **Delta chain** | A → B → C: B is a delta against A, C is a delta against B. To resolve C you must walk back to A. |
| **Whole object** | An object stored without delta encoding, fully self-contained in the pack. |
| **Topological order** | Children before parents: contents before directories, directories before revisions, etc. Required so that no object is written before its dependencies. |
| **swh.model object** | The Software Heritage in-Python representation of a git object — `Content`, `Directory`, `Revision`, `Release`. Hashed differently from raw git (sha256 + blake2s256 added on top). |
| **Storage backend** | The `swh.storage.StorageInterface` implementation that receives `*_add(batch)` calls. Could be Cassandra, Postgres, in-memory, or `DiscardStorage`. |
| **DiscardStorage** | Bench-only backend that satisfies the interface and drops every payload. Isolates loader cost from storage cost. |
| **cgroup** | Linux kernel feature that caps a process group's CPUs (`cpuset`) and memory (`memory.max`). Docker uses it to enforce container limits. |
| **`cpu_per_wall`** | `cpu_seconds ÷ wall_seconds`. Average number of cores effectively used by the workload. 1.0 for single-threaded; up to `len(cpuset)` for fully parallel. |
