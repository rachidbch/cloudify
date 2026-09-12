# tests/red - deliberately failing proofs

This directory holds red tests that state a contract the code does not
implement yet: a failing test here is expected evidence, not a broken build.
Neither `task test-unit` (`bats --recursive tests/unit/`) nor `task test`
(`bats tests/unit/ tests/integration/recipe-discovery.bats`) globs this
directory, so the default suite stays green. Run one explicitly inside the
container:

    ivps exec cloudai:cloudify -- bash -c 'cd /root/cloudify && bats -T --show-output-of-passing-tests tests/red/state-v2-duplicate-resolution.bats'

`tests/red/state-v2-duplicate-resolution.bats` fails today because one dispatch
resolves a declared value twice: the forwarding walker builds the payload, the
registry writer walks the same name with a separate implementation, and the run
snapshot reads the deployment store alone, so the three records disagree
(registry vs snapshot). Its second case fails because an application input
mapped onto two package variable names has no implementation at all. Each case
asserts its setup first, so the observed failure is the intended contract gap,
never a fixture error.
