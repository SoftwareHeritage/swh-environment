---
title: "Supercharging Cassandra content_add — Concurrent write path + journal-driven reconciler"
description: "Why, design, MR stack, rollout gates — sibling deck to INGESTION_REHAUL.md (loader engine)"
tags: presentation, storage, cassandra, content_add, hedgedoc
type: slide
slideOptions:
  transition: fade
  theme: white
  center: true
  slideNumber: true
  progress: true
style: |
  .reveal { font-size: 24px; }
  .reveal h1 { font-size: 1.8em; }
  .reveal h2 { font-size: 1.4em; }
  .reveal h3 { font-size: 1.15em; }
  .reveal table { font-size: 0.7em; }
  .reveal pre { font-size: 0.75em; }
  .reveal code { font-size: 0.85em; }
  .reveal li { font-size: 0.95em; line-height: 1.4; }
  .reveal blockquote { font-size: 0.85em; }
---

<!--
  HedgeDoc: open the note → View → Slide mode (Reveal.js).
  Slides: `---` on its own line = horizontal; `----` = vertical stack.
  Speaker notes: paragraph starting with `Note:` (speaker view, press S).
  Local preview from disk: `make -f notes/presentations/Makefile preview-watch`.
-->

<style>
.reveal .slides section { font-size: 0.68em; line-height: 1.2; }
.reveal .slides section h1 { font-size: 1.55em; }
.reveal .slides section h2 { font-size: 1.28em; }
.reveal .slides section h3 { font-size: 1.10em; }
.reveal .slides section table { font-size: 0.80em; }
.reveal .slides section pre { font-size: 0.70em; }
</style>

# Supercharging Cassandra `content_add` — Concurrent write path + journal-driven reconciler

The storage-side companion to the loader rehaul: the write-path bottleneck that slows ingestion regardless of which engine fetches the pack.

**Audience:** SWH tech leadership + storage track reviewers (Nicolas Dandrimont, David Douard, Valentin Lorentz, Antoine Lambert) · **~30–45 min**

Note: This deck is the storage-side sibling to `INGESTION_REHAUL.md`. The loader deck argues the engine swap (dulwich → gitoxide). This deck argues the storage write-path fix (concurrent `content_add` + journal-driven reconciler). The two are independent — the storage fix wins on dulwich today, compounds with gix tomorrow. Paced as: problem → safety story → MR stack → rollout gates. Open with the lag, frame the W20 reprioritisation, then walk the 4-MR sequence and the staging gates.

---

## The lag — same fact, new suspect

The ingestion pipeline stopped keeping up: 2025 ingestion is below 2014 levels. The loader deck argues the **engine** is one wall on the pipeline.

This deck is about the **other** wall: every blob the loader fetches has to be written into Cassandra, and **today that write path is sequential**.

- Loader-side rehaul covered in `notes/presentations/INGESTION_REHAUL.md` — gitoxide engine, parallelism per worker, the 4-MR Lane 1 stack on `swh-loader-git`.
- Storage-side rehaul, here — concurrent `_content_add`, journal-driven repair, the 4-MR stack on `swh-storage` (plus 3 puppet MRs + 1 optional defense-in-depth).

The two tracks run in parallel. Neither blocks the other.

Note: This deck stands alone; a reader who hasn't seen the loader deck can follow it end to end. The framing point: even with the existing dulwich loader on the existing production stack, the `content_add` write path is the dominant Cassandra-side bottleneck on large repos. Fixing it pays back **now**, on the current engine, and compounds with the engine swap when both land.

---

## Why this matters even with dulwich — the W20 decision

The Cassandra `content_add` write-path cost is paid per content **regardless of which loader engine fetches the pack**. Dulwich and gix are both bottlenecked by it.

At the W20 management coordination meeting (2026-05-13), this work was reprioritised:

- **Previously**: "Phase 3, later, after Lane 1 (loader engine) is at 100 %".
- **Now**: **first-sprint top priority**. The May audit window and the June launch window for the loader side run in parallel with the storage-side MR cadence.

Reason for the swap: the storage-side fix is independent of the loader-engine decision and wins on dulwich today. Holding it behind the engine swap was leaving wall-clock on the table for ~6 months.

The MR1–MR3 storage-side work is **zero-effect in production by default** (init refactor + opt-in concurrent path + bench harness), so it can land during the May loader-audit window without competing for review attention on the engine track.

Note: This slide is the framing shift from the W20 meeting. The previous decking order treated this as a follow-on optimisation; the new order treats it as the top-priority piece because it benefits the production pipeline today, before any engine decision. Cross-reference: `INGESTION_REHAUL.md` lines 762–795 ("concurrent content_add is the top priority — first sprint scope") records the same reprioritisation from the loader-side deck.

---

## What sequential does today

For each `Content` in a batch, `CassandraStorage._content_add` issues **5 sequential CQL round-trips**: one INSERT per `HASH_ALGORITHM` (sha1, sha1_git, sha256, blake2s256 — four index tables) + one INSERT for the main `content` row.

For a batch of N contents: **5N round-trips**, serialised, one connection.

On a healthy 3-node Cassandra cluster, per-RTT overhead is ~1 ms (network + driver dispatch, not Cassandra work). The cost is **dominated by the trip count**, not by what Cassandra does on each trip.

| Batch size | Round-trips | Pure-CQL wall (≈1 ms RTT) |
|---|---:|---:|
| 100 | 500 | 0.5 s |
| 1 000 | 5 000 | 5 s |
| 10 000 | 50 000 | 50 s |
| Kernel-sized (~3.85 M blobs) | ~19 M | **~5.4 h** |

