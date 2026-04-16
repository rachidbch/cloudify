CONTAINER   := cloudai:cloudify
REPO_DIR    := /root/cloudify

.PHONY: setup-container sync test test-unit test-integration lint itest-base itest-reset itest-clean

setup-container:
	ivps exec $(CONTAINER) -- bash -c 'apt-get update -qq && apt-get install -y -qq bats bats-assert bats-support bats-file'

sync:
	incus file push -r /home/rbc/PROJECTS/PROD/cloudify/lib       cloudai:cloudify/root/cloudify/ --create-dirs
	incus file push -r /home/rbc/PROJECTS/PROD/cloudify/tests     cloudai:cloudify/root/cloudify/ --create-dirs
	incus file push -r /home/rbc/PROJECTS/PROD/cloudify/pkg       cloudai:cloudify/root/cloudify/ --create-dirs
	incus file push /home/rbc/PROJECTS/PROD/cloudify/cloudify     cloudai:cloudify/root/cloudify/cloudify
	incus file push /home/rbc/PROJECTS/PROD/cloudify/Makefile     cloudai:cloudify/root/cloudify/Makefile

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
	@incus snapshot list $(CONTAINER) --format csv 2>/dev/null | grep -q itest-base && \
		echo "Snapshot itest-base already exists. Run 'make itest-clean && make itest-base' to recreate." || \
		(ssh root@cloudify 'DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq bats bats-assert bats-support bats-file' && \
		incus snapshot create $(CONTAINER) itest-base --no-expiry && echo "Snapshot itest-base created.")

itest-reset:
	incus snapshot restore $(CONTAINER) itest-base

itest-clean:
	incus snapshot delete $(CONTAINER) itest-base

lint: sync
	ivps exec $(CONTAINER) -- bash -c 'cd $(REPO_DIR) && shellcheck -x lib/*.sh cloudify'
