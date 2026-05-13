# SWH ingestion-pipeline rehaul — team-facing presentation

This directory contains the leadership-facing slide deck for the SWH ingestion-pipeline rehaul work (git loader engine + Cassandra `content_add` write path), plus the tooling to preview and export it.

## Contents

| File | Purpose |
|---|---|
| `INGESTION_REHAUL.md` | **The deck** — tech-leadership overview (~30–45 min). Audience: SWH tech leadership. Problem → diagnosis → measurement → solution → rollout plan, covering both the loader engine and the storage write path. |
| `figures/` | Charts and diagrams referenced by the deck (PNG). |
| `assets/style.css` | Theme overrides — tighter font sizes for data-dense slides. |
| `Makefile` | Drives the reveal-md preview / PDF export / static-site build. |

Engineer-facing material lives elsewhere in the tree: `notes/git-loader-rehaul/test-rig/` for hands-on reproduction, `notes/git-loader-rehaul/HANDOFF.md` + `HANDOFF-MR-PLAN.md` for per-MR walkthroughs and reviewer hours.

## Prerequisites

The deck uses [reveal-md](https://github.com/webpro/reveal-md) (reveal.js with a Markdown front-end). Install via npm:

```bash
npm install -g reveal-md
# verify
reveal-md --version
```

Node 18+ is required. Mermaid diagrams (used in the pipeline-flow slide) render in-browser; no extra install needed.

`make check-deps` from this directory confirms reveal-md is on PATH.

## Live preview (recommended for editing)

```bash
make preview
```

Opens a local web server on http://localhost:1948 with auto-reload. Edit `INGESTION_REHAUL.md`, save, the browser refreshes.

Override the port if 1948 is busy:

```bash
make preview PORT=8080
```

### Keyboard shortcuts in the preview

- `s` — open the **speaker view** window (notes + next-slide preview + timer). The `Note: ...` paragraphs at the bottom of each slide section show here.
- `f` — fullscreen.
- `o` — overview / slide-grid view.
- `Esc` — exit overview.
- `b` — black out the screen (when projecting and pausing).

## PDF export

```bash
make pdf
# Wrote INGESTION_REHAUL.pdf
```

Uses reveal-md's headless Chrome to print to PDF in A4 landscape. The PDF is a flat per-slide rendering — speaker notes are NOT included. Useful for email distribution / leave-behinds.

## Static HTML site

```bash
make static
```

Renders to `dist/` as a self-contained HTML site (no Node server required to serve). Useful for archiving or hosting behind a static-file server. Open `dist/index.html` in a browser.

## Cleanup

```bash
make clean
# removes dist/ and *.pdf
```

## Editing the deck

The deck source is plain Markdown with a YAML front-matter block at the top (reveal-md / HedgeDoc format). Conventions:

- **Slide separators**: `---` on its own line = horizontal slide break. `----` (four dashes) = vertical stack within a section.
- **Speaker notes**: a paragraph beginning with `Note:` becomes presenter-only notes (visible in the `s` speaker view).
- **Mermaid diagrams**: fenced code blocks with `mermaid` as the language. Render automatically.
- **Images**: relative paths under `figures/` — e.g., `<img src="figures/revision_growth.png" />`.
- **HTML in Markdown**: inline `<table>`, `<div>` etc. are fine; reveal-md renders them through.

To add a slide, insert `---` and write the next section. To split an over-long slide vertically, use `----` between sub-sections within the same horizontal slide.

### Speaker notes

Every substantive slide should carry a `Note: ...` paragraph at the bottom — read by the presenter via the `s` keyboard shortcut. Keep notes concise but informative; this is where the framing and the rebuttal-anticipation live.

## Hosting on HedgeDoc

The deck's front matter is HedgeDoc-compatible (`type: slide`, `slideOptions`, etc.). To host on a HedgeDoc instance:

1. Paste `INGESTION_REHAUL.md` into a new HedgeDoc note.
2. Click **View → Slide mode** (Reveal.js renderer).

Speaker view via `s` works the same way.

## Where the figures come from

`figures/revision_growth.png` is the headline "ingestion cliff" chart from the audit. Source data + regeneration script: see `notes/bench-dulwich-limitations/` and `report/ANALYSIS-git-loader-modernization.md` §1.

To swap a figure, replace the PNG in `figures/` and reload the preview.

## Cross-references from the deck

The deck links to a number of in-repo documents:

| Reference | Location |
|---|---|
| Executive summary + reading order | `notes/git-loader-rehaul/EXECUTIVE-SUMMARY.md` |
| Current state + branch table | `notes/git-loader-rehaul/HANDOFF.md` |
| Per-MR detail + reviewer hours | `notes/git-loader-rehaul/HANDOFF-MR-PLAN.md` |
| concurrent content_add architectural issue | `notes/git-loader-rehaul/ISSUE-concurrent-content-add.md` |
| concurrent content_add execution plan | `notes/git-loader-rehaul/PLAN-concurrent-content-add.md` |
| Full analysis (L1-L7 root causes) | `report/ANALYSIS-git-loader-modernization.md` |
| Pack-loading algorithms walkthrough | `report/ALGORITHMS-pack-loading.md` |
| Staging rollout proposal | `notes/PROPOSAL-staging-rollout.md` |
| Forward-looking: AdAstra | `notes/git-loader-rehaul/EXPLORE-adastra-direct-ingestion.md` |
| Forward-looking: github-ingestion | `notes/git-loader-rehaul/EXPLORE-github-ingestion-migration.md` |
| Live MRs | gitlab.softwareheritage.org/swh/devel/swh-loader-git !217-!220 |

Links in the deck use relative paths (e.g., `../git-loader-rehaul/HANDOFF.md`). When presenting from a local checkout, these resolve naturally; when hosting on HedgeDoc or a static site, replace with absolute GitLab URLs.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `reveal-md: command not found` | `npm install -g reveal-md` needed (or add `~/.npm-global/bin` to PATH). |
| Mermaid diagrams show as code blocks | Network blocked from CDN — reveal-md fetches Mermaid client-side. Test in a browser with internet access. |
| Speaker view shows blank notes | Make sure the `Note:` paragraph is on its own paragraph at the bottom of the slide, no markdown formatting prefix. |
| PDF export is huge / slow | Normal — Chrome headless takes ~30-60 s for 30 slides. |
| Figures missing in PDF | Confirm `figures/*.png` is committed and the deck's `<img src=...>` paths match (relative to the .md file). |
| Mermaid graph has stale layout in PDF | Use `make pdf` again — headless Chrome sometimes catches the diagram mid-render on first try. |