That last row is the kernel-sized ingest wall on the current path, post-Nicolas Sept-2025 read-batching. The 5.4 h is **pure serial CQL wait time**, not throughput; the actual loader walls behind it.

Note: The kernel-size number is the one to anchor the audience on. ~5.4 h of pure CQL wait per kernel-sized origin is the bottleneck the optimisation kills. The 6.4 h figure that appeared in earlier drafts was pre-Nicolas; the read batches already shipped (the architectural issue and the loader deck both credit those commits explicitly).

----

### The loop, in code

```python
# swh-storage/swh/storage/cassandra/storage.py — lines 472–493 (sequential write loop)
content_added = 0
for content in contents_to_add:
    content_added += 1

    (token, insertion_finalizer) = self._cql_runner.content_add_prepare(
        ContentRow(**remove_keys(content.to_dict(), ("data",)))
    )

    # Then add to index tables

    for algo in HASH_ALGORITHMS:
        self._cql_runner.content_index_add_one(algo, content, token)
    end_time = time.monotonic()
    timings["add_to_index_table"] += end_time - start_time
    start_time = end_time

    # Then to the main table
    insertion_finalizer()
```

Per content: 4 `content_index_add_one()` calls (each is a synchronous CQL INSERT) + 1 `insertion_finalizer()` (the main-row INSERT). Per N-content batch: 5N synchronous round-trips, all on the same session.

Note: The comment above the loop ("Then add to index tables") and the matching "Then to the main table" comment are load-bearing: they encode the implicit "indexes-before-main" ordering invariant. Fixing the throughput means relaxing that invariant — which is what the next half of the deck is about.

---

## What's already concurrent in the codebase

`execute_many_statements_with_retries` wraps `cassandra.concurrent.execute_concurrent` and is already used in production for two other write paths.

```python
# swh-storage/swh/storage/cassandra/cql.py — lines 488–507
@cassandra_retry()
def _execute_many_statements_with_retries_inner(
    self,
    statements_and_parameters: Sequence[Tuple[Any, Tuple]],
) -> Iterable[Dict[str, Any]]:
    for res in execute_concurrent(
        self._session, statements_and_parameters, results_generator=True
    ):
        yield from res.result_or_exc

def execute_many_statements_with_retries(
    self,
    statements_and_parameters: Sequence[Tuple[Any, Tuple]],
) -> Iterable[Dict[str, Any]]:
    try:
        return self._execute_many_statements_with_retries_inner(
            statements_and_parameters
        )
    except (ReadTimeout, WriteTimeout) as e:
        raise QueryTimeout(*e.args) from None
```

In-tree consumers today:

- `directory_entry_add_concurrent` — `swh/storage/cassandra/cql.py:881` — directory-entry fan-out.
- `object_reference_add_concurrent` — `swh/storage/cassandra/cql.py:1855` — graph-reference fan-out.

**Concurrent `content_add` extends an existing, production-tested pattern.** No new primitive; no new failure modes the cluster doesn't already see on the directory and reference paths.

Note: Important framing point for reviewers: this is not a new architectural choice. We are wiring up the same concurrency primitive that already moves directory entries and object references on production. The risk surface is "same primitive, new caller", not "new primitive".

---

## Prior work to credit — Nicolas's Sept 2025 batched reads

The `_content_add` **read** side was already batched by Nicolas Dandrimont in September 2025:

| Commit | What |
|---|---|
| `9a4d5596` | Batch hash-collision checks (4 reads per batch instead of 4 reads per content). |
| `9da2c163` | Add a statsd counter for the collision-detection path. |
| `c5e77f48` | Merge the "exists" and "collision" checks into a single pass. |

These commits also introduced the `execute_many_statements_with_retries` helper that the concurrent-write work stacks on. **The architectural lift was already done.**

The concurrent `content_add` work attacks the **write** side that remains: 4 index INSERTs + 1 main INSERT per content, still serialised in `for content in contents_to_add`.

Note: Credit matters for reviewer goodwill. Nicolas is the natural lead reviewer for MR2 — he's the prior-art owner on this exact code path. Same goes for the MR4 reconciler: he is the journal-client and content-add-architecture expert on the team. (Actual reviewer assignment is the task force / David's call.)

---

## The throughput hypothesis

Target: **5–10× wall-time reduction on the content-add hot path** at batch size ≥ 500. Currently a literature/intuition estimate.

| Batch size | Sequential wall (≈1 ms RTT) | Concurrent (projected) | Ratio |
|---|---:|---:|---:|
| 100 | 0.5 s | 0.05–0.10 s | 5–10× |
| 1 000 | 5 s | 0.5–1.0 s | 5–10× |
| 10 000 | 50 s | 5–10 s | 5–10× |
| Kernel-sized phase | ~5.4 h | ~30 min–1 h | 5–10× |

**The numbers above are projections.** Final figures are locked in by MR3 — the bench harness sweeps batch sizes 100 / 500 / 1000 against a reference cluster and emits p50/p95 latency + round-trip counts per batch.

Acceptance gate to advance past the bench phase: **≥ 3× sequential at batch 1000, no p99 latency outlier worse than 2× sequential.**

Note: Be explicit that these are projections, not measurements. The bench harness is MR3 precisely so the architectural issue can replace the estimate with a measured number before staging. The acceptance gate (≥ 3× at batch 1000) is deliberately conservative — if the bench shows less than 3×, something's structurally wrong with the concurrent path or with the cluster and we don't deploy.

---

## BUT — the relaxed ordering invariant

The sequential path encodes an implicit invariant: **for each content, all 4 index rows are written before the main row.**

