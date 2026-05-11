# Staging rollout proposal — git loader rehaul + REC-L4 + size-based dispatch

*Drafted 2026-04-14 as input to the SWH dev+ops team for sequencing a
staging deploy.  Last updated 2026-04-14 after the loader-side safety-net
re-queue landed.  Companion reference: `notes/ANALYSIS-dulwich-to-gitoxide.md`.*

> **Branch-name note (2026-05-08):** Branch names referenced below correspond to the post-2026-05-06 clean MR stack:
> `mr/1-gix-engine` → `mr/2-size-classed-queues` → `mr/3-dulwich-fallback` → `mr/4-helm-overlay` (in swh-loader-git);
> `mr/5-rec-l4-content-add` (in swh-storage, independent).
> The old pre-rewrite `feat/*` branches still exist as forensic snapshots (see `notes/git-loader-rehaul/HANDOFF.md` §2). Lane 2 (scheduler-side `feat/size-based-dispatch-v1`) and Lane 3 (lister-side `feat/github-size-metadata`) remain deferred — they did not make it into the clean MR stack.

## 1. TL;DR

Over the last three weeks we replaced the dulwich-based git loader with a
pure-Rust gitoxide pipeline (now `mr/1-gix-engine` through
`mr/4-helm-overlay` in swh-loader-git),
implemented a concurrent-write refactor of the Cassandra content path
(REC-L4, now `mr/5-rec-l4-content-add` in swh-storage), and built the full
v1 of size-based dispatch across swh-scheduler, swh-lister, and
swh-loader-git.  Measured speedups on the gitoxide pipeline are **1.3–1.6×
(Phase B) on top of 2.7× (Phase A) on top of 1.76× (Phase A0)**: the
Linux kernel went from a projected multi-hour dulwich load to **11.7 min
on maxxi direct mode (measured)**, and Chromium (30 GB pack, 27.9 M
objects) loads in **26 min** on the same hardware.  The remaining large
bottleneck — Cassandra content **writes** at ~5.4 h for the kernel
(post-Sept-2025 baseline; Nicolas Dandrimont's commits `9a4d5596`,
`9da2c163`, `c5e77f48` already batched the read-path collision check) —
is addressed by REC-L4's write-path concurrency with an expected 16–65×
speedup.  All five branches
are committed and test-covered; we propose a staged rollout where
zero-config pipeline improvements land first, REC-L4 lands behind a
config flag on a canary Cassandra writer, and size-based dispatch is
turned on progressively after the `listed_origins` migration (39.sql).

## 2. What changed

Five branches across four repositories, plus a worktree for the
still-unimplemented loader safety net.

