# Concurrent `content_add` — Issue + MR sequence (safe landing)

> *Provenance: this work was tracked as "REC-L4" in the SWH ingestion-pipeline audit; the descriptive name "concurrent `content_add`" is used here going forward. The pre-rewrite forensic tag `rec-l4-v0-history` on swh-storage and the existing branch `mr/5-rec-l4-content-add` retain the audit-era label as historical anchors.*

## Context

Concurrent `content_add` changes `CassandraStorage._content_add` from 5 sequential CQL round-trips per content (4 indexes + main) to one concurrent batch via `execute_concurrent`. Throughput target: ~5–10× on the content-add hot path.

Three safety findings frame the deployment:

1. **The class-level `_content_add_algo` default papers over a real bug** — `InMemoryStorage.__init__` doesn't call `super().__init__()`. The proper fix is splitting `CassandraStorage.__init__` into a config-only phase and an I/O phase.
2. **The "scrubber repairs incomplete index coverage" claim is false.** `swh-scrubber/swh/scrubber/storage_checker.py:192-194` literally `if isinstance(object_, Content): # TODO continue`. The scrubber doesn't check content integrity, and is on-demand (CLI), not scheduled.
3. **False-misses propagate to swh-web as 404.** `content_find` / `content_get` / `content_missing_per_sha1{_git}` return empty/None on a missing index row, no exception → `RetryingProxyStorage` doesn't fire (it only retries on raised exceptions). A user sees "not archived" as a transient wrong answer until the index row catches up.

This makes the optimization unsafe to enable in production without:
- A proper fix for the InMemoryStorage init bug (refactor, not class-default).
- Honest documentation of the consistency window.
- A **journal-driven content reconciler** that consumes `swh.journal.objects.content` continuously, verifies the 5-row Cassandra state per event, and re-emits idempotent inserts on miss. Reuses existing `JournalClient` (swh-journal) + `ModelObjectDeserializer` (swh-storage/swh/storage/replay.py) + the swh-objstorage-replayer pattern (~350 LOC of new code).
- A staged rollout where `concurrent` is only enabled in production after the reconciler has been validated in staging.

This plan structures the work as one architectural issue + 8 MRs, ordered so each step is independently revertable.

---

## 1. Open the architectural issue first

**Where**: gitlab.softwareheritage.org/swh/devel/swh-storage. Title:

> `[architecture] Concurrent content_add: Kafka as durable intent log, Cassandra as derived index, journal-driven reconciler as repair path`

Body content is in `notes/git-loader-rehaul/ISSUE-concurrent-content-add.md` — ready to copy/paste verbatim.

The issue is **the lever for team buy-in**. It must be readable in 10 minutes by Valentin, David, Thomas, Nicolas, Antoine; commit to specific numbers and decisions; reference code, not comments.

---

## 2. MR sequence (in order)

Each MR is independently revertable.

### MR1 — `cassandra: split __init__ into _configure() + _connect()`
- **Repo**: swh-storage. Files: `swh/storage/cassandra/storage.py` (~50 LOC refactor).
- **What**: Move all `self._x = …` assignments and validation into a new `_configure(...)` method; push `_set_cql_runner()`, `JournalWriter`, `ObjStorage` wiring into `_connect()`. `__init__` calls both. `InMemoryStorage` (and any subclass that overrides `__init__`) calls `_configure()` via `super()`.
- **Removes**: the class-level `_content_add_algo: str = "sequential"` default introduced by `b4d49a40` — superseded by the refactor.
- **Reviewers**: David Douard (cassandra surface) + Valentin Lorentz (`git blame` shows he authored most of `__init__`).
- **Lands alone**: no behavior change, pure refactor. Fixes the InMemoryStorage subclass bug properly.

### MR2 — `cassandra: add concurrent content_add path (opt-in, default sequential)`
- **Repo**: swh-storage. Stacks on MR1.
- **Source**: rebase commit `9bf92395` from `mr/5-rec-l4-content-add` onto MR1, with two surgical edits:
  - Remove the class-level default line (now in `_configure()` from MR1).
  - Rewrite the `content_add_algo` docstring at `storage.py:222-230` to drop the false scrubber-repair claim; reference the architectural issue + MR4 reconciler instead.
- **Includes**: `cql.py` helpers (+36 LOC), `storage.py` dispatch (+155 LOC), `metrics.py` cleanup, `tests/test_cassandra.py` parametrised across both algos (+66 LOC), the `content_add_concurrency` knob (R4 punch-list item, ~10 LOC, default 50).
- **Default**: `content_add_algo: "sequential"` — byte-identical to today.
- **Reviewers**: Nicolas Dandrimont (primary, concurrent content_add prior-art), David Douard / Valentin Lorentz (secondary).
- **Lands alone**: zero production effect (default sequential).