Concurrent dispatch reorders this. `execute_concurrent` fires the full 5N-statement batch across a connection pool and returns results in completion order. A reader doing a hash-lookup via an index table can briefly see one of two states:

1. **Index row exists, main row not yet** — a `content_find` returns the token, then `content_get_from_pk` returns nothing.
2. **Main row exists, index row not yet** — a `content_find` on that algorithm returns empty even though the content is being written right now.

Both states resolve within the in-flight statement window (sub-second). The question is: is the read path tolerant of those windows?

**Spoiler: no, it isn't. The next three slides walk the safety analysis.**

Note: This is the pivot from "throughput optimisation" to "safety architecture". The room needs to understand that the optimisation is **conceptually small** (one branch in `_content_add`) but the safety story is **load-bearing** — three findings each of which would have killed an earlier framing of this work.

---

## Safety analysis 1 — the scrubber claim is FALSE

The first version of the concurrent `content_add` branch carried a docstring asserting that "the scrubber repairs incomplete index coverage on crash". **That claim is false.**

```python
# swh-scrubber/swh/scrubber/storage_checker.py — lines 188–204
def check_object_hashes(self, objects: Iterable[ScrubbableObject]):
    """Recomputes hashes, and reports mismatches."""
    count = 0
    for object_ in objects:
        if isinstance(object_, Content):
            # TODO
            continue
        real_id = object_.compute_hash()
        count += 1
        if object_.id != real_id:
            self.statsd.increment("hash_mismatch_total")
            self.db.corrupt_object_add(
                object_.swhid(),
                self.config,
                value_to_kafka(object_.to_dict()),
            )
```

The scrubber **does not check content hashes**. The branch is literally a `# TODO` followed by `continue`.

Worse: the scrubber is **on-demand** (CLI: `swh scrubber check run <config-name>`), not scheduled. Even if the Content branch were implemented, the latency between a partial-state write and the next scrubber pass would be days to weeks.

**The scrubber is not in the safety story.** A different repair mechanism is required.

Note: This is the slide that changes how the team thinks about the optimisation. Previously the unspoken assumption was "the scrubber catches partial states". Once we open `storage_checker.py:192` together, that assumption is gone — and we need a real answer for repair. The reconciler (slide 13) is that answer.

---

## Safety analysis 2 — read paths return EMPTY on miss

The audit also found that Cassandra-side read paths are not tolerant of false-misses:

| Method | Index table used | Behaviour on missing index row |
|---|---|---|
| `content_find` | any of 4 | returns `[]` |
| `content_get` | by algo | returns `None` |
| `content_missing` | by algo | yields the missing-set as missing |
| `content_missing_per_sha1{,_git}` | sha1 / sha1_git | yields as missing |

`RetryingProxyStorage` retries on **exceptions**, not on empty returns:

```python
# swh-storage/swh/storage/proxies/retry.py — lines 23–54
def should_retry(retry_state: RetryCallState) -> bool:
    """Retry if the error/exception is (probably) not about a caller error"""
    attempt = retry_state.outcome
    assert attempt
    if attempt.failed:
        error = attempt.exception()
        if isinstance(error, NonRetryableException):
            return False
        elif isinstance(error, (KeyboardInterrupt, SystemExit)):
            return False
        else:
            # Other exception
            ...
            return True
    else:
        # No exception
        return False
```

An empty list `[]` is a successful return. The retry proxy doesn't fire. The empty result propagates straight through to the caller.

Note: This is the second load-bearing finding. The team will recognise the retry proxy as the standard SWH "transient errors are retried automatically" mechanism — but they may not have realised it only handles **exceptions**, not "successful empty answers". Make the point explicitly: a method that returns `[]` looks successful from the proxy's perspective.

---

## Safety analysis 3 — user-visible 404

The empty return from `content_find` / `content_get` / `content_missing_*` propagates upward:

```
CassandraStorage.content_find(hashes)
  → [] (index row not yet visible)
  → swh.storage RPC call returns []
  → swh-web lookup_content() sees empty result
  → raises NotFoundExc
  → HTTP 404 to the user
```

During the race window (sub-second under load), a `swh-web` user looking up a content that was just written sees **"not archived"** — a transient wrong answer.

This is the bug the safety architecture exists to prevent. The defensive properties that **would** have hidden it are both inoperative:

- The scrubber doesn't check Content (safety analysis 1).
- The retry proxy doesn't fire on empty returns (safety analysis 2).

So we need a positive repair path. **That path is the journal-driven reconciler.**

Note: Frame this as: "the bug we are not willing to ship." The optimisation's throughput case is open-and-shut; the reason this is a 4-MR storage stack plus 3 puppet MRs plus a 24h staging soak (instead of "one commit, ship it") is precisely to make sure the user-visible 404 window is closed before production traffic ever touches the concurrent path.

---

## The architectural pattern — journal as durable intent log

The optimisation only works if Cassandra is no longer treated as the canonical record of "what exists".

| Layer | Role | Durability |
|---|---|---|
| **Objstorage** (Winery / Ceph) | Holds the blob bytes. Content-addressed, idempotent. | Survives any crash; written **first**. |
| **Kafka journal** (`swh.journal.objects.content`) | The **intent log**: "we promise these contents will be in Cassandra". | Survives any crash; written **before** any CQL statement. |
| **Cassandra** (5-row per content) | Query-optimised derived index. Replayable from the journal. | A query cache that can be repaired by re-reading the journal. |

Inside `_content_add`, the existing write order is **objstorage → journal → CQL**. So:

