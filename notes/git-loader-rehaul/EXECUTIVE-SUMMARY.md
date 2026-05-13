# Executive summary — Git loader rehaul + concurrent content_add proposal

*Entry-point document for the SWH team. Read this first; navigation to detailed docs at §6.*

---

## 1. What this proposal is

The **gix engine rehaul** replaces dulwich (Python, single-threaded fetch + pack inflation) with gitoxide (Rust, streaming + parallel) for the git-loader hot path. The replacement is a drop-in for the loader's existing fetch + parse + hashing stages, with a dulwich-fallback safety net (typed exceptions classify gix failures and route the visit to a dulwich-only queue) and three size-classed Celery queues (`small` / `large` / `xl`) with a wall-time safety-net re-queue that auto-promotes oversized visits.

A **sibling workstream** covers the storage side: a concurrent code path for `CassandraStorage._content_add` that fires the 5N CQL round-trips per content batch through `cassandra.concurrent.execute_concurrent` instead of sequentially. Independent reviewer track in swh-storage; ships behind a config flag, default sequential, no behavior change unless enabled. Per the W20 management decision this work is top-priority for the first sprint — it bottlenecks dulwich today, not just the new gix engine. See `notes/git-loader-rehaul/ISSUE-concurrent-content-add.md` for the architectural-issue body and `notes/git-loader-rehaul/PLAN-concurrent-content-add.md` for the MR execution sequence.

---

## 2. What ships in Phase 1

The gix proposal's Phase 1 ships these as a single coherent rollout:

- **Gix engine** as the default git-loader fetch + parse + hash path. Build deps: `libssl-dev` + Rust toolchain + maturin at compile time. Runtime: just `libssl3`.
- **Dulwich-fallback dispatch** behind the `SWH_LOADER_GIT_DULWICH_FALLBACK=1` env var. Typed gix exceptions (`GixPackError` / `GixObjectParseError` / `GixTraverseError`) route the affected origin to a separate dulwich-only Celery worker pool of the same tier. Statsd: `git_dulwich_fallback_total{reason}`.
- **Three size-classed loader tasks** (`loader.git.small/large/xl`) with safety-net re-queue. New-origin default routing: `small`; auto-promote on `T_class` overrun.

**Deferred to Phase 2/3**:
- Scheduler-side size-based dispatch (Lane 2): adds `pack_size_kb` / `commit_count` to `listed_origins` and routes proactively rather than reactively.
- Lister-side GitHub size metadata (Lane 3): opt-in per-repo metadata collection on the GitHub lister.
- **concurrent `content_add` enable** (Phase 3 gate): the optimization is opt-in via storage config (`content_add_algo: concurrent`); enabling requires the journal-driven reconciler to be running with low lag in production first. See `PLAN-concurrent-content-add.md`.

---

## 3. Reviewable surface

4 stacked MRs open as drafts in `swh-loader-git` (`!217` → `!220`); the concurrent `content_add` MR stack on `swh-storage` is ready to execute (see `PLAN-concurrent-content-add.md`).

| Bucket | LOC | Notes |
|---|---:|---|
| Rust core (gix-lib, gix-py, typed exceptions, 2× Cargo.toml) | 2,428 | New crates; gix engine + PyO3 bindings |
| Python production code (loader.py, loader_dulwich.py, converters.py, dulwich_fallback.py, tasks.py, utils.py, _gix.py, _gix.pyi, pyproject.toml) | 3,519 | The actual loader changes + fallback path |
| Python tests | 1,364 | 6 new test files |
| Docs / deploy / infra (README, HANDOFF-OPS, Helm overlay) | 403 | |
| **Reviewable subtotal** (Rust + Python prod + tests + docs) | **~7,714** | What expert review targets |
| Auto-generated (Cargo.lock) | 2,040 | Cargo determines; reviewer skim only |
| Benchmarks (off the critical path) | 2,133 | Smoke-review |
| Binary fixture (malformed pack) | 53 b | Test data |

