# Cloudify schemas v1

Status: Phase 1 freeze of `plans/state-model-v2.md` (tasks 1.3, 1.4, and 1.5).
Design authority: `REDESIGN.md`.
Decision: `ADR.md` ADR-022.
These files are the contract for the v2 machine-owned artifacts.
No writer in `lib/` produces them yet, so nothing in this directory changes runtime behavior.

## Files

- `identity.md` - normative application, flavor, deployment name, package instance, and step ID rules.
- `deployment-manifest.schema.json` - current state for one deployment.
- `package-state.schema.json` - physical package state and active claims for one host, package, and package instance.
- `run.schema.json` - one execution of selected application phases.
- `event.schema.json` - one immutable observed attempt or state transition.
- `fixtures/<artifact>/valid/*.json` and `fixtures/<artifact>/invalid/*.json` - accepted and rejected instances per artifact.
- `migration-fixtures/` - copies of the current on-disk formats that the migration must be able to read.
- `lib/schema-check.jq` - bounded JSON Schema 2020-12 subset evaluator used with `jq`.
- `validate.sh` - local validator plus the inventory-only migration report.

## schema_version

Every machine-owned artifact requires `schema_version` and constrains it to `1`.
The field is required, not optional, so a reader never has to guess an unversioned shape.
`REDESIGN.md` requires a version from the first release, and there is no unversioned v2 predecessor.

## Field lists per artifact

`deployment-manifest.schema.json`: `schema_version`, `application`, `flavor`, `deployment`, `application_commit`, `development_override`, `status` (`applying`, `active`, `degraded`), `created_at`, `bindings` (per slot: `address`, `node`, `instance`, `ssh_host`), `last_run_id`, `last_event_id`.
Applied package values are deliberately absent, and `additionalProperties: false` makes an accidental `applied_values` field a validation failure.

`package-state.schema.json`: `schema_version`, `host`, `host_key`, `package`, `package_instance`, `revision`, `applied`, `last_attempt`, `health`, `claims`.
`applied` holds `package_version`, `application_commit`, `at`, `event_id`, and `values`.
`last_attempt` holds `phase`, `outcome`, `at`, `event_id`, and `requested`.
`health` holds `status`, `checked_at`, and `event_id`.
Each claim holds `application`, `flavor`, `deployment`, `step_id`, `claimed_at`, `run_id`, `event_id`, and `values`.
Each value entry holds `secret` (the explicit declaration), `declaration` (`explicit`, `legacy-heuristic`, `none`), `source_form`, `reference`, `digest`, and `redacted`.

`run.schema.json`: `schema_version`, `run_id`, `application`, `flavor`, `deployment`, `application_commit`, `development_override`, `phases`, `status`, `started_at`, `ended_at`, `writer`, `interrupted`.
No resolved value and no automatic step output exists in a run record.
`writer` holds `host`, `boot_id`, `pid`, and `process_start_ticks`.
`interrupted` holds `at` and `reason` (`writer-process-gone`, `writer-boot-changed`).

`event.schema.json`: `schema_version`, `event_id`, `at`, `tool`, `writer`, `run_id`, `step_id`, `application`, `flavor`, `deployment`, `application_commit`, `subject`, `phase`, `command_kind`, `values`, `outcome`, `state`, and an optional `log_reference`.
`subject` holds `kind` (`package` or `deployment`), `host`, `host_key`, `package`, and `package_instance`.
`values` maps a value name to `source`, `secret`, `declaration`, `reference`, and `digest` and carries no plaintext form at all.
`outcome` holds `exit_status` and a `summary` bounded to 512 characters without a newline.
`state` holds `previous_revision` and `resulting_revision`.
No `stdout`, `stderr`, rendered payload, or literal secret field exists, and `additionalProperties: false` makes one a validation failure.

## Artifact to current-format mapping

`~/.config/cloudify/deployments/<id>/config.yaml` becomes `<config-root>/deployments/<application>/<flavor>/<deployment>/values.yaml`.
Each `KEY: value` line is one deployment input, and the current `@base64:`, `@@`, and `@<backend>:` encodings carry over as the value's source form.

`~/.config/cloudify/deployments/<id>/runs/<UTC>.yaml` becomes the run record of `run.schema.json` for the same execution, and its `target.*` lines are the only current source of manifest bindings.
The run snapshot remains the replay source and is not deleted by migration.

