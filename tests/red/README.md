# tests/red - the executable v2 contract proofs

This directory holds tests that state a contract, in a shape the default suite
does not run: neither `task test-unit` (`bats --recursive tests/unit/`) nor
`task test` (`bats tests/unit/ tests/integration/recipe-discovery.bats`) globs
this directory, so a contract gap can never break the suite. Run one explicitly
inside the container:

    ivps exec cloudai:cloudify -- bash -c 'cd /root/cloudify && bats -T --show-output-of-passing-tests tests/red/state-v2-duplicate-resolution.bats'

`tests/red/state-v2-duplicate-resolution.bats` states two contracts and both are
green today. Its first case started red: one dispatch resolved a declared value
twice, the forwarding walker built the payload, the registry writer walked the
same name with a separate implementation, and the run snapshot read the
deployment store alone, so the three records disagreed. It turned green with the
Phase 2 dispatch context, which resolves a name once and feeds all three. Its
second case started red because an application input mapped onto two package
variable names had no implementation at all; it turned green with the Phase 3
canonical runbook inputs and `map:` declarations. Each case asserts its setup
first, so a failure here is a real regression of the contract, never a fixture
error.
