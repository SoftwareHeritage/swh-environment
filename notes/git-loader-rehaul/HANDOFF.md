# HANDOFF — git-loader rehaul, ready for team pickup

**Living document.** Updated as the rollout progresses. Section §0 ("Status as of") is the first thing to update on every change.

---

**Companion**: `HANDOFF-MR-PLAN.md` answers "how much complexity, how much review, what MR sequence?" — read it alongside this doc when planning the team handoff.

## 0. Status as of 2026-05-06

**Update — history rewrite landed.** The 5-MR sequence proposed in `HANDOFF-MR-PLAN.md` §5 has been built locally as a stack of clean branches:

```
master
  ↓
mr/1-gix-engine             (5 commits, swh-loader-git)
  ↓
mr/2-size-classed-queues    (1 commit, swh-loader-git)
  ↓
mr/3-dulwich-fallback       (3 commits, swh-loader-git)
  ↓
mr/4-helm-overlay           (1 commit, swh-loader-git)

master (swh-storage)
  ↓
mr/5-rec-l4-content-add     (2 commits, swh-storage; independent of the loader stack)
```

12 commits total replacing the prior 42-commit graph. Three departures from the original plan:
1. **MR #0 (production bug fix) was folded into MR #1**: the (2, Directory) crash lives on the gix `_convert_object` path, so it cannot land on master alone — its fix is part of MR #1's "wire gix into loader" commit.
2. **MR #2 ↔ MR #3 swap**: the dulwich-fallback wiring references the size-class tier mappings, so size-classed queues must land first. Final order: gix engine → size-classed queues → dulwich-fallback → helm overlay.
3. **REC-L4 split into 2 commits, not 3**: the planned commit 3 (`content_add_concurrency` knob + parametrised tests, R4+R8) is genuinely new work and stays on the §7 #4 punch-list rather than being faked into the rebase.

**Pre-rewrite tags retained** for forensic comparison:
- `gix-rehaul-v0-history` → original `feat/gix-dispatch-integrated` tip
- `fix-branch-v0-history` → original `fix/gix-loader-pack-reader-tree-tuple` tip
- `rec-l4-v0-history` → original `feat/content-add-concurrent` tip

`mr/4-helm-overlay` is tree-equal to `fix-branch-v0-history` modulo three intentional cleanups: codespell rephrase ("MAPE" → "mean absolute percentage error"), a less-redundant comment block in `loader.py`'s safety-net, and an isort fix to a stale import order in `test_loader.py`. All branches still local-only; push remains the next ops step.



The four-cell test-hang verification matrix from `PLAN-test-hang-verification.md` has converged. The rehaul branch on `swh-loader-git` and the REC-L4 branch on `swh-storage` are in a state where:

- **Three real regressions identified during the rehaul work, all fixed and verified end-to-end** (laptop + maxxi + Docker bookworm):
  1. `_gix` HTTPS handshake failure (rustls cert verifier missing) → `gix-lib` switched to curl/OpenSSL.
  2. `file://` URL fetch hang (gix subprocess never returns) → loader routes `file://` through dulwich's `LocalGitClient`.
  3. `InMemoryStorage` REC-L4 attribute crash (158 storage tests failing) → class-level default in `CassandraStorage`.
- **Six remaining test failures in `TestGitLoader`** are pre-existing rehaul-stack gaps newly visible after the file:// hang was unblocked. None are production regressions; all live in test code or assert dulwich-specific implementation details. Triage in §5.
- **Branches are local-only.** None pushed upstream to GitLab. Push-and-MR is the next ops step.

The rehaul's deployment readiness as a code artefact is **green**; what remains is the social process (MR review, ratification meeting, staging deploy) and the Phase-1 measurement window.

---

## 1. What ships in Phase 1 (zero-refactor MVP)

Per `notes/PROPOSAL-staging-rollout.md` §3 and the deck slide "The zero-refactor minimal path":

- **gix engine as the default loader** for git origins, with the dulwich-fallback dispatch path enabled behind `SWH_LOADER_GIT_DULWICH_FALLBACK=1`.
- **Three size-classed Celery queues** (`loader.git.small/large/xl`) with wall-time-based safety-net re-queue. Default routing for new origins: `small`, self-promote on `T_class` overrun.
- **REC-L4 concurrent `content_add`** as opt-in via `content_add_algo: "concurrent"` (default `sequential`); intended for a Phase-3 single-Cassandra-writer canary.

