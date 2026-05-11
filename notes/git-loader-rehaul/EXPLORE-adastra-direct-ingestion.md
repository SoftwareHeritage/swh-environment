# EXPLORE — Direct gix-to-ORC bulk ingestion (AdAstra)

*Forward-looking exploration. Sibling to the gix loader rehaul + REC-L4 proposal in this directory. Not yet a commitment — this document scopes the option and identifies the data we need to decide.*

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

For a 10k-content repo under the current pipeline, steps 4 and 6 alone account for **30–60 s** of wall time per origin (per the REC-L4 analysis: 5N sequential CQL round-trips at ~1 ms each). Multiplied across hundreds of millions of origins, this dominates total runtime.

## 3. Where the gains stack

Estimates per origin, vs the current dulwich-based loader → Cassandra pipeline:

| Source of gain | Magnitude | Notes |
|---|---|---|
| Skip Cassandra dedup lookup | ~50–200 ms / origin | 1 round-trip per hash per algo |
| Skip Cassandra writes | **5N × ~1 ms per content** | REC-L4's denominator; ~50 s saved on 10k-content repo |
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

## 7. Coordination

This work overlaps with two other SWH efforts:

- **swh-export / swh-datasets** — produces ORC datasets from existing Cassandra/objstorage state via Luigi pipelines. They have the ORC schema and the columnar-write infrastructure. The "ingest directly into ORC" path is structurally close to their existing pipeline but inverted (read upstream forge → write ORC, vs. read SWH storage → write ORC).
- **swh-graph** — compressed graph computation over the deduplicated archive. Consumes ORC-style flat exports as input.

Before prototyping, check with the swh-export team whether direct-to-ORC ingestion is on their roadmap, or whether they prefer the "ingest into SWH storage, then export to ORC" path that exists today. Two reasons:

1. They may have already prototyped this. No point duplicating work.
2. ORC schema decisions (which columns, which compression, which sharding scheme) should be made jointly so the output of bulk ingestion is consumable by the existing graph pipeline.

Likely contacts: same set of people as the storage proposal — David Douard, Thomas Pellissier-Tanon (storage side), plus whoever currently maintains swh-export and swh-graph.

## 8. Open questions

1. **Deduplication strategy at the merge pass**: full-archive global dedup, or shard-level dedup with cross-shard merge later? Affects ORC schema and merge job design.
2. **Origin discovery**: AdAstra implies a queue of origins to ingest. Where does that come from — the existing lister output? A dedicated AdAstra-side enumeration of forges?
3. **Failure handling**: per-origin failures should be logged (which origins, which step failed, retry policy). Lightweight compared to current visit-state tracking but cannot be zero.
4. **Coexistence with online ingestion**: AdAstra running alongside the existing loader fleet, or replacement? If coexistence, the dedup pass must reconcile both sources.
5. **ORC granularity**: one ORC file per origin? Per N origins? Time-partitioned? Affects per-batch wall time vs file-count overhead.

## 9. Recommended next steps

1. **Confirm with swh-export team** whether direct-to-ORC ingestion is already planned or prototyped. (~30 min conversation.)
2. **Pick 5–10 representative origins** of varying pack sizes (small flask-like / medium kernel-like / large chromium-like). Document them.
3. **Baseline the current dulwich loader** end-to-end against the sample, into a throwaway swh-storage. Capture per-origin wall time and CPU profile. (~1 day.)
4. **Write the ~200-LOC Rust prototype** — `gix-protocol` fetch + `gix-pack` iterate + ORC append. Use the same upstream gitoxide crates as `swh-loader-git/gix-lib/`. (~1–2 days.)
5. **Run the prototype against the same sample**, capture comparable numbers. (~1 day.)
6. **Cost-model the projection to 100M origins**: per-origin wall time × N origins / parallelism factor → wall time + cluster size. Identify whether network or CPU is the binding constraint at scale.
7. **Decision gate**: if the prototype shows ≥ 5× per-origin wall-time reduction AND the network ceiling allows the projected concurrency, proceed to a production AdAstra implementation. Otherwise reconsider — the SWH loader rehaul + REC-L4 may already be enough.

## 10. Relation to the gix loader rehaul + REC-L4 proposals

The two are not mutually exclusive:

- **Gix loader rehaul + REC-L4** (described in `HANDOFF.md` and `ISSUE-rec-l4-architecture.md`) accelerates the existing online ingestion pipeline. Targets the production loader fleet. Lands the gitoxide code into SWH's runtime, validated and reviewed.
- **AdAstra direct-to-ORC** would be a separate batch pipeline for bulk re-ingestion or initial-load scenarios. Reuses the same gitoxide crates but bypasses the SWH runtime infrastructure.

The rehaul lands first (production stability matters most), validates the gitoxide stack in SWH's hands, and yields the building blocks (`gix-lib` integration patterns, Rust+Python interop, deployment story) that AdAstra would extend. AdAstra can start prototyping in parallel with rehaul review, since they share dependencies but not deploy lifecycle.
