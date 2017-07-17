PYMODULES := $(shell bin/ls-py-modules)
DBMODULES := swh-storage swh-archiver swh-scheduler

all:

.PHONY: doc
doc:
	make -C doc/

check: $(patsubst %,check/%,$(PYMODULES))
distclean: $(patsubst %,distclean/%,$(PYMODULES))
test: $(patsubst %,test/%,$(PYMODULES))

check/%:
	make -C $* check
distclean/%:
	make -C $* distclean
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
