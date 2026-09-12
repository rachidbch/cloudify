# Cloudify Glossary

Concepts only. What changes, where things live and how the tools behave: REDESIGN.md.
`[proposed]` = not yet confirmed.

## node

**Definition.** A machine that runs an engine, registered with ivps under a stable name,
reachable from the operator's machine.

**Fields.**

- id: immutable identity; every other artifact references it.
- name: human handle, may change.
- hostname: the machine's own name.
- overlay name: how the overlay network names it.
- origin: provisioned (ivps asked a server provider for the machine) or adopted (the machine
  already existed and ivps registered it).
- engine: the stack the node runs. See engine.
- provider: display name (`digitalocean`, `aws`, `hetzner`, `premise`).
- provider id: stable dispatch key; starts equal to provider, may diverge.
- provider region: region inside the provider; empty for `premise`, or used to tell enterprise
  regions apart.
- role: declared purpose (today, the tailnet gateway).
- spec: OS/image, cpu, memory, disk.
- created at: when ivps registered it.
- addresses: see address.

**Rules.**

- Owner: ivps. cloudify reads nodes and never authors them.
- `local` is this machine's own daemon, not deleteable.
- Deletion follows origin: a provisioned machine is destroyed through its provider, an adopted
  node is only unregistered, `local` is refused.
- The cloud's active gateway is a cloud-level fact, not a node field.
- Never recorded on a node: liveness, the containers it hosts.
- Fields are captured when the node is provisioned or adopted, and updated on reconfigure.

## address

**Definition.** What makes a node or an instance reachable.

**Fields.**

- overlay IPv4: list. The mesh network.
- overlay IPv6: list.
- internal IPv4: list. The private network.
- internal IPv6: list.
- public IPv4: list.
- public IPv6: list.

**Rules.**

- Use order: overlay IPv4, then internal IPv4, then public IPv4. One strategy, may evolve.
- IPv6 is not in use yet; roadmapped.
- Overlay is not Tailscale. Tailscale is today's implementation; nothing above this concept
  names it.
- A name is not an address: hostname and overlay name are naming, never addresses.

## instance

**Definition.** A container (or VM) created by an engine on one node, addressed by name inside
it: the `Y` in `X:Y`.

**Fields.**

- id: immutable. Identity is (node id, instance id).
- name: mutable inside the node.
- node: the node it runs on.
- engine: the stack that owns it.
- image: what it was created from.
- hostname: the instance's own name.
- overlay name: how the overlay network names it.
- addresses: as for a node.
- os: the instance's own OS.
- spec: cpu, memory, disk.
- exposure: a published route (hostname, port, url).

**Rules.**

- Machine-describing fields stay empty when the engine does not provide a machine. An Incus system
  container or VM has an OS, memory and disk of its own; a docker or podman container has none of
  the three, so `os` and `spec` stay empty.
- Resource limits on a docker container are configuration, not capacity, so they do not fill `spec`.

## engine

**Definition.** The stack that creates and runs instances on a node: incus, docker, podman today.

**Fields.**

- name: `incus` | `docker` | `podman`.

**Rules.**

- A node runs one engine; an instance belongs to one node and one engine.
- Nothing above this concept names an engine.

## host

**Definition.** A place a package can be deployed onto.

**Rules.**

- host = node | instance | external.
- An external host is not in the inventory: ivps does not know it, and it is addressed by
  its ssh name. Adopting it makes it a node.
- Everything a package leaves behind is per host.

## target

**Definition.** A reference typed after `--on`, resolved at every use; never stored.

**Rules.**

- Kinds: node (`X:`), instance on a node (`X:Y`), instance on the active node (`:Y`), bare `X`
  (kind discovered; a name that is both a node and an instance is an error), external host (not
  adopted by ivps).
- A runbook declares target names and binds them for one run; the binding is history, not an
  address.

## package

**Definition.** The unit of provisioning: named software cloudify knows how to install, configure
and remove on a node or an instance.

Everything a package declares lives in its recipe, and only there:

- the legs it implements: install required, configure, uninstall and verify optional. A leg the
  package does not implement fails loudly when asked.
- a spec for each dependency, a descendant of the package spec.
- the values it consumes.

**Fields.**

