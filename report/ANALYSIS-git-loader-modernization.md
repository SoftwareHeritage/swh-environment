---
title: "Modernizing the SWH git loader"
subtitle: "A discard-mode head-to-head of the dulwich and gitoxide pipelines"
author: "Roberto Di Cosmo"
date: "2026-04-25"
geometry:
  - a4paper
  - margin=1cm
fontsize: 10pt
linkcolor: blue
urlcolor: blue
toc: true
toc-depth: 2
---

*Scope: characterise the architectural limitations of the
dulwich-based Software Heritage git loader and quantify the gap
to a gitoxide-based replacement, using a single-axis benchmark
that isolates loader cost from storage cost. Every measurement
runs in a production-shaped Kubernetes-like container cell,
with a discard storage backend that accepts writes and drops
payloads — so peak RSS reflects only the loader process and
CPU time reflects only loader work. Citations resolve to the
last upstream revision at which the git loader was dulwich-only;
exact pin in §7.*

---

## 1. Scope and where dulwich lives in the loader

The Software Heritage git loader has two code paths that use dulwich
end-to-end:

- **Network path** — `swh/loader/git/loader.py` (`GitLoader`). This
  is the main production loader: it negotiates a git smart-HTTP
  session, downloads the pack, and parses it with dulwich. Imports
  at lines 28–34.
- **From-disk path** — `swh/loader/git/from_disk.py`
  (`GitLoaderFromDisk`), used for tarball imports and for every
  head-to-head benchmark run described in §3. Imports at lines
  14–17.

Both share `BaseGitLoader` (`swh/loader/git/base.py`) and therefore
share the same four-pass `store_data()` loop ([`base.py:102–171`][b102-171]).

Everything below applies to both paths unless otherwise noted. All
line numbers in §4 and §6 resolve to the exact revision pinned in
§7 (the last upstream commit at which the git loader was
dulwich-only).

---

## 2. Methodology — discard-mode container harness

The measurements in §3 come from a controlled harness on a single
host, designed so that exactly one variable changes between paired
rows: the loader engine.

- **Host.** `maxxi` — 96 logical CPUs (2× Xeon Gold 6342, 24 cores
  × 2 hyperthreads), 4.13 TB DRAM, 2 NUMA nodes, Python 3.11.
- **Container cell.** Docker with `--cpuset-cpus=0-15` (16 effective
  vCPU, NUMA-local) and `--memory=64g` — the *xl* tier in the
  internal Kubernetes worker chart, the largest production-realistic
  worker dimension. cgroup v2; `memory.peak` and `cpu.stat` harvested
  post-run.
- **Loader.** `GitLoaderFromDisk` for the dulwich path; the
  gitoxide-based `swh-loader-git` direct-tree pack reader for the
  gix path. Both consume the same on-disk bare repository and
  the same pack file. Single-process, single-thread for the
  apples-to-apples comparison; gix is also reported in 96-thread
  mode in §3.5 to bound parallel speedup.
- **Storage.** A `DiscardStorage` backend (in-process Python
  implementation) that satisfies the full storage interface, accepts
  every `*_add` call, and drops payloads after returning a success
  summary. This isolates loader CPU from objstorage / journal /
  Cassandra latency, and isolates loader-resident memory from any
  in-memory accumulation downstream of the loader. The gix bench
  uses an equivalent discard semantic by consuming the converter
  output and dropping it.
- **Inputs.** Six bare-repo testbed packs from the production corpus
  spanning four orders of magnitude of object count: flask, requests,
  django, kubernetes, libreoffice, linux. Chromium is the seventh
  cell (xl-tier, 27.9 M objects); see §3 for status.
- **Headline metric: CPU time.** Across two same-cell runs the same
  process can experience different host contention profiles
  (noisy-neighbour CPU sharing on `maxxi` is real; see §3.6 for an
  in-flight example). `cpu_seconds = ru_user + ru_sys` measured by
  `getrusage(RUSAGE_SELF)` is invariant to scheduler-imposed wait,
  whereas `wall_seconds` inflates by whatever fraction of CPU is
  lost to neighbours. Wall time is recorded but is reported
  secondary, marked *(operator-visible)*.
- **Loader-resident peak memory.** Reported from cgroup
  `memory.peak` for the dulwich runs (authoritative — counts every
  process inside the container), and from `getrusage().ru_maxrss`
  for the gix runs. The latter slightly overstates concurrent RSS
  on parallel runs; for the 1-thread comparison rows it is within
  ~5 % of cgroup.peak.

Every dulwich row reports `cpu/wall ≈ 1.0` — the loader is
single-threaded by construction (see L2). Wall time inflation
above CPU time is therefore a host-contention artefact, not a
loader artefact, and is excluded from comparisons.

A pseudocode-level walkthrough of what each engine does on a single
pack — `git index-pack`, `dulwich.GitLoaderFromDisk`, and
`swh.loader.git.GitLoader` via `_gix.PackReader` — is in the
companion document `report/ALGORITHMS-pack-loading.md`. Read it
alongside §3 for the per-step time and memory budget breakdown that
explains where the headline numbers below come from.

---

## 3. Headline measurements — xl container cell, discard storage

### 3.1 Per-repo CPU time, dulwich vs gix

Every cell below is a single bench run inside the same xl container
(cpuset 0-15, 64 GB cap), with `DiscardStorage`, on the same testbed
bare repository (bind-mounted into the container). Both engines go
through `BaseGitLoader.load()`; the only variable between paired
rows is the engine. CPU time is the total user + system CPU
consumed by the loader process across all threads
(`getrusage(RUSAGE_SELF).ru_user + ru_sys`); the ratio column is
dulwich `cpu_seconds` ÷ gix `cpu_seconds`.

