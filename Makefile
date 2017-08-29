PYMODULES := $(shell bin/ls-py-modules)
DBMODULES := swh-storage swh-archiver swh-scheduler

all:

# TODO this is too close to "docs" below, but is meant to go away anyhow, when
# the dependency graph stuff will migrate to the swh-docs/ module
.PHONY: doc
doc:
	make -C doc/

check: $(patsubst %,check/%,$(PYMODULES))
distclean: $(patsubst %,distclean/%,$(PYMODULES))
test: $(patsubst %,test/%,$(PYMODULES))
docs: $(patsubst %,docs/%,$(PYMODULES))
clean-docs: $(patsubst %,clean-docs/%,$(PYMODULES))

check/%:
	make -C $* check
distclean/%:
	make -C $* distclean
docs/%:
	make -C $*/docs
clean-docs/%:
	make -C $*/docs clean
test/%:
	make -C $* test

.PHONY: rebuild-testdata rebuild-storage-testdata
rebuild-testdata: rebuild-storage-testdata
rebuild-storage-testdata:
	for dbmodule in $(DBMODULES); do \
		make -C $$dbmodule/sql/ distclean filldb; \
	done
	make -C swh-storage-testdata distclean dumpdb

update:
	make -C swh-storage-testdata distclean
	git pull
	mr up

clean:
	make -C doc/ clean
