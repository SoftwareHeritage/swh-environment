# EXPLORE — github-ingestion migration & reuse for the new pipeline

*Forward-looking exploration. Companion to `EXPLORE-adastra-direct-ingestion.md`. Maps the existing `github-ingestion` repo against the new gix-based pipeline, and identifies what to migrate, what to reuse, and what to drop.*

**Code lives at:** `https://gitlab.softwareheritage.org/teams/codecommons/github-ingestion` (public, `master` branch). It's under the `teams/codecommons/` namespace, not `swh/devel/` — this is why a `swh-environment` checkout doesn't include it by default.

---

## 1. What github-ingestion is today

A **custom batch ingestion pipeline** combining three components, ~2,600 LOC across 38 Python files. **Not** a lister.

| Component | LOC | Purpose |
|---|---:|---|
| **Batch Git Loader** | 363 | `GitLoaderFromBatchArchive` subclass of `swh.loader.git.GitLoaderFromDisk`. Extracts repos from pre-packed tar bundles (Stack V2 or HuggingFace downloads), runs them through SWH conversion, streams them via `_BoundedFileView` (no full-repo buffering). |
| **ORC Storage sink** | 390 | `OrcStorage(StorageInterface)` — writes all SWH object types (content, directory, revision, release, snapshot, origin, origin_visit) to ORC files instead of Cassandra. Pure sink, not a real backend. |
| **Deduplicator** | ~1,800 | Long-running Kafka journal consumer with dual RocksDB indices (CodeCommons + main SWH archive). Deduplicates SWH objects (revisions, releases, contents) across both archives; exports to ORC via `graph_data_exporter`. |

**Concurrency model**: single-origin-per-Celery-task; Celery handles distribution. Deduplicator is a separate long-running process.

**Storage path**: batch loader → `OrcStorage` sink → ORC files. **Not** Cassandra / Winery / journal Kafka. (The deduplicator does consume the main SWH Kafka, but that's separate from github-ingestion's own write path.)

**Fork / parent detection**: **not implemented**. The deduplicator does object-level dedup but does not detect fork relationships or skip forks of already-archived origins.

---

## 2. The architectural surprise

**github-ingestion already has the AdAstra pieces, partially.**

| Concern | github-ingestion today | AdAstra hypothetical |
|---|---|---|
| Pack source | Pre-packed tar bundles (Stack V2) | Direct from forge (HTTPS smart-protocol) |
| Pack parse | dulwich (via `swh.loader.git.GitLoaderFromDisk`) | gitoxide (via `gix-protocol` + `gix-pack`) |
| Storage sink | `OrcStorage` writes to ORC | ORC append |
| Schema | Same SWH model (because `OrcStorage` implements `StorageInterface`) | Same SWH model |
| Dedup | Post-ingest journal-driven RocksDB | Post-ingest merge pass over ORC files |

The pack-source step is the only real difference. github-ingestion fetches from local tar; AdAstra fetches from the network. Everything downstream (conversion → ORC write → dedup) is largely solved already.

