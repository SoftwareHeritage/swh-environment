# PLAN — Rigorous code review for confidence in the replacement loader

**Status:** plan, not yet executed. Companion to `PLAN-inventory-zero-refactor-loader.md` (the inventory is the *artefact reviewers consume*; this plan defines *the review process around it*).

**Why this exists.** Passing unit tests is necessary but not sufficient for production confidence — see the PROPOSAL §9'.4 staging-gate framing. The team's confidence in the rehaul is built *across* code review + benchmark equivalence + staging measurement, not from any single signal. This plan defines the code-review portion of that compound argument: who reviews what, in what order, with what acceptance criteria, and what decisions must be ratified along the way.

---

## 1. Goals

The review process must produce, for each branch under consideration:

1. **Engineering sign-off**: the runtime code is correct, well-tested at the unit level, and the diff matches the intent stated in the PROPOSAL.
2. **Architectural sign-off**: the per-visit type-emission shape (Q3a) and `BufferingProxyStorage` precondition questions have explicit decisions in writing.
3. **Operational sign-off**: the deployment surface (Celery queues, env vars, metrics, Helm overlays) matches what ops will actually deploy.
4. **Reviewer mental model**: at least one reviewer can describe the branch in one paragraph without consulting the diff.
5. **Rollback story**: every feature has a documented rollback path (feature flag default-off, queue removal, metric retirement) that a reviewer has confirmed exists.

What "rigorous" means in this context: each reviewer signs off on a checklist (§7), and at least one of those checklist items is *non-trivial* to satisfy without actually reading the code.

---

## 2. What the review depends on (prerequisites)

Before the first reviewer touches code, these artefacts must exist and be linked from each MR:

| Artefact | Status | Owner |
|---|---|---|
| Inventory document | To be produced per `PLAN-inventory-zero-refactor-loader.md` | Author of the rehaul |
| `report/ANALYSIS-git-loader-modernization.md` | Done | Author |
| `report/ALGORITHMS-pack-loading.md` | Done | Author |
| `PROPOSAL-staging-rollout.md` | Done | Author |
| Strict-cell benchmark data (`notes/bench-dulwich-limitations/strict-cell-results.jsonl`) | Done; 14 paired rows | Author |
| Slide deck `SESSION_B_TEAM.md` | Done; restructured 2026-05-05 | Author |
| Pre-read email (`PRE_READ_EMAIL.md` for engineers; SESSION_B pre-read TBD) | Engineers done; SESSION_B pending | Author |
| `make test` pass on a venv with PG-17 + sibling editable installs | Verified by test rig | Reviewer-side reproducible |
| `replicate.sh` reproducibility check on at least one repo | Per reviewer | Reviewer |

Reviewers who skip the prerequisites cannot give a meaningful sign-off.

---

## 3. Reviewer roster — roles, scope, and one-line responsibility

| Role | Scope | One-line responsibility |
|---|---|---|
| **Loader maintainers** (Antoine Lambert, Antoine R. Dumont) | `swh-loader-git/swh/loader/git/*.py`, dispatch helpers, fallback wiring, integration tests | "The Python loader paths are correct and the dulwich-fallback semantics match the design doc." |
| **Storage owners** (David, Thomas) | The Q3a per-visit type-separation question; `BufferingProxyStorage` precondition; journal-consumer impact | "The per-visit type-emission shape question has been answered in writing, and any consumer that would have noticed has been surveyed." |
| **REC-L4 primary reviewer** (Nicolas Dandrimont) | `swh-storage/swh/storage/cassandra/cql.py`, `swh/storage/cassandra/storage.py:_content_add` | "The concurrent-write path is consistent with my Sept 2025 batched-read restructure (`9a4d5596` / `9da2c163` / `c5e77f48`); the rebase resolution in `PLAN-rec-l4-concurrent-content.md` §Rebase status preserves my timing instrumentation; R4 (concurrency knob) and R8 (parametrised tests) are addressed before merge." |
| **Rust / PyO3 reviewer** | `gix-py/src/**/*.rs`, `python/_gix.pyi`, exception class declarations, pack iterator | "Every PyO3-exposed symbol has a stub, every typed exception has a Rust class + `create_exception!` declaration + `.pyi` line, and Cargo deps are conservative." |
| **Ops / SRE reviewer** | Helm overlays, Celery queue config, observability metrics, env vars | "What we deploy matches the runtime surface listed in the inventory; rollback is one Helm flip away." |
| **Independent reviewer** (someone unfamiliar with the rehaul) | The whole | "I can describe what each branch does without having been in the design conversations." |

