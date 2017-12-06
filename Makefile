PYMODULES := $(shell bin/ls-py-modules)
DB_MODULES = swh-storage swh-archiver swh-scheduler swh-indexer
DOC_MODULE = swh-docs

all:

# TODO this is too close to "docs" below, but is meant to go away anyhow, when
# the dependency graph stuff will migrate to the swh-docs/ module
.PHONY: doc
doc:
	make -C doc/

check: $(patsubst %,check/%,$(PYMODULES))
distclean: $(patsubst %,distclean/%,$(PYMODULES))
test: $(patsubst %,test/%,$(PYMODULES))

docs: $(patsubst %,docs/%,$(filter-out $(DOC_MODULE),$(PYMODULES)))
docs-apidoc: $(patsubst %,docs-apidoc/%,$(filter-out $(DOC_MODULE),$(PYMODULES)))
docs-clean: $(patsubst %,docs-clean/%,$(filter-out $(DOC_MODULE),$(PYMODULES)))

check/%:
	make -C $* check
distclean/%:
	make -C $* distclean
test/%:
	make -C $* test

docs/%:
	make -C $*/docs
docs-apidoc/%:
	make -C $*/docs apidoc
docs-clean/%:
	make -C $*/docs clean

.PHONY: rebuild-testdata rebuild-storage-testdata
rebuild-testdata: rebuild-storage-testdata
rebuild-storage-testdata:
	for dbmodule in $(DB_MODULES); do \
		make -C $$dbmodule/sql/ distclean filldb; \
	done
	make -C swh-storage-testdata distclean dumpdb

update:
	make -C swh-storage-testdata distclean
	git pull
	mr up

clean:
	make -C doc/ clean
