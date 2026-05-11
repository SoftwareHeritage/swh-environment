---
title: "Git-loader rehaul — Engineer onboarding (Session A)"
description: "Hands-on setup, architecture, demo, troubleshooting"
tags: presentation, git-loader, hedgedoc
type: slide
slideOptions:
  transition: slide
  theme: white
  center: false
  slideNumber: true
  progress: true
---

<style>
.reveal .slides section { font-size: 0.72em; line-height: 1.2; }
.reveal .slides section h1 { font-size: 1.55em; }
.reveal .slides section h2 { font-size: 1.28em; }
.reveal .slides section pre { font-size: 0.75em; }
</style>

# Session A — Hands-on for loader maintainers

**Audience:** 2–3 engineers who will operate and maintain the new git loader
**Duration:** 60–90 minutes · **Format:** live walkthrough + shared screen

Note: Ask participants to complete the pre-read before the session.

---

## Pre-read (send ~2 days before)

Skim only:

1. [LEARNING_PATH.md](LEARNING_PATH.md) — map of the four repos and the worktree
2. [PROPOSAL §1–§3](../PROPOSAL-staging-rollout.md) — problem, architecture, phases

Optional email template: [PRE_READ_EMAIL.md](PRE_READ_EMAIL.md)

---

## Agenda

1. Repo layout & branches (5 min)
2. Build the Rust engine — `maturin develop` (10 min)
3. Architecture: the four parallel changes (15 min)
4. Live demo — benchmark a repo against dulwich (15 min)
5. Size-dispatch + safety-net re-queue walkthrough (10 min)
6. Pitfalls & troubleshooting (10 min)
7. Where to go next + ownership (10 min)

---

## 1. Repo layout & branches

Four repos + one worktree, all under `swh-environment/`:

```
swh-loader-git/                     feat/gix-phase1-fetch   (gix engine, Phase A/B)
swh-loader-git-dispatch/ (worktree) feat/size-dispatch-safety-net
swh-storage/                        feat/content-add-concurrent  (REC-L4)
swh-scheduler/                      feat/size-based-dispatch-v1
swh-lister/                         feat/github-size-metadata
```

See [LEARNING_PATH.md](LEARNING_PATH.md) for the full map.

---

## 2. Build the Rust engine

> TODO: `maturin develop` walkthrough; the stale-`.so` gotcha and the shim fix.

---

## 3. Architecture

> TODO: the four parallel changes, the direct-tree inflater, the REC-L4 path, size-dispatch.

---

## 4. Live demo

> TODO: drive through [DEMO_SCRIPT.md](DEMO_SCRIPT.md) — bench a mid-sized repo
> (django works well, ~13 s gix vs 7.5 min dulwich) and show the proposal table.

---

## 5. Size-dispatch + safety-net

> TODO: show the scheduler filter, the three Celery task classes, and how the
> loader's size check re-queues a misrouted visit.

---

## 6. Pitfalls

> TODO: stale `.so`, missing `.idx`, channel starvation, safety-net loops.
> Pull from [LEARNING_PATH.md — troubleshooting](LEARNING_PATH.md#troubleshooting-quick-reference).

---

## 7. Ownership & next steps

> TODO: who reviews what, escalation boundary, how to add new metrics,
> canary plan for REC-L4.

---

## References

- [PROPOSAL-staging-rollout.md](../PROPOSAL-staging-rollout.md)
- [LEARNING_PATH.md](LEARNING_PATH.md)
- [DEMO_SCRIPT.md](DEMO_SCRIPT.md)
- [impl-log-phase-a.md](../impl-log-phase-a.md)
- [impl-log-size-dispatch.md](../impl-log-size-dispatch.md)
