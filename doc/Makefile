pyreqs = $(wildcard ../*/requirements.txt)
depgraphs = deps-all.pdf deps-swh.pdf deps-external.pdf
mkgraph = bin/py-depgraph

all: depgraphs

.PHONY: depgraphs
depgraphs: $(depgraphs)

deps-all.dot: ../$(mkgraph) $(pyreqs)
	cd .. ; $(mkgraph) > $(CURDIR)/$@

deps-swh.dot: ../$(mkgraph) $(pyreqs)
	cd .. ; $(mkgraph) --no-external > $(CURDIR)/$@

deps-external.dot: ../$(mkgraph) $(pyreqs)
	cd .. ; $(mkgraph) --no-internal > $(CURDIR)/$@

%.pdf: %.dot
	dot -T pdf $< > $@

clean:
	-rm -f $(depgraphs) $(patsubst %.pdf,%.dot,$(depgraphs))
