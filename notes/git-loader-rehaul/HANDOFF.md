# HANDOFF — SWH ingestion-pipeline rehaul, ready for team pickup

**Companion**: `HANDOFF-MR-PLAN.md` answers "how much complexity, how much review, what MR sequence?" — read it alongside this doc when planning the team work.

---

## 0. Current state

Two parallel workstreams ship in this rehaul. Per the W20 management coordination meeting, both are in scope for the first sprint.

**Loader engine (swh-loader-git) — 4 MRs open as drafts on GitLab:**

```
master (swh-loader-git)
  ↓
mr/1-gix-engine             (!217 — gix-lib + bindings + typed exceptions + loader wire-in + tests)
  ↓
mr/2-size-classed-queues    (!218 — small/large/xl Celery tasks + safety-net re-queue)
  ↓
mr/3-dulwich-fallback       (!219 — typed gix exceptions → dulwich-only worker pool)
  ↓
mr/4-helm-overlay           (!220 — Helm values + README deploy guide + ops handoff)
```

Assignee David Douard; he dispatches review. Per-MR detail in `HANDOFF-MR-PLAN.md` §5.

**Storage engine (swh-storage) — concurrent `content_add` — MR stack ready to execute:**

```
master (swh-storage)
  ↓
mr/1-cassandra-init-split          (refactor — splits CassandraStorage.__init__)
  ↓
mr/2-concurrent-content-add        (the REC-L4-derived concurrent path; rebases prior work)
  ↓
mr/3-content-add-bench             (throughput harness, sequential vs concurrent)

mr/4-content-reconciler            (journal-driven content reconciler — independent of master, ~350 LOC)
```

Architectural issue body ready at `ISSUE-concurrent-content-add.md`. Execution sequence + reviewer assignment + push playbook at `PLAN-concurrent-content-add.md`. The pre-execution rebase source `mr/5-rec-l4-content-add` (2 commits, swh-storage) is the historical anchor; MR2 above is its post-`__init__`-split successor.

**Task force (W20 charter):** Thomas (coord + main contact) · Valentin Lorentz (~90% blue team) · Théophile (~90% blue team) · Nicolas Dandrimont (red team, machines) · Martin (red, partial — on MOSAIC). Cadence: **May = audit + bench; June = decide + launch refactoring**; end-of-May presentation. No big refactoring during May.

---

## 1. What ships in Phase 1 (zero-refactor MVP)

Per `notes/PROPOSAL-staging-rollout.md` §3 and the deck slide "The zero-refactor minimal path":

- **gix engine as the default loader** for git origins, with the dulwich-fallback dispatch path enabled behind `SWH_LOADER_GIT_DULWICH_FALLBACK=1`.
- **Three size-classed Celery queues** (`loader.git.small/large/xl`) with wall-time-based safety-net re-queue. Default routing for new origins: `small`, self-promote on `T_class` overrun.
- **Concurrent `content_add`** as opt-in via `content_add_algo: "concurrent"` (default `sequential`). Per the W20 prioritization, this is in scope for the first sprint and runs as an independent track from the loader engine work — see `PLAN-concurrent-content-add.md`.

Out of Phase 1: scheduler-side size-based dispatch (Lane 2) and lister-side GitHub size metadata (Lane 3) — deferred. The Phase 1 path runs on the existing scheduler + lister.

---

## 2. Branches table

### `swh-loader-git`

| Branch | HEAD | Commits | MR | Purpose |
|---|---|---:|---|---|
| `mr/1-gix-engine` | `97d6d79` | 5 | `!217` | gix-lib + gix-py bindings + typed exceptions + wire-into-loader + tests |
| `mr/2-size-classed-queues` | `00ab2a3` | 1 | `!218` | Three size-classed Celery tasks + safety-net re-queue (stacked on mr/1) |
| `mr/3-dulwich-fallback` | `5f80b73` | 3 | `!219` | GitLoaderDulwich + classifier + marker + statsd + integration tests (stacked on mr/2) |
| `mr/4-helm-overlay` | `79b347a` | 1 | `!220` | README deploy guide + Helm values overlay + ops handoff (stacked on mr/3) |

### `swh-storage`

The concurrent `content_add` MR stack — `mr/1-cassandra-init-split` → `mr/2-concurrent-content-add` → `mr/3-content-add-bench`; `mr/4-content-reconciler` is independent of the stack — is ready to be built and pushed. See `PLAN-concurrent-content-add.md` for the per-MR specification, reviewer assignment, push playbook, and CI surface notes.