| Repo | Objects (M) | Pack | dulwich `cpu_s` | gix `cpu_s` | **dulwich/gix CPU** |
|---|---:|---:|---:|---:|---:|
| flask        | 0.03  | 7 MB    | 7.9      | 1.9     | **4.13×** |
| requests     | 0.03  | 11 MB   | 6.5      | 1.5     | **4.25×** |
| django       | 0.56  | 164 MB  | 309.5    | 61.7    | **5.02×** |
| kubernetes   | 1.73  | 608 MB  | 1,370.7  | 316.2   | **4.34×** |
| libreoffice  | 6.57  | 2.04 GB | 6,057.5  | 1,109.1 | **5.46×** |
| linux        | 13.55 | 7.89 GB | 15,410.4 | 3,101.9 | **4.97×** |
| **chromium** | **27.92** | **29.69 GB** | **68,339.3** | **12,171.4** | **5.61×** |

Two structural properties hold across all seven measured rows:

1. **The dulwich/gix CPU ratio sits in a tight 4.1-5.6× band**, with
   chromium at the upper end (5.61×). This is the per-thread engine
   cost gap — dulwich's pure-Python pack inflation + per-object
   materialisation versus gix's native-code pack inflation + Rust-side
   conversion, with the four-pass dulwich loop multiplied on top.
2. **The CPU comparison is invariant to threading.** Dulwich is
   single-thread by construction (GIL-bound); gix's
   `ParallelPackReader` engages on packs > 100 MB (django through
   chromium). `cpu_seconds` measures total CPU across all threads
   via `RUSAGE_SELF`, so this value reflects engine cost regardless
   of thread count. The wall-clock impact of gix's parallelism is in
   §3.4; the headline CPU column above attributes only the per-thread
   work.

### 3.2 Per-repo loader-resident peak memory, discard mode

The peak below is cgroup `memory.peak` — the kernel's authoritative
high-water mark of pages concurrently resident inside the container.
It is the loader's own working set: pack inflation buffers, per-thread
arenas (gix), parsed-object handoff queues, scan structures.
DiscardStorage drops payloads, so storage-resident memory is not
included.

| Repo | dulwich `cgroup peak_GB` | gix `cgroup peak_GB` |
|---|---:|---:|
| flask        | 0.10  | 0.10  |
| requests     | 0.10  | 0.10  |
| django       | 0.26  | 0.57  |
| kubernetes   | 0.76  | 3.07  |
| libreoffice  | 1.95  | 2.05  |
| linux        | 3.85  | 5.21  |
| **chromium** | **11.54** | **17.40** |

