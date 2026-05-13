# HANDOFF — MR plan, complexity stages, review surface

**Companion to `HANDOFF.md`.** Where `HANDOFF.md` describes *what is true today*, this document answers *what we ask the team to do next*: how the rollout decomposes into deployment stages, how much code each stage costs to review, who reviews what, and how we propose to rewrite history so the MRs are easy to follow.

Updated 2026-05-13.

---

## TL;DR (for a busy reader)

- **Total reviewable surface: ~9.6k lines** across `swh-loader-git` + `swh-storage`, of which ~2.4k Rust, ~3.5k Python production, ~1.4k Python tests, ~0.4k docs/deploy. Cargo.lock (~2k) and benchmark scripts (~2.1k) are line-by-line auto-generated or off-the-critical-path.
- **Five deployment stages**, each shippable on its own. **Stage 0** is a 91-line production bug fix that's already-deployable today. **Stage 1** is the gix engine as a drop-in replacement (no fallback, no knobs). **Stages 2–4** add the dulwich fallback, size-classed queues, and concurrent content_add in turn. Each stage commits the team to more code but unlocks more capability.
- **Two reviewers carry most of the load**: a senior engineer (estimate 1–1.5 days for the full rehaul) and an operator (estimate ~½ day for the deploy-surface). concurrent content_add is independent (~2 hours).
- **The MR stack is built and open as drafts on GitLab.** Five MRs total: four loader-side stacked drafts (`!217` → `!220` on `swh-loader-git`) and one independent concurrent `content_add` stack ready to push to `swh-storage` (see `PLAN-concurrent-content-add.md`).

---

## 1. The at-a-glance numbers

`swh-loader-git/feat/gix-dispatch-integrated` vs master (the full rehaul stack):

| Bucket | LOC | Files | Notes |
|---|---:|---:|---|
| Rust core (`gix-lib/src/lib.rs` + `gix-py/src/lib.rs` + `gix-py/src/exceptions.rs` + 2× `Cargo.toml`) | **2,428** | 5 | New crates; gix engine + PyO3 bindings + typed exceptions |
| Python production code (`loader.py`, `loader_dulwich.py`, `converters.py`, `dulwich_fallback.py`, `tasks.py`, `utils.py`, `_gix.py`, `_gix.pyi`, `pyproject.toml`) | **3,519** | 9 | The actual loader changes plus dulwich-fallback path |
| Python tests (`test_gix.py`, `test_gix_exceptions.py`, `test_dulwich_fallback*.py`, `test_safety_net.py`, `test_tasks_size_class.py`) | **1,364** | 6 | New test files; existing `test_loader.py` had small touches handled separately |
| Docs / deploy (`README.rst`, `deploy/HANDOFF-OPS.md`, `deploy/values-dulwich-fallback.yaml`, `.gitignore`) | **403** | 4 | |
| Benchmarks (`benchmarks/bench_*.py`, `run_testbed_suite.sh`) | 2,133 | 8 | Off-the-critical-path; smoke-review only |
| Auto-generated (`Cargo.lock`) | 2,040 | 1 | Cargo determines; reviewer skims for unexpected deps |
| Binary fixture (`invalid-type-nibble.pack`) | (53 b) | 1 | Test data |
| **Reviewable subtotal** (Rust + Python prod + tests + docs) | **~7,714** | 24 | What expert review actually targets |

`swh-storage/feat/content-add-concurrent` vs master :

| File | LOC | Notes |
|---|---:|---|
| `swh/storage/cassandra/storage.py` | +155 / –30 | Concurrent path + InMemoryStorage class default |
| `swh/storage/cassandra/cql.py` | +36 / –1 | Statement helpers |
| `swh/storage/metrics.py` | +17 / –4 | Coarse-grained timer |
| `swh/storage/tests/test_cassandra.py` | +66 / | New tests |
| **Total** | **+239 / –35** | 4 files |

---

## 2. Complexity, by deployment stage

The rehaul is not a single step; the team picks how far down the ladder to go. Each stage is a strict superset of the previous, deployable as a self-contained increment, with its own MR set.

### Stage 0 — the production bug fix (zero refactor)

**What ships**: commit `da7b2b1` only — the `_convert_object` `(2, Directory)` tuple crash fix.
**Why**: this is a real production bug found while preparing the rehaul; it has nothing to do with the rehaul itself.
**Diff**: 2 files, +91 / –4. `swh/loader/git/loader.py` +21 lines + a test.
**Build / runtime / ops impact**: zero — no new dependencies, no config changes, no behaviour change for non-tree paths.
**Risks**: minimal; covered by a dedicated test.
**Unblocks**: nothing else in this plan; can land on master independently of every other stage.
**Recommended review time**: 30 min by anyone touching the loader.