Rebase source: branch `mr/5-rec-l4-content-add` on swh-storage (HEAD `9bf92395`, 2 commits) carries the original concurrent-path work; MR2 above derives from it after applying the `__init__` refactor.

### Other repos (Lane 2/3, deferred)

| Repo | Branch | Status |
|---|---|---|
| `swh-scheduler` | `feat/size-based-dispatch-v1` | Local; Lane 2; not for Phase 1 |
| `swh-lister` | `feat/github-size-metadata` | Local; Lane 3; not for Phase 1 |

---

## 3. Known pre-existing test gaps on the loader MR stack

Six tests in `TestGitLoader` fail on the loader MR stack. **None are real production regressions.** Categorised so reviewers can triage Jenkins output:

### Category B — tests rely on dulwich-specific implementation details (4)

| Test | What it asserts | Why it fails |
|---|---|---|
| `test_load_visit_without_snapshot_so_status_failed` | monkey-patching `self.loader.get_contents = None` triggers `status="failed"` | gix pipeline doesn't call the legacy `get_contents` method, so the monkey-patch has no effect |
| `test_load_pack_size_limit` | pack > limit → `status="failed"` | size-limit check moved in the rehaul; test asserts old location |
| `test_metrics` | statsd calls fire in a specific order (`content` first) | rehaul's single-pass dispatch reorders object processing; metrics fire in the new order |
| `test_metrics_filtered` | same as above + a small ratio difference | same root cause |

**Action**: each test should be updated to either (a) assert the new behaviour or (b) be removed if the assertion is no longer meaningful. Loader maintainer call.

### Category B' — gix vs dulwich behavioural difference, ref_delta resolution (2)

| Test | What fails |
|---|---|
| `test_loader_with_ref_delta_in_pack[False-False]` | `_gix.GixPackError: failed to decode pack entry: A delta chain could not be followed as the ref base ... could not be found` |
| `test_loader_with_ref_delta_in_pack[False-True]` | same |

The test simulates a pack containing ref_deltas where the base commit is in the loader's object store but **not in the pack itself**. dulwich's pack reader looked up bases in the object store first. gix's pack reader does not — it expects bases to be in the pack or in the haves negotiated via the smart protocol.

**Whether this is a real production concern**: in normal smart-protocol fetch flows, the server only sends ref_deltas whose base is either in the pack or in the haves; this test simulates an unusual edge case. **Likely not a production regression**, but worth confirming with a loader maintainer that the smart-protocol guarantee holds.

**Action**: confirm the production assumption holds (loader maintainer review of gix-pack ref_delta handling); if yes, update or skip these test variants.

---

## 4. Reproducibility — running the test rig

### Docker on the laptop (recommended)

A self-contained Docker rig at `notes/git-loader-rehaul/test-rig/`. From the `swh-environment` root:

```bash
docker build -t swh-loader-git-testrig:latest \
    notes/git-loader-rehaul/test-rig/

docker run --rm \
    -v "$PWD:/work" \
    swh-loader-git-testrig:latest
```

The container runs as uid=1000 (matches typical Linux dev user), writes per-cell logs to `notes/git-loader-rehaul/test-rig/results/` (gitignored). Includes PG-17 with contrib (`btree_gist`/`pgcrypto`/`pg_trgm`), Rust toolchain at `/usr/local/cargo`, and the system pytest stack.

Wall time: ~5 min loader cells + ~5–10 min storage cells = ~15–20 min total.

### Laptop direct

`make test` from `swh-loader-git/` after the three-step setup in the README's "Test" section: editable installs of sibling SWH repos, system PostgreSQL 17, and `pip install -r requirements-test.txt`.

---

## 5. Outstanding decisions for the team

These are the items that should close in the team-coordination meeting (or async if simpler):

1. **Per-visit type separation** — `notes/presentations/INGESTION_REHAUL.md` "Type-emission shape" slide. Storage owners (David, Thomas) decide whether any journal consumer relies on per-visit `content` topic completing before `directory` topic. If yes → schedule the 2-walk follow-up MR; if no → ship single-walk as-is. **Recommended path**: ask the storage owners first, default to "no" unless they object.

2. **Concurrent `content_add` reconciler location** — recommend sub-package `swh.storage.reconciler` (alternatives in `PLAN-concurrent-content-add.md` §3). Storage owners decide before MR4 starts.

3. **Concurrent `content_add` concurrency knob default** — recommend `content_add_concurrency: 50` (vs cassandra-driver default 100). Conservative for first prod deploy; ops + storage owners decide.

