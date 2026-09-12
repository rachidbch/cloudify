# Cloudify + ivps redesign

What changes, where things live, how the tools behave. Concepts: GLOSSARY.md.

## Principles

- Derived lives nowhere: persist only what no live system answers.
- One plain json file per artifact. Nothing is marked as a cache, a durable fact or runtime
  state; read, write and refresh policy lives in the software.
- Renameable entities carry an id and a name. State records carry the id, so nothing depends on a
  name; a name is a user-facing handle that may change. An entity whose name is its identity (an
  ACL tag) needs no id.
- One declaration site: a package declares its legs, dependency specs and names in its recipe,
  and nowhere else.
- Minimal refactor: fix a value or a label before moving a field, file or tree.

## Where things live

- Plans: git (runbooks, recipes).
- Names and defaults: cloudify, and the tree mirrors the repo tree:
  `~/.config/cloudify/remote-vars.yaml` global, `~/.config/cloudify/pkg/<pkg>.yaml` per package,
  `~/.config/cloudify/runbooks/<app>/<flavor>.yaml` per application.
- State, the truth: the ivps inventory, mutated in place by the commands.
- Event log: the ivps inventory, at its top level, not inside a host bucket. The state is one
  slice per host, while the log is a single cross-host stream, so inside a bucket it would be
  duplicated per host. One file per event.
- Run files: next to the log, one per execution, holding its id, start, status and end.

## Versioning

- Versions live in git: commits and tags. The tree holds one working copy of each package and each
  runbook; there are no version directories.
- What ran is recorded: the version and the commit hash, in the event and in the state.
- Motive: a copy per version duplicates content and competes with the commit pin.

## Inventory ownership

- ivps owns the inventory folder and its lifecycle: `ivps node path <node>` hands over a
directory.
- cloudify owns what is inside: the state records' fields and their meaning, the reads and the
writes. ivps never parses it.
- The event shape is shared by both tools and needs a version.

## Inventory layout

- One folder per node name, holding the current state: the node's own state record, and the state
  records of the packages applied on it, per deployment. An instance's state lives under its node.
- A rename moves the folder, because the state is current only and cheap to move.
- A deleted node's state leaves the tree. Its story stays in the log.
- Only the current machine under a name has state there, so nothing mixes and nothing accumulates.

## State and events

- The state describes now: the hosts that exist, the deployments that exist, and for each of them
the current status of every package the deployment applied there. Every act that changes that
status flips the field and stamps a time: a deploy, a reconfigure, an uninstall, a teardown.
- What is no longer current leaves the state, a deleted host or a deleted deployment. Its story
stays in the log, which is never removed.
- A change to the same subject flips its state record.
- Every mutation appends an event: its own id and time, the command, the application, the
  deployment id, the resolved host, the values used (a reference when the value came from a
  secret backend), the commit hash of the repos used.
- The event records the outcome only where cloudify can see it: exit status, captured outputs, and
the values cloudify or ivps generated.
- A state record keeps the id of the last event that touched it, so the state and the log can be
checked against each other.
- Both ivps and cloudify write the state and the events.
- A run is a small file next to the log: its id, its start, and a status that flips to succeeded
or failed with an end time. Its events share that id and everything else is read from them, so
the per-run snapshot file goes.
- Rebuild is the exceptional repair path, behind a flag, in two modes: fold the log to a time and
converge, or replay the commands. A historical view is asked for by time and written to a temp
folder.
- The fold doubles as the drift check: a difference between the folded view and the live state is
drift.

## Legs and reconfigure

- A step declares `phase=install|reconfigure|verify|teardown`, defaulted from its step type. `run`
  and `human-gate` steps declare theirs, because nothing can infer them.
- A bare `cloudify run <application>` runs the install leg, then the verify leg. Reconfigure and
  teardown never run as part of it.
- Reconfigure requires the package state record to exist for that host and package, and fails
  loudly when nothing was applied.
- Reconfigure is seeded from the package state record, with the step's environment on top. It
  provisions nothing, removes nothing, compares nothing, and knows nothing about other hosts. A
  failure stamps the record, and re-running continues.
- One name per shared value: a value two packages must agree on is a single name, declared by both.
  A package prefix is for the names a package owns.

## Rebuild guarantees