The **independent reviewer** role is the most important: their experience tests whether the inventory + slides + journal entries are sufficient for someone joining cold. If they need to ask the author every five minutes, the documentation has gaps that need closing before the team session.

---

## 4. Process structure — six phases

### Phase A — SESSION_A walkthrough (60–90 min, hands-on)

Before anyone reads code:
- Live build of the gix-py crate (maturin develop).
- Live benchmark run on `django` (~13 s gix vs ~7.5 min dulwich).
- Code walkthrough of the dispatch logic, the typed exception flow, the safety-net re-queue path.
- Q&A on the per-visit type-separation question.

The point is *shared mental model before review*, not exhaustive coverage. Reviewers leave with: "I understand the moving parts; now I'm going to read the actual code."

### Phase B — Document review (each reviewer, 1–2 hours, async)

Each reviewer reads, **before** opening the MR diff:
1. The inventory document (§3 of `PLAN-inventory-zero-refactor-loader.md`).
2. The PROPOSAL §3 (what ships in Phase 1).
3. The deck section relevant to their domain (storage owners → type-emission slide; ops → operating-model + deployment slides; etc.).
4. The journal entry that captured the relevant design decision.

Reviewers who open the diff first are likely to miss why a decision was made and waste cycles on already-resolved questions.

### Phase C — Per-branch code review (parallel, by reviewer)

For each branch in dependency order (production-fix → typed-exceptions → dulwich-fallback → size-dispatch-safety-net → dispatch-integrated):

**First pass — diff stat walk** (~15 min per branch). Reviewer reads the file-level table from the inventory, classifies their reaction per file ("expected" / "surprised" / "needs question"). Surfaces any structural surprises before committing to a line-level read.

**Second pass — line-level read of key files** (~30–60 min per branch). Reviewer reads the actual diff for the files in their scope. Notes are recorded in MR comments, not in the inventory.

**Third pass — targeted scenarios** (~30 min per branch). Reviewer picks 3–5 scenarios from their domain, mentally walks them through the new code path, and confirms the outcome:
- *Loader maintainer scenarios*: a malformed pack lands on `loader.git.small`; an oversized pack lands on `small`; a wall-time threshold fires; a normal pack succeeds.
- *Storage owner scenarios*: a flush triggers mid-walk on contents threshold; a flush triggers on directory entries threshold; a crash happens between flushes.
- *Rust reviewer scenarios*: a `GixPackError` propagates from Rust to Python; a `.pyi` consumer (mypy / IDE) sees the new exception class; a panic in the parallel decoder is caught.
- *Ops scenarios*: a Helm rollout deploys the new queues; a feature flag flip enables fallback; a metric appears in Grafana.

### Phase D — Cross-cutting review (single reviewer, ~1 hour)

One reviewer (rotating, ideally the independent reviewer) walks the whole composed branch and verifies:
- **Security**: no new secrets, no path traversal in the safety-net's `os.path.getsize()` callers, no network endpoints introduced.
- **Observability**: every new code path that can fail emits a metric or log; every metric has a name registered in §3.6 of the inventory; ratios (success / failure) are queryable.
- **Error handling**: every new exception class has both a producer (where it's raised) and at least one consumer (where it's caught); no bare `except:` clauses introduced.
- **Rollback**: every feature has a flag default-off OR a queue that can be drained OR a metric that signals when it's safe to retire. Document the rollback path per feature in MR description.