4. **MR ordering** — push and review in this order:
    1. `swh-loader-git/mr/1-gix-engine` (5 commits, ~7.7k LOC; foundational) — open as `!217`
    2. `swh-loader-git/mr/2-size-classed-queues` (1 commit, ~620 LOC; stacks on mr/1) — open as `!218`
    3. `swh-loader-git/mr/3-dulwich-fallback` (3 commits, ~1.6k LOC; stacks on mr/2) — open as `!219`
    4. `swh-loader-git/mr/4-helm-overlay` (1 commit, ~360 LOC; stacks on mr/3) — open as `!220`
    5. Concurrent `content_add` storage-side stack — see `PLAN-concurrent-content-add.md` for the per-MR push playbook.

   See `HANDOFF-MR-PLAN.md` §5 for the per-MR commit list and reviewer hours.

---

## 6. Recommended next actions

In order, lowest cost first:

1. **Run `make test` from a fresh clone** to confirm the README's Build + Test setup is sufficient for a fresh team member.
2. **Share `notes/presentations/INGESTION_REHAUL.md`** with the task force (Thomas / Valentin / Théophile / Nicolas) ahead of the May audit kickoff. Engineer-facing material lives in `test-rig/` + `HANDOFF-MR-PLAN.md` §5 — no separate maintainer deck.
3. **Resolve item 1 in §5** (per-visit type separation) — single conversation with David and Thomas. Path forward depends on their answer.
4. **Execute the concurrent `content_add` MR sequence** per `PLAN-concurrent-content-add.md`: publish the architectural issue on `swh/devel/swh-storage`, then build and push MR1–MR4.
5. **Phase 1 staging deploy** per `PROPOSAL-staging-rollout.md` §5 once the four staging-gate values are agreed.

---

## 7. Document index

Pick by topic.

### Entry points
- **`notes/git-loader-rehaul/EXECUTIVE-SUMMARY.md`** — the proposal overview; start here.
- **`notes/git-loader-rehaul/HANDOFF-MR-PLAN.md`** — deployment stages, reviewable code surface, reviewer time estimates, per-MR commit recipe.
- `notes/git-loader-rehaul/ISSUE-concurrent-content-add.md` — concurrent `content_add` architectural-issue body, ready to publish in `swh/devel/swh-storage`.
- `notes/git-loader-rehaul/PLAN-concurrent-content-add.md` — concurrent `content_add` MR execution sequence + push playbook.
- `notes/PROPOSAL-staging-rollout.md` — full staging proposal with metric gates.
- `notes/git-loader-rehaul/EXPLORE-adastra-direct-ingestion.md` — forward-looking sibling: direct gix-to-ORC bulk ingestion for hundreds of millions of repositories, bypassing the SWH loader→storage runtime.
- `notes/git-loader-rehaul/EXPLORE-github-ingestion-migration.md` — companion: maps the existing github-ingestion repo against the new pipeline; identifies a 2–4 hour dulwich→gix migration plus a 390-LOC `OrcStorage` sink reusable by AdAstra.
- `report/ANALYSIS-git-loader-modernization.md` — strict-cell evidence + L1-L7 root causes.
- `report/ALGORITHMS-pack-loading.md` — per-step algorithm walkthrough.
- `notes/presentations/INGESTION_REHAUL.md` — team-leadership deck (covers loader engine + Cassandra `content_add` write path).
- `swh-loader-git/README.rst` — Build + Test dependency sections updated for the rehaul (libssl-dev, PG-17, sibling installs).

### Reproducibility
- `notes/git-loader-rehaul/test-rig/Dockerfile` — bookworm + PG-17 + Rust + maturin + pytest stack.
- `notes/git-loader-rehaul/test-rig/run-cells.sh` — entrypoint that bind-mounts `/work` and runs the four cells.

---

## 8. Open questions / things this doc does NOT answer

- **Mirror replay against partial visits**: probably non-issue, but worth a five-minute confirmation with whoever runs the SWH mirrors.
- **Concurrent `content_add` MissTolerantProxy** (optional MR8) — code now shipped as `!1227` (GATED draft). Defense-in-depth against the consistency window. Wire into the read pipeline only if production metrics show user-facing 404s from the race window.
- **Reconciler chart + per-cluster overlays** (MRs 5/6/7) — tracking issue `swh/infra/ci-cd/swh-charts#5`. Full design in `notes/git-loader-rehaul/SPEC-reconciler-deploy.md`. Blocks on `!1223`–`!1226` merging to swh-storage master + a tagged release.
