# Plan: REC-L4 — Concurrent Cassandra content writes

> **Status as of 2026-04-20.** Implementation committed on branch
> `feat/content-add-concurrent` of swh-storage (HEAD `e7db95bb`).
> Not end-to-end tested on a Cassandra instance; that validation is
> the next step before the change can be proposed upstream. This
> plan remains the canonical design reference.

## The problem (from ANALYSIS-dulwich-to-gitoxide §5.2)

`swh-storage/swh/storage/cassandra/storage.py:435-448` writes each content via
**5 sequential synchronous CQL round-trips**:

```python
for content in contents_to_add:                            # per-content loop
    (token, finalizer) = self._cql_runner.content_add_prepare(
        ContentRow(**remove_keys(content.to_dict(), ("data",)))
    )
    for algo in HASH_ALGORITHMS:                           # 4 sequential RTTs
        self._cql_runner.content_index_add_one(algo, content, token)
    finalizer()                                            # 1 RTT
```

Every call bottoms out in `execute_with_retries` (`cql.py:456`) which calls
`session.execute()` synchronously.

At ~1 ms/round-trip, a single flush of 10,000 contents = **50 s** of pure
serialised CQL wait. For the Linux kernel (3.85 M blobs) this projects to
**~6.4 hours** of Cassandra wait time alone — dwarfing the entire inflate+
convert pipeline that we just optimised to ~15-20 min.

**This is now the dominant end-to-end bottleneck for production loads of
large repos.**

## What already exists (we don't need to invent anything)

`cql.py:498-507` already provides:

```python
def execute_many_statements_with_retries(
    self, statements_and_parameters: Sequence[Tuple[Any, Tuple]]
) -> Iterable[Dict[str, Any]]:
    ...
    execute_concurrent(
        self._session, statements_and_parameters, results_generator=True
    )
    ...
```

This drives Cassandra's **concurrent execution** — hundreds of in-flight
requests, not serialised. It is the exact primitive we need.

It's already used in production for object references
(`cql.py:1855 object_reference_add_concurrent`) and directory entries
(`cql.py:881 directory_entry_add_concurrent`). Content is the unfortunate
exception.

## Design

### Ordering semantics change

The current sequential loop guarantees that **all 4 index rows for a content
land before the main row**. This was intentional (`storage.py:327` comment):

> "The proper way to do it would probably be a BATCH, but this would be
> inefficient because of the number of partitions we need to affect"

The reason for the ordering: a concurrent reader doing hash lookup via an
index should not find the main row absent. With the sequential loop, there's
a brief window where index rows exist without the main row, but never the
other way around (so an existence-check via hash can't false-miss; it can
only false-hit, which the hash-verification step catches).

With `execute_concurrent`, order of individual completions is unordered.
Concretely, the new failure modes are:

1. **False "not found" during the sub-second write window.** A reader doing
   a hash lookup between "main row inserted" and "index row inserted" would
   see the index row as not yet present. Self-healing: reader retries later.
2. **Partial-write on crash.** A SIGKILL mid-batch can leave some contents
   with incomplete index coverage. Recoverable: all inserts are plain
   `INSERT` (no LWT, idempotent), so a re-run of the same loader task fills
   the gaps. The sequential code already has the same partial-state risk
   between its 5 steps.
3. **Collision detection unchanged.** The existence check at
   `storage.py:347-383` runs before any write; `_content_add` is already
   documented as non-atomic with respect to insertion.

**What is NOT at risk:** blob data. `self.objstorage.content_add()` at
`storage.py:403` runs before any Cassandra write. Even if all Cassandra
writes fail, the content bytes are in objstorage.

**Mitigation plan:** after a large bulk ingest, run `swh-scrubber` to detect
and repair any partial-index states. The scrubber is designed for exactly
this — it's already the mitigation pattern we use for concurrent writes
elsewhere.

### Code changes

Three files in `swh-storage`:

1. **`swh/storage/cassandra/cql.py`** — add two statement-returning variants
   of the existing execute-and-return methods:

   ```python
   @_prepared_insert_statement(ContentRow)
   def content_add_statement(
       self, content_row: ContentRow, *, statement
   ) -> Tuple[int, Tuple[Any, Tuple]]:
       """Like content_add_prepare, but returns (token, (stmt, params))
       for use with execute_many_statements_with_retries — does not
       execute by itself."""
       bound = statement.bind(dataclasses.astuple(content_row))
       token_class = self._cluster.metadata.token_map.token_class
       token = token_class.from_key(bound.routing_key).value
       assert TOKEN_BEGIN <= token <= TOKEN_END
       return (token, (bound, None))  # already-bound, no extra params

   def content_index_add_one_statement(
       self, algo: str, content: Content, token: int
   ) -> Tuple[Any, Tuple]:
       """Like content_index_add_one, but returns (stmt, params) without
       executing.  Companion to content_add_statement above."""
       table = content_index_table_name(algo, skipped_content=False)
       query = f"INSERT INTO {self.keyspace}.{table} ({algo}, target_token) VALUES (%s, %s)"
       return (query, (content.get_hash(algo), token))
   ```

   Keep the existing `content_add_prepare` and `content_index_add_one` for
   backwards compatibility (they are used by other callers, tests, etc.).

2. **`swh/storage/cassandra/storage.py`** — replace the per-content loop in
   `_content_add` (lines 435-448):

   ```python
   # OLD — sequential, 5N round-trips:
   content_added = 0
   for content in contents_to_add:
       content_added += 1
       (token, finalizer) = self._cql_runner.content_add_prepare(
           ContentRow(**remove_keys(content.to_dict(), ("data",)))
       )
       for algo in HASH_ALGORITHMS:
           self._cql_runner.content_index_add_one(algo, content, token)
       finalizer()

   # NEW — concurrent, 1 pipelined batch:
   content_added = len(contents_to_add)
   statements: List[Tuple[Any, Tuple]] = []
   for content in contents_to_add:
       content_row = ContentRow(**remove_keys(content.to_dict(), ("data",)))
       (token, main_stmt) = self._cql_runner.content_add_statement(content_row)
       for algo in HASH_ALGORITHMS:
           statements.append(
               self._cql_runner.content_index_add_one_statement(algo, content, token)
           )
       statements.append(main_stmt)

   # Consume the generator to drive all the writes
   for _ in self._cql_runner.execute_many_statements_with_retries(statements):
       pass
   ```

3. **Tests** — add a test in
   `swh-storage/swh/storage/tests/test_cassandra.py` (or the appropriate
   shared suite) that verifies:
   - A batch content_add with 100+ contents succeeds.
   - All 4 index rows exist for every content.
   - Ordering within a batch does not affect correctness.
   - `content_find` by any hash returns the inserted content.

   The existing test suite should already cover correctness; this new test
   exists to confirm the concurrent variant's behaviour matches.

### Benchmark plan

Before/after, using the existing integration test infrastructure:

1. Spin up an in-memory or test Cassandra instance.
2. Run `content_add` with 10,000 contents (enough to amortise any fixed
   cost).
3. Measure wall-clock time. Expected ratio: **10-50× faster** once the
   concurrent driver saturates available in-flight requests (typical
   driver default is 200 concurrent).

Production validation: a canary deploy on one worker, load a known large
repo (e.g., kubernetes or libreoffice), compare Cassandra-phase timing
against baseline from pre-deploy.

### Risk mitigation — rollout

1. **Land behind a config flag initially.** Add
   `CassandraStorage._content_add_concurrent` as opt-in via a storage
   config key (e.g., `content_add_algorithm: "concurrent"` vs `"sequential"`).
   Default to sequential for one release cycle.
2. **Canary for one week.** Enable on one worker; monitor error rates,
   scrubber findings, Cassandra driver metrics (in-flight requests, driver
   exceptions).
3. **Promote to default** once canary is clean. Remove the flag in a
   subsequent release.

This mirrors the rollout pattern for `directory_entries_insert_algo`
already present in the code (`storage.py:743-754`).

## Expected impact

| Metric | Sequential (current) | Concurrent (REC-L4) | Ratio |
|---|---|---|---|
| Per-content round-trips | 5 sequential | 5 pipelined | — |
| 10,000-content flush wall time @ 1 ms RTT | ~50 s | ~0.25-2 s | 25-200× |
| Linux kernel content phase (3.85 M blobs) | ~6.4 hours | ~5-20 min | 20-100× |