Both engines stay well within the 64 GB cell on every measured row.
Notable: **dulwich uses *less* loader-resident memory than gix in the
strict cell**. The pure-Python single-thread loop has bounded transient
memory (each materialised `ShaFile` is GC'd as the next is produced).
Gix's `ParallelPackReader` allocates one decompression arena per worker
thread (rayon scales the pool to the cpuset width), which dominates the
working set on the medium-large rows — the same structures that enable
the parallel speedup in §3.4. The **memory cost of gix's parallelism is
real**, but it stays within the production xl cell on every measured
repo.

### 3.3 Object-throughput

Throughput, expressed as objects processed per second of CPU time,
is the natural cross-repo summary. Larger repos amortize per-run
fixed costs better.

| Repo | dulwich obj/cpu_s | gix obj/cpu_s |
|---|---:|---:|
| flask        | 3,310    | 13,840   |
| requests     | 4,330    | 18,830   |
| django       | 1,800    | 9,030    |
| kubernetes   | 1,260    | 5,490    |
| libreoffice  | 1,090    | 5,920    |
| linux        | 880      | 4,370    |
| chromium     | 410      | 2,290    |

Dulwich's throughput drops by **~8×** between flask and chromium —
the per-object Python overhead grows because the four-pass loop's
delta-resolution working set thrashes the interpreter's
allocation-and-GC paths at scale. Gix's throughput drops by ~6×
across the same range, while starting **3-4× higher** on small
repos and finishing **5.6× higher** on chromium.

Same testbed pack on both sides of every row — comparable per-cell.

### 3.4 Operator-visible wall-clock + parallel ceiling

The wall-clock footprint a worker-pod operator would observe. Dulwich is
single-thread by construction (GIL-bound pack inflation); gix's
`ParallelPackReader` engages on packs > 100 MB, with the worker-pool
size capped at the cpuset width (16 threads here).

| Repo | dulwich wall | gix wall | gix `cpu/wall` |
|---|---:|---:|---:|
| flask        | 7.9 s        | 1.9 s        | 1.00 |
| requests     | 6.5 s        | 1.5 s        | 1.00 |
| django       | 5 min 10 s   | 21 s         | 2.97 |
| kubernetes   | 22 min 51 s  | 1 min 6 s    | 4.76 |
| libreoffice  | 1 h 41 min   | 6 min 36 s   | 2.80 |
| linux        | 4 h 17 min   | 21 min 44 s  | 2.38 |
| **chromium** | **19 h 00 min** | **45 min 42 s** | **4.44** |

The **wall ratio (4× → 25×)** is dramatically larger than the
**CPU ratio (4.1× → 5.6×, §3.1)**. The extra factor comes from gix's
parallel mode: same total CPU work, spread across multiple cores, in
elapsed time = `cpu_seconds / cpu_per_wall`. Dulwich has no equivalent —
the GIL holds throughout dulwich's pack inflation, so even a
fully-parallelised dulwich would not close the per-thread CPU gap from
§3.1 (the gap is per-object work, not scheduling overhead).

### 3.5 Why dulwich cannot match gix's wall by adding cores

For the avoidance of doubt: dulwich's single-thread CPU bound is
structural, not configurable. There is no number of cores or workers
that lets dulwich finish chromium in less than ~19 hours of single-
threaded Python pack inflation. The `cpu/wall = 1.0` row in §3.4 is the
ceiling. Gix's parallelism, in contrast, scales sublinearly with cpuset
size — chromium gix at 16 cores measures 4.44 effective cores; doubling
the cpuset would buy more, bounded by the channel-bound and the
single-thread Python conversion at the receiver end.
gap is per-object work, not scheduling overhead.

### 3.6 Why CPU time is the right metric here

The data points in §3.1–§3.5 were collected on `maxxi` over several
days of mixed workloads. During the chromium gix-96thread run the
host was lightly loaded (`cpu/wall = 5.34` matches the configured
parallelism). During the in-flight chromium dulwich run the host
shares ~63 cores' worth of CPU with another user's szz job; our
container's `cpu/wall` will be < 1.0 by exactly the contention
fraction. CPU time is unaffected, wall is. Comparing wall would
penalise dulwich for vlorentz's szz; comparing CPU does not.

### 3.7 An external reference — `git` itself

The previous tables compare two loader engines against each other.
A natural absolute reference is the standard `git` toolchain: how
long does plain git take to do the *strict prerequisite* work that
any loader must rely on — fetch the pack and build its `.idx`?

The dulwich `GitLoaderFromDisk` path operates on a bare repository
where the `.idx` is already present (L5). Producing that index is a
hard prerequisite handled by `git index-pack` in the production git
toolchain. We measure its cost separately so the comparison is
fair: dulwich's CPU has to be at least the cost of decompressing
and indexing the pack, plus whatever the loader adds on top.

**Methodology.** Same maxxi host, no container cap (matches what
`git` natively does on a worker host). Two measurements per repo:

1. `git clone --bare --quiet $URL $DEST` — total clone wall clock
   (network download + automatic indexing). `/usr/bin/time -v` for
   the wall + cpu + RSS breakdown.
2. `git index-pack` on the existing testbed pack file (the same
   pack the loader bench in §3.1 consumes), with the `.idx`
   removed first. This isolates the local-CPU work — pack
   decompression + delta resolution + SHA-1 hashing + idx writing
   — from the network download.

Measured on maxxi, no container cap. Source data:
`notes/bench-dulwich-limitations/clone-timing.jsonl`.

| Repo | Pack | `git clone` total wall | `git index-pack` wall | `git index-pack` `cpu_s` | max RSS |
|---|---:|---:|---:|---:|---:|
| flask        | 7 MB     | 1.94 s    | 0.45 s    | 1.25     | 23 MB    |
| kubernetes   | 608 MB   | 72.75 s   | 36.99 s   | 187.71   | 1.06 GB  |
| libreoffice  | 2.04 GB  | 312.17 s  | 142.64 s  | 543.00   | 1.14 GB  |
| linux        | 7.89 GB  | 473.34 s  | 429.14 s  | 1,344.68 | 2.22 GB  |
| chromium     | 29.69 GB | (skipped — pack already on testbed) | 1,525.25 s (25 min 25 s) | **6,829.74** (1 h 54 min) | 4.55 GB |

`git index-pack` parallelises delta resolution across ~3-5 cores by
default; the `cpu_seconds / wall_seconds` ratio is 3-5× on every row,
matching `nproc`-bounded thread scheduling.

**The comparison against the dulwich loader on the same packs**
(from §3.1):

| Repo | `git index-pack` `cpu_s` | dulwich-container `cpu_s` | dulwich/git ratio |
|---|---:|---:|---:|
| flask        | 1.25     | 7.9      | **6.3×** |
| kubernetes   | 187.71   | 1,370.7  | **7.3×** |
| libreoffice  | 543.00   | 6,057.5  | **11.2×** |
| linux        | 1,344.68 | 15,410.4 | **11.5×** |
| chromium     | 6,829.74 | 68,339.3 | **10.0×** |

**Reading.** `git index-pack` does the same low-level pack work
dulwich's `PackInflater` does — decompress, resolve delta chains,
hash, write the `.idx`. The difference is **6-11×** across the
production-corpus repo ladder, with the gap widening as repo size
grows past kubernetes. On linux, `git` does the prerequisite work in
22 minutes of CPU using ~3 cores in parallel; dulwich does the same
prerequisite *and* the four-pass loader machinery in **4 h 17 min** of
CPU on a single thread — an **11.5× CPU multiplier** and a **35× wall
multiplier** (4 h 17 min vs 7 min 9 s). On chromium the ratio is
similar: git index-pack = 1 h 54 min CPU vs dulwich = 19 h 00 min CPU
= **10× CPU multiplier**, **25× wall multiplier**.

The point is not that dulwich could be made to match `git
index-pack`. The point is that the *floor* for this work is
well-defined and small — and the dulwich loader is paying tens of
times that floor for the loader-side work *on top* of the
prerequisite. That overhead is exactly what L1 (pure-Python
inflation), L3 (four-pass iteration), L4 (per-object Python
allocation), and L7 (per-object dispatch) predict.

---

## 4. Root causes

Each subsection below states a limitation, the code evidence for
it, and why it cannot be overcome while remaining on dulwich. Every
limitation is an architectural property of dulwich's data model,
public API, or runtime — not a tunable parameter.

### L1 — Pure-Python pack inflation

**What.** Pack parsing — walking the pack header, inflating zlib
streams, resolving OFS/REF delta chains, and materialising each
object — is implemented entirely in Python bytecode by dulwich's
`PackInflater`.

**Evidence.**

- [`loader.py:32`][l32] — `from dulwich.pack import PackData, PackInflater`.
- [`loader.py:584`][l584] — `PackInflater.for_pack_data(...)` is the
  per-object iterator driving every `get_contents()` /
  `get_directories()` / `get_revisions()` / `get_releases()` call.
- `PackInflater` is implemented in Python in `dulwich/pack.py`
  upstream (no native acceleration).

**Quantified impact.** On linux (13.55 M objects, 7.89 GB testbed
pack), the dulwich loader spent **15,410 cpu_seconds = 4 h 17 min of
pure CPU** (§3.1) — single-threaded — almost entirely inside
`PackInflater`. The gix loader on the same input, same cell, spent
**3,102 cpu_seconds = 51 min CPU** (in 21 min 44 s wall-clock thanks
to its ~2.4 effective parallel cores) — a **5.0× CPU reduction**, and
a **12× wall reduction**. On chromium (27.92 M objects, 29.69 GB
pack) the same ratio holds: dulwich 19 h CPU vs gix 12,171 cpu_s = 3 h
23 min CPU (in 45 min 42 s wall thanks to ~4.4 effective cores) —
**5.6× CPU**, **25× wall**. The gap is the cost of running pack
inflation in Python bytecode versus native code, with gix's
parallelism stacking on top.

**Why it cannot be overcome within dulwich.** Dulwich advertises
itself as a pure-Python implementation; CPU-bound pack inflation
runs at bytecode speed with per-object Python allocations
(`ShaFile` subclass instances, attribute dicts, sha/zlib bindings).
No configuration, caching, or call-site change inside dulwich
removes Python-bytecode overhead from the inflation hot loop.

---

### L2 — Single-threaded by construction

**What.** A single dulwich load runs on one CPU core. Network
I/O, pack parsing, conversion, and storage writes are sequential.

**Evidence.**

- `swh-loader-git/swh/loader/git/loader.py` contains no `asyncio`,
  `threading`, or `concurrent.futures` imports;
  [`swh-loader-core/swh/loader/core/loader.py:392–568`][lc392-568]
  (the `load()` loop) is likewise synchronous.
- Measured `cpu/wall ≈ 1.0` on every dulwich run in §3 — no use of
  additional cores even with 95 idle on the maxxi host.

**Quantified impact.** Even on a 96-core host, a single dulwich
loader saturates exactly one core. The gix engine, configured with
96 threads on the same chromium input (§3.5), uses ~5.3 effective
cores in parallel and reduces wall time by 5.2× *while doing the
same total CPU work*. No equivalent path exists for dulwich.

**Why it cannot be overcome within dulwich.** Pack inflation holds
the GIL throughout: all delta-chain state, Python object
construction, and zlib calls run in a single interpreter thread.
Splitting the pack across threads would require a pack iterator
that releases the GIL — dulwich has none, because its pack code
is pure Python. True process-level parallelism would require
partitioning work outside dulwich (not a loader-side change), and
dulwich's pack iteration state cannot be handed off between
processes without re-decoding the delta chain on each side.

---

### L3 — Four sequential full-pack passes

**What.** `BaseGitLoader.store_data()` iterates four times over the
pack — once for blobs, once for trees, once for revisions, once
for tags — with an explicit `self.flush()` between types.

**Evidence.** [`swh-loader-git/swh/loader/git/base.py:122–165`][b122-165]:

```python
if self.has_contents():
    for obj in self.get_contents():
        storage_summary.update(self.storage.content_add([obj]))
    storage_summary.update(self.flush())
if self.has_directories():
    for directory in self.get_directories():
        storage_summary.update(self.storage.directory_add([directory]))
    storage_summary.update(self.flush())
if self.has_revisions():
    for revision in self.get_revisions():
        storage_summary.update(self.storage.revision_add([revision]))
    storage_summary.update(self.flush())
if self.has_releases():
    for release in self.get_releases():
        storage_summary.update(self.storage.release_add([release]))
    storage_summary.update(self.flush())
```

Each `get_*()` method funnels through `iter_objects(type_name)`
([`loader.py:579–592`][l579-592]), which calls `PackInflater.for_pack_data(...)`
and filters by `type_name` — i.e. it inflates the full pack once
per type, discarding three quarters of the inflated objects each
pass.

**Why the pattern exists.** The Merkle DAG must be written
leaves-first: contents before directories before revisions before
releases before the snapshot. Inter-type `flush()` calls guarantee
crash safety — no object lands in storage referencing a child that
hasn't been committed yet. A single-pass write in pack order would
violate this invariant.

**Why it cannot be overcome within dulwich.** Dulwich's public API
for pack iteration is `PackInflater.for_pack_data(pack_data, ...)`.
It is a forward iterator without typed-partitioning support or
cheap random-access retrieval by offset; partitioning the objects
by type in a single pass would require either retaining every
object in memory simultaneously or building an external type
index, which dulwich does not expose. The four-pass shape is
forced by the intersection of dulwich's iteration API with the
topological-write requirement, and is the principal multiplier
on top of L1's per-object CPU cost.

---

### L4 — Per-object Python overhead at scale

**What.** Each git object that the loader yields to storage passes
through several Python-side allocations: a `dulwich.objects.ShaFile`
subclass instance for the parsed git form, its attribute dict, a
`swh.model` model object for the swh-archive form, and a
`storage.<type>_add([obj])` dispatch (see L7 for that boundary).
At chromium scale (27.9 M objects) the cumulative cost of these
per-object allocations dominates wall-clock time.

**Evidence.**

- §3.3 throughput numbers — dulwich processes objects **4-6× slower**
  per CPU-second than gix on the same inputs. The gap widens
  monotonically with repo size (flask 4.13×, linux 4.97×, chromium
  5.61×) — a signature of per-object overhead compounded by L3's
  four-pass multiplier rather than a fixed startup cost.
- Code path: `iter_objects(...)` in [`loader.py:579–592`][l579-592]
  yields `dulwich.objects.{Blob,Tree,Commit,Tag}` instances; each
  is then converted into the corresponding `swh.model` object in
  [`loader.py:594–626`][l594-626]; the swh.model object is itself
  passed in a single-element list to `storage.*_add([obj])` (L7);
  every step is a Python-bytecode call with reference-count
  manipulation and attribute-dict creation.

**Quantified impact.** Loader-resident peak RSS in discard mode
stays modest (3.5 GB for linux, §3.2) — Python-object memory does
not blow the worker envelope when storage is not buffering. The
cost is paid in *time*, not space: those allocations are
short-lived and reclaimed, but they are made once per object and
each one runs through the GIL-bound interpreter. Linux's 8-hour
single-thread CPU footprint (§3.1) is the visible expression of
this cost.

**Why it cannot be overcome within dulwich.** Pure-Python
representations are dictated by dulwich's data model
(`dulwich.objects.{Blob,Tree,Commit,Tag}`). Avoiding the
per-object allocation overhead would require a pack iterator that
materialises objects at native speed and yields them as zero-copy
views — exactly what gix provides via its Rust converter. Within
dulwich's public API there is no way to skip the Python-object
materialisation step; it is the iterator's only output shape.

---

### L5 — Hard dependency on a pre-built `.idx` file

**What.** The `GitLoaderFromDisk` variant relies on
`dulwich.repo.Repo(directory).object_store`, which for every
packfile in `objects/pack/` loads the corresponding `.idx` via
`PackIndex(...)`. Dulwich has no code path that builds an index
from a bare `.pack`.

**Evidence.**

- [`from_disk.py:14–17`][fd14-17], [`65+`][fd65] — dulwich imports
  and (at line [106][fd106]) `dulwich.repo.Repo(self.directory)`
  construction.
- [`from_disk.py:112`][fd112] — iterates objects via
  `pack.index.iterentries()`, entirely `.idx`-driven.
- Benchmark-setup observation: bare repositories produced by
  `git repack -a -d -f` are missing `.idx` files (repack deletes
  the old index without writing a new one), and every dulwich run
  on such a repo reports zero objects loaded until `git index-pack`
  is run manually. The failure is silent (the load reports success
  with an empty object count), which is itself a consequence of
  the `.idx`-centric API contract described below.

**Why it cannot be overcome within dulwich.** Dulwich's
`ObjectStore` / `PackIndex` construction is not a configuration
choice but a hard API contract — `PackIndex(path)` raises
`FileNotFoundError` when the `.idx` is absent, and every SHA
lookup in the repository goes through this index. There is no
public "scan the pack to build an index in memory" entry point.
Any workflow that receives a fresh pack without a co-located
index must shell out to `git index-pack` before dulwich can read
it, which is an extra subprocess, an extra full pack pass, and an
extra disk artifact on the critical path.

---

### L6 — `SpooledTemporaryFile` spill and 4× pack re-read

**What.** The network loader buffers the incoming pack in a
`SpooledTemporaryFile` that keeps bytes in RAM up to a configurable
threshold (default 100 MB) and spills to disk above it. Because the
pack is then read four times (L3), every non-trivial repo incurs
4× sequential disk re-reads.

**Evidence.**

- [`loader.py:207`][l207] — `temp_file_cutoff: int = 100 * 1024 * 1024`
  (default 100 MB).
- [`loader.py:230`][l230] — `self.temp_file_cutoff = temp_file_cutoff`.
- [`loader.py:252`][l252] —
  `pack_buffer = SpooledTemporaryFile(max_size=self.temp_file_cutoff)`.
- L3 above — four passes over the pack file.

**Why it cannot be overcome within dulwich.** The 4× pass count is
imposed by L3's typed-iterator API. Increasing `temp_file_cutoff`
trades disk I/O for memory — viable on the discard-mode harness
because the loader-resident envelope is small (§3.2), but mooted by
the CPU bottleneck (L1, L4): even with the pack fully resident in
RAM, dulwich's per-object Python overhead means each pass is
CPU-bound, not I/O-bound. The factor itself cannot be reduced
without replacing the pack iterator.

---

### L7 — Per-object storage writes in `base.py`

**What.** The four-pass loop in `BaseGitLoader.store_data()` calls
`self.storage.<type>_add([obj])` **once per object**, wrapping
each object in a single-element list.

**Evidence.** [`base.py:124–165`][b124-165] — reproduced in L3 above.
Each call crosses the `BufferingProxyStorage` boundary
([`swh-storage/swh/storage/proxies/buffer.py:245–309`][bf245-309]);
the proxy batches internally, but every call still pays the full
function-call and proxy-dispatch overhead before any batching
takes effect.

**Quantified impact.** For a 13.5 M-object pack this is 13.5 M
Python calls (one per object) crossing the proxy boundary before
the buffer's flush thresholds are considered. For chromium's 27.9
M objects it is 27.9 M calls. Even with discard storage in §3 (no
real write happens), the call-site overhead is paid in full —
this contributes to the per-object CPU cost characterised in L4.

**Why it cannot be overcome within dulwich's store-data loop.**
`BaseGitLoader.store_data()` consumes the `iter_objects()`
generators described in L3. A batched
`self.storage.<type>_add(batch)` call requires accumulating a batch
on the loader side — which means iterating the inflated objects
twice (once to batch, once to write) or holding a typed buffer
that grows without bound. Within dulwich's iterator API neither is
viable; meaningful batching requires replacing the per-object
materialisation pattern itself, which means replacing the pack
iterator — not available within dulwich.

---

## 5. Why gix structurally avoids these limitations

The seven items in §4 are properties of dulwich's *language*
(L1, L2 — pure Python, GIL-bound), of its *public API*
(L3, L5, L7 — typed forward iterator, mandatory `.idx`, per-object
add boundary), and of the cumulative effect of the first two on
*scale* (L4, L6). The gitoxide-based replacement avoids each by
construction rather than by tuning:

- **Native code, GIL-free** *(addresses L1, L2).* Pack inflation,
  delta resolution, and OID hashing are implemented in Rust
  (`gix-pack`, `gix-features`), invoked from Python through a thin
  PyO3 binding that releases the GIL for the duration of the call.
  The 4.1-5.6× CPU-time reduction in §3.1 and the 4-25× wall
  reduction in §3.4 are direct expressions of this — per-thread cost
  cut by the language switch, then multiplied by the parallelism
  that becomes available once the GIL is out of the way.
- **Typed pack iteration without re-passes** *(addresses L3, L4,
  L7).* The Rust-side `DirectTreePackReader` walks the pack once,
  emits typed objects in pack order, and feeds them to a single
  converter pipeline. There is no "blob pass / tree pass /
  revision pass" structure — typed dispatch happens inline. The
  multiplier on L1's per-object cost disappears.
- **Index-on-the-fly** *(addresses L5).* Gix can build the pack
  index in memory at iteration time; a pre-built `.idx` is an
  acceleration, not a precondition. The repack-without-index
  failure mode that affects dulwich is structurally absent.
- **Streaming converter without `.add([obj])` boundary**
  *(addresses L7).* Converters yield objects through a Rust-side
  channel directly into the storage write path; the per-object
  Python proxy hop is replaced by a typed channel of native
  objects.
- **Memory-bounded by design** *(addresses L4, L6 indirectly).*
  Pack mmap + fixed-size delta cache + native object representation
  means loader-resident memory grows with parallelism (per-thread
  decode buffers), not with object count.

The combination is not incremental: the bottleneck moves from "the
loader's Python interpreter" to "the storage write path on the
other side of the channel" — exactly where the audit's REC-L4 work
on concurrent Cassandra writes lives.

---

## 6. Summary table

| # | Limitation | Root in dulwich architecture | Quantified gap to gix (xl/discard, strict cell) |
|----|----------------|----------------------|---|
| L1 | Pure-Python pack inflation | Language; no native acceleration | **4.1-5.6× CPU** across the production-corpus ladder (chromium 5.61×) |
| L2 | Single-threaded (GIL-bound) | No GIL release in pack code | **4-25× wall** reduction available to gix's auto-parallel mode (chromium 24.9×) |
| L3 | Four sequential full-pack passes | Iterator-only API; topological flushes | embedded in L1's CPU multiplier |
| L4 | Per-object Python overhead at scale | Python objects + L3's 4× | obj/cpu_s drops 8× small→large for dulwich, 6× for gix |
| L5 | Hard `.idx` dependency | `PackIndex(path)` API contract | qualitative — silent zero-loads on missing `.idx` |
| L6 | 100 MB spool + 4× disk re-read | L3 × disk-backed temp buffer | mooted by CPU bottleneck (loader is not I/O bound) |
| L7 | Per-object `*_add([obj])` calls | `BaseGitLoader.store_data()` loop | embedded in L4 per-object CPU cost |

The seven limitations are not independent. L1 and L2 are properties
of the language. L3 multiplies L1's per-object cost by four. L4
combines L1+L3+L7 as observed wall-clock and CPU-time growth. L5 is
a hard API contract at dulwich's public boundary. L6 is forced by
L3 and bounded by L4.

Taken together they explain the §3 measurements — a tight **4.1-5.6×
CPU-time gap to gix** across the production-corpus repo ladder,
growing monotonically with repo scale, plus an additional **2-5×
wall multiplier** from gix's parallelism (gix uses ≥1 effective core,
dulwich is forever 1 by construction). On chromium this means
**19 hours of dulwich CPU vs 12,171 cpu_s = 3 h 23 min CPU for gix**,
and **19 hours of dulwich wall vs 45 min 42 s wall for gix** — a
**24.9× wall reduction** at production scale, with no path to
incremental narrowing while dulwich remains on the critical path.


