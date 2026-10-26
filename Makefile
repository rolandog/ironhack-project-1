# Makefile -- build the C4 diagrams (aasvg) that README.md embeds
# '>' is the recipe prefix, so a pasted file cannot break on tab conversion
#.RECIPEPREFIX := >
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DELETE_ON_ERROR:
.SUFFIXES:

AASVG      ?= aasvg
AASVG_OPTS ?= --backdrop --spaces=2
DIAGDIR    := docs/diagrams
SRC        := $(wildcard $(DIAGDIR)/*.txt)
SVG        := $(SRC:.txt=.svg)

.PHONY: all diagrams check clean help
all: diagrams

help:
	@printf '%s\n' 'targets:' \
	  '  diagrams  build docs/diagrams/*.svg from *.txt when a source is newer (default)' \
	  '  check     rebuild, then fail if any svg differs from what git has (for CI)' \
	  '  clean     delete the generated svg files' \
	  'variables: AASVG (default aasvg), AASVG_OPTS (default: compatible backdrop spaces=2)'

diagrams: $(SVG)

# Makefile is a prerequisite so that changing AASVG_OPTS rebuilds everything
$(DIAGDIR)/%.svg: $(DIAGDIR)/%.txt Makefile
	@command -v '$(AASVG)' >/dev/null || { echo 'make: $(AASVG) not found; run: npm install -g --prefix ~/.local aasvg' >&2; exit 1; }
	$(AASVG) $(AASVG_OPTS) < $< > $@.tmp || { rm -f -- $@.tmp; exit 1; }
	mv -f -- $@.tmp $@

check: diagrams
	@out=$$(git status --porcelain -- $(DIAGDIR)); \
	  if [ -n "$$out" ]; then printf '%s\n' "$$out" >&2; echo 'make: diagrams out of date; run make and commit' >&2; exit 1; fi; \
	  echo 'diagrams up to date'

clean:
	rm -f -- $(SVG) $(addsuffix .tmp,$(SVG))