concurrent content_add sibling proposal adds **239 LOC** in swh-storage (4 files in `swh/storage/cassandra/` + `metrics.py` + tests). Independent review track.

---

## 4. Reviewer time estimates

Focused-reading estimates assuming reviewer is fresh, has pre-read access to this summary + `HANDOFF.md`, and is not pair-debugging. Add ~30% for clarification round-trips.

| Reviewer profile | Hours | Splittable? |
|---|---:|---|
| Senior engineer (full stack — gix + loader seam + tests) | ~10 | Yes; ~2-3h per MR |
| Operator (deploy surface only — Helm, Celery topology, README build deps) | ~4 | No; one focused pass |
| Storage owner (concurrent `content_add` MR stack on `swh-storage`) | ~9 | 4 MRs across init refactor + concurrent path + bench + reconciler — see `PLAN-concurrent-content-add.md` |
| Storage owners (per-visit type-emission yes/no question) | ~1 | Single-question review |
| **Grand total** | **~17** | Parallelizable across 2-3 reviewers |

Wall time: two parallel reviewers (senior + operator) running on adjacent days + the two storage-side parallel tracks → reviewable in one work week.

---

## 5. MR stack diagram

```
swh-loader-git / master
  ↓
mr/1-gix-engine                 (5 commits — gix-lib, gix-py, typed exceptions, wire-into-loader, tests)
  ↓
mr/2-size-classed-queues        (1 commit — small/large/xl Celery tasks + safety-net re-queue)
  ↓
mr/3-dulwich-fallback           (3 commits — GitLoaderDulwich, dispatch helpers, wire + tests)
  ↓
mr/4-helm-overlay               (1 commit — deploy guide + Helm values + ops handoff)


swh-storage / master
  ↓
mr/1-cassandra-init-split           (refactor — splits CassandraStorage.__init__)
  ↓
mr/2-concurrent-content-add         (opt-in concurrent path, default sequential)
  ↓
mr/3-content-add-bench              (throughput harness, sequential vs concurrent)

mr/4-content-reconciler             (journal-driven content reconciler, ~350 LOC; independent)
```

See `PLAN-concurrent-content-add.md` for the per-MR specification, reviewer assignment, and push playbook.

---

## 6. Navigation (by reader role)

| Role | First read | Then |
|---|---|---|
| Decision-makers / leadership | this summary + `notes/presentations/INGESTION_REHAUL.md` (slide deck) | `HANDOFF.md` §0 for current state |
| Code reviewers | `HANDOFF.md` §2 (branches) + `HANDOFF-MR-PLAN.md` §5 (per-MR detail) | per-MR commit-by-commit on the branch |
| Operators | `notes/PROPOSAL-staging-rollout.md` + `deploy/HANDOFF-OPS.md` (lands on mr/4) + `notes/git-loader-rehaul/test-rig/` | `HANDOFF.md` §6 for the test rig setup |
| Engineers wanting hands-on | `notes/git-loader-rehaul/test-rig/Dockerfile` + `HANDOFF-MR-PLAN.md` §5 | run the test rig, check out the branches |
| concurrent content_add reviewers | `ISSUE-concurrent-content-add.md` (issue body, ready for GitLab) + `PLAN-concurrent-content-add.md` (8-MR sequence) | `HANDOFF.md` §7 for open decisions |
| Pack-loading deep dive | `report/ALGORITHMS-pack-loading.md` | `report/ANALYSIS-git-loader-modernization.md` |

The **test rig** at `notes/git-loader-rehaul/test-rig/` is the reproducibility artifact — `docker build` + `docker run` reproduces the verification results on any Docker host (~15-20 min wall time). Highly recommended for any reviewer who wants to verify claims independently.

---

## 7. Open decisions to ratify

From `HANDOFF.md` §5 + `ISSUE-concurrent-content-add.md`:

1. **Per-visit type separation** (storage owners) — does any journal consumer rely on per-visit `content` topic completing before `directory` topic? If yes → schedule a 2-walk follow-up MR; if no → ship single-walk as-is. Single yes/no from David Douard / Thomas.
2. **Concurrent `content_add` reconciler location** — recommend sub-package `swh.storage.reconciler` (alternatives in `PLAN-concurrent-content-add.md` §3). Storage owners decide.
3. **Concurrent `content_add` concurrency knob default** — recommend `content_add_concurrency: 50` (vs cassandra-driver default 100). Conservative for first prod deploy; ops + storage owners decide.
4. **MR3 bench harness location** — recommend `swh-storage/swh/storage/tests/bench/content_add.py` (in-tree). Storage owners decide.

---

## 8. What's NOT in this proposal

- **Phase 2/3 Lane work** — Lane 2 (scheduler-side size-based dispatch) and Lane 3 (lister-side GitHub size metadata) are deferred. The Phase 1 path runs on the existing scheduler + lister; we revisit after Phase 1 telemetry shows whether the size-based migration is worth the schema change.
- **The journal-driven content reconciler for concurrent content_add** — required before concurrent content_add's `concurrent` algo can be enabled in production. Covered as MR4-MR7 in `PLAN-concurrent-content-add.md`; sequenced after the architectural issue is opened and ratified.
- **Production rollout decisions** — those live in the ops repos (`swh/infra/ci-cd/swh-charts`), gated by the staging metrics described in `PROPOSAL-staging-rollout.md` §5 and `PLAN-concurrent-content-add.md` §6. The reconciler chart + per-cluster overlay design is captured in `SPEC-reconciler-deploy.md` (this directory); tracking issue at `swh/infra/ci-cd/swh-charts#5`.
- **Mirror replay against partial visits** — probably non-issue; worth a five-minute confirmation with whoever runs the SWH mirrors. Listed in `HANDOFF.md` §8.
- **Direct gix-to-ORC bulk ingestion (AdAstra)** — a forward-looking sibling exploration for bulk-loading hundreds of millions of repositories directly into ORC files, bypassing the SWH loader→storage runtime. Scoped in `EXPLORE-adastra-direct-ingestion.md`; not part of this proposal's rollout, but reuses the same gitoxide stack and can prototype in parallel with rehaul review.
- **github-ingestion migration** — the existing `github-ingestion` repo's batch loader has only 3 dulwich call sites (2–4 hour migration to gix once `mr/1-gix-engine` lands) and ships with a 390-LOC `OrcStorage` sink that AdAstra can reuse without modification. Scoped in `EXPLORE-github-ingestion-migration.md`.

---

## 9. concurrent content_add sibling proposal — pointer

The Cassandra concurrent content_add work ships independently (different repo, different reviewer track, opt-in via storage config). Read `notes/git-loader-rehaul/ISSUE-concurrent-content-add.md` for the architectural-issue body (copy/paste-ready into a GitLab issue in `swh/devel/swh-storage`) and `notes/git-loader-rehaul/PLAN-concurrent-content-add.md` for the 8-MR sequence (refactor → concurrent content_add code → bench → reconciler → 4 deploy gates → optional miss-tolerant proxy).

---

## 10. Recommended reading order

For a fresh reviewer (operator profile or engineer profile alike):

1. **This summary** — orientation (5 min).
2. **`notes/presentations/INGESTION_REHAUL.md`** — visual narrative of the rehaul story (slide deck, 15-20 min).
3. **`HANDOFF.md` §0 (current state) + §2 (branches)** — what's in each MR (5 min).
4. **`HANDOFF-MR-PLAN.md` §5 (per-MR commit recipe)** — drill into the MR you'll review (5 min per MR).
5. **The actual commit diffs on the branch** — `git checkout mr/<N>-<name>`; read commit-by-commit (depends on MR).
6. **`notes/git-loader-rehaul/test-rig/`** — optional, reproduces results on your machine (~15-20 min).
7. **For concurrent `content_add` specifically**: `ISSUE-concurrent-content-add.md` → `PLAN-concurrent-content-add.md` → execute the MR sequence per the push playbook.

After this reading order a reviewer should be able to ratify the open decisions in §7, approve or request changes on their assigned MR, and weigh in on the staging-rollout gates.
