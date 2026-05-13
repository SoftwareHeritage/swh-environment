# [architecture] Concurrent `content_add`: Kafka as durable intent log, Cassandra as derived index, journal-driven reconciler as repair path

> **Architectural issue draft for gitlab.softwareheritage.org/swh/devel/swh-storage.** Body is ready to copy/paste into a new GitLab issue.
>
> *Provenance: this work was tracked as "REC-L4" in the SWH ingestion-pipeline audit; the descriptive name "concurrent `content_add`" is used here going forward. The pre-rewrite forensic tag `rec-l4-v0-history` on swh-storage retains the audit-era label.*

---

## TL;DR

`CassandraStorage._content_add` issues 5 sequential CQL round-trips per content (4 indexes + main row). Switching to `cassandra.concurrent.execute_concurrent` over the full batch — using prepared-statement scaffolding already in place ([cql.py L489-L504](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/cassandra/cql.py#L489-504)) — collapses this to ~constant time per batch. Throughput target: **5–10× on the content-add hot path** (numbers locked in by MR3 bench harness).

The optimization relaxes the "all index rows written before main row" invariant. Analysis revealed this is **not safely caught by the scrubber** (Content is TODO-skipped at [storage_checker.py L192-L194](https://gitlab.softwareheritage.org/swh/devel/swh-scrubber/-/blob/master/swh/scrubber/storage_checker.py#L192-194)) and **not caught by the retry proxy** (read paths return empty/None on miss, no exception → [retry.py L88-L122](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/proxies/retry.py#L88-122) doesn't fire) → user-visible swh-web 404s during the race window.

The safe architecture treats **the Kafka journal as the durable intent log**, Cassandra as a query-optimized derivative, and **a continuous journal-driven reconciler at consumer-lag (~seconds)** as the repair path — replacing the false scrubber claim.

This issue commits to: **8 MRs (one optional)**, each independently revertable, with explicit metric gates between staging and production.

---

## 1. Problem (efficiency)

`_content_add` is the loader's content-write hot path. Today it is sequential:

```python
# swh-storage/swh/storage/cassandra/storage.py — current sequential path
for content in contents_to_add:
    (token, insertion_finalizer) = self._cql_runner.content_add_prepare(...)
    for algo in HASH_ALGORITHMS:                # 4 hash algos
        self._cql_runner.content_index_add_one(algo, content, token)
    insertion_finalizer()                       # main row write
```

Per content: **5 CQL round-trips** (4 index INSERTs + 1 main INSERT). Per N-content batch: **5N round-trips**. On a healthy 3-node Cassandra cluster the per-RTT overhead is ~1ms; a 1000-content batch pays ~5s of wall-time, dominated by network + driver overhead, not Cassandra work.

This is the rate-limiting step in the loader → storage pipeline for git origins with many small blobs (typical for our long-tail of repositories).

## 2. Optimization (`execute_concurrent`)

Fire all 5N statements concurrently via `cassandra.concurrent.execute_concurrent`. This was already partially built: Nicolas Dandrimont's Sept 2025 batched-read work introduced [`execute_many_statements_with_retries`](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/cassandra/cql.py#L498-507) and the prepared-statement scaffolding concurrent content_add stacks on. The new code adds two factory helpers (`content_add_statement` and `content_index_add_one_statement`) that return bound statements without executing them, plus the dispatch in `_content_add` that builds the full batch and drains the generator.

**Code shape (unchanged from current concurrent content_add branch):**

```python
if self._content_add_algo == "concurrent":
    statements: List[Tuple[Any, Any]] = []
    for content in contents_to_add:
        (token, main_stmt) = self._cql_runner.content_add_statement(...)
        for algo in HASH_ALGORITHMS:
            statements.append(
                self._cql_runner.content_index_add_one_statement(algo, content, token)
            )
        statements.append((main_stmt, None))
    for _ in self._cql_runner.execute_many_statements_with_retries(statements):
        pass
else:
    # sequential path — unchanged from today
    ...
```

**Throughput target.** MR3 benchmark harness commits to publishing p50/p95 numbers across batch sizes 100/500/1000 on a reference cluster. Indicative target from prior-art: **5–10× wall-time reduction** at batch ≥ 500.

**Default**: `content_add_algo: "sequential"` — byte-identical to today. Concurrent is opt-in via storage config; rollback is a config flip, not a deploy.

## 3. Safety architecture (three load-bearing claims, each backed by code)

### 3.1 Blob durability is unaffected

Objstorage write happens **before** any Cassandra write — [storage.py L447-L455](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/cassandra/storage.py#L447-455):

```python
summary = self.objstorage.content_add(c for c in contents_to_add if c.status != "absent")
content_bytes_added = summary["content:add:bytes"]
# ...
self.journal_writer.content_add(contents_to_add)
```

A crash mid-`_content_add` cannot lose data: the blob bytes are already in objstorage (which is content-addressed and idempotent). What can be lost is *Cassandra's awareness* of the content — the index/main rows.

### 3.2 Kafka is the durable intent log

`journal_writer.content_add(contents_to_add)` runs at [storage.py L456](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/cassandra/storage.py#L456), **before** any CQL statement is issued. Once the journal write returns, the intent ("we promise these contents will be in Cassandra") is durable in Kafka and replayable.

Cassandra is therefore a **query-optimized derivative of the journal**, fully replayable from `swh.journal.objects.content`. This is the architectural claim that justifies relaxing the in-Cassandra index-vs-main ordering: the canonical record lives elsewhere.

### 3.3 Repair is event-driven, not periodic

A new sub-package `swh.storage.reconciler` (MR4 below) consumes `swh.journal.objects.content` continuously, deserializes each event, queries Cassandra for the expected 5-row state, and **re-emits idempotent inserts on miss**. Window from inconsistency to repair = Kafka consumer lag, typically **seconds**.

This replaces the existing docstring claim that "the scrubber repairs incomplete index coverage" — which is **false** for content. [storage_checker.py L188-L196](https://gitlab.softwareheritage.org/swh/devel/swh-scrubber/-/blob/master/swh/scrubber/storage_checker.py#L188-196):

```python
def check_object_hashes(self, objects: Iterable[ScrubbableObject]):
    """Recomputes hashes, and reports mismatches."""
    count = 0
    for object_ in objects:
        if isinstance(object_, Content):
            # TODO
            continue
        ...
```

Plus the scrubber is on-demand (CLI: `swh scrubber check run <config-name>`), not scheduled. The reconciler is the primary repair mechanism; the scrubber is not in the safety story.

The reconciler reuses the production-tested replayer scaffolding: `JournalClient` (swh-journal), `ModelObjectDeserializer` ([swh-storage replay.py L88](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/replay.py#L88)), and the [swh-objstorage-replayer pattern](https://gitlab.softwareheritage.org/swh/devel/swh-objstorage-replayer/-/blob/master/swh/objstorage/replayer/replay.py) (~560 LOC reference). New code: ~350 LOC.

## 4. Read-side caveat

Audit revealed CassandraStorage read paths are **not retry-tolerant** to false-misses:

| Method | Index table | Miss-mode | Retry-tolerant? |
|---|---|---|---|
| `content_find` | any of 4 | returns `[]` | **NO** — no exception, retry proxy doesn't fire |
| `content_get` | by algo | returns None | **NO** |
| `content_missing` / `content_missing_per_sha1{_git}` | by algo | yields as missing | **NO** |

`RetryingProxyStorage` ([retry.py L88-L122](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/proxies/retry.py#L88-122)) only retries on raised exceptions. A method that returns `[]` succeeds from the proxy's perspective, so the empty result propagates straight through swh-web's `lookup_content` → `NotFoundExc` → HTTP 404 to the user.

**Mitigation**: the reconciler closes the window in seconds, so the failure mode is "transient 404 within ~5s of a write" rather than "404 until next scrubber pass" (which today is days-to-weeks). Optional MR8 adds defense-in-depth via a retry-on-miss read proxy if metrics show this matters.

## 5. MR sequence

Each MR is independently revertable.

| # | Branch | Repo | LOC | Reviewers | Lands alone — what changes? |
|---|---|---|---|---|---|
| **MR1** | `cassandra: split __init__ into _configure() + _connect()` | swh-storage | ~50 | David Douard, Valentin Lorentz | nothing (pure refactor; fixes InMemoryStorage subclass bug) |
| **MR2** | `cassandra: add concurrent content_add path (default sequential)` | swh-storage | ~250 | Nicolas Dandrimont (P), David / Valentin (S) | nothing (default sequential) |
| **MR3** | `bench: content_add throughput harness` | swh-storage | ~150 | Antoine Lambert, Valentin | nothing (test-only) |
| **MR4** | `swh.storage.reconciler: journal-driven content reconciler` | swh-storage | ~350 | Nicolas Dandrimont, David Douard | new daemon, nobody runs it yet |
| **MR5** | `puppet: deploy reconciler in observe-only mode (staging)` | swh-sysadmin | ~50 | Antoine Lambert, Nicolas | reconciler observes staging journal, no writes |
| **MR6** | `puppet: enable repair in staging, then concurrent algo in staging` | swh-sysadmin | ~30 | Ops + David / Valentin | staging-only |
| **MR7** | `puppet: production rollout, one Cassandra-fronting storage at a time` | swh-sysadmin | ~30 | Ops + senior engineer sign-off | one prod canary, then fleet |
| MR8 (opt) | `storage: MissTolerantProxyStorage` | swh-storage | ~80 | Thomas | nothing unless wired |

Detailed per-MR scope, file lists, and test plans are in the companion plan at `notes/git-loader-rehaul/PLAN-concurrent-content-add.md` on the `share/ingestion-rehaul` branch of swh-environment.

## 6. Decision matrix (deployment gates)

| Phase | Code merged | Reconciler running | Algo enabled | Gate to advance |
|---|---|---|---|---|
| dev | MR1 + MR2 | no | sequential | tests green; MR3 numbers acceptable |
| reconciler-build | + MR4 | no | sequential | reconciler unit + integration tests pass |
| staging-observe | + MR5 | observe-only on staging | sequential | `lag_seconds` p95 < 60s sustained 24h |
| staging-repair | — | repair-enabled on staging | sequential | `repairs_total` ~0 sustained 6h |
| staging-canary | — | repair on staging | concurrent (staging) | 72h soak; no swh-web 404 anomalies |
| prod-canary | + MR6 / MR7 | repair on prod | concurrent (one prod instance) | 72h soak; same criteria |
| prod-fleet | — | repair on prod | concurrent (all) | — |

Throughput-target gate (between dev and reconciler-build): **MR3 bench shows ≥ 3× sequential at batch 1000**, no >2× p99 latency outlier vs sequential.

## 7. Open decisions to ratify

1. **Reconciler location** — recommend (b) sub-package `swh.storage.reconciler` (vs (a) new repo `swh-storage-reconciler` or (c) inside swh-scrubber as a continuous mode). Rationale: reuses `ModelObjectDeserializer` without inter-repo imports; ships in MR4 without ~1 week of new-repo packaging overhead. **Storage owners decide.**
2. **Concurrency knob default** — recommend `content_add_concurrency: 50` (vs cassandra-driver's default 100). Conservative for first prod deploy; tunable per environment. **Ops + storage owners decide.**
3. **Reconciler initial mode** — recommend `observe-only` on first staging deploy, flip to `repair-enabled` only after `lag_seconds p95 < 60s` sustained 24h. **Ops decides on the cadence.**
4. **MR3 bench harness location** — recommend `swh-storage/swh/storage/tests/bench/content_add.py` (in-tree, easy to maintain) vs its own repo. **Storage owners decide.**

## 8. References

**Companion documents (on the `share/ingestion-rehaul` branch of swh-environment):**
- Detailed per-MR execution plan: `notes/git-loader-rehaul/PLAN-concurrent-content-add.md`
- Gix engine rehaul handoff (companion proposal): `notes/git-loader-rehaul/HANDOFF.md` + `HANDOFF-MR-PLAN.md`
- Executive summary across both proposals: `notes/git-loader-rehaul/EXECUTIVE-SUMMARY.md`

**Code citations (load-bearing):**
- `journal_writer.content_add` ordering: [storage.py L456](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/cassandra/storage.py#L456)
- `execute_many_statements_with_retries` (concurrent content_add stacks on this): [cql.py L489-L507](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/cassandra/cql.py#L489-507)
- Scrubber Content gap: [storage_checker.py L188-L196](https://gitlab.softwareheritage.org/swh/devel/swh-scrubber/-/blob/master/swh/scrubber/storage_checker.py#L188-196)
- Retry proxy (only retries on exceptions): [retry.py L88-L122](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/blob/master/swh/storage/proxies/retry.py#L88-122)
- Reconciler scaffolding precedent: [swh-objstorage-replayer/replay.py](https://gitlab.softwareheritage.org/swh/devel/swh-objstorage-replayer/-/blob/master/swh/objstorage/replayer/replay.py)

**Prior art:**
- Nicolas Dandrimont's batched-read commits (Sept 2025): `9a4d5596`, `9da2c163`, `c5e77f48` — the prepared-statement scaffolding concurrent content_add stacks on.
- Original concurrent content_add branch (pre-rewrite): preserved at tag `rec-l4-v0-history` on swh-storage.

---

*Line numbers in code citations are anchored to upstream `master` HEAD as of 2026-05-08; re-verify after `git fetch` before publishing. Throughput target (5–10×) is a literature/intuition estimate; MR3 bench will produce the measured number, to be edited in once available.*