### Phase E — Decision ratification meeting (synchronous, 30–45 min)

After Phases B–D produce reviewer comments, a single meeting (or async thread) ratifies:
1. **Per-visit type separation** (Q3a). Storage owners answer with one of: "not needed → ship single-walk" / "needed → schedule 2-walk follow-up MR before staging rollout."
2. **`BufferingProxyStorage` precondition** (Q1 in old framing, now subsumed). Decided alongside Q3a — if Q3a is "not needed", proxy is just a batching convenience.
3. **Phase 4C docstring rationale** (Q2). Decision: rewrite or leave; one-liner change either way.
4. **Phase 1 gating values** (Q3 in old framing). Confirm or adjust the four numeric thresholds.
5. **Mirror replay shape against partial visits** (Q3b). Mirror operator confirms the new prefix shape is tolerable.

Outcomes recorded in the journal as the next entry, with explicit decisions.

### Phase F — Reproduction step (per reviewer, ~30 min)

Each reviewer must, *before signing off*, do at least one of:
- Run `make test` from a fresh venv that follows the README's three-step setup.
- Run `replicate.sh` on `flask` or `requests` (smallest testbed repos) and confirm SWHID equivalence between the dulwich and gix engines.
- Build `gix-py` via `maturin develop` and import `_gix` from a Python REPL.

This catches "the README is incomplete" and "the build is broken on a fresh checkout" issues that no amount of diff-reading would surface. The reproduction step is also what makes the inventory's *runtime surface* real to the reviewer — they see the queue names actually exist, the metrics actually emit, the env var actually toggles behaviour.

---

## 5. Ordering — which MRs first, in what shape

### Stacked vs single MR

**Stacked** (recommended): six MRs in dependency order, each rebased on the previous as it merges. Each MR carries one feature; each reviewer can scope their attention narrowly. Reviewer fatigue is the lowest. Total wall-clock for sign-off is longest because of dependency chain.

**Single composed MR**: one big MR for `feat/gix-dispatch-integrated`. Lowest wall-clock if reviewers are available simultaneously; highest reviewer fatigue; harder to revert if one piece needs rework.

**Recommendation**: stacked. Open in order.

### Stack order with rationale

| Order | MR | Why this order |
|---|---|---|
| 1 | `fix/gix-loader-pack-reader-tree-tuple` | Bug fix; smallest review surface; gets reviewers warmed up |
| 2 | `feat/gix-typed-exceptions` | Foundation; no behaviour change without consumers; safe to land first |
| 3 | `feat/dulwich-fallback` | Adds the consumer for #2; default-off behind env var |
| 4 | `feat/size-dispatch-safety-net` | Independent of #1–#3 but conceptually paired; ships in Phase 1 |
| 5 | `feat/gix-dispatch-integrated` | Composition + integration glue + Helm overlay + e2e tests |
| 6 | `swh-storage/feat/content-add-concurrent` (REC-L4) | Independent of loader entirely; can run in parallel with the entire above stack |
| 7+ | Lane 2 / Lane 3 (scheduler / lister) | Deferred until after Phase 1 ships |

REC-L4 has its own reviewer set (storage owners as the *primary* reviewers, not the *secondary*). It can land on a different cadence and ships in Phase 3, after Phase 1 reaches 100% production.

### One-MR-per-branch vs depot-of-commits

Each MR should be a *coherent feature*, not a literal copy of the branch's commit history. If a branch has 30 commits where 20 are "Phase X step Y" intermediate commits, the MR should land them as a coherent set, with the description referring back to the journal entries for the design narrative.

Squashing should be the author's call per branch. Stacked-MR review is easier with a clean history; coverage of the design evolution is in the journal.

---

## 6. Sign-off matrix — minimum reviewers per MR