- A crash mid-CQL cannot lose data (objstorage has it, journal has it).
- The "all index rows before main row" invariant inside Cassandra is no longer the durability boundary — Kafka is.
- Repair becomes "consume the journal, verify Cassandra, re-emit on miss" — at consumer-lag, not at CLI invocation.

**This is the architectural claim that justifies relaxing the in-Cassandra ordering.**

Note: The room needs to hold this picture in mind for the next two slides. The reconciler is not a periodic scrubber catch-up; it's a continuous derivative-table reconciler at Kafka consumer-lag. Same pattern as `swh-objstorage-replayer`, applied to the content index. The MR4 sub-package is ~290 LOC of new code modelled on a 560-LOC reference implementation.

---

## The reconciler — one paragraph + a dataclass

`swh.storage.reconciler` consumes `swh.journal.objects.content` continuously via `JournalClient`, deserialises each event via `ModelObjectDeserializer` (reused from `swh.storage.replay`), queries Cassandra for all 5 expected rows, and **idempotently re-emits the missing ones**.

Per-event work:

1. Compute the partition token deterministically from the `Content` (via `content_add_prepare`).
2. For each of the 4 hash algorithms: `content_get_tokens_from_single_algo(algo, [hash])`; if `expected_token` is not in the result, the index row is missing.
3. `content_get_from_pk(hashes_dict)`; if None, the main row is missing.
4. If `repair_enabled` and anything is missing: re-INSERT (plain `content_index_add_one` + `content_add_prepare(...)[1]()`). Cassandra treats these as upserts — racing reconciler instances are safe.

Window from inconsistency to repair = **Kafka consumer lag, typically seconds**.

Note: This collapses what was originally a 350-LOC sketch into 290 LOC. Two contracts to call out: (a) the verifier is stateless, each call is independent; (b) the read uses the same `_cql_runner` the writer uses, so the consistency level matches — see the consistency contract slide. The 560-LOC `swh-objstorage-replayer` precedent is exactly the same shape: `JournalClient` + per-message verifier + idempotent replay.

----

### The `VerifyResult` dataclass

```python
# swh-storage/swh/storage/reconciler/verifier.py — lines 48–64
@dataclass
class VerifyResult:
    """Outcome of a single :meth:`ContentVerifier.verify_and_repair` call."""

    #: Hash algorithms whose index row was missing.
    missing_indexes: List[str] = field(default_factory=list)

    #: True if the main ``content`` row was missing.
    main_missing: bool = False

    #: True if any of the missing rows were re-inserted by the verifier.
    repaired: bool = False

    @property
    def all_present(self) -> bool:
        """True if all 5 rows were present and no repair was needed."""
        return not self.missing_indexes and not self.main_missing
```

The `verify_and_repair()` contract: take a `Content`, return a `VerifyResult` describing what was missing and whether repair fired. The statsd counter `swh_storage_reconciler_repairs_total{reason}` increments once per missing row.

```python
# swh-storage/swh/storage/reconciler/verifier.py — verify_and_repair (excerpt)
def verify_and_repair(self, content: Content) -> VerifyResult:
    ...
    cql = self.storage._cql_runner
    content_row = ContentRow(**remove_keys(content.to_dict(), ("data",)))
    (expected_token, main_finalizer) = cql.content_add_prepare(content_row)

    missing_indexes: List[str] = []
    for algo in HASH_ALGORITHMS:
        hash_value = content.get_hash(algo)
        tokens = list(cql.content_get_tokens_from_single_algo(algo, [hash_value]))
        if expected_token not in tokens:
            missing_indexes.append(algo)

    main_row = cql.content_get_from_pk(cast(dict, hashes_dict))
    main_missing = main_row is None
    ...
    if self.repair_enabled:
        # idempotent re-INSERT of missing rows
        ...
```

Note: The verifier is stateless on purpose: any number of reconciler workers can race on the same Content without interference, because every INSERT is an upsert in Cassandra. That removes a whole class of coordination questions ("which worker owns which partition?") — operators just scale horizontally.

---

## Modes — observe-only vs repair-enabled

The reconciler ships with two modes, controlled by a single CLI flag:

| Mode | What it does | Writes? | Repair counter |
|---|---|---|---|
| `--observe-only` *(default)* | Verifies every `Content` event, increments `swh_storage_reconciler_repairs_total{reason}` on miss. | **No.** | Increments. |
| `--repair-enabled` | Same verification, plus idempotent re-INSERT of missing rows. | Yes. | Increments. |

**The counter increments in both modes.** Operators can size the expected repair-rate by running observe-only first; only flip to `--repair-enabled` once the rate is understood.

Operational gate (from the architectural issue): flip from observe-only to repair-enabled **only after `lag_seconds p95 < 60 s` sustained 24 h on staging**.

Default = observe-only because the safe operational sequence is "watch first, write later". A reconciler that starts writing immediately on deploy could mask its own bugs.

Note: This is the operational story that makes the rollout staged. The deck's MR5–MR7 slides build on this: staging gets observe-only (MR5), then repair-enabled (MR6 step 1), then the concurrent algo gets flipped on for one staging storage (MR6 step 2), then production canary (MR7). At each gate, an operator can stop without rolling back code.

---

## Consistency contract — read at the same level the writer uses

The verifier reads through `storage._cql_runner`, which uses the storage instance's configured `_consistency_level`. **The reconciler reads at the same consistency level the writer wrote at.**

| If verifier reads at … | … the failure mode is … |
|---|---|
| Same level as writer | Correct: a miss is a real miss (or a window the reconciler is meant to close). |
| **Stricter** level (e.g. `QUORUM` when writer uses `ONE`) | **False misses** — the verifier reports rows missing that are actually present-but-not-yet-quorum-visible. Spurious repair churn. |
| **Weaker** level | **Real misses missed** — the verifier sees stale state and reports rows present that are actually missing on enough replicas. Silent inconsistency. |

