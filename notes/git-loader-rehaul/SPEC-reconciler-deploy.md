# SPEC — Reconciler deployment (MRs 5, 6, 7)

> **Status: gated, not yet executed.** This document captures the design so the team picks up the deploy work without re-deriving it. MRs 5–7 land in `swh/infra/ci-cd/swh-charts` once the storage-side stack (`!1223`–`!1226` in swh-storage) merges to master and ships a tagged release. See architectural issue `swh/devel/swh-storage#4727` and execution plan `notes/git-loader-rehaul/PLAN-concurrent-content-add.md` for the broader context.

---

## 1. Why three MRs, not one

The reconciler safely transitions through three operating points:

| Stage | Reconciler mode | Cassandra `content_add_algo` | What we're verifying |
|---|---|---|---|
| MR5 | `observe-only` | `sequential` | The reconciler runs on staging, consumes `swh.journal.objects.content`, and emits `swh_storage_reconciler_lag_seconds` / `swh_storage_reconciler_repairs_total` metrics. **No writes, no behaviour change.** We confirm the consumer keeps up (`lag_seconds` p95 < 60 s sustained for 24 h) before any flip. |
| MR6 (step 1) | `repair-enabled` | `sequential` | Flip `--repair-enabled` on staging. The repair-rate should be ≈ 0 — sequential writes don't produce inconsistencies. If `repairs_total` is non-trivial, the reconciler has a bug; abort and fix before proceeding. |
| MR6 (step 2) | `repair-enabled` | `concurrent` on ONE staging storage writer | Flip the storage config for a single canary writer. Watch `repairs_total` (expect a small steady rate matching the concurrent ordering window) and the staging `swh-web` 404 rate. **72-hour soak.** |
| MR7 | `repair-enabled` (already on) | `concurrent` on production fleet, **one writer at a time** | Production canary on one storage instance, 72-h soak, then fleet rollout. |

Each step is independently revertable (config flip, no schema change, no migration).

---

## 2. Chart anatomy — proposed structure

The chart lives at `gitlab.softwareheritage.org/swh/infra/ci-cd/swh-charts` under `swh/templates/`. The closest existing analogue is **`objstorage-replayer/`** (245 lines across 4 files): same JournalClient consumer shape, same per-deployment values-stanza pattern, same KEDA autoscaling story. The reconciler differs in two ways:

- Writes go back to **Cassandra** rather than to an objstorage. We don't need `sourceObjstorageConfigurationRef` / `destinationObjstorageConfigurationRef`; instead we need `storageCassandraConfigurationRef` (already used by `cassandraChecks`).
- The reconciler subscribes to `content` only — no per-deployment `object_types` array.

### 2.1 New template directory

```
swh/templates/content-reconciler/
├── configmap.yaml          # ~ mirror of objstorage-replayer/configmap.yaml
├── deployment.yaml         # ~ mirror of objstorage-replayer/deployment.yaml; container command: `swh storage -C /etc/swh/config.yaml reconciler run [--observe-only | --repair-enabled]`
├── _helper.yaml            # hydrate deploymentConfig from defaults; build the journal_client + storage config sections
└── keda-autoscaling.yaml   # ~ mirror; trigger on `swh_storage_reconciler_lag_seconds`
```

Recommended copy-edit recipe:

1. `cp -r swh/templates/objstorage-replayer/ swh/templates/content-reconciler/`
2. Replace `objstorageReplayer` → `contentReconciler` throughout (4 files).
3. In `deployment.yaml`, replace the container `command:` / `args:` block. The reconciler's entrypoint is the CLI subcommand registered in `swh-storage` (MR1226's commit 3):
   ```yaml
   command:
     - swh
     - storage
     - --config-file=/etc/swh/config.yaml
     - reconciler
     - run
   args:
     {{- if $deployment_config.repairEnabled }}
     - --repair-enabled
     {{- else }}
     - --observe-only
     {{- end }}
   ```