### Stage 1 — gix engine as default loader (drop-in replacement, no knobs)

**What ships**: the gix engine entirely replaces dulwich for fetch + pack parse + hashing. **No fallback path**, no size-classed queues, no concurrent storage write. Plus the three regression fixes from the pre-rehaul analysis (TLS, file://, InMemoryStorage).
**Why**: the minimum viable rehaul. Fastest path to "gix is in production"; no operational complexity beyond the dependency change. If gix has bugs at this stage, they manifest as visit failures (no automatic rescue).
**Diff**: ~2,400 Rust + ~1,300 Python (loader + converters + utils, no `loader_dulwich.py`, no `dulwich_fallback.py`, no size-classed `tasks.py`) + test files for gix + ~100 lines of docs.
**Build dependency added**: `libssl-dev` (compile time), Rust toolchain (compile time), maturin (build harness). `libssl3` at runtime is universal on Debian/Ubuntu.
**Config knobs added**: none — just install and run.
**Ops impact**: workers need to be rebuilt with the Rust toolchain and `libssl-dev`. No deployment topology change.
**Risks**: a class of pack patterns gix doesn't handle yet (e.g. ref-delta lookups outside the pack — see `HANDOFF.md` §5 Category B') would crash visits with no rescue.
**Unblocks**: Stage 2 sits on top.
**Recommended review time**: see §4.

### Stage 2 — gix + dulwich-fallback dispatch (operational safety net)

