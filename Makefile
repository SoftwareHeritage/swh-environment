PYMODULES := $(shell bin/ls-py-modules)
DB_MODULES = swh-storage swh-archiver swh-scheduler swh-indexer swh-scheduler/sql/updater
DOC_MODULE = swh-docs

all:

# TODO this is too close to "docs" below, but is meant to go away anyhow, when
# the dependency graph stuff will migrate to the swh-docs/ module
.PHONY: doc
doc:
	make -C doc/

check: $(patsubst %,check/%,$(PYMODULES))
typecheck: $(patsubst %,typecheck/%,$(PYMODULES))
distclean: $(patsubst %,distclean/%,$(PYMODULES))
test: $(patsubst %,test/%,$(PYMODULES))

docs: $(patsubst %,docs/%,$(filter-out $(DOC_MODULE),$(PYMODULES)))
docs-assets: $(patsubst %,docs-assets/%,$(filter-out $(DOC_MODULE),$(PYMODULES)))
docs-apidoc: $(patsubst %,docs-apidoc/%,$(filter-out $(DOC_MODULE),$(PYMODULES)))
docs-clean: $(patsubst %,docs-clean/%,$(filter-out $(DOC_MODULE),$(PYMODULES)))

check/%:
	make -C $* check
typecheck/%:
	make -C $* typecheck
distclean/%:
	make -C $* distclean
test/%:
	make -C $* test

docs/%:
	if test -e $*/docs/Makefile; then make -I swh-docs -C $*/docs; fi
docs-assets/%:
	if test -e $*/docs/Makefile; then make -I swh-docs -C $*/docs assets; fi
docs-apidoc/%:
	if test -e $*/docs/Makefile; then make -I swh-docs -C $*/docs apidoc; fi
docs-clean/%:
	if test -e $*/docs/Makefile; then make -I swh-docs -C $*/docs clean; fi

.PHONY: update clean
update:
	git pull
	mr up

clean:
	make -C doc/ clean

.PHONY: check-staged
check-staged:
	make -C docker/ check-staged
