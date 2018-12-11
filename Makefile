ALL_DOCKERFILES := $(wildcard dockerfiles/Dockerfile-*)
ALL_BUILD_TARGETS := $(subst dockerfiles/Dockerfile-,build-,$(ALL_DOCKERFILES))

all: $(ALL_BUILD_TARGETS)

run: $(ALL_BUILD_TARGETS)
	# Discard existing volumes
	docker-compose down --volumes
	# Runs containers in the foreground
	docker-compose up

build-%: dockerfiles/Dockerfile-%
	@echo ""
	@echo "+----------------------------------------------------+"
	@printf '| %-50s |\n' "Building $(subst build-,,$@)"
	@echo "+----------------------------------------------------+"
	@echo ""
	docker build -f $< -t $(subst build-,,$@) $(BUILD_CONTEXT) ..