**What Stage 2 *adds* over Stage 1**: a typed-exception-based classifier that catches gix errors and re-routes the affected origin to a dulwich-only Celery queue, plus a `git_dulwich_fallback_total{reason}` statsd metric.
**Why**: turns "gix bug → failed visit" into "gix bug → fallback succeeds, metric fires, we investigate offline". This is what makes Stage 1 deployable without losing sleep.
**Additional diff**: `loader_dulwich.py` (825 lines, mostly mechanical copy-and-rename of the legacy dulwich loader), `dulwich_fallback.py` (120 lines: classifier + marker + metric), Celery task additions in `tasks.py`, ~530 lines of integration tests, deploy doc + Helm overlay.
**Config knobs added**: `SWH_LOADER_GIT_DULWICH_FALLBACK=1` (env flag), Celery routing rules in the Helm values.
**Ops impact**: a second worker pool runs dulwich-only loaders; routing is automatic via the classifier. Helm overlay provided.
**Risks**: dulwich is still in the codebase. If dulwich + gix both ship, the team carries two implementations until Stage 1 is proven stable enough that we can remove dulwich. (That's a future MR, not part of Phase 1.)
**Unblocks**: a production rollout you can actually let run unattended.

### Stage 3 — size-classed Celery queues + safety-net re-queue

**What Stage 3 *adds* over Stage 2**: three size-classed loader tasks (`loader.git.small/large/xl`) + a wall-time-based safety-net that auto-promotes an over-running visit to the next class. New origins default to `small`.
**Why**: prevents large-repo visits from starving the small-visit queue. The actual throughput knob in Phase 1.
**Additional diff**: `tasks.py` (+109 lines), `test_safety_net.py` (252) + `test_tasks_size_class.py` (114). Independent of gix; it's a scheduler-side improvement.
**Config knobs added**: `T_class` thresholds per size class (Helm-configurable), worker pool sizing per class.
**Ops impact**: three Celery queues to provision instead of one. Worker count per queue tunable.
**Risks**: if `T_class` thresholds are wrong, work bounces between queues. Tunable in production without code changes.

### Stage 4 — concurrent `content_add` (write-path optimization)

**What Stage 4 *adds* over Stage 3**: a concurrent code path in `CassandraStorage.content_add` (`swh-storage/feat/content-add-concurrent`).
**Why**: cuts content-add latency on multi-blob batches. Prior-art (Nicolas Dandrimont's Sept 2025 batched-read work) makes this a natural follow-up.
**Additional diff**: 4 files in `swh-storage`, +239 / –35.
**Config knobs added**: opt-in via `content_add_algo: "concurrent"` in storage config (default `sequential`). Pre-MR work to add a `content_add_concurrency` knob (default 50, see HANDOFF.md §7 #4).
**Ops impact**: zero on the loader side. Storage-side: concurrent writes against a single Cassandra writer; behaves like a queue burst rather than steady load.
**Risks**: untuned concurrency could push Cassandra harder than expected. Mitigated by the knob and a Phase-3 single-Cassandra-writer canary in `PROPOSAL-staging-rollout.md` §5.
**Independent**: lives in `swh-storage`, has its own reviewer (Nicolas Dandrimont). Can land in any order with respect to Stages 1–3.

### Stage 5 — Lane 2/3 (deferred, NOT in Phase 1)

**What Stage 5 would add**: scheduler size-based dispatch (`swh-scheduler/feat/size-based-dispatch-v1`) and lister-side GitHub size + fork metadata (`swh-lister/feat/github-size-metadata`). These use first-party metadata to pre-route origins instead of relying on Stage 3's reactive safety-net.
**Why deferred**: they require schema changes in scheduler and additional API calls in the GitHub lister. The Phase 1 path runs on the existing scheduler + lister, so we delay until Phase 1 has telemetry showing it's worth the migration.
**Out of scope** for this MR plan. Documented in `PROPOSAL-staging-rollout.md`.

---

## 3. Code surface by review category

This is a different cut of the same bytes — by *who* should review *what*.

### 3.1 Rust (gix engine + Python bindings) — ~2,428 LOC

| File | LOC | What's in it | Reviewer expertise |
|---|---:|---|---|
| `gix-lib/src/lib.rs` | 1,417 | The gix engine: fetch, pack inflate, tree/commit/tag parsers, traverse, error types. The bulk of the rewrite. | Strong Rust + git-protocol familiarity |
| `gix-py/src/lib.rs` | 775 | PyO3 bindings; channel-based streaming, GIL handling, error mapping | Rust + PyO3 experience |
| `gix-py/src/exceptions.rs` | 156 | Typed exception classes for fallback dispatch | Rust |
| `gix-lib/Cargo.toml` | 28 | Crate definition; `http-client-curl-openssl` feature flag | Rust + understanding of the curl/rustls trade-off |
| `gix-py/Cargo.toml` | 17 | Bindings crate metadata | Rust |

**What needs careful attention**: streaming pack inflation (Phase 4A), single-pass dispatch (Phase 4C), the unsafe / channel boundaries, and ref_delta resolution (the cause of two of the remaining 6 test gaps).

**Auto-generated, skim only**: `Cargo.lock` (2,040 lines) — dependency review (no surprising crates, no unmaintained deps). curl crate, openssl-sys, gix workspace are the load-bearing pieces.

### 3.2 Python production code — ~3,519 LOC

| File | LOC delta | What changed | Risk profile |
|---|---:|---|---|
| `swh/loader/git/loader.py` | +680 | gix dispatch wired in; `fetch_pack_from_origin` now branches on URL scheme; `_fetch_pack_from_local_file` for file://; `store_data` adapted to single-pass dispatch | **High** — this is the integration seam |
| `swh/loader/git/loader_dulwich.py` | +825 (new) | Copy of legacy `loader.py` renamed `GitLoaderDulwich` for fallback dispatch | **Low** — mechanical copy; reviewer compares to legacy |
| `swh/loader/git/converters.py` | +722 | Tree/commit/tag preparsed conversion for the gix path; legacy converters retained for dulwich fallback | **Medium** — parallel implementations need invariants check |
| `swh/loader/git/dulwich_fallback.py` | +120 (new) | Classifier (typed exception → reason) + marker + statsd metric | **Medium** — small but operationally critical |
| `swh/loader/git/tasks.py` | +109 | Three size-classed Celery tasks + safety-net re-queue | **Medium** — Celery dispatch logic |
| `swh/loader/git/utils.py` | +74 | Helper changes for the gix path | **Low** |
| `swh/loader/git/_gix.py` | +39 (new) | Python shim for maturin dev workflow | **Low** |
| `swh/loader/git/_gix.pyi` | +112 (new) | Type stubs for mypy | **Low** |
| `pyproject.toml` | +40 | Build dep on maturin; workspace declaration | **Low** |

### 3.3 Python tests — ~1,364 LOC

| File | LOC | Coverage |
|---|---:|---|
| `test_gix.py` | 316 | gix engine round-trips, error injection, channel-bound behaviour |
| `test_dulwich_fallback_dispatch.py` | 385 | end-to-end fallback dispatch wiring |
| `test_safety_net.py` | 252 | size-classed re-queue behaviour |
| `test_gix_exceptions.py` | 153 | typed exception classes |
| `test_dulwich_fallback.py` | 144 | classifier + marker isolated |
| `test_tasks_size_class.py` | 114 | Celery task signatures |

### 3.4 Docs / deploy / infra — ~403 LOC

| File | LOC | Purpose |
|---|---:|---|
| `deploy/HANDOFF-OPS.md` | 175 | Ops runbook for the dulwich-fallback rollout |
| `deploy/values-dulwich-fallback.yaml` | 125 | Helm values overlay |
| `README.rst` | +59 | Build (libssl-dev, Rust, maturin) + Test (PG-17, sibling installs) sections |
| `pyproject.toml` | +40 | (Counted under prod; reviewer-overlap with build/deploy) |
| `.gitignore` | +4 | Cargo target/ etc. |

### 3.5 swh-storage concurrent content_add — 239 LOC

Independent review track; see HANDOFF.md §7 #2.

---

## 4. Reviewer time estimates

These are *focused-reading* estimates assuming reviewer is fresh, has access to this doc + HANDOFF.md as pre-read, and is not pair-debugging. Add ~30% for clarification round-trips.

### 4.1 Senior engineer (Valentin Lorentz–profile reader): ~10 hours / ~1.5 working days

This is the only reviewer who needs to cover the whole stack end to end. Rough breakdown:

| Surface | Time | Why |
|---|---:|---|
| Rust core (`gix-lib`, `gix-py`) | 4–5 h | 2.4k LOC dense Rust; needs cross-checking against gitoxide upstream APIs and the ref_delta edge case |
| Python production seam (`loader.py` + `converters.py`) | 2–3 h | 1.4k lines of integration logic; reviewer maps single-pass dispatch onto the legacy 4-pass shape |
| `loader_dulwich.py` mechanical copy | 30 min | Diff against legacy loader; verify it's a faithful copy |
| Tests | 1–1.5 h | Skim to confirm coverage; spot-check the gix engine tests |
| Docs + Cargo.lock skim | 30 min | Check no surprising crates pulled in |

**Splittable**: yes. If reviewed per-MR (see §5), each MR fits a 2–3 hour reviewer slot; the full stack lands across ~5 review rounds.

### 4.2 Operator (Antoine Lambert–profile reader): ~4 hours / ~½ working day

Targets the deployable surface only:

| Surface | Time | Why |
|---|---:|---|
| `deploy/HANDOFF-OPS.md` + Helm overlay | 1 h | Read + cross-check against current loader Helm values |
| Build dep changes (`README.rst` Build section) | 30 min | Verify `libssl-dev` + Rust toolchain are available in the worker image build |
| Celery size-class config (`tasks.py` signatures, queue names) | 1 h | Confirm queue topology matches what the runner can route to |
| Hands-on: `docker run` on the test rig | 30 min | One end-to-end test on their machine |
| Staging-deploy dry-run | 1 h | Try the new worker image in staging |

### 4.3 Storage owner (Nicolas Dandrimont–profile reader, concurrent content_add): ~2 hours

Already familiar with the prior batched-read commits this stacks on. 239 LOC, 4 files. Needs a parametrised-tests review pass (R8 in HANDOFF.md §7 #4).

### 4.4 Storage owners (David Douard / Thomas Pellissier-Tanon, type-emission Q): ~1 hour

A single-question review: does any consumer of the storage API rely on per-visit `content` topic completing before the `directory` topic? Doesn't require reading code — needs a yes/no from the owner team.

### 4.5 Total reviewer-hours

| Reviewer | Hours |
|---|---:|
| Valentin (senior, full stack) | 10 |
| Antoine (operator, deploy surface) | 4 |
| Nicolas  | 2 |
| David / Thomas (type-emission Q) | 1 |
| **Grand total** | **~17** |

Wall time depends on schedule overlap, but two parallel reviewers (Valentin + Antoine) running on adjacent days plus the two storage-side parallel tracks puts the rehaul in *reviewable, not reviewed* state inside one work week.

---

## 5. Per-MR specifications

The MR stack below maps directly to the four drafts open on GitLab (`!217`–`!220` on `swh-loader-git`). The concurrent `content_add` storage-side MR sequence is described in `PLAN-concurrent-content-add.md`.

#### MR #1 — `mr/1-gix-engine` (5 commits, ~7.7k LOC) — `!217`
Compresses the 31 commits on `feat/gix-typed-exceptions` + 6 session commits (TLS fix, file:// fix, prod-bug fix, README docs, FetchPackReturn test fix) into 5 logical commits:

1. **`562feae` — gix-lib: add Rust gix engine + workspace setup** (Cargo workspace, Cargo.lock, gix-lib crate, README build/test deps, benchmarks, pyproject.toml setuptools-rust + mypy ignores). 5,348 LOC.
2. **`2ea9ee9` — gix-py: add PyO3 bindings for the gix engine** (gix-py/src/lib.rs, _gix.py shim, _gix.pyi type stubs). 943 LOC.
3. **`a944666` — gix-py: add typed exception classes** (gix-py/src/exceptions.rs). 156 LOC.
4. **`47c083f` — loader: wire gix engine into swh.loader.git** (loader.py + converters.py + utils.py; **incorporates** the file:// dulwich routing and the (2, Directory) PackReader fast-path fix). 960 LOC.
5. **`97d6d79` — loader: tests for the gix engine** (test_gix.py, test_gix_exceptions.py, test_loader.py FetchPackReturn adaptation + TestConvertObjectPackReaderTreeShape). 555 LOC.

#### MR #2 — `mr/2-size-classed-queues` (1 commit, ~620 LOC) — `!218`
Stacks on `mr/1-gix-engine`. Squashes `a6652e9` (mypy fix) and `b0cf0e6` (size-classed tasks) plus a `getattr` guard on `pack_buffer` (which doesn't exist on the gix-only stack):

1. **`00ab2a3` — loader: size-classed Celery tasks + safety-net re-queue**. 633 LOC.

#### MR #3 — `mr/3-dulwich-fallback` (3 commits, ~1.6k LOC) — `!219`
Stacks on `mr/2-size-classed-queues`. Reorders the 5 fallback commits into 3 logical ones:

1. **`e488ef0` — loader: add GitLoaderDulwich (copy-and-rename) + fallback Celery tasks** (from `8aa83cb`). 868 LOC.
2. **`da24376` — loader: dulwich-fallback dispatch helpers (classifier + marker + metric)** (from `1edb733`). 264 LOC.
3. **`5f80b73` — loader: wire dulwich-fallback dispatch + integration tests** (combines `d10b579` + `b2b571c` + `404188e`). 477 LOC.

#### MR #4 — `mr/4-helm-overlay` (1 commit, ~360 LOC) — `!220`
Stacks on `mr/3-dulwich-fallback`. Squashes `298edb4` + `155e154` + `a342384`:

1. **`79b347a` — deploy: Helm overlay + ops handoff for dulwich-fallback rollout**. 359 LOC. (Codespell rephrase: "MAPE" → "mean absolute percentage error".)

#### MR #5 — Concurrent `content_add` on swh-storage

The storage-side workstream is a separate MR stack on `swh-storage`. Per-MR specifications (init refactor, concurrent path, bench harness, journal-driven reconciler), reviewer assignments, push playbook, and CI surface notes are in `PLAN-concurrent-content-add.md`.

---

## 6. Risks and mitigation

| Risk | Mitigation |
|---|---|
| Reviewer asks for a refactor | Each MR is a single squash branch; refactoring per reviewer feedback is just amending the MR's branch tip. |
| MR #1 is too big for one reviewer | Split commit #4 ("Wire gix into loader") into per-file commits (loader.py, converters.py, utils.py separately). Adds ~3 commits, no extra MRs. |
| Stage 1 ships, gix has a bug, there's no fallback | Don't ship Stage 1 alone in production — ship Stages 1+2 together (the dulwich fallback is the safety net). Stage 1 alone is for staging / canary only. |
| concurrent content_add `content_add_concurrency` default too high | Default 50 (vs cassandra-driver's 100); knob-tunable per-deploy. Documented in HANDOFF.md §7 #4. |
| The file:// dulwich-routing path becomes a long-lived hybrid | Production never uses file://, so the path is test-only. If a future dulwich-removal MR drops it, that's one delete + test cleanup. |

---

## 7. Maintenance

- When an MR lands, update HANDOFF.md §0 and §2 (the branches table) and tick the corresponding stage above.
- When the team produces an alternative review allocation (e.g., a different senior reviewer), update §4 reviewer-profile naming.
- When Stage 5 is unblocked, expand §2.5 with the same shape as the other stages.

---

*This document is the planning companion to `HANDOFF.md`. `HANDOFF.md` is the source of truth for current state. This file is the source of truth for the proposed rollout shape.*
