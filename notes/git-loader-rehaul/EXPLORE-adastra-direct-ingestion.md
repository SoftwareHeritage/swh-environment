# EXPLORE — Direct gix-to-ORC bulk ingestion (AdAstra)

*Forward-looking exploration. Sibling to the gix loader rehaul + concurrent content_add proposal in this directory. Not yet a commitment — this document scopes the option and identifies the data we need to decide.*

---

## 1. Question

For AdAstra-style bulk ingestion targeting hundreds of millions of repositories into ORC files, can we gain time by using gitoxide directly — bypassing the SWH loader → storage pipeline — given that:

- Per-object ordering does not matter for ORC ingestion (columnar, append-only, deduplication happens at a later merge pass).
- Per-origin atomicity does not matter (we don't need visit-state guarantees during the ingest run).
- The end-state is one or more ORC files, not Cassandra rows or Winery blobs.

## 2. What the existing SWH pipeline does that ORC ingestion does not need

The current loader → storage path executes, per origin:

| Step | Cost | Needed for ORC ingestion? |
|---|---|---|
| 1. Pack download from origin | network-bound | **YES (unavoidable)** |
| 2. Pack inflation → typed objects | CPU | **YES** |
| 3. Hashing → SWHIDs | CPU | **YES** |
| 4. Dedup lookup against Cassandra | 1 round-trip per hash per algo | **NO** (later merge pass) |
| 5. Write blobs to objstorage (Winery) | per-blob storage I/O | **NO** (ORC blob column) |
| 6. Write metadata to Cassandra | 5N CQL round-trips per content batch | **NO** (ORC append) |
| 7. Journal publish to Kafka | per-batch producer cost | **NO** |
| 8. Update visit state | per-origin storage write | **NO** |
| 9. Celery / scheduler overhead | task pickup + visit init | **NO** if bulk-in-process |

Steps 1–3 are intrinsic to ingestion. Steps 4–9 are SWH framework overhead that ORC ingestion can skip.

For a 10k-content repo under the current pipeline, steps 4 and 6 alone account for **30–60 s** of wall time per origin (per the concurrent content_add analysis: 5N sequential CQL round-trips at ~1 ms each). Multiplied across hundreds of millions of origins, this dominates total runtime.

## 3. Where the gains stack

Estimates per origin, vs the current dulwich-based loader → Cassandra pipeline:

| Source of gain | Magnitude | Notes |
|---|---|---|
| Skip Cassandra dedup lookup | ~50–200 ms / origin | 1 round-trip per hash per algo |
| Skip Cassandra writes | **5N × ~1 ms per content** | concurrent content_add's denominator; ~50 s saved on 10k-content repo |
| Skip objstorage (Winery) writes | ms – tens of ms per blob | Winery is fast but adds per-blob overhead |
| Skip journal publish | ~10 ms / origin | Kafka producer cost |
| Skip Celery scheduling | ~10–100 ms / origin | Task pickup + visit init |
| dulwich → gix pack parse | **2–10×** on CPU | Per the gix loader rehaul benchmarks; bigger packs gain more |
| dulwich → gix hashing | **2–10×** on CPU | Rust SIMD-sha1 vs Python hashlib loop |
| Parallel pack inflation (gix) | **2–4×** on large packs | Phase 5 DirectTreeInflater on multi-core |
| Skip `git index-pack` | constant cost saved per origin | Streaming parse instead of build-idx-then-parse |

For a 10k-content repo:
- **Current dulwich-based path**: ~30–60 s in storage + ~20–30 s in pack parse ≈ **50–90 s/origin** (network excluded).
- **gix-direct-to-ORC**: ~5–10 s pack parse + ~1 s ORC append ≈ **~10 s/origin** (network excluded).

**Plus the network download**, which is intrinsic and identical across both paths.

## 4. What a prototype looks like

A standalone Rust binary that bypasses both SWH's storage layer and dulwich entirely:

```rust
fn ingest_origin(url: &str, orc_writer: &mut OrcBatch) -> Result<()> {
    // Stream pack via gix-protocol (no .idx ever built)
    let pack_stream = gix_protocol::fetch_pack(url)?;

    // Iterate objects, hash each, append to ORC columns
    for object in gix_pack::iterate(pack_stream)? {
        let swhid = compute_swhid(&object);
        orc_writer.append(swhid, object.kind, object.bytes);
    }

    // Deduplication happens at a later merge pass over the ORC files
    Ok(())
}
```

Estimated size: a few hundred LOC plus the ORC schema definition. Reuses the same gitoxide crates the SWH `gix-lib` already uses (`gix-protocol`, `gix-pack`, `gix-object`, `gix-hash`). No Python, no Celery, no Cassandra.

**Concurrency model**: N worker threads each pulling origins from a queue, each writing into a per-thread (or sharded) ORC file. At 100M+ origins, partition by repo-hash across many machines; per-machine bottleneck becomes network egress to the upstream forge and disk write for ORC.

**ORC writing libraries in Rust**: `arrow-orc` (Apache Arrow's ORC bindings) and `orc-rs` are the candidates. Either gives writer throughput north of 1 GB/s on a single core for typed columnar data.

## 5. Floor measurement from local bench

A small four-variant bench was run against `github.com/Byron/gitoxide.git` (95 MB pack, single connection from a Debian laptop):

| Variant | Mean wall time | What it measures |
|---|---:|---|
| `gix free pack receive` (discard) | 10.36 s | pack receive + in-memory `.idx` build, discarded |
| `gix free pack receive <dir>` | 10.43 s | same + write pack+idx to disk |
| `gix clone --bare` | 11.28 s | pack + idx + ref updates |
| `git clone --bare` | 11.59 s | same shape via stock git, control |

Effective network throughput: **95 MB / 10.4 s ≈ 9 MB/s** per connection.

**Interpretations:**

- The 10.4 s baseline is the floor for what any pack-based ingestion can achieve against GitHub from this network position. Anything below it is unavoidable network cost.
- Differences between the four variants are small (<2.6 %) because all four are dominated by GitHub's per-connection throttling, not local CPU/disk.
- For the AdAstra use case, **per-connection throughput is the binding constraint**, not local work. Aggregate throughput requires many concurrent fetches per machine.

**Caveats:**

- 95 MB is a small pack relative to SWH's long tail (Linux kernel ~7 GB, Chromium ~30 GB).
- Single-connection bench from one laptop does not stress local resources (CPU, disk, memory).
- `gix free pack receive` always builds the `.idx` (in memory in the discard variant); a true "pack bytes only" measurement requires either a custom Rust binary against `gix-protocol` or invoking the existing SWH `gix-lib` low-level fetch directly.

## 6. What needs to be benchmarked to decide

To go/no-go this, three measurements:

1. **Per-origin wall time, dulwich-loader vs prototype-gix-to-ORC**, on a sample of representative origins (small / medium / large / pathological pack-shape). Stress every code path, not just network.

2. **Aggregate single-machine throughput**: how many origins per hour can one box process when the SWH framework is stripped? Cap measurements both with and without network constraints (use a local mirror / `file://` URLs to isolate local-side cost).

3. **Network ceiling against upstream forges**: how many concurrent fetches against GitHub (and other forges) before rate-limits fire? This determines per-machine concurrency and feeds the cluster-sizing calculation.

For (1), the gix CLI bench above is the wrong shape — its variants don't reflect either the current SWH pipeline's actual cost (it doesn't include Cassandra/objstorage) or the proposed ORC path's actual cost (it doesn't include ORC writes). A proper comparison needs:

- Pick 5–10 representative origins (range of pack sizes and tree shapes).
- Time the current dulwich loader against them end-to-end into a throwaway storage.
- Write the ~200-LOC Rust binary, time it against the same origins end-to-end into a throwaway ORC.
- Compare wall times per-origin, plus aggregate throughput.

Estimated effort: 1–2 day prototype + 1 day bench setup + 1 day measurement and write-up.

## 7. Coordination — prior-art search

This work overlaps with two other SWH efforts:

- **swh-export / swh-datasets** — produces ORC datasets from existing Cassandra/objstorage state via Luigi pipelines. They have the ORC schema and the columnar-write infrastructure. The "ingest directly into ORC" path is structurally close to their existing pipeline but inverted (read upstream forge → write ORC, vs. read SWH storage → write ORC).
- **swh-graph** — compressed graph computation over the deduplicated archive. Consumes ORC-style flat exports as input.

### Prior-art search outcome

A scan of the SWH ecosystem (swh-export, swh-datasets, swh-graph, swh-graph-libs, swh-shard, swh-objstorage, plus `git log --since='2025-11-01'` across them) confirms that direct-from-forge bulk ingestion into ORC has **not been prototyped or implemented anywhere in the codebase**. Net-new work.

Specifically:

- **swh-export's existing ORCExporter** (`swh-export/swh/export/exporters/orc.py:132+`) and schema (`swh-export/swh/export/relational.py:9-110`) read **only from Cassandra/journal**, via `journalprocessor.ParallelJournalProcessor` (`swh-export/swh/export/luigi.py:365+`). No adapter for non-SWH sources exists.
- **swh-datasets** Luigi pipelines have no forge-direct ingestion paths.
- **swh-graph** input adapters expect the standard ORC layout produced by swh-export; no alternative inputs documented.
- **swh-shard / Winery** offer bulk-read paths but no direct write-to-ORC pipeline.
- Recent (since 2025-11) commits across these repos contain no "bulk ingest", "direct ingest", "forge ingest" or "AdAstra" subjects.

### Reusable assets from swh-export AND github-ingestion

**Two existing ORC writers in the SWH ecosystem**, with complementary fit for the AdAstra prototype:

**swh-export's `ORCExporter`** — reads from Cassandra/journal, writes ORC. Use for **schema definitions and metadata helpers**:

- Schema definitions at `swh-export/swh/export/relational.py:9-110` (`MAIN_TABLES`, `RELATION_TABLES`) — column types for content / directory / revision / release / snapshot / origin / origin_visit + relation tables. Includes bloom-filter definitions.
- `SWHTimestampConverter` at `swh-export/swh/export/exporters/orc.py:101-129` — handles SWH's `(seconds, microseconds)` → ORC `(seconds, nanoseconds)` conversion correctly.
- `hash_to_hex_or_none()` at `swh-export/swh/export/exporters/orc.py:79-80` — hash-formatting helper.

**github-ingestion's `OrcStorage`** (`github-ingestion/custom_swh_components/orc_storage/orc_storage.py`, ~390 LOC) — implements `StorageInterface` and writes incoming SWH objects directly to ORC. **This is the writer body AdAstra actually needs** — it accepts in-memory objects from a loader pipeline and flushes to ORC, exactly the shape AdAstra wants on the sink side. Has been exercised at AdAstra HPC scale.

The two are complementary: swh-export's `ORCExporter` is *read-from-Cassandra*, github-ingestion's `OrcStorage` is *write-into-ORC-from-anywhere*. AdAstra reuses github-ingestion's `OrcStorage` body + swh-export's schema constants. The output should land in the same ORC schema as swh-export's so the graph-compression pipeline consumes it unchanged.

See `EXPLORE-github-ingestion-migration.md` for the full mapping of github-ingestion to the new pipeline, including effort estimates for migrating its batch loader to gix.

### No conflict with existing code

The existing `ORCExporter` reads **from** Cassandra/journal. The AdAstra prototype reads **from** the forge directly. Both write into the same ORC schema. They are siblings on the producer side, not competitors.

### Likely contacts

From `git log` analysis on the relevant repos:

- **swh-export ORC code**: Aymeric Varasse, Antoine Lambert, Valentin Lorentz, David Douard.
- **swh-datasets pipelines**: Valentin Lorentz (primary), Stefano Zacchiroli, Thibault Allançon.
- **swh-graph**: Valentin Lorentz (dominant contributor).
- **Storage side** (from the storage proposal): David Douard, Thomas Pellissier-Tanon.

Recommended single conversation: **Valentin Lorentz** (overlaps swh-export + swh-datasets + swh-graph). Confirm AdAstra is not on their roadmap, then proceed.

## 8. Open questions

1. **Deduplication strategy at the merge pass**: full-archive global dedup, or shard-level dedup with cross-shard merge later? Affects ORC schema and merge job design.
2. **Origin discovery**: AdAstra implies a queue of origins to ingest. Where does that come from — the existing lister output? A dedicated AdAstra-side enumeration of forges?
3. **Failure handling**: per-origin failures should be logged (which origins, which step failed, retry policy). Lightweight compared to current visit-state tracking but cannot be zero.
4. **Coexistence with online ingestion**: AdAstra running alongside the existing loader fleet, or replacement? If coexistence, the dedup pass must reconcile both sources.
5. **ORC granularity**: one ORC file per origin? Per N origins? Time-partitioned? Affects per-batch wall time vs file-count overhead.

## 9. Recommended next steps

1. **Codebase scan: done** (§7 above). Direct-from-forge ingestion into ORC is genuinely net-new — no existing implementation in swh-export, swh-datasets, swh-graph, swh-shard, or related repos. Reusable assets (ORC schema, writer setup, timestamp converter, hash helpers) identified at `swh-export/swh/export/exporters/orc.py` and `relational.py`.
2. **One short conversation** with Valentin Lorentz (covers swh-export + swh-datasets + swh-graph): confirm AdAstra is not on the team's near-term roadmap and the proposed schema reuse is acceptable. (~30 min.)
3. **Pick 5–10 representative origins** of varying pack sizes (small flask-like / medium kernel-like / large chromium-like). Document them.
4. **Baseline the current dulwich loader** end-to-end against the sample, into a throwaway swh-storage. Capture per-origin wall time and CPU profile. (~1 day.)
5. **Write the ~200-LOC Rust prototype** — `gix-protocol` fetch + `gix-pack` iterate + ORC append (reusing `swh-export`'s schema and timestamp/hash converters). Same upstream gitoxide crates as `swh-loader-git/gix-lib/`. (~1–2 days.)
6. **Run the prototype against the same sample**, capture comparable numbers. (~1 day.)
7. **Cost-model the projection to 100M origins**: per-origin wall time × N origins / parallelism factor → wall time + cluster size. Identify whether network or CPU is the binding constraint at scale.
8. **Decision gate**: if the prototype shows ≥ 5× per-origin wall-time reduction AND the network ceiling allows the projected concurrency, proceed to a production AdAstra implementation. Otherwise reconsider — the SWH loader rehaul + concurrent content_add may already be enough.

## 10. Relation to the gix loader rehaul + concurrent content_add proposals

The two are not mutually exclusive:

- **Gix loader rehaul + concurrent content_add** (described in `HANDOFF.md` and `ISSUE-concurrent-content-add.md`) accelerates the existing online ingestion pipeline. Targets the production loader fleet. Lands the gitoxide code into SWH's runtime, validated and reviewed.
- **AdAstra direct-to-ORC** would be a separate batch pipeline for bulk re-ingestion or initial-load scenarios. Reuses the same gitoxide crates but bypasses the SWH runtime infrastructure.

The rehaul lands first (production stability matters most), validates the gitoxide stack in SWH's hands, and yields the building blocks (`gix-lib` integration patterns, Rust+Python interop, deployment story) that AdAstra would extend. AdAstra can start prototyping in parallel with rehaul review, since they share dependencies but not deploy lifecycle.
