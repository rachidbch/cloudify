#!/usr/bin/env bats
# Registry writer retirement (state-model-v2 4.3): the runtime no longer
# writes registry records - the deployment inventory built from result lines
# replaces them. The storage layer survives read-only: `cloudify state
# migrate-registry` (4.7) consumes legacy records, `deployment delete` sweeps
# them. The legacy record samples live in tests/fixtures/legacy-registry/.

source tests/helpers/common.bash

setup() {
    setup_test_env

    export CLOUDIFY_CREDENTIALS_DIR="$CLOUDIFY_TMP/creds"
    mkdir -p "$CLOUDIFY_CREDENTIALS_DIR"

    source lib/colors.sh && cloudify_setup_colors
    source lib/utils.sh
    source lib/os.sh
    source lib/pkg-config.sh
    source lib/package-api.sh
    source lib/registry.sh

    DEP="legacy-dep"
    NODE="cloudai"
    HOST="cloudify"
    PKG="legacy-pkg"
}

teardown() {
    teardown_test_env
}

@test "retired: the runtime writer and its renderer are gone" {
    [ -z "$(type -t _cloudify_registry_record_bg)" ]
    [ -z "$(type -t cloudify_registry_record_apply)" ]
    [ -z "$(type -t cloudify_registry_record_build)" ]
    [ -z "$(type -t _cloudify_registry_field)" ]
    [ -z "$(type -t _cloudify_registry_declared_names)" ]
    [ -z "$(type -t _cloudify_registry_context_raw)" ]
    [ -z "$(type -t _cloudify_registry_now)" ]
}