4. In `_helper.yaml`, replace `sourceObjstorageConfigurationRef` / `destinationObjstorageConfigurationRef` with `storageCassandraConfigurationRef`. The configmap renders to a YAML file with two top-level sections — `storage:` and `journal_client:` — exactly like the existing `swh storage replay` command consumes.
5. In `keda-autoscaling.yaml`, change the trigger metric from `kafka_consumer_lag` (or whatever objstorage-replayer uses) to `swh_storage_reconciler_lag_seconds` — see §4 for the alert thresholds.
6. Docker image: needs to be a `swh-storage` image at a version ≥ the tag that includes `mr/4-content-reconciler` (`!1226`). Ops will tag a release after MR1–MR4 merge.

### 2.2 `swh/values.yaml` — new stanza

Insert near the existing `objstorageReplayer:` block (around line 1770):

```yaml
contentReconciler:
  enabled: false                   # opt-in per cluster
  # storageCassandraConfigurationRef: storageCassandraConfiguration
  # journalClientConfigurationRef: journalClientConfiguration
  # sentry:
  #   enabled: false
  #   secretKeyRef: my-secret
  #   secretKeyName: my-key
  # extraCliLogLevel: ""
  # deployments:
  #   content:
  #     repairEnabled: false       # MR5: false (observe-only); MR6+: true
  #     replicas: 1                # single consumer per group_id — no parallelism within group
  #     journalClientOverrides:
  #       group_id: swh-storage-reconciler-staging   # cluster-distinct
  #       batch_size: 200
  #     # KEDA off until we know the typical lag/throughput profile.
  #     # autoScaling:
  #     #   pollingInterval: 60
  #     #   lagThreshold: 60        # lag_seconds; the staging exit gate
  #     #   minReplicaCount: 1
  #     #   maxReplicaCount: 4
```

### 2.3 Per-cluster overlay

The actual flips happen in the per-cluster values files under `swh/values/`. Two flips need ratification per cluster:

```yaml
# swh/values/staging.yaml (MR5)
contentReconciler:
  enabled: true
  deployments:
    content:
      repairEnabled: false

# swh/values/staging.yaml (MR6 step 1)
contentReconciler:
  deployments:
    content:
      repairEnabled: true

# swh/values/staging.yaml (MR6 step 2) — the *storage* config, not the reconciler:
storageCassandraConfiguration:
  # ... existing fields ...
  content_add_algo: concurrent      # ← single line flip
  content_add_concurrency: 50       # default; explicit for documentation
```

For MR7 the same two flips happen in `swh/values/production.yaml`, one storage instance at a time.

---

## 3. Operator gates (numeric thresholds)

These are the operator's exit criteria for each stage. They mirror the rollout gates listed in `notes/git-loader-rehaul/PLAN-concurrent-content-add.md` §6.

| Gate | Threshold | Rationale |
|---|---|---|
| MR5 → MR6 step 1 | `swh_storage_reconciler_lag_seconds` p95 < 60 s sustained for **24 h** on staging | Confirms the consumer keeps up with steady-state ingestion before we let it write. |
| MR6 step 1 → MR6 step 2 | `swh_storage_reconciler_repairs_total` rate ≈ 0 sustained for **6 h** on staging (with `sequential` still active) | Sequential writes produce zero ordering inconsistencies; a non-zero rate means the reconciler has a bug. |
| MR6 step 2 → MR7 | 72-h soak on one staging writer with `concurrent` active: stable bounded `repairs_total` rate AND no `swh-web` 404 anomaly attributable to content lookups | The reconciler is closing the consistency window faster than user reads observe it. |
| MR7 fleet → done | Same criteria on one production writer for 72 h, then fleet | Same shape, production traffic. |

If any gate fails, **revert with a config flip**: change `content_add_algo` back to `sequential` (instantaneous; no migration). Reconciler stays running with `repair-enabled` — under `sequential` it does nothing, which is safe.

---

## 4. Prometheus alerts (proposed)

