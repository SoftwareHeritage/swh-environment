# Pre-read email (engineers) — copy-paste

**Subject:** Before the git-loader rehaul session — 15 min read

Hi,

Ahead of the hands-on session, please skim these three pages (no need to
build or run anything yet):

1. **Map of the four repos + worktree** —
   [notes/presentations/LEARNING_PATH.md](LEARNING_PATH.md)
   Focus on the *Who you are → where to start* table and the
   *Repository map*.

2. **The proposal (sections 1–3)** —
   [notes/PROPOSAL-staging-rollout.md](../PROPOSAL-staging-rollout.md)
   Why we are doing this, the four parallel changes, and the rollout
   phases.

3. **The benchmark results** —
   [notes/PROPOSAL-staging-rollout.md §6.2](../PROPOSAL-staging-rollout.md)
   The head-to-head table — context for the session.

In the session we walk through the Rust engine build, architecture, a
live benchmark (django — ~13 s gix vs ~7.5 min dulwich), the size-dispatch
path, and the open questions we need the team to decide.

Thanks,

---

**Ownership reminder.**
The Rust engine (`swh-loader-git/gix-py/`) is its own crate. The Python
loader, scheduler, and lister changes follow each repo's normal SWH
review process. REC-L4 lives in swh-storage and is config-gated off by
default — it does not ship turned on.