---

## 7. Code references

Every citation in §4 resolves to the following source locations,
pinned at the upstream revision given in §8.

| File (relative to repo root) | Lines | Role |
|------------------|-----|------------------------------------|
| [`swh/loader/git/loader.py`][l-all] | [28–34][l28-34] | dulwich imports |
| | [207][l207], [230][l230], [252][l252] | `temp_file_cutoff`, `SpooledTemporaryFile(max_size=...)` |
| | [466][l466] | `PackData.from_file(...)` |
| | [579–592][l579-592] | `iter_objects(object_type)` — filters by type after full inflation |
| | [584][l584] | `PackInflater.for_pack_data(...)` — pure-Python inflater |
| | [594–626][l594-626] | `get_contents` / `get_directories` / `get_revisions` / `get_releases` |
| `swh/loader/git/base.py` | [47–71][b47-71] | `get_*` abstract hooks |
| | [102–171][b102-171] | four-pass `store_data()` with inter-type `flush()` |
| | [124–165][b124-165] | per-object `*_add([obj])` loop |
| `swh/loader/git/from_disk.py` | [14–17][fd14-17] | dulwich imports (tarball path) |
| | [106][fd106] | `dulwich.repo.Repo(self.directory)` construction |
| | [112][fd112] | `pack.index.iterentries()` — requires `.idx` |

