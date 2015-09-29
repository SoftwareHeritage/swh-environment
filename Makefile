PYMODULES := $(shell bin/ls-py-modules)

all:

check: $(patsubst %,check/%,$(PYMODULES))
distclean: $(patsubst %,distclean/%,$(PYMODULES))
test: $(patsubst %,test/%,$(PYMODULES))

check/%:
	make -C $* check
distclean/%:
	make -C $* distclean
test/%:
	make -C $* test
