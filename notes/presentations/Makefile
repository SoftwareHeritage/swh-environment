# Makefile for the SWH ingestion-pipeline rehaul presentation.
#
# Three primary targets:
#   make preview   — live reveal-md preview, auto-reload on save
#   make pdf       — export INGESTION_REHAUL.pdf via reveal-md headless
#   make static    — export a self-contained HTML site under dist/
#
# The deck source is INGESTION_REHAUL.md (HedgeDoc / reveal-md format).
#
# Prerequisites: see README.md.

DECK         ?= INGESTION_REHAUL
SOURCE        := $(DECK).md
DIST          := dist
PDF           := $(DECK).pdf
PORT         ?= 1948

REVEAL_FLAGS := --css assets/style.css --highlight-theme github
PRINT_FLAGS  := $(REVEAL_FLAGS) --print-size A4-landscape
STATIC_FLAGS := $(REVEAL_FLAGS) --static $(DIST)

.PHONY: help preview pdf static clean check-deps watch

help:
	@echo "Targets:"
	@echo "  preview      — live reveal-md preview, auto-reload on save (default $(DECK))"
	@echo "  pdf          — export $(PDF) via reveal-md headless print"
	@echo "  static       — export self-contained HTML site under $(DIST)/"
	@echo "  clean        — remove $(DIST)/ and *.pdf"
	@echo "  check-deps   — verify reveal-md is installed and on PATH"
	@echo ""
	@echo "Variables:"
	@echo "  DECK=$(DECK)     (override DECK=<name> to render a different .md)"
	@echo "  PORT=$(PORT)            (override for the preview server)"

check-deps:
	@command -v reveal-md >/dev/null 2>&1 || { \
	  echo "ERROR: reveal-md not installed. See README.md §Prerequisites."; \
	  echo "Quick install: npm install -g reveal-md"; exit 1; }
	@echo "reveal-md $$(reveal-md --version) found at $$(command -v reveal-md)"

preview: check-deps
	reveal-md $(SOURCE) --watch --port $(PORT) $(REVEAL_FLAGS)

watch: preview

pdf: check-deps $(PDF)

$(PDF): $(SOURCE) figures/*.png
	reveal-md $(SOURCE) --print $(PDF) $(PRINT_FLAGS)
	@echo "Wrote $(PDF)"

static: check-deps $(DIST)
	@echo "Static site at $(DIST)/. Open $(DIST)/index.html."

$(DIST): $(SOURCE) figures/*.png
	rm -rf $(DIST)
	reveal-md $(SOURCE) $(STATIC_FLAGS)

clean:
	rm -rf $(DIST) *.pdf