Even a conservative 10× improvement would turn the production bottleneck
from "hours per large repo" to "minutes per large repo" and close the
throughput gap against the already-optimised inflate+convert pipeline.

## Implementation sequence

1. Fork a feature branch from `master` in swh-storage: `feat/content-add-concurrent`.
2. Add the two statement-returning CQL helpers in `cql.py`.
3. Add `_content_add_concurrent` alongside `_content_add` in `storage.py`;
   pick between them via config.
4. Add the new test.
5. Run the full test suite (`tox -e py3-cassandra`); verify all green.
6. Bench on a test Cassandra instance — record the ratio.
7. PR to swh-storage with the config-flag rollout.
8. Canary + monitor + promote.

## Dependencies and non-blockers

- **No swh-loader-git changes needed.** The content_add interface is
  unchanged at the loader boundary.
- **No swh-model changes.** Content and ContentRow are unchanged.
- **No journal changes.** `journal_writer.content_add` is called before the
  CQL work and is unaffected.
- This is a **pure swh-storage internal refactor** once the config flag is
  designed.

## Out of scope (future work)

- Apply the same pattern to skipped_content_add, directory_add (main rows,
  entries already use concurrent), revision_add, release_add — but these
  are smaller contributors than content_add at current scales.
- True single-CQL-batch semantics via `BATCH` statements — explicitly
  rejected in the existing code comment (`storage.py:327-331`) because of
  multi-partition overhead.
- Changing the fire-and-forget model to "journal first, CQL async". Bigger
  change; defer.

## Rebase status (2026-05-05)

Branch `feat/content-add-concurrent` (commit `e7db95bb`, dated 2026-04-14)
was originally cut against the swh-storage master at that time. Since
then, Nicolas Dandrimont landed three commits in Sept 2025 that
restructured the *read* path of `_content_add`:

- `9a4d5596` (2025-09-03) — Batch hash collision checks in cassandra storage.
- `9da2c163` (2025-09-03) — Add statsd counter for detected colliding contents.
- `c5e77f48` (2025-09-04) — Merge the "content exists" and "content hash
  collision" checks in content_add.

Plus, master has since gained timing instrumentation around the
per-content write loop:

```python
start_time = time.monotonic()
content_added = 0
for content in contents_to_add:
    content_added += 1
    # ... per-content writes ...
    end_time = time.monotonic()
    timings["add_to_index_table"] += end_time - start_time
    start_time = end_time
    insertion_finalizer()
    end_time = time.monotonic()
    timings["add_to_main_table"] += end_time - start_time
```

A `git rebase origin/master feat/content-add-concurrent` (attempted
2026-05-05, then aborted) produces conflicts in
`swh/storage/cassandra/storage.py` at two regions, both inside the
per-content insert loop:

1. **Around lines 488–529 (HEAD vs ours)**: master initialises the
   timing `start_time` and starts the per-content `for` loop; our
   patch replaced the loop with the
   `if content_add_algo == "concurrent"` branch.
2. **Around lines 540–566 (HEAD vs ours)**: master's per-content
   `content_index_add_one` + `insertion_finalizer()` block is followed
   by the timing collection (`timings["add_to_index_table"] += ...`
   and `timings["add_to_main_table"] += ...`); our patch removed the
   per-content loop for the concurrent path.

**Resolution landed (2026-05-05, commit `2ca1a132` on `feat/content-add-concurrent`)**: coarse-grained single timer for the concurrent branch. The if/else now opens with `start_time = time.monotonic()` *before* the algorithm dispatch; the `else` (sequential) arm keeps master's fine-grained per-content `timings["add_to_index_table"]` / `timings["add_to_main_table"]` accumulation; the `if "concurrent"` arm emits a single `timings["add_concurrent_writes"] = end_time - start_time` after `execute_many_statements_with_retries` drains. The shared `for suboperation, value in timings.items(): statsd.increment(...)` loop emits whichever keys were set (`add_to_index_table` + `add_to_main_table` on a sequential run; `add_concurrent_writes` on a concurrent run), so dashboards can disambiguate which path was active without breaking existing sequential metrics.

