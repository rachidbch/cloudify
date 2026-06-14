#!/usr/bin/env bash
# pkg/hermes/verify.sh — verification hook for the hermes package.
# Sourced in a clean subshell by _cloudify_run_verify. Reads only env + on-disk
# state. No recipe-local vars, no hardcoded endpoints.
pkg_verify() {
    command -v hermes >/dev/null 2>&1 || return 1
}