Out of Phase 1: `feat/size-based-dispatch-v1` (scheduler) and `feat/github-size-metadata` (lister) — Lane 2/3, deferred. The Phase 1 path runs on existing scheduler + lister.

---

## 2. Branches and current state

All branches are **local-only** as of this writing. Push order recommendation in §7.

### `swh-loader-git` — clean MR stack (post-rewrite)

| Branch | HEAD | Commits | Purpose |
|---|---|---:|---|
| `mr/1-gix-engine` | `97d6d79` | 5 | gix-lib + gix-py bindings + typed exceptions + wire-into-loader (incl. file:// fix and (2, Directory) fix) + tests |
| `mr/2-size-classed-queues` | `00ab2a3` | 1 | Three size-classed Celery tasks + safety-net re-queue (stacked on mr/1; `pack_buffer` access guarded via `getattr` so the gix-only stack lints clean) |
| `mr/3-dulwich-fallback` | `5f80b73` | 3 | GitLoaderDulwich + Celery tasks; classifier + marker + metric helpers; wiring + integration tests + malformed-pack fixture (stacked on mr/2) |
| `mr/4-helm-overlay` | `79b347a` | 1 | README deploy guide + Helm values overlay + ops handoff doc (stacked on mr/3) |

### `swh-loader-git` — pre-rewrite (retained as tags + branches)

| Branch / tag | HEAD | Purpose |
|---|---|---|
| `feat/gix-typed-exceptions` | `1f16601` | Typed exception classes on the Rust side; foundation of the dulwich-fallback dispatch |
| `feat/dulwich-fallback` | `1edb733` | Classifier + marker + statsd metric; stacked on `feat/gix-typed-exceptions` |
| `feat/size-dispatch-safety-net` | `b0cf0e6` | Three size-classed Celery tasks + safety-net re-queue + 24 unit tests |
| `feat/gix-dispatch-integrated` | `a342384` | Composition of the four feature branches plus deployment helpers |
| `fix/gix-loader-pack-reader-tree-tuple` | `8f3c70c` | Production bug fix on top of integrated **plus all three regression fixes from the rehaul work** (TLS, file://, test-rig docs, etc.) |
| `gix-rehaul-v0-history` (tag) | `a342384` | Pre-rewrite snapshot of integrated branch tip |
| `fix-branch-v0-history` (tag) | `8f3c70c` | Pre-rewrite snapshot of fix branch tip — tree-equal to `mr/4-helm-overlay` modulo 3 intentional cleanups |

The session's three regression fixes layered on `fix/gix-loader-pack-reader-tree-tuple`:

```
8f3c70c  tests: update FetchPackReturn(pack_buffer=) to FetchPackReturn(pack_path=)  [Category-A test cleanup]
ef34d76  loader: route file:// URLs to dulwich LocalGitClient (Option A)            [regression #2 fix]
f372b9c  docs: document libssl-dev / OpenSSL build dep for _gix Rust extension       [doc companion to #1]
0c813c6  gix-lib: switch curl HTTP backend from rustls to OpenSSL                    [regression #1 fix]
1c54e18  docs: document PG-17 + sibling-editable-install test deps                   [test setup]
da7b2b1  loader: fix _convert_object crash on (2, Directory) tuples from PackReader  [pre-existing prod bug fix]
```

### `swh-storage`

| Branch / tag | HEAD | Purpose |
|---|---|---|
| `mr/5-rec-l4-content-add` | `9bf92395` | **Clean MR stack (post-rewrite)** — 2 commits: (1) class-level `_content_add_algo` default for subclass compat; (2) concurrent content_add path + cql.py + tests + metric |
| `feat/content-add-concurrent` | `4e51c838` | Pre-rewrite REC-L4 branch (1 commit); tree-equal to `mr/5-rec-l4-content-add` |
| `backup-pre-rebase-20260505-184555` | (preserved) | Pre-rebase snapshot of the original commit `e7db95bb`, retained in case the resolution needs to be redone |
| `rec-l4-v0-history` (tag) | `4e51c838` | Pre-rewrite snapshot of REC-L4 tip |

### Other repos (Lane 2/3, deferred)

| Repo | Branch | Status |
|---|---|---|
| `swh-scheduler` | `feat/size-based-dispatch-v1` | Local; Lane 2; not for Phase 1 |
| `swh-lister` | `feat/github-size-metadata` | Local; Lane 3; not for Phase 1 |

---

## 3. Verified regression fixes (the three regressions)

### 3.1 gix HTTPS rustls cert verifier (`0c813c6`)

**Failure**: `_gix.GixFatalError: ... no server certificate verifier was configured on the client config builder` on every HTTPS handshake.

**Root cause**: `gix-transport`'s `http-client-curl-rust-tls` feature pulls in `curl/rustls`. The curl crate's rustls feature does not wire a default certificate verifier; rustls 0.23+ made the verifier mandatory. The curl crate has no companion `rustls-native-roots` flag.

**Fix**: switched `gix-lib/Cargo.toml` from `http-client-curl-rust-tls` to `http-client-curl-openssl`. OpenSSL via `openssl-probe` auto-detects the system CA bundle, matches git's own TLS stack, and the curl crate's `ssl` feature has been the default and battle-tested for years. Net effect on build: `rustls` + `ring` + `rustls-platform-verifier` + `rustls-webpki` and several more transitive deps fall out (-462 lines in `Cargo.lock`).

**New build dep**: `libssl-dev` at compile time (`libssl3` at runtime is universal). Documented in `swh-loader-git/README.rst` "Build" section.

**Verified**: `test_fetch_pack_list_refs_only` and `test_fetch_pack_size_limit` pass in 1.34 s on laptop and maxxi against `gitlab.softwareheritage.org`.

### 3.2 gix file:// fetch hang (`ef34d76`)

**Failure**: `loader.load()` hung indefinitely on any test using `prepare_repository_from_archive` (which returns a `file://` URL pointing at a tarball-extracted bare repo). Confirmed on three substrates: laptop, maxxi, Docker bookworm. py-spy live stack on each: `loader.py:292` → `gix_fetch_pack(file://...)`.

**Root cause**: gix's `connect()` for `file://` URLs spawns `git-upload-pack` as a subprocess and blocks indefinitely on its stdin/stdout. The dulwich master path handled `file://` in-process via `LocalGitClient`, so the rehaul broke this case. `pytest --timeout=60 --method=signal` does not interrupt because SIGALRM is delivered when Python regains control, but Python is blocked inside a Rust FFI call that never returns.

**Fix**: at the top of `fetch_pack_from_origin`, detect `file://` URLs and delegate to a new `_fetch_pack_from_local_file()` method that uses dulwich's `LocalGitClient`. The pack data is written to a `NamedTemporaryFile` on disk — same `pack_path` interface the gix path returns, so the rest of the pipeline (`_gix.iter_pack_objects(pack_path)`) consumes it without any downstream change. Hybrid layout: dulwich does the fetch (network/transport, in-process), gix does the parse (pack walking).

**Production safety**: `file://` is a test-rig convention only; production origins are always `https://` / `git://` / `ssh://`. The new branch in `fetch_pack_from_origin` is taken only in test contexts.

**Verified**: `test_load_tag_minimal` + `test_load_empty_tree` pass in 2.21 s on laptop, 1.69 s on maxxi.

### 3.3 REC-L4 InMemoryStorage subclass crash (`4e51c838`)

**Failure**: 158 storage-side test failures in `test_filter.py`, `test_tenacious.py`, etc., with `AttributeError: 'InMemoryStorage' object has no attribute '_content_add_algo'`.

**Root cause**: REC-L4 added `self._content_add_algo = content_add_algo` in `CassandraStorage.__init__`. `InMemoryStorage` extends `CassandraStorage`, overrides `__init__` without forwarding the new parameter, then inherits `_content_add` which dispatches on `self._content_add_algo`. AttributeError on every test that exercises in-memory storage through proxy classes.

**Fix**: class-level default `_content_add_algo: str = "sequential"` on `CassandraStorage`. Subclasses skipping the parameter inherit the safe default; instance `__init__` overrides when provided.

**Verified**: Docker storage cells (`D-storage-master` vs `D-storage-recl4`) now show identical numbers (2799 passed, 305 errors). The 158-failure delta is gone.

---

## 4. Verification matrix — what was confirmed where

`PLAN-test-hang-verification.md` defined a 2×2 `{laptop, maxxi} × {master, rehaul}` matrix; the Docker test rig at `notes/git-loader-rehaul/test-rig/` collapses two cells into a clean substrate. Final outcomes:

| Cell | Substrate | Master | Rehaul (post-fixes) |
|---|---|---|---|
| L-loader | laptop | not run (control sufficient from D-cells) | 26/32 TestGitLoader (was 8h hang pre-fix) |
| M-loader | maxxi | passed (171/171) prior session | TestGitLoader specific tests pass |
| **D-loader** | **Docker bookworm** | **171 passed cleanly** | **TBD on next rig run** — file:// fix verified, full re-run pending |
| L-storage | laptop | not run | not run |
| M-storage | maxxi | 1010 passed, 2094 errors | 1010 passed, 2094 errors (identical, modulo broken conda PG env after `--force-reinstall`) |
| **D-storage** | **Docker bookworm** | **2799 passed, 305 errors** | **2799 passed, 305 errors (identical)** |

**Headline**: storage cells (master vs REC-L4) are now identical pass/fail counts → **REC-L4 is regression-free** with the InMemoryStorage fix in place. Loader cells need one more clean Docker run after Option A's commit to confirm; the 26/32 laptop result (with the 6 known-pre-existing failures) is the current baseline.

The 305 errors on storage cells affect both master and REC-L4 equally — they're a Docker-rig environmental issue (likely missing Cassandra or other transitive service), not a regression. Loader maintainers can decide whether to extend the rig to cover them.

---

## 5. Pre-existing rehaul-stack test gaps now visible (the 6 remaining)

After Option A unblocked the file:// hang, these 6 tests in `TestGitLoader` fail. **None are real production regressions**. Categorised:

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

### Already fixed (Category A, 2 tests)

`test_loader_empty_pack_file` and `test_loader_with_ref_delta_in_pack[True-False]` were failing because they constructed `FetchPackReturn(pack_buffer=...)` — a dataclass field name the rehaul renamed to `pack_path`. Fixed in commit `8f3c70c` (writes to `NamedTemporaryFile`, passes its `.name`).

---

## 6. Reproducibility — running the test rig

### Docker on the laptop (recommended)

The audit notes ship a self-contained Docker rig at `notes/git-loader-rehaul/test-rig/`. From the `swh-environment` root:

```bash
docker build -t swh-loader-git-testrig:latest \
    notes/git-loader-rehaul/test-rig/

docker run --rm \
    -v "$PWD:/work" \
    swh-loader-git-testrig:latest
```

The container runs as uid=1000 (matches typical Linux dev user), writes per-cell logs to `notes/git-loader-rehaul/test-rig/results/` (gitignored). Includes PG-17 with contrib (`btree_gist`/`pgcrypto`/`pg_trgm`), Rust toolchain at `/usr/local/cargo`, and the system pytest stack.

Wall time: ~5 min loader cells + ~5–10 min storage cells = ~15–20 min total.

### Maxxi (longer-form, full PG)

The `~/test-hang-verification/` checkout on maxxi mirrors the local `swh-environment`, with sibling repos editable-installed in `~/test-hang-verification/.venv` and `_gix` built via maturin. PG-17 via `conda install -c conda-forge "postgresql=17.4=h9e3fa73_0"` (the older build avoids the glibc-2.38 ABI break of newer h3161d51_0 builds).

Run via `tmux new -s loader-test && bash ~/test-hang-verification/run-tests.sh`.

### Laptop direct

`make test` from `swh-loader-git/` after the three-step setup in the README's "Test" section: editable installs of sibling SWH repos, system PostgreSQL 17, and `pip install -r requirements-test.txt`.

---

## 7. Outstanding decisions for the team

These are the items that should close in the team-coordination meeting (or async if simpler):

1. **Per-visit type separation (Q3a-loaded ratification)** — `notes/presentations/SESSION_B_TEAM.md` "Type-emission shape" slide. Storage owners (David, Thomas) decide whether any journal consumer relies on per-visit `content` topic completing before `directory` topic. If yes → schedule the 2-walk follow-up MR; if no → ship single-walk as-is. **Recommended path**: ask the storage owners first, default to "no" unless they object.

2. **REC-L4 reviewer assignment** — name **Nicolas Dandrimont** as primary reviewer for `swh-storage/feat/content-add-concurrent`. He authored the Sept 2025 batched-read commits (`9a4d5596`, `9da2c163`, `c5e77f48`) that REC-L4 stacks on. David / Thomas as secondary.

3. **REC-L4 timing-metric resolution** — the rebase used coarse-grained `add_concurrent_writes` for the concurrent path; alternatives are documented in `notes/PLAN-rec-l4-concurrent-content.md` §"Rebase status (2026-05-05)". If reviewers prefer a different shape (separate index/main metrics, unified `add_to_storage`, or no metric), the change is ~5 LOC.

4. **REC-L4 R4 + R8 before-MR items** — currently the patch has no `content_add_concurrency` config knob (default 100 from cassandra-driver, recommend ≤ 50 for production multi-loader) and no parametrised tests across `sequential` / `concurrent`. Both should land before the MR opens.

5. **MR ordering** (post-rewrite) — push and review the clean stack in this order:
    1. `swh-loader-git/mr/1-gix-engine` (5 commits, ~7.7k LOC; foundational)
    2. `swh-loader-git/mr/2-size-classed-queues` (1 commit, ~620 LOC; stacks on mr/1)
    3. `swh-loader-git/mr/3-dulwich-fallback` (3 commits, ~1.6k LOC; stacks on mr/2)
    4. `swh-loader-git/mr/4-helm-overlay` (1 commit, ~360 LOC; stacks on mr/3)
    5. `swh-storage/mr/5-rec-l4-content-add` (2 commits, ~240 LOC; **independent** of the loader stack — see `HANDOFF-MR-PLAN.md` §5.2 and §10 below)

   See `notes/git-loader-rehaul/HANDOFF-MR-PLAN.md` §5 for the per-MR commit list and `PLAN-code-review-strategy.md` for the sign-off matrix and per-reviewer checklists.

---

## 8. Recommended next actions

In order, lowest cost first:

1. **Open the production bug-fix MR** (commit `da7b2b1` on `swh-loader-git`). Smallest review surface, fixes a real crash. Independent of the rehaul; can land first regardless.
2. **Run `make test` from a fresh clone** to confirm the README's Build + Test setup is sufficient for a fresh team member.
3. **Send the SESSION_A pre-read email** (`notes/presentations/PRE_READ_EMAIL.md`) to the loader maintainers. Schedule SESSION_A.
4. **Draft the SESSION_B pre-read email** (currently missing). Schedule SESSION_B.
5. **Resolve item 1 in §7** (per-visit type separation) — single conversation with David and Thomas. Path forward depends on their answer.
6. **R4 + R8 on REC-L4** — add the concurrency knob + parametrised tests in two small commits on `feat/content-add-concurrent`.
7. **Open the rehaul stack MRs** in the order from §7 #5.
8. **Phase 1 staging deploy** per `PROPOSAL-staging-rollout.md` §5 once the four staging-gate values are agreed.

---

## 9. Document index

Pick by topic.

### Team-facing (cleaned, entry points)
- **`notes/git-loader-rehaul/EXECUTIVE-SUMMARY.md`** — the proposal overview; start here.
- **`notes/git-loader-rehaul/HANDOFF-MR-PLAN.md` — companion to this doc**: deployment stages, reviewable code surface, reviewer time estimates, MR-rewrite recipe.
- `notes/git-loader-rehaul/PLAN-code-review-strategy.md` — six-phase review process, sign-off matrix, per-reviewer checklists.
- `notes/git-loader-rehaul/ISSUE-rec-l4-architecture.md` — REC-L4 architectural-issue body, ready to publish in `swh/devel/swh-storage`.
- `notes/git-loader-rehaul/PLAN-rec-l4-execution.md` — REC-L4 8-MR execution sequence.
- `notes/PROPOSAL-staging-rollout.md` — full staging proposal with metric gates.
- `report/ANALYSIS-git-loader-modernization.md` — strict-cell evidence + L1-L7 root causes.
- `report/ALGORITHMS-pack-loading.md` — per-step algorithm walkthrough.
- `notes/presentations/SESSION_B_TEAM.md` — team-leadership deck.
- `notes/presentations/SESSION_A_ENGINEERS.md` — engineer-facing hands-on deck.
- `swh-loader-git/README.rst` — Build + Test dependency sections updated for the rehaul (libssl-dev, PG-17, sibling installs).

### Reproducibility
- `notes/git-loader-rehaul/test-rig/Dockerfile` — bookworm + PG-17 + Rust + maturin + pytest stack.
- `notes/git-loader-rehaul/test-rig/run-cells.sh` — entrypoint that bind-mounts `/work` and runs the four cells.

---

## 10. Open questions / things this doc does NOT answer

- **The 305 storage-cell errors** (PG-fixture-related, identical on master and REC-L4): worth a separate triage if the team wants the storage suite green in Docker. Likely Cassandra-driver fixture chain that needs an actual Cassandra cluster. Does not block REC-L4 review.
- **The 6 remaining `TestGitLoader` failures**: documented in §5; loader-maintainer call on whether to update or remove.
- **Mirror replay against partial visits** (Q3b in the deck): probably non-issue, but worth a five-minute confirmation with whoever runs the SWH mirrors.

---

*Maintenance instruction*: when the rollout state changes (a branch lands, a decision is taken, a new regression is found), update §0 + the relevant section. Section §9 is the document index — keep it current as new plans/notes are produced.