**Implication**: AdAstra is closer to a fork of github-ingestion than a greenfield project. The reusable assets from the prior-art search (swh-export's ORC writer) are good for *schema reference*, but github-ingestion's `OrcStorage` is what AdAstra actually wants on the sink side.

---

## 3. Replacement effort — three scenarios

### Scenario A — Drop-in gix replacement (keep github-ingestion's batch-from-tar architecture)

**Scope**: swap dulwich for the new gix engine inside `batch_git_loader.py`. Everything else (`OrcStorage`, deduplicator, CLI, scheduling) unchanged.

| Item | Detail |
|---|---|
| Files affected | 1 (`custom_swh_components/batch_git_loader/batch_git_loader.py`) |
| Call sites to migrate | 3 dulwich converter calls (lines 244, 258, 268) |
| New code | ~50 LOC (gix converters or dulwich-fallback dispatch) |
| **Effort** | **2–4 hours** |
| Risk | Low — converters are stateless; output schema is fixed |

Test on 2–3 sample repos, verify ORC output matches dulwich's. Done.

### Scenario B — Adopt the size-classed Celery queues + dulwich-fallback

**Scope**: github-ingestion adopts the same size-classed routing (`small`/`large`/`xl`) and dulwich-fallback dispatch as the production loader. Single-origin-per-task becomes size-aware; fallback safety net is shared.

| Item | Detail |
|---|---|
| Modified modules | `batch_git_loader.py` (+50 LOC), `tasks.py` (+30 LOC), `cli.py` (+20 LOC) |
| New modules | dispatch logic (~100–150 LOC; can largely mirror what's on `mr/2-size-classed-queues` + `mr/3-dulwich-fallback`) |
| **Effort** | **8–12 hours** |
| Risk | Medium — Celery queue isolation, fallback correctness; benefits from staging cluster |

Breakdown:
- 2 h — design queue dispatch (size thresholds, AdAstra cluster's worker pool sizing)
- 2 h — implement dulwich-fallback handler (reuse `mr/3-dulwich-fallback`'s `dulwich_fallback.py`)
- 2 h — Celery task registry + CLI scheduling
- 2–3 h — staging test on AdAstra HPC
- 1–2 h — statsd integration

### Scenario C — Full replacement with AdAstra direct-to-ORC

**Scope**: github-ingestion becomes a thin wrapper. Drop the tar-extract path entirely; fetch direct from forge via the AdAstra prototype's gix-protocol path. Keep the deduplicator (it already works on Kafka/ORC).

| Item | Detail |
|---|---|
| Drops | `GitLoaderFromBatchArchive`, `_BoundedFileView`, tar-extract pipeline (~270 LOC removed) |
| New code | ~50 LOC wrapper calling AdAstra fetch + reusing `OrcStorage` |
| Modified | `orc_storage.py` (no change — already does direct ORC writes), deduplicator (no change if ORC schema unchanged), `tasks.py`, `cli.py` |
| **Effort** | **12–16 hours**, *blocked on AdAstra prototype existing* |
| Risk | High while AdAstra is unproven; low once it is |

Breakdown (post-AdAstra-prototype):
- 1–2 h — validate AdAstra fetch API + pack format
- 3–4 h — direct-to-ORC writer (reuse github-ingestion's `OrcStorage`)
- 2–3 h — rewrite scheduling (Celery → AdAstra-native driver)
- 3–4 h — integration test (ORC schema + deduplicator)
- 2–3 h — migration of in-flight tar bundles (operational only)

---

## 4. Recommended sequencing

Two paths are independently valuable and can run in parallel:

**Track 1 — short-term cleanup (Scenario A)**: 2–4 hours of work. Eliminates github-ingestion's dulwich dependency once the new gix engine ships. Removes the per-origin "dulwich is slow" floor on AdAstra HPC runs. Low risk, no architectural commitment. **Recommended even if Scenario C never lands.**

**Track 2 — AdAstra prototype** (independent, per `EXPLORE-adastra-direct-ingestion.md`): if the prototype validates, github-ingestion's batch-from-tar path becomes redundant and Scenario C absorbs it. If the prototype doesn't validate, Track 1's work still stands.

**Scenario B is the awkward middle.** It only makes sense if AdAstra is deferred *and* github-ingestion is going to keep running at scale for many months. In most plausible futures (either AdAstra wins, or concurrent content_add + gix-loader rehaul absorbs the throughput need), Scenario B is overkill.

---

## 5. Reusable assets in github-ingestion (for AdAstra)

If AdAstra builds, **don't write a new ORC sink from scratch**. github-ingestion's `OrcStorage` at `custom_swh_components/orc_storage/orc_storage.py` (390 LOC) is a working `StorageInterface` adapter that:

- Implements all SWH object types (content, directory, revision, release, snapshot, origin, origin_visit).
- Writes binary `(id, data)` columns to ORC files.
- Compatible with the existing deduplicator's expected schema.
- Has been exercised at AdAstra-HPC scale.

This is structurally different from swh-export's `ORCExporter`:

| Aspect | swh-export's ORCExporter | github-ingestion's OrcStorage |
|---|---|---|
| Source | Reads from Cassandra/journal | Receives objects in-memory via `StorageInterface` |
| Sink shape | Per-table ORC files via `pyorc.Writer` | Per-table ORC files |
| Reuse for AdAstra | Schema definitions (relational.py) | Writer + buffering + flush mechanics |

**Practical**: AdAstra should reuse github-ingestion's `OrcStorage` body + swh-export's schema constants. That's mostly already glued together via `StorageInterface`.

---

## 6. Open question for the team

**Who maintains github-ingestion today?** The repo is at `gitlab.softwareheritage.org/teams/codecommons/github-ingestion` — under the `teams/codecommons/` namespace, separate from `swh/devel/`. Maintenance ownership matters for:

- Reviewer assignment when Scenario A's MR opens (the MR targets the codecommons fork, not a `swh/devel/` repo).
- Coordination with the swh-loader-git rehaul (Scenario A depends on `mr/1-gix-engine` landing in swh-loader-git).
- The decision on Scenario B vs C (AdAstra direction).

Resolve before opening MRs against `teams/codecommons/github-ingestion`.

---

## 7. Headline numbers for the team-facing pitch

- **3 dulwich call sites** in github-ingestion's batch loader. **2–4 hours** to migrate to gix once `mr/1-gix-engine` lands.
- **390 LOC `OrcStorage` sink** in github-ingestion is reusable for AdAstra without modification — closer to a fork of github-ingestion than greenfield.
- **No fork-detection** logic in github-ingestion → fork-aware ingestion is still a separate proposal (not delivered by either rehaul or AdAstra).
- **The deduplicator** (Kafka → RocksDB → ORC) is independent of the loader work and continues to function regardless of the chosen ingestion path. It is **not** part of the migration work.

---

## 8. Relation to the other proposals

- **Gix loader rehaul** (`HANDOFF.md`, `HANDOFF-MR-PLAN.md`): Scenario A above is a **post-rehaul follow-up** — depends on `mr/1-gix-engine` shipping, then a small MR against github-ingestion's `batch_git_loader.py`.
- **concurrent content_add** (`ISSUE-concurrent-content-add.md`, `PLAN-concurrent-content-add.md`): orthogonal. github-ingestion writes to ORC, not Cassandra; concurrent content_add is a Cassandra-side optimization. No interaction.
- **AdAstra direct-to-ORC** (`EXPLORE-adastra-direct-ingestion.md`): this document is the companion that operationalises the AdAstra exploration against the existing github-ingestion code. AdAstra's "build a new ORC sink" line item is **already partly built** — reuse `OrcStorage`.
