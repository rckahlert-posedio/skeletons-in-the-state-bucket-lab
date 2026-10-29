# Two kinds of experiments (see README):
#   make            the core experiments: shell tools only, no network, no services
#   make backend    the backend experiments: need a local S3-compatible endpoint,
#                   skipped (not failed) when it isn't there
#   make e03 / b01  a single experiment
# Each prints CLAIM/OBSERVE lines and writes .work/<experiment>/results.txt; a
# CLAIM SURPRISE makes it exit non-zero. Exit 77 means SKIPPED (a missing optional
# prerequisite, e.g. a too-old terraform for e07) and does not fail the run.
EXPERIMENTS := $(sort $(notdir $(wildcard experiments/e*)))
BACKEND     := $(sort $(notdir $(wildcard backend-experiments/b*)))
short        = $(foreach e,$(1),$(firstword $(subst -, ,$(e))))
SHORT        := $(call short,$(EXPERIMENTS))
BACKEND_SHORT:= $(call short,$(BACKEND))

.PHONY: all backend clean versions $(SHORT) $(BACKEND_SHORT)
all: versions $(SHORT)
backend: versions $(BACKEND_SHORT)

versions:
	@terragrunt --version; terraform version | head -1

$(SHORT):
	@./experiments/$(filter $@-%,$(EXPERIMENTS))/run.sh || [ $$? -eq 77 ]

$(BACKEND_SHORT):
	@./backend-experiments/$(filter $@-%,$(BACKEND))/run.sh || [ $$? -eq 77 ]

clean:
	rm -rf .work