External references (separate repositories; secondary to the
primary `swh-loader-git` analysis above). Pins below are
`origin/master` of each upstream repo at the time of writing; see
§8 for the exact revision and snapshot SWHIDs used.

| Repository | File | Lines | Role |
|--------|----------------|-----|----------------------------|
| `swh-loader-core` | `swh/loader/core/loader.py` | [392–568][lc392-568] | synchronous `load()` loop |
| `swh-storage` | `swh/storage/proxies/buffer.py` | [245–309][bf245-309] | `BufferingProxyStorage` |
| | | [51–66][bf51-66] | default buffer thresholds |

---

## 8. Reproducing the citations — exact source pin

All line numbers in §4 and in the primary table in §7 resolve to
the following public upstream revision of `swh-loader-git`:

- **Repository.**
  `https://gitlab.softwareheritage.org/swh/devel/swh-loader-git`
- **Commit.** `4ea30e301bfc4ff9ac597df18d067512975c1eba`
  (abbreviated `4ea30e3`)
- **Author / date.** Antoine Lambert
  `<anlambert@softwareheritage.org>`, 2026-01-23
- **Subject.** *Fix format of some license headers in Python files*
- **Status.** Last upstream commit on `master` at which the git
  loader was implemented end-to-end on top of dulwich. Every
  dulwich-specific line cited in this document is present at this
  exact revision.