This is why MR4 inherits `_consistency_level` from the storage instance instead of exposing its own knob — getting it wrong in either direction is silently wrong, and there's no "safer default" for cross-deployment consistency.

If a reviewer wants explicit per-deployment override (e.g. always `LOCAL_QUORUM` regardless of writer), it's a follow-up commit, not a blocker for MR4.

Note: This is a subtle but load-bearing point. The reconciler is not "more cautious" by reading at higher consistency — it's actively wrong. The MR4 description spells this out as an open decision; the recommendation is "inherit, don't override".

---

## MR stack — overview

```
swh-storage repo:

  master
    │
    ├── mr/1-cassandra-init-split        !1223   ~50 LOC   refactor
    │       │
    │       ├── mr/2-concurrent-content-add  !1224  ~155 LOC  opt-in concurrent path
    │       │       │
    │       │       └── mr/3-content-add-bench   !1225  ~290 LOC  bench harness
    │       │
    │       └── (no further stack)
    │
    └── mr/4-content-reconciler          !1226   ~290 LOC + ~210 tests
            └── independent of the stack; targets master directly

swh-sysadmin (puppet) — next sprint, not in this deck's scope:
    MR5  reconciler observe-only on staging
    MR6  flip reconciler to repair-enabled, then concurrent algo on staging
    MR7  production canary, one storage instance, then fleet

Optional defense-in-depth:
    MR8  MissTolerantProxyStorage  ~80 LOC  wire only if needed
```

Each MR is **independently revertable**. MR1–MR3 are zero-effect in production (refactor + opt-in branch + test-only). MR4 is a new daemon nobody runs yet. MR5–MR7 are config flips that can each be reverted at runtime.

Note: The intent of this slide is for the room to see the full sequence at once and feel the safety: there is no single MR that, if reverted, requires anything other than "deploy the previous build" or "flip the config back". This is the property that lets staging-canary actually be a canary, not a one-way door.

---

## MR1 — `cassandra: split __init__ into _configure() + _connect()`

**GitLab:** [!1223](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/merge_requests/1223) · **LOC:** ~50 · **Risk:** pure refactor.

Splits `CassandraStorage.__init__` into:

- `_configure(...)` — stores attributes and validates them. No I/O.
- `_connect(...)` — sets up `_cql_runner`, `JournalWriter`, `ObjStorage`. Does I/O.
- `__init__` — calls `_configure()` then `_connect()`.

**Why it's needed:** the first version of the concurrent `content_add` branch carried a class-level workaround `_content_add_algo: str = "sequential"` because `InMemoryStorage.__init__` doesn't call `super().__init__()`. The proper fix is to make the config phase callable on its own — which is what `_configure()` is. `InMemoryStorage.__init__` then calls `super()._configure()` and inherits any future config attribute for free.

**Verified by:**

- `pytest swh/storage/tests/test_in_memory.py` — 240 passed, 8 skipped.
- Broader non-Cassandra surface — 1994 passed (6 unrelated `test_replay.py` errors are missing-redis-fixture env, pre-existing on `origin/master`).

**Suggested reviewers (David dispatches):** Valentin Lorentz on the refactor itself (`git blame` shows he authored most of `__init__`); David Douard on the Cassandra surface. Estimated ~2 h.

Note: This MR is deliberately small and surgical. Reviewers can rubber-stamp it from the diff alone — there's no behavioural decision to make. Landing it first removes the class-level-default hack that was a smell on the original branch.

---

## MR2 — `cassandra: add concurrent content_add path (opt-in)`

**GitLab:** [!1224](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/merge_requests/1224) · **LOC:** ~155 across 2 commits · **Risk:** default sequential — zero effect unless opted in.

| Commit | What |
|---|---|
| `9b1d3d7c` | Add `CONTENT_ADD_ALGOS = ["sequential", "concurrent"]` validation; new `content_add_algo` param on `__init__`/`_configure()`; new `concurrent`-branch in `_content_add` that builds the full batch and drains the `execute_concurrent` generator. New factory helpers `content_add_statement` and `content_index_add_one_statement` in `cql.py`. |
| `961d4ecd` | Add `content_add_concurrency` knob (default 50) wired through `execute_many_statements_with_retries` → `execute_concurrent`. |

**Default is `sequential`** — byte-identical to today. Concurrent is opt-in via storage config: `content_add_algo: "concurrent"`. Rollback is a config flip, not a deploy.

**Until the reconciler is running with low lag, `concurrent` MUST NOT be enabled in production** (architectural issue ratifies this gate; MR4 ships the reconciler).

**Suggested reviewers (David dispatches):** Nicolas Dandrimont — prior-art owner on the Sept 2025 batched-read commits this stacks on; David Douard. Estimated ~4 h.

**Not in this MR:** R8 — parametrise existing `_content_add` tests across both algos. The concurrent branch is config-gated but currently uncovered at the unit level. Bench harness in MR3 provides throughput-level validation in the meantime; a follow-up commit can parametrise the tests.

Note: This is the central code MR. The "default sequential, opt-in concurrent" framing is what makes it safe to merge before MR3 / MR4 land — turning it on in production is a separate operational decision gated by MR5–MR7. If a reviewer pushes for parametrised tests as a blocker, point them to MR3 (which covers the same throughput properties end-to-end) and offer a follow-up commit on the same branch.

---

## MR3 — `bench: content_add throughput harness`