### MR3 — `bench: content_add throughput harness`
- **Repo**: swh-storage. Files: new `swh/storage/tests/bench/content_add.py` or similar.
- **What**: Standalone benchmark parametrized on algo + batch size (100 / 500 / 1000), emitting p50/p95 latency and round-trip count per batch. Produces the numbers the architectural issue commits to.
- **Reviewers**: Antoine Lambert (loaders downstream), Valentin (test infra).
- **Lands alone**: no production effect; produces the data that gates MR6.

### MR4 — `swh.storage.reconciler: journal-driven content reconciler`
- **Repo**: swh-storage. New sub-package `swh/storage/reconciler/` (~350 LOC).
- **What**: `JournalClient` consumer for `swh.journal.objects.content` → `ModelObjectDeserializer` (reuse from `swh.storage.replay`) → per-content verifier that queries Cassandra for the 5-row state → idempotent re-emit on miss → statsd metrics: `swh_storage_reconciler_lag_seconds`, `swh_storage_reconciler_repairs_total{reason}`, `swh_storage_reconciler_throughput`. Modeled on swh-objstorage-replayer (560 LOC reference).
- **CLI entry point**: `swh storage reconciler run <config>`, systemd-aware.
- **Modes**: `observe-only` (metrics, no writes) and `repair-enabled` (writes idempotent inserts on miss).
- **Tests**: integration test that injects a missing index row, runs the reconciler, asserts repair fires.
- **Reviewers**: Nicolas Dandrimont (journal infrastructure) + David Douard (cassandra repair semantics).
- **Lands alone**: a new daemon nobody runs yet. Zero effect on running systems.

### MR5 — `puppet/sysadmin: deploy reconciler in observe-only mode (staging)`
- **Repo**: swh-sysadmin / puppet (ops).
- **What**: Helm values overlay deploying the MR4 daemon against staging Cassandra + staging Kafka consumer group, with `repair_enabled: false` (metrics-only). Prometheus alerts: `reconciler_lag_seconds > 60s` (warning), reconciler-down (critical).
- **Operator gate to advance**: `lag_seconds` p95 < 60s sustained for 24h on staging.
- **Reviewers**: Ops (Antoine Lambert) + Nicolas (config sanity check).
- **Lands alone**: pure observation; no writes.

### MR6 — `puppet: enable repair in staging, then enable concurrent algo in staging`
- **Repo**: swh-sysadmin / puppet. Two staged config flips:
  1. **Reconciler `repair_enabled: true`** in staging. Watch `repairs_total` — should be ~0 under sequential algo. If it isn't, the reconciler has a bug; abort and fix.
  2. **`content_add_algo: concurrent`** on one staging storage instance. Watch `repairs_total` — expect a small steady rate matching the concurrent ordering window. Also watch staging swh-web 404 rate via existing probes.
- **Operator gate to advance to MR7**: 72h soak with stable `repairs_total` rate, no swh-web 404 spikes attributable to content lookups.
- **Reviewers**: Ops + sign-off from David / Valentin on the metric thresholds.

### MR7 — `puppet: production rollout, one Cassandra-fronting storage at a time`
- **Repo**: swh-sysadmin / puppet.
- **What**: Production canary on one storage instance (`content_add_algo: concurrent`), 72h soak, then fleet rollout.
- **Reviewers**: Ops + senior engineer sign-off.
- **Pre-requisite**: reconciler running with `repair_enabled: true` in production, `lag_seconds` p95 < 60s sustained 24h.

### MR8 (optional, deferrable) — `storage: MissTolerantProxyStorage`
- **Repo**: swh-storage. New proxy at `swh/storage/proxies/miss_tolerant.py` (~80 LOC).
- **What**: Wraps `content_find` / `content_missing_per_sha1{_git}` / `content_get` to retry once after a short delay on empty result. Defense-in-depth.
- **Default**: off. Wire into web pipeline only if metrics show a problem.
- **Reviewers**: Thomas Pellissier-Tanon (read-path semantics).

---

## 3. Reconciler location — recommendation

| Option | Pros | Cons |
|---|---|---|
| **(a)** New repo `swh-storage-reconciler` | Mirrors `swh-objstorage-replayer` precedent; independent release cadence | New repo overhead (copier, CI, packaging) — adds ~1 week to MR4 |
| **(b)** Sub-package `swh.storage.reconciler` | Co-located with the storage it reconciles; reuses `ModelObjectDeserializer` without inter-repo import | Couples deploy lifecycle with storage releases |
| **(c)** Inside swh-scrubber as a continuous mode | Semantically tempting (scrubber = consistency tool) | scrubber is CLI/on-demand; storage_checker.py:192 is TODO for Content; category change |

**Recommendation: (b) `swh.storage.reconciler`.** Reuses `swh.storage.replay.ModelObjectDeserializer` trivially, ships in MR4 without packaging overhead. If it later grows beyond Content it can be promoted to its own repo — `swh-objstorage-replayer` made exactly this trip.