`<bucket>/deployments/<id>/pkgs/<pkg>/config.yaml` becomes `<host-state-root>/cloudify/packages/<pkg>/<package_instance>/state.json` following `package-state.schema.json`.
The bucket is `ivps node path <node>`, that path plus `<instance>`, or `<config-root>/registry/hosts/<ssh_host>`.
The `applied` section comes from a record with `status: installed` or `status: configured`.
A record with `status: removed` becomes migration history and never a claim.

The deployment manifest has no current-format source: nothing on disk records a pinned commit, target bindings, lifecycle status, or run and event IDs today.

Events have no current-format source: the existing log at `/tmp/cloudify/logs/<timestamp>.log` contains raw command output and is never converted into events.

A `var.<NAME>` field is observation data for migration, never intent and never a claim by itself.

## Migration mapping rules for one stored value

A raw stored value that begins with `@<backend>:` is a secret reference: `secret: true`, `declaration: explicit`, `reference` and `source_form` both hold the reference string, `redacted: false`, `digest: null`.

A raw stored value whose name matches the heuristic (`TOKEN`, `KEY`, `PASSWORD`, `SECRET`) and that is not a reference is a literal secret: the migration computes `digest: sha256(<plaintext>)`, drops the plaintext, and writes `secret: true`, `declaration: legacy-heuristic`, `source_form: null`, `redacted: true`.

A raw stored value that begins with `@@` is an escaped literal and keeps its source form with `secret: false` unless the name heuristic applies.

Any other raw stored value is a non-secret literal: `secret: false`, `declaration: none`, `source_form: <raw>`, `redacted: false`.

The package instance is `default` for every existing record, because the current format has no instance key.

`installed_at` becomes `applied.at`, `version` becomes `applied.package_version`, and the single-string deployment ID becomes a claim only after the operator supplies the application and flavor explicitly.

## What cannot be derived from the current formats

1. The application and flavor of a single-string deployment ID, because the ID does not encode them and must never be split to guess.
2. The pinned application commit of an existing deployment, because nothing recorded a commit before manifests existed.
3. Target bindings for a deployment whose runs left no snapshot, because the newest snapshot is the only recorded source of `target.*`.
4. Writer identity, selected phases, run IDs, and event IDs of a past execution, because a snapshot has none of them and a missing record must not be invented.
5. The durable `host_key` of an external host, because the fallback bucket is keyed by the mutable SSH alias and the accepted host-key fingerprint is not recorded anywhere yet.
6. The secret classification of a stored value, because current declaration files carry no secret marker; the heuristic rule above is the only available signal.
7. Event history, because current logs carry raw output and are not event records.
8. `output.*` lines, because they were never replay inputs and `REDESIGN.md` forbids copying them into runs or events.

## Migration report contract

Command: `bash schemas/v1/validate.sh report [--config-dir DIR] [--nodes-dir DIR]`.
Defaults: `--config-dir` is `$CLOUDIFY_CREDENTIALS_DIR`, else `$XDG_CONFIG_HOME/cloudify`, else `~/.config/cloudify`; `--nodes-dir` is `$IVPS_CONFIG_DIR/nodes`, else `$XDG_CONFIG_HOME/ivps/nodes`, else `~/.config/ivps/nodes`.
It prints one physical line per item:
`deployment <id> dir=<path>`.
`  inputs <path>`.
`  input-key <NAME>`.
`  run <file> path=<path> runbook=<path>`.
`  run-target <file> <slot>`.
`  run-value <file> <NAME>`.
`  run-output <file> <name>`.
`record path=<path> bucket=<node|instance|external-host> deployment=<id> node=<name> instance=<name> package=<pkg> status=<status> version=<version>`.
`  record-var <NAME>`.
`summary deployments=<n> runs=<n> records=<n>`.
It prints a name, a path, or one whitelisted record metadata field (`status`, `version`, `deployment`, `node`, `instance`, `package`) and nothing else.
It never prints a `KEY: value` value, a `var.<NAME>` value, a snapshot `value.*` value, a target address, or an `output.*` value.
The `runbook=` field is the recorded runbook path, which is a path and not a value.
The report is read-only and writes no file, so it is safe to run against the live configuration.

## Validator command