**GitLab:** [!1225](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/merge_requests/1225) · **LOC:** ~290 · **Risk:** test-only, no production impact.

New package `swh/storage/tests/bench/` containing:

- `bench_content_add.py` — ~200 LOC standalone CLI.
- `__init__.py` + `README.md`.

**Not collected by pytest** — the filename starts with `bench_` not `test_`, so `pytest --collect-only swh/storage/tests/bench/` returns 0 items.

Invocation:

```bash
python -m swh.storage.tests.bench.bench_content_add \
    --hosts 127.0.0.1 --keyspace swh_storage_bench \
    --batch-sizes 100,500,1000 --iterations 20
```

Generates synthetic deterministic `Content` objects, sweeps batch sizes, emits p50/p95 latency + round-trip counts per batch.

**Output:** the numbers the architectural issue currently quotes as a 5–10× estimate. Once run against a reference cluster, the measured number replaces the estimate.

**Suggested reviewers (David dispatches):** Antoine Lambert (consumes the numbers downstream in loader sizing); Valentin Lorentz on test-infra placement. Estimated ~2 h.

**Reviewer should also check:** reference-cluster description in `README.md` (hardware, schema version, network topology) so future runs are comparable. Whether `concurrency=50` is the right knob value to sweep first.

Note: This MR is the data-locking MR. Once it lands and runs, the architectural issue gets edited to replace "5–10×" with the measured number, and the operational gate ("≥ 3× at batch 1000") becomes a real go/no-go check rather than a paper threshold.

---

## MR4 — `swh.storage.reconciler`

**GitLab:** [!1226](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/merge_requests/1226) · **LOC:** ~290 + ~210 tests · **Risk:** new daemon, nobody runs it yet.

| Commit | What |
|---|---|
| `3e6bc604` | Package skeleton + `JournalClient` consumer (observe-only). Package layout, `ContentReconciler` worker callback signature, statsd plumbing, empty `_verify_one` hook. |
| `0e8aebf5` | `ContentVerifier.verify_and_repair(content)` returning `VerifyResult`; wires the verifier into `_verify_one`. |
| `35d8be48` | CLI entry point `swh storage reconciler run`; `[project.entry-points."swh.cli.subcommands"]` registration; 11 unit/behaviour tests. Fixes a partial-import cycle that surfaced once the CLI entry point was registered. |

**4 modules:** `__init__.py`, `journal_client.py`, `verifier.py`, `cli.py`.

**11 unit/behaviour tests** in `tests/test_reconciler.py` covering: `VerifyResult` semantics, all-present-no-repair, partial-index-miss-detected, partial-index-miss-repaired, main-row-miss-detected-and-repaired, repair-disabled-by-default, etc.

**Independent of the stack** — targets `master` directly. The reconciler is useful on the `sequential` path too (it would repair any index row missing from a rare CQL failure), so it does not depend on MR2 landing first.

The **operational link** to MR2: MR2's `concurrent` algo SHOULD NOT be enabled in production until the reconciler is running with low lag.

**Suggested reviewers (David dispatches):** Nicolas Dandrimont (journal-client + content-add architecture); David Douard (Cassandra repair semantics). Estimated ~5 h.

Note: This is the biggest MR by lines but conceptually simpler than MR2 — it's a single new sub-package with one well-defined contract (`verify_and_repair(content) → VerifyResult`). Three open decisions are flagged in the MR description: reconciler location, consistency level override, integration-test against real Cassandra. All three are recommendations-with-rationale, not blockers; defer to staging-canary phase for the integration test.

---

## MR5 – MR7 — puppet rollout (next sprint, out of scope here)

The storage repo work is done after MR4. The remaining sequence is **operational** and lives in `swh-sysadmin` / puppet.

| MR | What | Operator gate to advance |
|---|---|---|
| **MR5** | Deploy reconciler in **observe-only** on staging. Prometheus alerts wired: `reconciler_lag_seconds > 60s` (warning), reconciler-down (critical). | `lag_seconds p95 < 60s` sustained **24 h** on staging. |
| **MR6 step 1** | Flip reconciler to **repair-enabled** on staging. Watch `repairs_total` — should be ~0 under sequential algo. | `repairs_total` ~0 sustained **6 h**. |
| **MR6 step 2** | Enable **`content_add_algo: concurrent`** on **one** staging storage. Watch `repairs_total` (expect small steady rate) and staging swh-web 404 rate. | 72 h soak with stable `repairs_total`, no swh-web 404 anomalies. |
| **MR7** | Production canary: one storage instance on `concurrent`. | 72 h soak; same criteria as MR6 step 2. Then fleet. |

Each step is **independently revertable at runtime** — flip the config back, no deploy needed.

Detail in `notes/git-loader-rehaul/PLAN-concurrent-content-add.md` §2.

Note: This deck does not propose the puppet MRs as part of this sprint. The reason is the storage-side review burden (4 MRs) is already substantial for the first sprint; the ops side has its own cadence and its own dependencies (reconciler must already be running with low lag in production before concurrent is flipped on anywhere). The puppet sequence is the natural next-sprint scope.

---

## MR8 (optional) — `MissTolerantProxyStorage`

**Defense-in-depth on the read path**, deferrable.

A new proxy at `swh/storage/proxies/miss_tolerant.py` (~80 LOC) wraps:

- `content_find`
- `content_missing_per_sha1`
- `content_missing_per_sha1_git`
- `content_get`

…and **retries once after a short delay (~100 ms) on an empty result**. This closes the user-visible 404 window even if the reconciler is lagging.

Wire it in front of `CassandraStorage` only if production metrics from MR7 show that the user-visible 404 rate during the race window is non-negligible. **Default: not wired.**