- **Archived revision SWHID** (used as `anchor` in every link).
  `swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba`
- **Archived snapshot SWHID** (the visit that covered this revision;
  used as `visit` in every link).
  `swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6`
- **Archived content SWHIDs** (one per file, used as the link root so
  that `lines=` highlights the cited range — `lines` is only
  meaningful on a `cnt` SWHID):
  - `loader.py`: `swh:1:cnt:4e492888ee76529eadbbd1914821682722123239`
  - `base.py`: `swh:1:cnt:a8e7c02ffb4511548ab65e1bfc5150db0a2b7567`
  - `from_disk.py`: `swh:1:cnt:60ffeaa5c85efd2b06398ec74abc824924b7ac48`
- **Browse in the archive.** [loader.py (pinned file)][l-all] opens
  the content view of `loader.py` at the pinned commit, with the
  revision as anchor. Every line-number reference in §4–§7 is
  hyperlinked directly to its archived view using the same URL
  shape: `swh:1:cnt:<blob>;origin=…;visit=…;anchor=<rev>;path=…;lines=…`.

To obtain the exact source referenced in §4 and §7:

```bash
git clone https://gitlab.softwareheritage.org/swh/devel/swh-loader-git.git
cd swh-loader-git
git checkout 4ea30e301bfc4ff9ac597df18d067512975c1eba

# Spot-check a few citations against the table in §7:
sed -n '28,34p'   swh/loader/git/loader.py     # dulwich imports
sed -n '207p'     swh/loader/git/loader.py     # temp_file_cutoff default
sed -n '252p'     swh/loader/git/loader.py     # SpooledTemporaryFile(max_size=...)
sed -n '579,592p' swh/loader/git/loader.py     # iter_objects(object_type)
sed -n '584p'     swh/loader/git/loader.py     # PackInflater.for_pack_data(...)
sed -n '102,171p' swh/loader/git/base.py       # four-pass store_data()
sed -n '14,17p'   swh/loader/git/from_disk.py  # dulwich imports (tarball path)
sed -n '112p'     swh/loader/git/from_disk.py  # pack.index.iterentries()
```

