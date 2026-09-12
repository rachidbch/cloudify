# State model implementation (ADR-021)

Goal: cloudify and ivps match `REDESIGN.md`, the bats suite passes on `cloudai:cloudify`, and the
docs and skills speak the new language. Concepts: `GLOSSARY.md`.

## Gate, before any change under `lib/` or `ivps`

- [ ] Description artifact: how value forwarding works end to end, declaration to `.remote-vars`,
      router dispatch, payload via `declare -f` and the `envsubst` allow-list, what the shadows
      intercept; and how the runbook engine runs a step, what it exports, and where it writes.
- [ ] A plan per change below arguing non-breakage against those mechanisms.
- [ ] Explicit consent from Rachid.

## Phase 1, docs and skills, no code

- [ ] README: targets, values, state records, the read surface, the teardown contract.
- [ ] Skills `cloudify` and `cloudify-dev`: application instead of deployment, state record
      language, the phase attribute, the seed.
- [ ] `runbooks/README.md`: the application file shape, phases, and the binding rules.

## Phase 2, ivps

- [ ] node: immutable `id`, provider as where it lives, `adopted` as the origin flag, declared
      spec, six address lists used in overlay, internal, public order. Every reader updated.
- [ ] dispatch and the deletion origin test move to provider id.
- [ ] instance: an `id`; engine: a `name`.
- [ ] the event log area, and ivps writing its own events in the shared shape.
- [ ] current-only state: deleting a node removes its state, renaming a node moves its folder.
- [ ] an external host's state record carries the ssh host key fingerprint.

## Phase 3, cloudify

- [ ] the value walk: step environment, then the package state record, then the defaults. The
      per-deployment defaults file goes.
- [ ] the application: folder shape, front matter, the phase attribute, the four legs.
- [ ] the run state record replaces the per-run snapshot; the event writer.
- [ ] the state record writer: drop `var.*`, write the new shape.
- [ ] the read surface: the four commands.

## Phase 4, tests

- [ ] bats per module for what each phase changed.
- [ ] the E2E runbook on disposable infra, ending with the human gate.

Every phase ends with the relevant bats scope, and the full suite at each phase boundary.