**Suggested reviewer (David dispatches):** Thomas (read-path semantics).

**Why optional:** the reconciler closes the window in seconds; the user-visible 404 surface is bounded to "transient 404 within ~5 s of a write". If that's tolerable per swh-web SLA, MR8 is unnecessary complexity on the read path. If it's not, MR8 is a small targeted fix.

Note: This MR is on the table specifically so reviewers don't feel cornered: there is a defense-in-depth option if the reconciler-alone story turns out to be insufficient under production load. Most likely we ship without it. But it's good to have it scoped so the team can hand it to someone with read-path expertise if/when production data warrants it.

---

## Review sequence (suggested) — assignment is David's call

The architectural issue (`#4727`) is already open on GitLab. The 4 MRs are open as drafts. **Reviewer assignment is the task force / David's call**; the table below is a suggestion based on `git blame` + prior-art context.

| MR | Suggested reviewer | Co-reviewer | Est. hours | Why |
|---|---|---|---|---|
| **!1223** MR1 — init split | Valentin | David | ~2 h | Valentin authored most of `__init__` per blame; David owns the Cassandra surface. |
| **!1224** MR2 — concurrent path | Nicolas | David | ~4 h | Nicolas owns the prior-art (Sept 2025 batched-reads this stacks on). |
| **!1225** MR3 — bench | Antoine | Valentin | ~2 h | Antoine consumes the numbers downstream in loader sizing. |
| **!1226** MR4 — reconciler | Nicolas | David | ~5 h | Nicolas on journal + content-add architecture; David on repair semantics. |

**~13 h of senior-engineer review time total**, if assignment lands this way. Parallelisable across reviewers (MR2 + MR4 do share Nicolas, but they're different review windows).

The architectural issue is the **lever for team buy-in**: it must be readable in 10 minutes by anyone the task force points at it; commits to specific numbers; references code, not comments.

Note: The 13 h total is conservative. The MR2 and MR4 reviews are the substantive ones; MR1 and MR3 are more mechanical. The hours-per-MR estimates come from the MR descriptions on GitLab; actual reviewer dispatch is whatever the task force decides works.

---

## Test plan

| Layer | Coverage |
|---|---|
| **MR1** | Existing `pytest swh/storage/tests/test_in_memory.py` — 240 passed, 8 skipped. Pure-refactor: no new tests needed. |
| **MR2** | Existing `_content_add` test suite covers `sequential` (the default). `concurrent` branch is config-gated and currently uncovered at the unit level — R8 follow-up to parametrise. Bench harness in MR3 covers throughput validation. |
| **MR3** | Test-only itself. Validates by being **runnable** against a reference cluster: 3 runs on the same hardware should produce stable numbers within ~10 % across runs. |
| **MR4** | 11 unit/behaviour tests in `tests/test_reconciler.py`: `VerifyResult` semantics; all-present path; partial-index detection; partial-index repair; main-row miss detection + repair; `observe-only` skips writes; `repair-enabled` issues idempotent INSERTs. Backed by `InMemoryStorage` fixtures (no Cassandra cluster needed). |
| **Integration against real Cassandra** | **Deferred to staging-canary** (MR6 in puppet). Every other Cassandra test in the suite uses a heavy fixture (~30–60 s startup); adding one to MR4 would slow the storage CI substantially for marginal extra coverage. |

**End-to-end (after MR7):** p95 `_content_add` latency on the canary instance matches MR3 projections; reconciler `repairs_total` rate bounded and decreasing; swh-web content-lookup 404 rate unchanged from baseline.

Note: The deferred Cassandra integration test is a calculated trade-off — it would be the most expensive single test in the suite, and the staging-canary phase (MR6 step 2) covers exactly the same path with real cluster latency. We close that loop in puppet, not in `pytest`.

---

## Staging → production rollout gates

Operator-actionable thresholds, monotonic from left to right. Each gate is independently revertable.

| Phase | Code merged | Reconciler | Algo on staging | Gate to advance |
|---|---|---|---|---|
| **dev** | MR1 + MR2 + MR3 | — | sequential | tests green; MR3 bench ≥ 3× sequential at batch 1000; no p99 outlier > 2× sequential. |
| **reconciler-build** | + MR4 | — | sequential | reconciler unit tests pass; CLI entry point registered. |
| **staging-observe** | — | observe-only on staging | sequential | `lag_seconds p95 < 60 s` sustained **24 h**. |
| **staging-repair** | — | **repair-enabled** on staging | sequential | `repairs_total ~0` sustained **6 h** (non-zero = reconciler bug; abort, fix). |
| **staging-canary** | — | repair-enabled | **concurrent** (one staging storage) | **72 h soak**; stable `repairs_total`; no swh-web 404 anomalies. |
| **prod-canary** | + MR6 / MR7 (puppet) | repair-enabled on prod | **concurrent** (one prod instance) | **72 h soak**; same criteria. |
| **prod-fleet** | — | repair-enabled on prod | concurrent (all) | — |

**Rollback at any phase:** code MRs revert by deploying the prior version (default sequential; no state migration). Config MRs revert by flipping the config back at runtime.

Note: The 24 h / 6 h / 72 h windows are starting proposals. The W20 task force may want longer soaks; that's an operator decision. The shape of the table — observe before repair, repair before concurrent — is the load-bearing invariant. Reordering these flips re-introduces the user-visible 404 risk the safety architecture was designed to eliminate.

---

## Recap — the story in one slide

This deck walked through:

1. **The bottleneck**: `_content_add` issues 5N sequential CQL round-trips per content batch — the dominant cost on large repos, paid by dulwich and gix alike.
2. **The fix**: switch to `cassandra.concurrent.execute_concurrent`, opt-in via `content_add_algo: "concurrent"`. Targeted 5–10× on the hot path (MR3 measures).
3. **The safety problem**: concurrent writes relax the index-vs-main ordering. The scrubber doesn't catch Content (it's TODO at `storage_checker.py:192`); read paths return empty on miss without raising, so `RetryingProxyStorage` doesn't fire. Without something else, the race window surfaces as user-visible 404s.
4. **The safety pattern**: treat Kafka as the durable intent log, Cassandra as the derived index, and a journal-driven reconciler at consumer-lag as the repair path.
5. **What ships**: 4 storage-side MRs (init refactor → concurrent path → bench → reconciler), each independently revertable. 3 puppet MRs follow next sprint with numeric soak gates between stages. 1 optional read-side defense-in-depth proxy if production metrics ever warrant it.