**Other options the reviewer might prefer.** The coarse-grained timer is a *defensible default*, not a forced choice. If reviewer feedback prefers a different shape, the alternatives are:

1. **Two metrics from one execute_concurrent call.** Hold the start_time twice — once at the boundary of statements that are index inserts, once at the boundary of the main-row appends. This still uses one `execute_concurrent` invocation but gives separate `concurrent_index_writes` / `concurrent_main_writes` numbers. Caveat: the timings overlap in wall time because the calls are concurrent, so the sum will exceed the wall time of the call — operations need to know that.

2. **Two execute_concurrent calls (split by statement type).** Fire all the index_add_one statements first, drain, then fire the main-row statements, drain. Cleaner timing breakdown but **defeats the batching win for the cross-type interleaving** that gives `execute_concurrent` its parallelism, and tightens the index-vs-main ordering window into a deterministic order. **Do not pick this one without explicit rationale**; it's strictly worse for throughput.

3. **Unified metric across both paths (`add_to_storage` += writes_wall).** Drop the `add_to_index_table` / `add_to_main_table` split entirely and replace with one `add_to_storage` key for both paths. Cleaner reporting at the cost of breaking existing sequential dashboards that consume the split keys. Probably needs storage-team coordination if any Grafana panel reads those keys today.

4. **No timing on the concurrent path.** Skip the `add_concurrent_writes` metric entirely; rely on the outer `add_to_storage_total` (already emitted higher up in `_content_add`) to capture wall time. Smallest diff but loses observability into the new code path.

The chosen #0 (coarse-grained, current commit) is the smallest deviation from master's existing convention. **If David, Thomas, or Nicolas ask for option 1 or 3 during MR review, those are reasonable swaps.** Option 2 should not land. Option 4 should only land if the reviewer explicitly says they don't want a new metric.

**Backup branch preserved**: `backup-pre-rebase-20260505-184555` on
swh-storage retains the pre-rebase state in case the rebase needs to
be redone with a different resolution strategy (e.g., reviewer prefers
option 1 or 3 above).

### Subclass-default fix (2026-05-05, amended into the same commit)

Maxxi test run surfaced a real regression in the rebased branch:
**`InMemoryStorage` (which extends `CassandraStorage`) does not forward
the new `content_add_algo` parameter** through its overridden
`__init__`, so the `if self._content_add_algo == "concurrent":` dispatch
in `_content_add` raised `AttributeError` on every test that exercises
the in-memory storage class through the inherited code path.
Visible-by-failing-test count: **158 storage-side test failures** in
`test_filter.py`, `test_tenacious.py`, and other proxy-storage tests
that wrap `InMemoryStorage`.

**Fix**: a class-level default `_content_add_algo: str = "sequential"`
on `CassandraStorage`. Subclasses that skip the new parameter now
inherit the safe default; instance `__init__` overrides it when the
parameter is provided. Amended into commit `4e51c838` (was
`2ca1a132` pre-fix). Verified by re-running the previously-failing
`test_filtering_proxy_storage_empty_list` — passes.

**Lesson for the MR.** When a patch adds a parameter to a base class's
`__init__`, audit subclasses for whether they forward the parameter
through `super().__init__(...)`. The defensive class-level default is
the cheaper insurance than chasing every subclass.

**Implication for the MR**: do this rebase resolution in the MR-prep
stage, not now. Loop in Nicolas Dandrimont as primary reviewer (he is
the recent active contributor to `_content_add` and his Sept 2025
work is the immediate context); David / Thomas as secondary.

**Open before-MR items** (also tracked on `SESSION_B_TEAM.md`'s REC-L4
slide):
- **R4** — add a `content_add_concurrency` config knob. Currently the
  patch uses `execute_concurrent`'s default 100 with no override.
  Default 100, recommend ≤ 50 for production multi-loader.
- **R8** — parametrise existing `_content_add` test scenarios across
  both `sequential` and `concurrent` algos. The concurrent branch is
  config-gated but currently untested.