Flag this as an "open decision to ratify" in the architectural issue.

---

## 4. What to do with the existing `mr/5-rec-l4-content-add` branch

Two commits: `b4d49a40` (class-default hack) and `9bf92395` (concurrent path with false scrubber-repair docstring). Diff is +239/-35 across 4 files.

**Disposition: rebase, do not abandon.**

1. **Drop `b4d49a40` entirely.** Its reason for existing is solved properly by MR1's `_configure()` split.
2. **Rebase `9bf92395` onto MR1** as MR2's body, with two edits:
   - Remove the class-level default line (now in `_configure()`).
   - Rewrite the `content_add_algo: concurrent` docstring — drop the scrubber-repair sentence, replace with a reference to the architectural issue + MR4 reconciler.
3. **Add the R4 concurrency knob** (~10 LOC) and the R8 parametrised tests.
4. Close the existing branch only after MR2 merges; until then keep it as the rebase source.
5. The pre-rewrite tag `rec-l4-v0-history` already preserves the original state for forensic comparison.

Net: zero rewritten code, two deletions (class default, false comment), one rewritten docstring paragraph, ~10 new LOC for the knob.

---

## 5. Critical files

For implementation reference:

- `swh-storage/swh/storage/cassandra/storage.py` — concurrent content_add surface; refactor target for MR1; dispatch for MR2.
- `swh-storage/swh/storage/cassandra/cql.py` — prepared-statement helpers (`content_add_statement`, `content_index_add_one_statement`; existing `execute_many_statements_with_retries` at L489-L504).
- `swh-storage/swh/storage/replay.py` — `ModelObjectDeserializer` at L88; reused by MR4 reconciler.
- `swh-storage/swh/storage/proxies/retry.py` — retry behaviour (L95-L120); load-bearing for the read-path safety analysis.
- `swh-scrubber/swh/scrubber/storage_checker.py` — L192-L194 (Content TODO); cited in the issue to refute the scrubber-repair claim.
- `swh-objstorage-replayer/swh/objstorage/replayer/replay.py` — pattern reference for MR4 reconciler.
- `swh-journal/swh/journal/client.py` — `JournalClient` consumer base class.

For local repo state:
- `mr/5-rec-l4-content-add` HEAD `9bf92395` — source for MR2 rebase.
- Tag `rec-l4-v0-history` — pre-rewrite snapshot, preserved for forensics.

---

## 6. Verification

**Per-MR verification (before merge):**

- MR1: existing test suite green (`pytest swh/storage/tests/`); diff is pure refactor; InMemoryStorage instantiation tests pass.
- MR2: parametrised tests pass for both `sequential` and `concurrent`; MR3 bench shows expected throughput delta.
- MR3: bench harness produces stable numbers across 3 runs on a reference cluster.
- MR4: integration test (inject missing index row → reconciler repairs it → verify all 5 rows present); unit tests for the deserializer + Cassandra-state checker.
- MR5: staging dashboard shows reconciler `lag_seconds` p95 < 60s for 24h before MR6 step 1.
- MR6 step 1: staging `repairs_total` ~0 sustained for 6h before step 2.
- MR6 step 2: staging soaks 72h with stable `repairs_total` rate, no swh-web 404 anomalies.
- MR7: production canary 72h with same criteria as MR6 step 2.

**End-to-end verification (after MR7):**

- p95 `_content_add` latency on production canary instance shows the throughput target from MR3 numbers.
- Reconciler `repairs_total` rate is bounded and decreasing over time.
- swh-web content-lookup 404 rate is unchanged from pre-rollout baseline.
- Loader end-to-end ingest rate on representative origins shows expected speedup.

**Rollback procedure (any stage):**

- Code MRs (1, 2, 3, 4, 8): revert by re-deploying prior swh-storage version. No state migration needed (default sequential).
- Config MRs (5, 6, 7): flip config back. `content_add_algo: sequential` reverts behavior at runtime.
- Reconciler causing problems: stop the daemon. Cassandra remains in whatever state it's in; sequential algo doesn't produce inconsistencies, so stopping the reconciler under sequential is safe.

---

## 7. Open questions to ratify

1. **Reconciler location** — recommend (b) `swh.storage.reconciler` sub-package. Confirm with David / Thomas before MR4 starts.
2. **Concurrency knob default** — recommend 50 (vs cassandra-driver default 100). Confirm with David / ops.
3. **Issue venue** — open in gitlab.softwareheritage.org/swh/devel/swh-storage as primary, cross-link from swh-environment if helpful.
4. **MR3 bench harness location** — under `swh-storage/swh/storage/tests/bench/` or its own repo? Recommend the former (in-tree, easy to maintain).
