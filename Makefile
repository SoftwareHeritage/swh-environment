PYMODULES := $(shell bin/ls-py-modules)

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
	make -C swh-storage/sql/archiver distclean filldb
	make -C swh-storage/sql/ distclean filldb
	make -C swh-storage-testdata distclean dumpdb

update:
	make -C swh-storage-testdata distclean
	git pull
	mr up

clean:
	make -C doc/ clean