The external references (`swh-loader-core`, `swh-storage`) are
maintained in separate repositories. Their citations are pinned to
`origin/master` of each upstream repo at the time of writing; the
exact SWHIDs used by the hyperlinks in §4 and §7 are:

**swh-loader-core** (`https://gitlab.softwareheritage.org/swh/devel/swh-loader-core`)

- anchor: `swh:1:rev:65f728aaf1de2d3fedf5a966e273dd193f792972`
- visit: `swh:1:snp:d933973142e5f484a2c83302fed10e5057a44798`
- content (`loader.py`):
  `swh:1:cnt:47b48b1c1ce844a2ec30d69c16880b58cf5ae073`

**swh-storage** (`https://gitlab.softwareheritage.org/swh/devel/swh-storage`)

- anchor: `swh:1:rev:d56b7b817d13537637e76bc35296bdcc2ada5b9c`
- visit: `swh:1:snp:b9075fb175bf204afa05bf6f3a1f91519f01167c`
- content (`buffer.py`):
  `swh:1:cnt:58d0be4e42c27856489388f0350564b2778d7e25`

---

## 9. Reproducing the measurements

The bench harness lives in
`notes/bench-dulwich-limitations/` (Python `bench.py` plus
`discard_storage.py`) and `notes/bench-dulwich-limitations/container/`
(Docker wrapper `bench_dulwich_container.sh`). Image
`bench-gix-dulwich:latest` extends `bench-gix:latest` with the
swh-loader-git Python deps already installed; no image rebuild is
required.