Note: This slide is the takeaway. If a reader walks out remembering one thing, it should be the safety pattern in point 4 — that's the architectural shift the deck argues for. The throughput win is the *motivation*; the safety story is the *contribution*.

---

## Where the design choices are recorded

The deck's claims map to durable records the team can read after the meeting:

| Claim | Where it's recorded |
|---|---|
| Reconciler lives at `swh.storage.reconciler` (in-tree sub-package, not a new repo) | MR4 description on `!1226`; architectural issue `#4727` §6 |
| Concurrency knob defaults to 50 (vs cassandra-driver's 100) | MR2 description on `!1224`; storage.py docstring on the `content_add_concurrency` parameter |
| Verifier inherits the storage's consistency level | MR4 description on `!1226`; `verifier.py` module-level comment |
| `content_add_algo` defaults to `sequential` | storage.py docstring; MR2 description |
| W20 reprioritisation — first-sprint top priority | `INGESTION_REHAUL.md` slide on the W20 cadence; `HANDOFF.md` §0 |
| Sprint boundary: MR1–MR4 this sprint; MR5–MR7 next | `PLAN-concurrent-content-add.md` §2; the `swh-charts#5` tracking issue |

Note: This slide is the rebuttal-anticipation slot. If someone in the room asks "wait, who decided X?", point at the row. Every claim has a written record; nothing is being decided in this room.

---

## References

**On this branch (`share/ingestion-rehaul` of swh-environment):**

- Architectural issue body: [`notes/git-loader-rehaul/ISSUE-concurrent-content-add.md`](../git-loader-rehaul/ISSUE-concurrent-content-add.md) — ready to publish, mirrors `#4727`.
- Execution plan: [`notes/git-loader-rehaul/PLAN-concurrent-content-add.md`](../git-loader-rehaul/PLAN-concurrent-content-add.md) — 8-MR sequence, rollback procedures, verification matrix.
- Sibling deck (loader engine): [`notes/presentations/INGESTION_REHAUL.md`](INGESTION_REHAUL.md) — gitoxide rehaul, Lane 1 stack, W20 task-force context.
- Cross-deck framing: `INGESTION_REHAUL.md` lines 762–795 — "concurrent content_add is the top priority — first sprint scope".

**On GitLab:**

- Architectural issue: [swh/devel/swh-storage#4727](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/issues/4727).
- MR1 init split: [!1223](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/merge_requests/1223).
- MR2 concurrent path: [!1224](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/merge_requests/1224).
- MR3 bench: [!1225](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/merge_requests/1225).
- MR4 reconciler: [!1226](https://gitlab.softwareheritage.org/swh/devel/swh-storage/-/merge_requests/1226).

**Load-bearing code citations:**

- Sequential write loop: `swh-storage/swh/storage/cassandra/storage.py` — lines 472–493.
- `execute_many_statements_with_retries`: `swh-storage/swh/storage/cassandra/cql.py` — lines 488–507.
- Existing concurrent users: `cql.py:881` (`directory_entry_add_concurrent`), `cql.py:1855` (`object_reference_add_concurrent`).
- Scrubber Content gap: `swh-scrubber/swh/scrubber/storage_checker.py` — lines 188–204 (TODO at 192–194).
- Retry proxy: `swh-storage/swh/storage/proxies/retry.py` — lines 23–54 (`should_retry`), 88–119 (`RetryingProxyStorage`).
- Reconciler: `swh-storage/swh/storage/reconciler/{verifier.py,journal_client.py,cli.py}`.

**Prior art:**

- Nicolas Dandrimont's Sept 2025 batched-read commits: `9a4d5596`, `9da2c163`, `c5e77f48` (the prepared-statement scaffolding this stacks on).
- Reconciler pattern reference: `swh-objstorage-replayer/swh/objstorage/replayer/replay.py` (~560 LOC).

Note: The references slide doubles as the speaker's safety net — if a reviewer asks "where does the X claim come from", everything they need is one click away. The order is: architectural docs first, GitLab MRs second, code third, prior art last.

---

# Questions?

Note: This deck is informational — the team is not being asked to ratify anything in the room. Likely discussion topics: (1) the consistency-level question — why inherit vs override, what happens at LOCAL_QUORUM, etc.; (2) the migration sequence — why MR4 is independent of the stack and how that affects review order; (3) whether the reconciler can be promoted to its own repo later — yes, `swh-objstorage-replayer` made exactly that trip; (4) the staging soak windows — 24 h / 6 h / 72 h are starting proposals, task force may want longer. The MR8 question (do we need MissTolerantProxyStorage?) is best answered "we'll know after MR7 canary data". Keep at least 10 minutes for discussion.