| Repo | Branch | Purpose | Commits (subject) | Risk |
|---|---|---|---|---|
| swh-loader-git | `mr/1-gix-engine` through `mr/4-helm-overlay` (clean stack, post-2026-05-06 rewrite) | Full gitoxide rehaul (Phases 1–6C, A0, A, B) + dulwich-fallback + size-classed queues + helm overlay | 5+1+3+1 commits across the 4 stacked MRs; see `notes/git-loader-rehaul/HANDOFF.md` §2 for per-MR detail | med |
| swh-storage | `mr/5-rec-l4-content-add` (local; not pushed) | REC-L4 concurrent Cassandra content writes (write path only — Nicolas's Sept 2025 commits already batched the read path) | `9bf92395` add concurrent `content_add` path (REC-L4) | med |
| swh-scheduler | `feat/size-based-dispatch-v1` (Lane 2, deferred — not in clean MR stack) | Schema + size-aware `grab_next_visits` | `fec39d0` mypy prep; `642f2a6` add `pack_size_kb`+`commit_count` to `listed_origins` (+ `sql/upgrades/39.sql`); `28747d5` add `size_class` filter | low |
| swh-lister | `feat/github-size-metadata` (Lane 3, deferred — not in clean MR stack) | Opt-in GitHub per-repo size collection | `ed711c4` mypy prep; `8b35f1e` github lister: optional `collect_metadata` | low |
| swh-loader-git | `mr/2-size-classed-queues` (stacked on `mr/1-gix-engine`) | 3 size-classed Celery tasks + post-download safety-net re-queue | 1 commit (squash of `a6652e9` mypy + `b0cf0e6` tasks+safety-net+24 tests) | med |

Key commits for each item:

- **Phase A0** (`04a0230`, gix-py/src/lib.rs:482/616): default `channel_bound`
  4,096 → 65,536. Measured in isolation at **1.76×** on the Linux kernel
  iterate-only workload (bench-results.md Exp 2).
- **Phase A** (`f8c8c8c`, +66/−198): ParallelPackReader and
  DirectTreePackReader always emit a 5-tuple tree instead of a pre-built
  `Directory`. Moves ~1,984 Python C-API calls/tree out of `__next__()`.
  Projected **~2.7×** on the kernel (16.5 min at ~13,700 obj/s).
- **Phase B** (`8fff133`, in `converters.py`): `__new__` + `object.__setattr__`
  bypass of attrs validators in `tree_to_directory_preparsed`.
  Micro-benchmark 0.81 µs → 0.32 µs per entry (**2.53×**). Measured
  **1.58× on django**, **1.49× on kubernetes** (direct mode).
- **Stale .so shim** (`ca2a0fc`, `swh/loader/git/_gix.py`): dev-workflow
  only. `maturin develop` now suffices; setuptools-rust in production is
  unaffected.
- **DirectTreeInflater** (`413e1eb`): scan-based delta tree, skips
  `git index-pack`; enables direct mode path.
- **REC-L4** (committed on `mr/5-rec-l4-content-add`, HEAD `9bf92395`; not
  yet pushed; execution plan in `notes/git-loader-rehaul/PLAN-rec-l4-execution.md`): adds
  `content_add_statement` and `content_index_add_one_statement` in
  `cql.py`; replaces the per-content sequential write loop in `_content_add`
  (around `storage.py:439-446` of current master; line numbers updated
  post Nicolas's restructure) with `execute_many_statements_with_retries`.
  Reuses the existing primitive at `cql.py:881`
  (`directory_entry_add_concurrent`) and `cql.py:1855`
  (`object_reference_add_concurrent`). **Scope clarification**: the
  Sept-2025 commits `9a4d5596` / `9da2c163` / `c5e77f48` already batched
  the **read** path of `_content_add` (the existence + hash-collision
  checks); REC-L4 is the next-stage optimization, targeting the **write**
  path that remains 5 sequential round-trips per content (4 index
  inserts + 1 finalizer). Two before-MR items: (R4) add a
  `content_add_concurrency` config knob (default 100, recommend ≤ 50
  for production multi-loader); (R8) parametrise existing
  `_content_add` test scenarios across both `sequential` and
  `concurrent` algos. Loop in Nicolas Dandrimont as primary reviewer;
  David / Thomas as secondary.
- **Size dispatch scheduler** (`642f2a6`, `28747d5`):
  `swh/scheduler/sql/upgrades/39.sql` adds two nullable `INTEGER` columns
  (`pack_size_kb`, `commit_count`); `grab_next_visits(size_class=…)` adds
  a three-class filter (`small` / `large` / `xl`) with thresholds 100 MB
  and 2 GB; incremental visits (`last_snapshot IS NOT NULL`) always route
  to `small`.
- **GitHub lister size collection** (`8b35f1e`): opt-in
  `collect_metadata=True`; one extra `GET /repos/{full_name}` per origin
  in the bulk page; graceful degradation on 404/403/rate-limit/network.
- **Loader size-classed tasks + safety-net re-queue** (`b0cf0e6`):
  three new Celery tasks (`UpdateGitRepositorySmall` / `Large` / `Xl`) in
  `swh/loader/git/tasks.py`, each routed to a queue with the same name
  per the swh-scheduler convention.  The legacy `UpdateGitRepository`
  task is retained unchanged for backwards compatibility.  After
  `fetch_pack_from_origin` returns, the loader checks the actual pack
  size against (a) a hard threshold (the next queue's boundary) and
  (b) a soft threshold (2× the scheduler's `predicted_pack_size_kb`).
  On oversized pack: `celery.current_app.signature(<next_task>,
  kwargs=...).apply_async()` re-dispatches, `_delegated=True`,
  `visit_status()→"partial"`, `load_status()→{"status":"uneventful",
  "delegated_to":<task>}`, and the loader exits cleanly.  `xl` is a
  terminal queue — `_SIZE_CLASS_NEXT_TASK["xl"] is None` — so no
  re-dispatch loops are possible.  New statsd metrics:
  `git_safety_net_redispatch_total{from_queue,to_task}` and
  `git_safety_net_redispatch_failed_total{from_queue}`.  24 unit tests
  (mocked Celery, no broker, no PostgreSQL) cover the predicate, the
  Celery integration, metric emission, exception propagation, and the
  load/visit status overrides.

## 3. Measured impact

### 3.1 Linux kernel — pipeline phase-by-phase (maxxi, isolated)

Pack: 7.89 GB, 13,546,420 objects (3.85 M blobs, 8.03 M trees, 1.67 M commits).

| Configuration | Wall time | obj/s | Source |
|---|---|---|---|
| Dulwich (S4 estimate) | 2.5–6 h | ~700–1,400 | S4 §Q7 |
| Sequential PackReader (Phase 4) on laptop | 98.6 min | 2,291 | bench-results.md §3+4 |
| Indexed parallel (Phase 5 rewrite), contended | 40.9 min | 5,524 | bench-results.md 3-way |
| Direct-tree (Phase 5 opt), isolated | 44.9 min | 5,026 | bench-results.md Run 2 |
| + Phase A0 (channel_bound=65536) iterate-only | 45.4 min | 4,972 | Exp 2 |
| **+ Phase A + Phase B, direct mode (measured)** | **11.7 min** | **19,319** | bench-results.md Phase B full testbed |
| + Phase A + Phase B, indexed mode (measured) | 18.2 min | 12,385 | same |

The measured 11.7 min direct-mode number beats even the Phase-A-only
projection (16.5 min); Phase B's entry-construction bypass compounded
with Phase A's channel unblocking.  The dulwich estimate is still
first-principles; a head-to-head dulwich vs direct run on the kernel
is proposed in §6 of this document.

### 3.2 Full testbed — Phase A+B direct mode (maxxi, 2026-04-14, MEASURED)

All ten repos run end-to-end, direct mode, Phase A+B active.  Indexed
numbers in parentheses where meaningfully different.  Peak RSS is the
process's peak, not just the Rust side.

| Repo | Pack | Objects | Wall time | obj/s | Peak RSS |
|---|---|---|---|---|---|
| swh-py-template | 115 KB | 611 | 0.2 s | 3,959 | 43 MB |
| flask | 7.4 MB | 26,179 | 0.7 s | 40,147 | 272 MB |
| requests | 10.8 MB | 26,575 | 0.4 s | 66,908 | 376 MB |
| django | 163.7 MB | 558,423 | 13.4 s | 41,769 | 2.6 GB |
| kubernetes | 608.4 MB | 1,734,359 | 38.9 s | 44,568 | 13.4 GB |
| llvm-project | 2,023 MB | 7,086,259 | 330.7 s (5.5 min) | 21,428 | 18.2 GB |
| libreoffice | 2,195 MB | 6,573,747 | 203.1 s (3.4 min) | 32,359 | 18.4 GB |
| gcc (repacked 12 GB *) | 12,261 MB | 3,345,101 | 521.5 s (8.7 min) | 6,415 | **41 GB** |
| linux | 7.9 GB | 13,546,420 | 701 s (11.7 min) | 19,319 | 22 GB |
| **chromium** | **30 GB** | **27,916,948** | **1,569 s (26 min)** *(indexed: 1,349 s = 22.5 min)* | 17,794 *(indexed: 20,691)* | **144 GB** |

\* gcc's pack is pathological: repacked with default window=10 it
inflates 3× (server pack 4.15 GB → 12 GB).  Production SWH loads the
server-sent pack directly; the 8.7 min here is a worst-case.  llvm/
libreoffice/linux are more representative of real large-repo throughput.

### 3.2.1 Direct vs indexed: where each wins

- **Small to medium repos (< 7 M objects):** direct is 30-60% faster
  than indexed.  `git index-pack` startup amortises poorly when the
  traverse itself finishes quickly.
- **Chromium (28 M objects, 30 GB pack):** indexed beats direct by
  14%.  The pack outsizes working-memory patterns that the OS page
  cache can keep hot for direct mode; index-pack's streaming write
  plus mmap-random traversal pattern wins at this scale.
- **Operational implication:** the size-classed tasks don't need to
  carry a `mode=direct/indexed` choice in v1 — direct is the right
  default for small/large.  For the xl queue, consider making indexed
  the default (one-line config in the worker loader YAML) or exposing
  the choice per-task.

### 3.3 Projected REC-L4 impact

Currently `_content_add` (`swh-storage/swh/storage/cassandra/storage.py:436-448`)
issues 5 sequential CQL round-trips per content. At 1 ms/RTT this is
~50 s per 10,000-content flush. Linux kernel projection:

| Metric | Sequential (today) | Concurrent (REC-L4) | Ratio |
|---|---|---|---|
| Per-content CQL cost | 5 × 1 ms sequential | 5 pipelined | — |
| 10,000-content flush @ 1 ms RTT | ~50 s | 0.25–2 s | 25–200× |
| Linux kernel content phase (3.85 M blobs) | **~6.4 h** | **~5–20 min** | 20–100× |

Conservative acceptance target: **≥10× speedup** on the flush wall time
on a test Cassandra cluster.

### 3.4 Memory concern that motivates dispatch (all measured on maxxi)

| Repo | Direct-mode peak RSS | Container tier required |
|---|---|---|
| django (164 MB pack) | 2.6 GB | small (4 GB) is tight; large safer |
| kubernetes (608 MB pack) | 13.4 GB | large (16 GB) |
| llvm-project (2 GB pack) | 18.2 GB | large (16 GB) is tight; xl safer |
| libreoffice (2 GB pack) | 18.4 GB | large / xl |
| linux (7.9 GB pack) | 22 GB | xl (32 GB) |
| gcc (12 GB repacked) | **41 GB** | xl (64 GB) |
| **chromium (30 GB pack, 28 M obj)** | **144 GB** | **extreme — beyond xl spec** |

**A gcc or chromium pack landing on a 4-vCPU/4 GB worker is a hard OOM.**
The safety-net re-queue (step 10) catches this without data loss: the
small worker detects the oversized pack before decoding, re-dispatches,
and exits cleanly — no process kill.

The v1 plan's xl tier (16 vCPU / 64 GB) is adequate for Linux but
**insufficient for Chromium at 144 GB**.  Options:
(a) add a 4th `extreme` tier (32 vCPU / 256 GB + local SSD), roughly
1-2 workers; (b) handle Chromium-class repos manually out-of-band; or
(c) accept a one-worker-per-extreme-repo queue with no parallelism.
This is Q4 for the team in §10 below.
Production today routes all git loads to one queue — this is the
motivation for Approach C size-based dispatch.

## 4. What still works in production (today)

All new features are **off by default**. A fresh deploy of the five
branches without any config change is behaviourally identical to current
production:

- `CassandraStorage` keeps the sequential `_content_add` unless
  `content_add_algo: "concurrent"` is set in the storage config (same
  opt-in pattern as the existing `directory_entries_insert_algo` flag at
  `swh-storage/swh/storage/cassandra/storage.py:743-754`).
- The GitHub lister's `collect_metadata` defaults to `False`; no extra
  per-repo API calls are issued.
- `grab_next_visits(size_class=None)` falls through to the current
  unfiltered query; scheduler behaviour is unchanged when no caller
  passes `size_class`.
- The new `listed_origins.pack_size_kb` and `commit_count` columns are
  nullable; existing rows stay NULL. No application code reads them
  unless explicitly enabled.
- Existing Celery workers continue to consume the `loader.git` queue;
  no new queue is required unless the ops team creates one.

The scheduler migration `swh/scheduler/sql/upgrades/39.sql` is a pair of
`ALTER TABLE listed_origins ADD COLUMN … INTEGER` statements. On
PostgreSQL these are metadata-only and complete in milliseconds — no
full-table rewrite, no lock escalation beyond the brief exclusive lock
on the relation.

## 5. Staging rollout plan

Ten steps, sequenced from zero-risk to coupled infrastructure changes.
Each step states the knob, the monitoring signal, and the rollback.

| # | Step | Flag / config | Success signal | Rollback |
|---|---|---|---|---|
| 1 | Phase A0 (channel 65536) | none — new default in `gix-py/src/lib.rs:484/684` | obj/s ↑ vs baseline on small+medium loads; no change in error rate | revert `04a0230` |
| 2 | Phase A + B on canary worker | none; built-in | obj/s ↑ at least 1.3× on medium repos; RSS unchanged | pin to pre-Phase-A `.so` |
| 3 | Stale-.so shim | none (dev-only) | `maturin develop` no longer needs manual `cp` | revert `ca2a0fc` |
| 4 | REC-L4 canary | storage config `content_add_algo: "concurrent"` on one writer | scrubber finds no new partial-index states after 7 days; Cassandra flush wall-time ↓ | flip flag back to `"sequential"` |
| 5 | Scheduler migration 39.sql | apply to staging scheduler DB | `pack_size_kb` / `commit_count` columns present; no regressions in `record_listed_origins` | drop columns (safe — nullable) |
| 6 | GitHub lister size collection | `collect_metadata: True` on GitHub lister in staging | +~50K API calls/day; `listed_origins.pack_size_kb` populated for new rows | flip back to `False` |
| 7 | Register `loader.git.small/large/xl` queues + deploy task code | apply `b0cf0e6`; Celery config all three → same worker pool initially | tasks `UpdateGitRepositorySmall/Large/Xl` visible to Celery inspector; legacy task still works | undo Celery config; task code is backwards-compatible (legacy task unchanged) |
| 8 | Deploy differently-sized worker pools | Helm: 3 deployments (4 GB / 16 GB / 64 GB) | pools healthy | scale new pools to 0 |
| 9 | Enable size routing in scheduler | `recurrent_visits` policy passes `size_class` to `grab_next_visits` and names the new task in the queue prefix | origins reach the expected queue; xl queue populated by gcc/libreoffice/linux-class repos | policy falls back to `size_class=None` + legacy task name |
| 10 | Activate loader safety-net re-queue | `b0cf0e6` is already deployed with step 7; activate by enabling safety-net from step 9 — no extra flag | `git_safety_net_redispatch_total{from_queue,to_task}` > 0 on misclassifications; no OOMs on small/large workers | set `safety_net_enabled: False` on worker loader config — re-queue becomes inert (same failure mode as today for oversized packs) |

Metrics to watch across steps: `loader.git.objects_per_sec` (rate),
`loader.git.peak_rss_mb`, `cassandra.content_add_flush_ms`,
`scheduler.grab_next_visits_latency_ms`, `lister.github.ratelimit_remaining`,
`listed_origins.pack_size_kb IS NULL` ratio.

## 6. Test plan for staging

### 6.1 Confidence-building runs (small first, risky last)

1. **Small canary** — one swh-py-template load end to end with
   `content_add_algo="concurrent"`. Verify: (a) snapshot completes;
   (b) all 4 content index rows present for each blob; (c) a
   `swh-scrubber` pass finds no anomalies.
2. **Medium canary** — load `kubernetes` (608 MB, 1.73 M objects) with
   size-dispatch routing **enabled**. Verify: origin picked from the
   `large` queue; run completes on a 16 GB worker; wall time
   approximately 40 s (matches the maxxi 38.9 s).
3. **Large canary** — load llvm-project (2 GB, 7 M objects) on a
   pre-sized large worker. Verify peak RSS ≈ 18 GB, wall time
   approximately 5 min (maxxi: 5.5 min).  Compare against the
   pre-deploy baseline.
4. **Acid test: chromium** — one chromium load (30 GB pack, 28 M
   objects).  Now we KNOW it needs 144 GB RSS (measured on maxxi),
   which is **beyond the v1 xl spec** (64 GB).  Two acceptable
   outcomes for this test on staging: (a) deploy a one-off "extreme"
   worker (256 GB RAM) and verify a full chromium load completes in
   ≈ 22-26 min (maxxi indexed: 22.5 min, direct: 26 min); or
   (b) explicitly skip chromium for v1 staging and document it as a
   known gap.
5. **Regression** — replay the currently-loading production origin
   window (24 h) against the staging stack. Compare ingestion rate
   and error rate vs baseline.
6. **Safety-net path** — force a prediction error: pre-stage an
   origin with a deliberately-low `pack_size_kb` (e.g., 10 MB)
   pointing at a 500 MB repo.  Run on the small queue.  Verify:
   (a) the loader emits `git_safety_net_redispatch_total`;
   (b) the large queue picks up the re-dispatched task;
   (c) the load completes on the large worker;
   (d) the original origin's `last_visit_status` ends up `successful`
   after both visits are journal-processed.

### 6.2 Dulwich head-to-head comparison runs

To ground the team's expectations, we ran the **legacy dulwich-based
loader** (`swh.loader.git.from_disk.GitLoaderFromDisk`, which still
uses dulwich end-to-end — see
`swh-loader-git/swh/loader/git/from_disk.py:14-17`) on the same testbed
repos used for the gix runs, with in-memory storage to isolate the
loader cost.  Same maxxi hardware, same packs, single-threaded dulwich
vs ~19-effective-cores gix direct.

| Repo | Objects | **Dulwich wall** | **Gix direct wall** | Speedup | Dulwich RSS | Gix RSS | Memory ratio |
|---|---|---|---|---|---|---|---|
| flask | 26K | **12.7 s** | 0.7 s | **18×** | 0.4 GB | 0.3 GB | 1.3× |
| requests | 27K | **11.2 s** | 0.4 s | **28×** | 0.4 GB | 0.4 GB | 1.0× |
| django | 558K | **450.3 s (7.5 min)** | 13.4 s | **34×** | 7.5 GB | 2.6 GB | **2.9×** |
| kubernetes | 1.7M | **1567 s (26.1 min)** | 38.9 s | **40×** | 39.1 GB | 13.4 GB | 2.9× |
| libreoffice | 6.6M | **7739 s (2 h 9 min)** | 203.1 s | **38×** | 147.2 GB | 18.2 GB | **8.1×** |
| llvm-project | 7.1M | **12274 s (3 h 25 min)** | 330.7 s | **37×** | 247.3 GB | 18.2 GB | **13.6×** |
| gcc | 3.3M | **14667 s (4 h 5 min)** | 521.5 s | **28×** | 365.8 GB | 40.3 GB | 9.1× |
| linux | 13.5M | **20408 s (5 h 40 min)** | 701.2 s | **29×** | 407.0 GB | 21.3 GB | **19.1×** |
| chromium | 27.9M | **64253 s (17 h 51 min)** | 1568.9 s (26.1 min) | **41×** | **1.68 TB** | 144.2 GB | **11.7×** |

**The pattern is consistent and holds at every scale:** speedup grows
with repo size from 18× (flask) to **40× (kubernetes)**, settles into
a **28–38× band** for very large repos (libreoffice, llvm, gcc,
linux), and opens back up to **41× on chromium** — the largest repo
we tested.  The wall-time gains are decisive on their own, but the
**memory reduction is the more surprising result**: gitoxide's peak
RSS scales proportionally to repo size, while dulwich's grows
pathologically — 407 GB on linux, 366 GB on gcc, and **1.68 TB on
chromium** (17 h 51 min, completed).  The memory ratio on large repos
is **8–19×**, not ~3× as the smaller testbed repos first suggested,
and reaches **11.7× on chromium**.

CPU/wall ratio for every dulwich run is **1.00** — confirming dulwich
runs purely single-threaded.  Gix runs at 2–8× CPU/wall depending on
parallelism opportunity.

**Operational implication.** The current dulwich loader is *effectively
incapable* of ingesting repos at the top of the size distribution: a
chromium-scale load needs **17 h 51 min of wall time and 1.68 TB of
peak RSS** — outside the envelope of any reasonable Kubernetes pod.
The gix loader does chromium in **26 minutes at 144 GB peak** on the
same hardware.  This is not a performance improvement at the margin
— it is the difference between "we can archive this class of repo in
production" and "we cannot."

The chromium dulwich baseline completed successfully
(`status: ok`, `load_status: eventful`) — the load is correct, just
pathologically slow and memory-hungry.  The 41× wall-time speedup and
11.7× memory reduction are the hardest evidence in this proposal.

#### Aside: why dulwich runs needed an extra step (`git index-pack`)

The repacked testbed bare repos (single-pack form, produced by
`git repack -a -d -f`) lacked the corresponding `.idx` files —
`repack -d` deletes the old index without writing a new one.  Gix runs
fine on a bare `.pack`: `DirectTreeInflater` builds the delta tree
in memory from a streaming header scan, and `ParallelPackReader`
shells out to `git index-pack` if needed.  Dulwich's
`Repo.object_store` path (used by `GitLoaderFromDisk`) requires the
`.idx` to exist on disk: it does SHA→offset lookups against the
sorted index, with no fallback path to scan the pack from scratch.

Without the `.idx`, every object read fails as "not found" and the
load returns success with zero objects (we saw this on the first
swh-py-template run before regenerating the indexes).  In production
this never matters because both production paths (pre-rehaul dulwich
network loader and the new gix loader) build the `.idx`/equivalent
during their first pass over the freshly-fetched pack.  But it
matters for benchmark setup, and it matters for reasoning about
gix's other architectural advantage:

- **Dulwich**: pack → `.idx` build → SHA→offset lookups for every
  object → 4 sequential pack-iteration passes (one per type) →
  storage write
- **Gix direct**: pack → in-memory delta tree → parallel decode →
  storage write (no `.idx`, no extra disk artifact, no second pass)

The disk-state simplification is small relative to the throughput win
but it's a real ergonomic improvement: less filesystem state for ops
to manage, fewer failure modes around `.idx`/`.pack` mismatch.

### 6.3 Scrubber coverage

Step 1 runs the scrubber specifically; for steps 2–5 the scrubber
should be scheduled at least once after the run completes — this is the
mitigation documented in `notes/PLAN-rec-l4-concurrent-content.md
§Mitigation plan` for the new concurrent-write failure modes.

## 7. Ops considerations — container sizing and dispatch model

### Reframing: tier is a throughput/cost knob, not a feasibility gate

The sizing table previously in this section was derived from uncapped
`ru_maxrss` figures on maxxi (96 cores, 1.5 TB RAM). The container-bench
campaign has shown that `ru_maxrss` overstates real memory demand by
3--12x under production container caps, because (a) per-thread decode
arenas scale with the uncapped core count (96 on maxxi vs 2--16 in a
container) and (b) `VmHWM` accumulates across time while cgroup
`memory.peak` tracks concurrent RSS. Every repo tested so far --
through chromium at 27.9 M objects / 30 GB pack -- fits in a 16 GB
`large` container. The 4th "extreme" tier is not needed.

Authoritative reference:
`notes/ANALYSIS-container-bench-and-adaptive-dispatch.md`.

### Cost/performance model

Fitted on 28 container-capped runs across 7 repos x 3 tiers
(source: `notes/data/container-model-v1.json`):

    log(wall_s)         ~= 1.689 + 0.171*log(cpu) + 0.713*log(pack_gb) + 0.242*log(commits)
    log(memory_peak_gb) ~= -0.206 + 0.593*log(cpu) + 0.357*log(pack_gb)

Wall model MAPE 33%, memory model MAPE 43% (6 OOM-censored samples
excluded from the memory fit).

**Reading the coefficients.** Pack size is the dominant wall-time
predictor (0.713): doubling the pack roughly doubles wall time. CPU
count has heavy diminishing returns (0.171): doubling CPUs cuts wall
time by only ~11%. Commit count contributes modestly (0.242). For
memory, CPU count matters more than pack size (0.593 vs 0.357) because
per-thread decode arenas scale with core count.

### Per-repo container-measured table

Replaces the old `ru_maxrss`-derived sizing table. All numbers are
cgroup `memory.peak` under enforced container caps.

| Repo | Tier | Wall (s) | memory.peak (GB) |
|---|---|---|---|
| django | large (8c/16G) | 24 | 1.4 |
| kubernetes | large (8c/16G) | 55 | 3.4 |
| libreoffice | large (8c/16G) | 268 | 1.8 |
| linux | large (8c/16G) | 775 | 11.9 |
| chromium | large (8c/16G) | 2420 | 9.2 |
| chromium | xl (16c/64G) | 1889 | 11.6 |

OOM boundary (observed kills): gcc/small (4 GB cap), chromium/small
(4 GB cap), linux/small at 3 GB and 2 GB caps. No OOM observed on
any repo at the `large` tier or above.

### Recommended first deployment: zero-refactor path

Route all new-origin visits to `loader.git.small`. The loader
self-promotes by wall-time threshold: `T_class = 600 s` (small to
large), `T_class = 1800 s` (large to xl). On typed gix exceptions
(`GixPackError` / `GixObjectParseError` / `GixTraverseError`), the
loader dispatches to the dulwich fallback queue.

**What this path does NOT require:** no lister change
(`feat/github-size-metadata` stays on the shelf, Lane 3 deferred), no
scheduler change (`feat/size-based-dispatch-v1` stays on the shelf,
Lane 2 deferred), no `pack_size_kb` database migration. Only the
loader-side piece (now `mr/2-size-classed-queues`, stacked on
`mr/1-gix-engine`) ships.

### Dulwich fallback

Three fallback queues mirroring the gix tiers: `loader.git.dulwich_fallback_small`,
`loader.git.dulwich_fallback_large`, `loader.git.dulwich_fallback_xl`.
Fallback inherits the gix tier; OOM on small/large promotes to xl; xl is
terminal. Feature-flagged, opt-in for the first production window (see
`notes/PLAN-dulwich-fallback-wiring.md` section 13 for resolved decisions;
`notes/DESIGN-dulwich-fallback-signals.md` section 6 for typed exceptions).

### Objective function: Scenario C (blended)

Maximise throughput subject to a tail-latency guardrail: no origin waits
more than `N_max` days between visits. Scenarios A (throughput-first) and
B (SLA-first) are documented as alternatives considered in
`notes/ANALYSIS-container-bench-and-adaptive-dispatch.md` section 5.

### Staging gating values

Four gates (starting proposals for team negotiation):

| Gate | Threshold | Window |
|---|---|---|
| Redispatch rate | < 5 % of visits | 7 days |
| Dulwich-fallback rate | < 0.1 % of visits | 7 days |
| p95 wall time | within 30 % of model prediction | 7 days |
| OOM-kills on `small` | zero | 7 days |

### Noisy-neighbor finding

Container co-location on the same NUMA node shows ~42% wall-time
penalty from memory-bandwidth contention. NUMA-split co-location is
negligible (~2%). Production k8s should NUMA-pin worker pods where
possible to avoid same-NUMA contention.

### What maxxi cannot tell us

- **Network-attached storage latency.** maxxi has local NVMe; production
  workers may hit networked storage with higher seek latency.
- **Real multi-tenant scheduling jitter.** maxxi runs isolated
  benchmarks; production k8s has noisy neighbors beyond what the
  container-bench pairs captured.
- **Production Cassandra write latency.** The model measures
  loader-only cost with in-memory storage. REC-L4 pending.

### Thread cap

Cap Rust traverse threads at the container's vCPU count (not
`None`/all-cores). `DirectTreePackReader(thread_limit=N)` exposes this;
wire to an `OMP_NUM_THREADS`-style env var in the worker image.

## 8. Known open items (NOT in scope for staging v1)

- **Phase C (`directory_add_raw`)**: ~15% additional gain on the kernel
  (PLAN-tree-bottleneck §Phase C). Requires cross-backend interface
  change. Defer until REC-L4 lands and we can remeasure.
- **M1 — `from_disk.py` still uses dulwich** (PLAN-misc-loader-fixes
  §M1; `swh-loader-git/swh/loader/git/from_disk.py:14-17,230,239,261`).
  Non-network path, lower priority.
- **M2 — Mercurial per-object writes** (`swh-loader-mercurial/swh/loader/mercurial/loader.py:422,616,726`).
- **M3 — Bazaar per-object writes** (`swh-loader-bzr/swh/loader/bzr/loader.py:319,434,561`).
- **Scan-phase CPU gap**: 558 s on maxxi vs 62 s on laptop (9× vs 3× CPU-clock gap; ~3× unexplained).
  Possibly NUMA / L3 / zlib-rs microarchitecture effects. Not blocking.
- **Fork-parent-aware dispatch**: needs REC-S4 (`forked_from_url`
  population for GitHub). Currently incremental-visit routing via
  `has_snapshot` gives 80% of the benefit.
- **GitLab / Gitea / Bitbucket size collection**: the v2 of dispatch;
  each is 1–2 days of work (PLAN-size-based-dispatch §Approach C v2).
- **Extreme tier (chromium-class repos)**: chromium peaked at 144 GB
  RSS on maxxi, beyond the v1 xl spec (64 GB).  Either (a) add a 4th
  `extreme` worker tier with 256 GB RAM hosting 1-2 workers, or
  (b) handle the < 0.01% of supermassive repos out-of-band.  See
  question 4 below.

## 9. Risks and mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Cassandra partial writes under concurrent mode | medium | objstorage-first ordering (`storage.py:403`) means blob data is never lost; scrubber pass after bulk ingest (standard pattern for concurrent paths already in use for `directory_entry_add_concurrent`, `object_reference_add_concurrent`). |
| Worker OOM on dispatch misprediction | high (without safety net) | step 10 re-queue catches >2× size drift; staging without safety net *should* start with conservative size thresholds (e.g., medium=50 MB not 100 MB) to leave headroom. |
| GitHub rate-limit exhaustion | medium | +50 K/day ≈ 40% of one token's 120 K budget. Plan token rotation, or add a second token to the existing GitHub lister pool, before step 6. |
| Stale `.so` in dev causes confusing benchmark runs | low | fixed by `ca2a0fc` shim; operators using `maturin develop` in staging no longer need manual `cp`. |
| Scheduler `grab_next_visits` regression under new `size_class` branch | low | unit tests in `swh-scheduler/tests/test_size_class.py` (8 tests on in-memory backend); feature default is `size_class=None` — code path only runs when explicitly opted in. |
| Channel buffer 65536 increases peak memory | low | Phase A0 test on kernel showed RSS unchanged vs 4096. Worst case: 65536 tuples × ~1 KB = 64 MB — inside any worker tier. |

## 10. Questions for the team

1. **Staging timeline**: are we running steps 1–5 in a single week, or
   one-per-day with metric review between each?
2. **Worker pool sizing**: start with 3 pools of 2–4 workers each, or
   match current production fleet size and scale later?
3. **Scrubber cadence after REC-L4 rollout**: ad-hoc after each large
   canary, or schedule a weekly sweep over newly-written content?
4. **GitHub size collection mode**: run the lister once as a backfill
   (populate `pack_size_kb` for the entire existing `listed_origins`
   table, ~50 M rows = ~10 K hours of API calls across tokens), or
   only forward (new origins only, accept that old origins stay NULL
   until they age out)? Forward-only gives faster staging traction
   and avoids the token-rotation headache; backfill can run in the
   background on a dedicated rate-limited lister.
5. ~~Safety-net priority~~ — **DONE** (commit `b0cf0e6`).  Already
   ships with step 7's task code.
6. **Extreme-tier (chromium) handling**: do we want a 4th worker tier
   (256 GB RAM, 1-2 workers) in v1 staging, or document chromium as
   a known gap and handle out-of-band?  Current count of repos that
   would land in this tier: probably single-digit (chromium itself,
   maybe a couple of others SWH has not yet enumerated).
7. **Dulwich head-to-head runs**: which subset from §6.2 do we run on
   staging?  Recommended minimum: flask + django + kubernetes
   (+1-3 hours of staging-worker time total).  llvm and linux are
   higher commitment but give the more-impressive headline numbers.
8. **Phase C / from_disk / Mercurial / Bazaar** — would the team prefer
   these bundled into a single follow-up release after REC-L4 lands,
   or kept as independent tickets?

---

*Supporting documents in `notes/`:
`ANALYSIS-dulwich-to-gitoxide.md` (reference),
`bench-results.md` (canonical numbers),
`PLAN-tree-bottleneck.md` (Phases A–D),
`PLAN-rec-l4-concurrent-content.md` (REC-L4),
`PLAN-size-based-dispatch.md` (Approach C),
`PLAN-misc-loader-fixes.md` (M1/M2/M3),
`impl-log-phase-a.md`, `impl-log-size-dispatch.md`,
`REC-git-loader.md` (original bottleneck ranking).*
