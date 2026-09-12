# Identity and validation rules

Status: normative for schema_version 1.
Frozen under Phase 1 of `plans/state-model-v2.md` (tasks 1.3 and 1.4), before any v2 writer exists.
Implementation contract: `REDESIGN.md` section "Identity", decision: `ADR.md` ADR-022 point 1.

## Scope

These rules cover every machine-owned identity component: application name, flavor, deployment name, package instance, and the stable runbook step ID that names a claim.
They apply in three places: CLI parsing, on-disk path construction, and JSON field validation.
Every schema under `schemas/v1/` encodes them as `$defs/component`, so a violating fixture fails before any writer runs.
The `--on` host target grammar (`X`, `X:`, `X:Y`, `:Y`) is explicitly out of scope and unchanged during the state-model work; ivps owns node and instance identity.

## A component

A component is a non-empty byte string.
It must not contain `/`, because `/` is the path and reference separator.
It must not contain a control character, meaning any byte in 0x00 to 0x1f or 0x7f.
It must not be exactly `.` and must not be exactly `..`, because those are traversal.
It must not begin or end with whitespace, because then the rendered form does not round-trip through a command line.
It must not begin with `-`, because then it parses as a flag.
It must be at most 255 bytes, the POSIX `NAME_MAX`, because a component that cannot exist as a path component cannot name a deployment.
Everything else is permitted: interior spaces, `@`, `+`, `=`, `:`, `.` inside a name, and non-ASCII bytes, because the current code permits them and no rule needs them forbidden.
Components compare byte for byte: no case folding, no Unicode normalization, no percent decoding.
A validator rejects and exits non-zero, naming the offending component; it never silently rewrites, trims, or normalizes a component.

## The deployment tuple

A deployment is identified by the tuple `(application, flavor, deployment name)`.
The three components are independent: none is derived from another, and no component is a joined key.
The tuple is never flattened into one path component or one identifier.
The application command exports `CLOUDIFY_APPLICATION`, `CLOUDIFY_FLAVOR`, and `CLOUDIFY_DEPLOYMENT_NAME` for its child dispatches.
The legacy `CLOUDIFY_DEPLOYMENT` value stays an opaque single-string compatibility identity, and it cannot be translated into the tuple without an explicit application and flavor supplied to migration.

## Defaults

The default flavor is `default`.
The default deployment name is `default`.
The default package instance is `default`.
Defaults are applied before validation, so `k3s` resolves to the application reference `k3s/default`, and an omitted `--name` resolves to the deployment name `default`.

## Two applications using deployment name default

`k3s/default` with deployment name `default` and `xfce-guacamole/default` with deployment name `default` are two different deployments and never collide.
Their desired inputs live in different directories: `deployments/k3s/default/default/values.yaml` and `deployments/xfce-guacamole/default/default/values.yaml` under the Cloudify configuration root.
Their manifests live in different directories: `deployments/k3s/default/default/manifest.json` and `deployments/xfce-guacamole/default/default/manifest.json` under the Cloudify state root.
On a shared host they meet only inside physical package state, as two separate claim entries, so one deployment can neither read nor overwrite the other's intent.

## Canonical reference, CLI rendering, and parsing

The canonical application reference is `<application>/<flavor>`.
A rendered reference always carries the flavor, including `default`, so two references are equal only when both components are equal.
A command line passes the reference plus the deployment name: `cloudify app run k3s/default --name prod`.
A parsed reference contains exactly one `/`, with a non-empty component on each side.
An empty token, a leading `/`, a trailing `/`, a second `/`, or an empty `--name` value is rejected at parse time.
A three-segment form such as `a/b/c` is rejected rather than guessed, because the missing component would otherwise be invented.
Machine-readable output carries the three tuple fields separately, and human-readable output renders `<application>/<flavor> --name <name>`, so no rendering is ambiguous.

## Rejection rules and their origin

Current code rejects an empty deployment ID and the components `/`, `.`, and `..`: `lib/deployments.sh:19-24` for the deployment ID, and `lib/registry.sh:48-57` for every present registry component.
Anything else is accepted today, including a newline in a deployment ID and a trailing space in a package or instance component.
The v2 rule keeps every current rejection and adds these:
1. Control characters (0x00 to 0x1f, 0x7f), because such a component still reaches a `KEY: value` store line, a log line, and a JSON string where it changes the meaning of surrounding text.
2. Leading and trailing whitespace, because a component that does not round-trip cannot be parsed back unambiguously.
3. A leading `-`, because such a name cannot be handed to the CLI without being read as a flag.
4. A 255-byte length limit, because the component must be usable as a path component.
5. Validation of application, flavor, deployment name, package instance, and step ID as separate components, instead of validating one deployment ID and inheriting its rule set for everything else.
6. Enforcement before the first mutation: validation failure creates no directory, no record, no state file, and no manifest.
The step ID rule is the existing runbook ID shape (`lib/runbooks.sh:246-270`: any non-empty token, defaulted to a two-digit index) tightened to a leading alphanumeric followed by alphanumerics, `.`, `_`, or `-`, so IDs remain shell- and filename-safe.
The package name rule is the current `pkg/` directory shape: a lowercase alphanumeric followed by lowercase alphanumerics, `.`, `_`, or `-`.

## Legacy compatibility

An existing `CLOUDIFY_DEPLOYMENT` ID keeps the old rule set (empty, `/`, `.`, `..`), so every existing deployment remains readable and executable during the compatibility period.
An ID that the v2 component rules reject, for example one containing a newline or a trailing space, is migratable only through an explicit operator rename, because the old and new stores cannot both name it.
The legacy ID must not be split on any character to guess the tuple, and it stays opaque until migration receives the application and flavor.
Desired inputs and run snapshots keep working from the legacy path for as long as the legacy readers exist.

## On-disk consequence

Each tuple component is one directory level, in the order application, flavor, deployment name.
Desired inputs live at `<config-root>/deployments/<application>/<flavor>/<deployment>/values.yaml`.
Current state lives at `<state-root>/deployments/<application>/<flavor>/<deployment>/manifest.json`.
Host package state lives at `<host-state-root>/cloudify/packages/<package>/<package-instance>/state.json`.
A claim names its deployment with three separate fields inside one flat claim object instead of one joined key, so no separator choice can be ambiguous.

## Executable check

`schemas/v1/fixtures/deployment-manifest/invalid/traversal-deployment-name.json` and the manifest fixtures prove the component rule positively at the schema level.
`bash schemas/v1/validate.sh` runs every fixture against its schema and fails when a violating instance is accepted.