- Recipes are bash on remote hosts, so outcomes are not fully observable. A rebuild is mostly the
same, not exact.
- Secrets are references and the log holds no plaintext, so a rebuild takes today's secret value,
not the value of that time.
- Upstreams move: apt, npm and docker tags. A rebuild reproduces the pinned commit and the
recipe's intent, up to upstream versions.
- Production discipline: no deploy from a dirty tree. In development a rebuild is best effort.

## Value resolution

- Sources, weakest first: recipe default, global default, package default, application default,
  caller environment.
- The ladder picks a default. What the caller supplies wins, otherwise the default applies.
- A run may set some values and let the cascade decide the rest.
- The applied state is a source for a reconfigure: the walk is the step's environment, then the
  package state record for that host, deployment and package, then the defaults.

## Secrets

- A value's content may be a literal or a reference to a secret backend.
- Never in git, never in logs, never on a command line; masked in debug output.
- The stored form stays the reference.

## ivps changes

- node: add `id` beside `name`; provider is the server provider name or `premise` and `adopted`
  stays the origin flag (adoption today writes `provider: adopted`); dispatch moves to provider
  id, and so does the deletion origin test; spec fields (os, cpu, memory, disk) join the node state
  record; addresses become six lists (overlay, internal, public; IPv4 and IPv6), used in that order;
  `role` and the active gateway pointer stop sharing one meaning.
- Node field authority: ours = id, name, origin, role, created at, provider, provider id, provider
  region; mirrors of the machine or the provider = hostname, overlay name, addresses, spec.
- instance: add `id`. Nothing else recorded, the engine is the authority.
- engine: a `name` field (incus | docker | podman).
- Instances are created only through ivps; cloudify never invents a host.
- An external host has no id from ivps, so its state record carries the machine's ssh host key
  fingerprint, and a dispatch compares it with the live machine. A mismatch means the machine
  changed and the state there is stale.
- ivps records events for its own actions (node create, delete, tag, route) in the shared shape.
- The inventory holds the state: applied values, versions, statuses and stamps. Keeps
  `nodes/<node>/deployments/<id>/pkgs/<pkg>/`, with the instance level for instance hosts and a
  fallback area keyed by ssh name for external hosts.

## cloudify changes

- An application is a runbook: one file per application at
  `/home/rbc/PROJECTS/PROD/cloudify/runbooks/<app>/<flavor>/runbook.md`, whose body is the steps,
  whose front matter declares the target names and the names it consumes, and whose version is part
  of the repo. Nothing about it is state. Its identity is `<name>/<flavor>`; a flavor is a variant
  of one name, and `default` is the flavor when none is given.
- A deployment is the outcome of running an application: the state it wrote on the hosts it
  touched. Its id is the application plus the operator-given instance name. That name is its
  identity, so reusing it after a teardown continues the same timeline (installed, uninstalled,
  installed). No id of its own: the state records sit per host, so a re-deploy on new hosts cannot
  collide.
- The deployment entity goes: no per-deployment default file, and no write subcommands such as
  `run` and `delete`. Motive: the runbook names the plan, the operator names the instance, the
  state lives with the host, and teardown keys on the same pair. The entity added a name for that
  pair, not a behaviour, and its default file is empty today so removal costs nothing. Reading
  stays, in the read surface.
- The command that runs an application is named in the UX pass (`run` or `app run`).
- The deployment name comes from `--name <name>` on that command, and defaults to `default` when
  no name is given, so one copy costs nothing and a second copy is explicit.
- The UX refactor has to consume that deployment identity.
- cloudify holds defaults only, never applied values.
- The application owns its lifecycle: install, reconfigure, verify and uninstall are phases of its
  runbook, and a teardown removes what the runbook says. No package property decides sharing or
  parallel copies; the runbook's steps and the values do.
- package: id is the repo path, plus name and version; legs, dependencies and names live in the
  recipe. Packages stay flat: no flavor level, since a package variant is a dependency or a value.
- target: "plain host" becomes `external`.

## Read surface

- `cloudify --on <target> show overlay-name` prints that host's overlay name, which the cross-host
  wiring in a runbook needs.
- `cloudify --on <target> state [--deployment <name>]` prints what is applied on that host: per
  package, the status, the version, the stamps, the values with secrets masked, and the last event.
- `cloudify deployments` lists the names, by scanning the run files, with each one's last run and
  its status.
- `cloudify deployments show <name>` prints the application that produced it and, per host, the
  packages and their stamps.
- These commands are how a human or an agent learns the state. The value walk never reads it on its
  own; it is seeded only where a reconfigure asks for it.
