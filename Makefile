PYMODULES := $(shell bin/ls-py-modules)

all:

check: $(patsubst %,check/%,$(PYMODULES))
test: $(patsubst %,test/%,$(PYMODULES))

check/%:
	make -C $* check
test/%:
	make -C $* test