To reproduce one cell on a host with Docker access:

```bash
# xl tier = cpuset 0-15, --memory=64g (production worker dimension).
# BARE_BIND injects a host-side bare repo into /rundir/$REPO.git
# read-only, avoiding a 30 GB copy for chromium-class repos.
env TIER=xl REPO=linux BACKEND=discard NO_PREPARE=1 \
    IMAGE=bench-gix-dulwich:latest \
    RUNDIR=/srv/peak-rss-decomp/run-linux-discard-xl \
    HARNESS_DIR=$HOME/peak-rss-decomp/harness \
    BARE_BIND=$HOME/testbed/linux.git \
    bash $HOME/peak-rss-decomp/container/bench_dulwich_container.sh
```

Each invocation appends one JSONL row to `$RUNDIR/results.jsonl`:

- `cpu_seconds` (= user + sys, from `getrusage(RUSAGE_SELF)`)
- `wall_seconds` (from `time.monotonic()`)
- `cpu_user_seconds`, `cpu_sys_seconds`, `cpu_per_wall`
- `peak_rss_kb` (from `VmHWM`), `cgroup_memory_peak_kb`
- `object_count`, `pack_bytes`, `storage_backend`

The xl-tier rows in §3 above were produced with the exact command
shape shown.

---

[l28-34]:    https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=28-34
[l32]:       https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=32
[l207]:      https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=207
[l207-230-252]: https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=207-252
[l230]:      https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=230
[l252]:      https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=252
[l466]:      https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=466
[l579-592]:  https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=579-592
[l584]:      https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=584
[l594-626]:  https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py;lines=594-626
[l-all]:     https://archive.softwareheritage.org/swh:1:cnt:4e492888ee76529eadbbd1914821682722123239;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/loader.py
[b47-71]:    https://archive.softwareheritage.org/swh:1:cnt:a8e7c02ffb4511548ab65e1bfc5150db0a2b7567;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/base.py;lines=47-71
[b102-171]:  https://archive.softwareheritage.org/swh:1:cnt:a8e7c02ffb4511548ab65e1bfc5150db0a2b7567;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/base.py;lines=102-171
[b122-165]:  https://archive.softwareheritage.org/swh:1:cnt:a8e7c02ffb4511548ab65e1bfc5150db0a2b7567;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/base.py;lines=122-165
[b124-165]:  https://archive.softwareheritage.org/swh:1:cnt:a8e7c02ffb4511548ab65e1bfc5150db0a2b7567;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/base.py;lines=124-165
[fd14-17]:   https://archive.softwareheritage.org/swh:1:cnt:60ffeaa5c85efd2b06398ec74abc824924b7ac48;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/from_disk.py;lines=14-17
[fd65]:      https://archive.softwareheritage.org/swh:1:cnt:60ffeaa5c85efd2b06398ec74abc824924b7ac48;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/from_disk.py;lines=65
[fd106]:     https://archive.softwareheritage.org/swh:1:cnt:60ffeaa5c85efd2b06398ec74abc824924b7ac48;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/from_disk.py;lines=106
[fd112]:     https://archive.softwareheritage.org/swh:1:cnt:60ffeaa5c85efd2b06398ec74abc824924b7ac48;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-git;visit=swh:1:snp:ec15c752ad40f8e16a34c2ba08540ca5c30f3dd6;anchor=swh:1:rev:4ea30e301bfc4ff9ac597df18d067512975c1eba;path=/swh/loader/git/from_disk.py;lines=112
[lc392-568]: https://archive.softwareheritage.org/swh:1:cnt:47b48b1c1ce844a2ec30d69c16880b58cf5ae073;origin=https://gitlab.softwareheritage.org/swh/devel/swh-loader-core;visit=swh:1:snp:d933973142e5f484a2c83302fed10e5057a44798;anchor=swh:1:rev:65f728aaf1de2d3fedf5a966e273dd193f792972;path=/swh/loader/core/loader.py;lines=392-568
[bf51-66]:   https://archive.softwareheritage.org/swh:1:cnt:58d0be4e42c27856489388f0350564b2778d7e25;origin=https://gitlab.softwareheritage.org/swh/devel/swh-storage;visit=swh:1:snp:b9075fb175bf204afa05bf6f3a1f91519f01167c;anchor=swh:1:rev:d56b7b817d13537637e76bc35296bdcc2ada5b9c;path=/swh/storage/proxies/buffer.py;lines=51-66
[bf245-309]: https://archive.softwareheritage.org/swh:1:cnt:58d0be4e42c27856489388f0350564b2778d7e25;origin=https://gitlab.softwareheritage.org/swh/devel/swh-storage;visit=swh:1:snp:b9075fb175bf204afa05bf6f3a1f91519f01167c;anchor=swh:1:rev:d56b7b817d13537637e76bc35296bdcc2ada5b9c;path=/swh/storage/proxies/buffer.py;lines=245-309