- id: the package's relative path in the repo. Immutable, and the key every reference uses.
- name: human handle, usually the same as the last path segment so the tree stays scannable; may
  change.
- version: the version the package installs.

**Rules.**

- One declaration site: the recipe.
- A package carries no per-host facts. What landed is an observation.
- The same package installed on two hosts is two observations.
- An application does not own a package. Several applications can use the same package, and the
  package state record is one per deployment.

## value

**Definition.** A string a recipe consumes at run time, addressed by name. The recipe declares the
names it consumes; the operator supplies a string for a name in one of several sources.

**Fields.**

- name: the name the recipe declares.
- content: the string, either a literal or a reference to a secret backend, resolved when used.
- secret: true when the content is sensitive.

**Rules.**

- One concept, several sources. The same name may exist in more than one source; that is
  precedence, not duplication. The strongest source that provides it wins.
- Source order: REDESIGN.md. The recipe default is the only source in git.
- A reference stays a reference in a state record; the literal never replaces it.

## secret backend

**Definition.** The external system that holds secrets and resolves a reference to its content.

**Fields.**

- name: the backend.

**Rules.**

- A value's content may be a reference instead of a literal; the backend resolves it when the
  value is used.
- No backend configured means no lookup happens.

## application

**Definition.** A runnable runbook: the program that applies intertwined packages to hosts. Lives
in cloudify, in git.

**Fields.**

- id: the runbook's relative path in the repo, `<name>/<flavor>`. Immutable, and the key every
  reference uses.
- name: the application name, shared by its flavors.
- flavor: the variant of that name; `default` when none is given.
- version: the application's version.

The runbook, and only there, declares the host slots to bind, the names the application consumes,
and its legs: install, reconfigure, verify, uninstall.

**Rules.**

- An application declares names, never values. Defaults are the exception.
- An application is not state. Applying it produces state.
- An application owns its lifecycle. What a teardown removes is the runbook's decision.
- A verify step writes no state record, so an application can use a package it does not own.

## deployment

**Definition.** The outcome of running an application: the state recording what was applied,
where, when and with which values.

**Fields.**

- id: the application plus the name the operator gives this instance. The key the state path uses.
- application: the application it applied.
- host: where each package landed.

**Rules.**

- Its state lives in the package state records, one per host and per package.
- The events live in the log.
- The state is distributed: one package state record per host and per package, tied together by
  the deployment name in each path.
- The package state records under a deployment are that application's uninstall checklist. A
  package another application installed is not among them.

## event

**Definition.** One mutation of the system, appended to the log and never removed.

**Fields.**

- id: its own key.
- time: when it happened.
- command: what was run.
- application, deployment id, host: the subject it touched, by id.
- run id: the execution it belongs to.
- values: what was used, a reference when the value came from a secret backend.
- commit: the code it ran from.
- outcome: exit status, captured outputs, and the values cloudify or ivps generated.

## run

**Definition.** One execution of an application.

**Fields.**

- id: the key its events carry.
- application: the application it ran.
- deployment: the name it ran under.
- started at: when the execution began.
- status: running, succeeded or failed.
- finished at: when it ended.

It is written before the first event, so a run that dies immediately still leaves a trace.

**Rules.**

- It is the run's genesis, and it flips to a final status at the end, like every other state
  record.
- Its values, its hosts and its outcomes are those of its events, so nothing is duplicated.
- It sits next to the log, at the top of the inventory.

## dispatch

**Definition.** One command cloudify sends to one host: an install, a configure, a verify or an
uninstall of one package.

**Rules.**

- The host, the deployment and the package come from the step that runs it.
- Values resolve at the dispatch: what the step's environment supplies wins, then the values in the
  package state record for that host, deployment and package, then the defaults.
- It appends an event.

## package state record

**Definition.** The state cloudify keeps for one package on one host in one deployment: what was
applied there, with which values, and when. One file.

**Fields.**

- application: the application that asked for it.
- version: the package version that landed.
- values: the values that were applied, a reference when the value came from a secret backend.
- status and stamps: the current status, and the time of each act.
- last event: the id of the event that touched it.

The host, the deployment and the package are the file's path, so they are not repeated.

**Rules.**

- It is what a reconfigure of that package on that host is seeded with.
- Every dispatch that touches it updates it and sets its last event.