| MR | Engineering sign-off | Storage sign-off | Rust sign-off | Ops sign-off | Independent sign-off |
|---|---|---|---|---|---|
| 1. Production fix | 1 | — | — | — | — |
| 2. typed-exceptions | 1 | — | **1** | — | — |
| 3. dulwich-fallback | 1 | — | optional | optional | — |
| 4. size-dispatch-safety-net | 1 | — | — | **1** | — |
| 5. gix-dispatch-integrated | 1 | **1** | optional | **1** | **1** |
| 6. REC-L4 (swh-storage) | optional | **1** primary: Nicolas Dandrimont; secondary: David / Thomas | — | optional | — |

**Bold** = mandatory. Optional = welcome but not blocking.

The only MR requiring all five sign-off types is the composed one (#5), which is by design — it's the one that integrates everything and triggers the Phase 1 staging deploy.

**Why Nicolas is named primary on #6**: he authored the three Sept 2025 commits (`9a4d5596`, `9da2c163`, `c5e77f48`) that batched the read path of `_content_add`. Our REC-L4 patch attacks the *write* path that remains; the rebase resolution must preserve his timing instrumentation (see `PLAN-rec-l4-concurrent-content.md` §Rebase status). He is the immediate-context owner; opening the MR without his review would risk a reasonable "wait, didn't I just touch this?" reaction.

---

## 7. Per-reviewer acceptance checklists

Before each reviewer can sign off on their assigned scope:

### Loader maintainer
- [ ] I have read the inventory entry for every file in my scope.
- [ ] I can describe in one paragraph what each branch does, without consulting the diff.
- [ ] I have walked at least 3 of the loader-side scenarios in §4 Phase C.
- [ ] I have run `make test` on the branch and seen it pass.
- [ ] I have identified the rollback path for each feature (default-off flag, queue drain, etc.).
- [ ] I have noted any `# TODO`, `# FIXME`, or `# XXX` markers introduced and confirmed they're either tracked or trivial.

### Storage owner (David, Thomas)
- [ ] I have read the deck slide on type-emission and the per-call vs per-visit distinction.
- [ ] I have an explicit answer to Q3a (per-visit type separation: needed / not needed).
- [ ] I have confirmed (or denied) that `BufferingProxyStorage` is a hard precondition for the deployed configuration.
- [ ] If Q3a = "needed", I have signed off on scheduling the 2-walk follow-up MR before Phase 1 staging.
- [ ] I have confirmed the Phase 4C docstring rationale at `loader.py:863-867` either is correct or needs the proposed rewrite.
- [ ] I have ratified the journal-consumer survey result (Q3a-applied).

### Rust / PyO3 reviewer
- [ ] Every typed exception has all three artefacts: Rust class, `create_exception!` declaration, `.pyi` stub line.
- [ ] Every PyO3-exposed function or class has a `.pyi` entry that matches its actual signature.
- [ ] Cargo deps added are reviewed for license, maintenance, and bus-factor.
- [ ] No `unsafe` blocks introduced without a `// SAFETY:` comment.
- [ ] `#[pyo3(...)]` decorators match the documented Python-side interface.
- [ ] I have built the crate from a clean checkout via `maturin develop` and imported it.

### Ops / SRE reviewer
- [ ] Every new Celery queue is in the inventory (§3.6) and the Helm overlay.
- [ ] Every new metric is registered in the Grafana dashboard config (or has an issue tracking it).
- [ ] Env var defaults are safe: `SWH_LOADER_GIT_DULWICH_FALLBACK` defaults to off.
- [ ] The four staging gating values are concrete numbers, not "TBD".
- [ ] The rollback path for the Phase 1 deploy is one Helm flip (and I know what it is).
- [ ] The pod specs for new queues are in the Helm chart with correct resource limits.

### Independent reviewer
- [ ] I have read the inventory + the relevant deck slides + at least two journal entries.
- [ ] I have NOT consulted the rehaul author during review (other than scheduled walkthroughs).
- [ ] I can describe in two paragraphs what the rehaul does and why.
- [ ] I have walked through Phase C of §4 for at least one branch.
- [ ] I have completed the Phase F reproduction step.
- [ ] I have noted at least one place where the documentation could be clearer for a future maintainer.

---

## 8. Time budget

| Phase | Per-reviewer effort | Wall-clock |
|---|---|---|
| Phase A (SESSION_A walkthrough) | 90 min, attended live | One scheduled session |
| Phase B (document read) | 1.5 h | Async, ~3 days |
| Phase C (code review per branch × 5–6 branches) | 6–10 h | Async, ~1 week |
| Phase D (cross-cutting) | 1–2 h | One reviewer, async |
| Phase E (decision ratification) | 45 min | One scheduled meeting |
| Phase F (reproduction) | 30–60 min | Per reviewer |

Total per-reviewer: ~10–15 hours over ~1.5 weeks elapsed.

Total wall-clock for the whole stack to clear review: ~2 weeks if sign-offs proceed in parallel; ~3 weeks if they serialise.

---

## 9. Failure modes — when the review surfaces a problem

### Mild — comments need addressing
The author commits fixes; the reviewer re-reviews; the MR moves forward. Standard.

### Moderate — a feature needs to be removed or reworked
The branch is rebased to drop or rewrite the offending commits. Inventory is regenerated for the affected branch. Other branches in the stack rebase if needed. Journal updated to record the rework decision.

### Severe — Phase 1 should not deploy
A reviewer surfaces a correctness concern that no amount of documentation can paper over. Decision: hold the MR, hold the deployment, write a follow-up plan to investigate. Phase 1 deployment slips by however long the investigation takes. This is the *value* of doing review before deployment — it's the cheapest place to catch a severe issue.

### Catastrophic — the rehaul is wrong-shaped
A reviewer surfaces an architectural mistake (e.g., the per-visit type separation issue lands on the *needed* side and the 2-walk option turns out infeasible at the originally estimated cost). Decision: rewind to PROPOSAL revision, reset the deployment plan, regenerate the inventory and the deck. We don't expect this; the strict-cell benchmark and the deck rewrites have already exercised most of this risk.

---

## 10. Continuous-improvement hooks

After Phase 1 staging deploys (regardless of outcome):

- The reviewer who served as "independent" writes a short note for the journal: what was clear, what was opaque, what they had to ask the author about. Feeds back into the inventory + slide updates.
- The author tracks the reproduction step's friction points: how many commands a reviewer had to run, how many of those failed first time, how many required asking. Feeds back into the README.
- If a reviewer's checklist item turned out to be impossible to satisfy honestly without reading the code, the documentation has a gap; flag for the inventory.

The point of the review is not just to ship Phase 1 — it's to leave the project in a state where the next change can be reviewed faster.

---

## 11. What this plan does NOT do

- It does not assert that the rehaul is correct. Correctness is a compound argument: review + tests + strict-cell + staging-gate measurement.
- It does not prescribe specific tooling beyond what already exists (`make test`, `replicate.sh`, Grafana). Reviewers use what they're comfortable with.
- It does not duplicate the inventory. The inventory is the change-list; this plan is the social process around reading it.
- It does not commit reviewers to a calendar. Per-reviewer time budgets in §8 are estimates; actual scheduling is the team's call.

---

## 12. Decision now (before review starts)

To unblock the process, the rehaul author should decide and record:

- [ ] Single MR vs stacked? (recommend: stacked — §5)
- [ ] Squash per branch vs preserve commits? (per-branch choice; default: squash if intermediate commits don't carry standalone value)
- [ ] Who fills each reviewer role? (§3 lists role expectations; specific people TBD by author + team lead)
- [ ] When is SESSION_A scheduled? (§4 Phase A; date drives the rest of the timeline)
- [ ] Where does Q3a get answered: inline in MR comments or in a separate decision document? (recommend: separate doc, linked from #5's MR description)

Once those are answered, Phase A can be scheduled and the review process can start.
