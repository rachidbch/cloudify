CONTAINER   := cloudai:cloudify
REPO_DIR    := /root/cloudify
LOCAL_DIR   := $(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))

.PHONY: setup-container sync test test-unit test-integration lint itest-base itest-reset itest-clean

setup-container:
	ivps exec $(CONTAINER) -- bash -c 'apt-get update -qq && apt-get install -y -qq bats bats-assert bats-support bats-file'

sync:
	ivps push $(CONTAINER) $(LOCAL_DIR)/lib $(REPO_DIR)/
	ivps push $(CONTAINER) $(LOCAL_DIR)/tests $(REPO_DIR)/
	ivps push $(CONTAINER) $(LOCAL_DIR)/pkg $(REPO_DIR)/
	ivps push $(CONTAINER) $(LOCAL_DIR)/cloudify $(REPO_DIR)/
	ivps push $(CONTAINER) $(LOCAL_DIR)/Makefile $(REPO_DIR)/

test: sync
	ivps exec $(CONTAINER) -- bash -c 'cd $(REPO_DIR) && bats tests/unit/ tests/integration/recipe-discovery.bats'
	bash tests/run-integration.sh

test-unit: sync
	ivps exec $(CONTAINER) -- bash -c 'cd $(REPO_DIR) && bats --recursive tests/unit/'

test-integration:
	bash tests/run-integration.sh

test-integration-%:
	bash tests/run-integration.sh "tests/integration/package-$(subst test-integration-,,$@).bats"

itest-base:
	ivps exec $(CONTAINER) -- bash -c 'apt-get update -qq && apt-get install -y -qq bats bats-assert bats-support bats-file'
	ivps snapshot $(CONTAINER) itest-base

itest-reset:
	ivps snapshot $(CONTAINER) itest-base --restore

itest-clean:
	ivps snapshot $(CONTAINER) itest-base --delete

lint: sync
	ivps exec $(CONTAINER) -- bash -c 'cd $(REPO_DIR) && shellcheck -x lib/*.sh cloudify'