Emitted by the reconciler (already wired in MR4 / `!1226`); the alerting rules live in `swh-grafana-dashboards` or wherever the chart's `PrometheusRule` resources are managed.

| Alert | Expression | Severity | Reason |
|---|---|---|---|
| `ReconcilerDown` | `up{job="content-reconciler"} == 0 for 5m` | critical | Reconciler stopped; concurrent path is unsafe until it returns. |
| `ReconcilerLagHigh` | `quantile_over_time(0.95, swh_storage_reconciler_lag_seconds[10m]) > 60` | warning | Consumer lag exceeds the gate; investigate before any further flips. |
| `ReconcilerRepairRateUnexpected` | `rate(swh_storage_reconciler_repairs_total[5m]) > <baseline * 3>` | warning | Tune baseline per cluster after the first 7 days of metrics. A 3x burst beyond baseline likely indicates a storage-write incident. |

The reconciler also emits `swh_storage_reconciler_throughput_total` (counter, content events processed); use it as a sanity check that the daemon is alive even when there's nothing to repair.

---

## 5. What MR5/MR6/MR7 individually contain

- **MR5** — new chart template + values stanza + enabling in staging overlay with `repairEnabled: false`. Lives entirely in swh-charts.
- **MR6** — purely a values-overlay change in `swh/values/staging.yaml` (and possibly `swh/values/azure-staging.yaml` or similar — list TBD with ops). Two commits ideally: (1) `repairEnabled: true`; (2) `content_add_algo: concurrent` on one staging writer. Each commit independently revertable.
- **MR7** — same shape as MR6, but on `swh/values/production.yaml`, one writer at a time. Recommend two commits: one to canary, one to fleet, gated on 72-h soaks each.

Optionally **MR8** (`MissTolerantProxyStorage`, swh-storage `!1227`) lands at any time but is only WIRED into the read pipeline if production metrics surface user-visible 404s — see its own description for the gating logic.

---

## 6. Open questions to ratify with ops before MR5 opens

1. **Cluster list.** Which staging clusters get the reconciler first? Recommend: `azure-staging` (the loader-side rehaul's primary canary target) → then `azure-production`. Confirm with ops.
2. **`group_id` per cluster.** Each cluster needs its own consumer group so the consumers don't share offsets. Recommend `swh-storage-reconciler-<cluster>`.
3. **Sentry / log routing.** Mirror the existing `swh storage replay` setup (it uses `error_reporter` for Redis). The reconciler doesn't need an error reporter (no validation failures to surface); just regular logging.
4. **Image source.** Ops tags a `swh-storage` release after MR1–MR4 merge. The chart pins to that tag. Confirm tagging cadence.
5. **Read consistency for the verifier.** Currently MR4 inherits the writer's consistency level via `storage._consistency_level`. If ops wants explicit override per deployment (e.g. read at `LOCAL_QUORUM` regardless of writer config), that's a small follow-up commit on the reconciler (~3 LOC + a CLI flag).

---

## 7. References

- Architectural issue: `gitlab.softwareheritage.org/swh/devel/swh-storage/-/issues/4727`
- Execution plan: `notes/git-loader-rehaul/PLAN-concurrent-content-add.md` on this branch
- Companion deck slide: `notes/presentations/CONCURRENT_CONTENT_ADD.md` slide 25 ("Staging → production rollout gates")
- swh-storage MRs (the storage-side stack):
  - `!1223` — `mr/1-cassandra-init-split`
  - `!1224` — `mr/2-concurrent-content-add`
  - `!1225` — `mr/3-content-add-bench`
  - `!1226` — `mr/4-content-reconciler`
  - `!1227` — `mr/8-miss-tolerant-proxy` (GATED)
- Existing chart analogue: `swh-charts/swh/templates/objstorage-replayer/` (245 LOC; the reconciler chart should be ~ same size)
- KEDA autoscaling reference: `swh-charts/swh/templates/objstorage-replayer/keda-autoscaling.yaml`