`bash schemas/v1/validate.sh` from the repository root.
It requires only `jq`, creates no file, needs no container and no network, and exits 0 only when every valid fixture is accepted and every invalid fixture is rejected.
The four schema files are the only validity definition: `lib/schema-check.jq` evaluates a bounded JSON Schema subset against them, so a fixture cannot silently disagree with its schema.
The invalid fixtures cover failures that must happen before any mutation: a missing `schema_version`, an applied value inside a manifest, a plaintext literal secret in package state and in an event, a secret reference and a digest on the same value, a negative revision, a missing host key, a traversal component, an unbound target slot, a partial deployment tuple, a package subject without a host, teardown selected beside install, an interrupted run without classification, a writer without boot identity, a multi-line outcome summary, and a raw `stdout` field.
The default mode then runs the migration report over `migration-fixtures/` and fails when any committed placeholder value appears in its output.
The `jq` interpreter evaluates `$ref` alone and ignores sibling keywords, so every schema uses `$ref` without siblings.

## Fixture placeholders

Every secret-looking string in `fixtures/` and `migration-fixtures/` is an obvious placeholder such as `PLACEHOLDER_LITERAL_SECRET`, and every digest is the real sha256 of that placeholder.
No fixture, comment, or schema description contains a real credential.

## Open points

Points where `REDESIGN.md` implies a field but does not specify it, with the leanest shape chosen here.

1. No `kind` discriminator field exists in any artifact; the artifact is identified by its path and its required-field set, so no writer must invent an extra field.
2. Claims are an array of flat claim objects rather than a map keyed by a joined string, so the deployment tuple is never flattened; duplicate claims and revision monotonicity are state-check concerns, not JSON Schema constraints.
3. The durable host key spelling is `ivps:<node>`, `ivps:<node>:<instance>`, or `ssh-sha256:<fingerprint>`; `REDESIGN.md` requires fingerprint-keyed external state but names no string form.
4. Source labels are fixed to `caller`, `deployment`, `applied`, `application`, `package`, `global`, and `recipe`; `REDESIGN.md` calls the strongest source "step or caller environment", so `caller` covers both.
5. The manifest status enum is `applying`, `active`, `degraded`; `REDESIGN.md` says an interrupted run is classified from process identity on the next read without naming a manifest status, so the classification lives in the run record.
6. The run `interrupted` object with `at` and `reason` is chosen because `REDESIGN.md` requires an interrupted classification and a distinction between a live writer, a gone process, and a reboot, while naming no record.
7. Writer identity is `host`, `boot_id`, `pid`, and `process_start_ticks`; `REDESIGN.md` asks for "enough local process and boot information" without naming fields, and the boot ID plus the process start tick are what actually distinguish a reused PID from a live writer.
8. `phases` is capped at one entry when `teardown` is selected; this encodes the success criterion that a normal run cannot execute teardown steps, while `REDESIGN.md` does not say whether other phases may accompany teardown.
9. Event `tool` is const `cloudify`; `REDESIGN.md` permits a shared envelope version with ivps but defines neither the shared field set nor the ivps payload, so this schema fixes the Cloudify side only.
10. Event subject kinds are `package` and `deployment`; a runbook action event that touches no package uses the deployment subject and names its step in the top-level `step_id`.
11. Event value metadata has no source-form field at all, which makes a plaintext value structurally impossible in an event; `REDESIGN.md` lists names, sources, references or digests, and secret flags only.
12. The optional `log_reference` with `path` and `sha256` is the leanest shape for "referenced by path and digest where useful"; `REDESIGN.md` defines no such record.
13. `application_commit` is a 40-hex git commit and `development_override` is a separate boolean; `REDESIGN.md` requires an explicit development override that marks a deployment unreproducible but names neither the field nor the marker.
14. The manifest has no `updated_at`; `REDESIGN.md` states only a creation time, and `last_run_id` plus `last_event_id` already order later changes.
15. Component patterns are fully anchored, and the local interpreter evaluates `pattern` as an unanchored search, which is equivalent for an anchored pattern; `identity.md` specifies the byte length while the schema approximates it with a character length.
16. A single-string deployment ID keeps the old rule set, so an existing ID that the v2 component rules reject must be renamed explicitly when it is migrated.
17. The migration report prints record metadata `status` and `version` in addition to names and paths, because the plan requires the inventory to be actionable without reading a value.
