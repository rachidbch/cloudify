# AGENTS.md — skill-cloudify

Helper on use of cloudify to author, provision, and manage packages on local/remote Linux boxes.

## Repo

We're writing an agent skill to teach an ai agent how to use cloudify to author, provision, and manage packages on local/remote Linux boxes.

- **Skill Name:** `cloudify`
- **Audience:** an AI with no session memory — instructions must be self-contained and re-verifiable each invocation.
- **Scope:** (1) daily usage (install/uninstall/verify/hosts/remote), (2) authoring package recipes under `pkg/`.
- **Best practices:** Refer to the skill creation skill.

## Conventions to preserve

- **Missing-cloudify warner.** SKILL.md tells the AI: if `cloudify` isn't on PATH, stop and ping the human — never self-install or work around it. Keep this; a missing dependency must surface, not compound silently.
- **The `--on <host>` ordering rule** is cloudify's #1 footgun — keep it prominent in SKILL.md.
- **200-line rule.** SKILL.md and each reference stay under 200 lines. Move detail into a reference rather than growing the entry. References are one level deep.

## Structure

```
skill-cloudify/
├── SKILL.md                         # entry: warner, cheat sheet, mental model
├── AGENTS.md                        # THIS file — skill dev/maintenance
└── references/
    ├── usage.md                     # hosts, tags, creds, env vars, remote flow
    ├── package-authoring.md         # API, install guards, verify.sh, testing
    └── troubleshooting.md           # logs, debug, common failures
```

## Source of truth

Distilled from cloudify's own docs (`README.md`, `CLAUDE.md`, `cloudify --help`, `pkg/bat` + `pkg/hermes` examples). **cloudify is authoritative** — when they disagree, fix the skill.

## Keeping in sync

cloudify moves fast:

1. `cd ~/PROJECTS/PROD/cloudify && git pull`
2. Re-skim `README.md`, `CLAUDE.md`, `cloudify --help`.
3. Spot-check the "70+ packages" count vs. `pkg/`, the `pkg_*` table vs. `lib/package-api.sh`, and command examples vs. real flags.
4. If CLI flags changed, update **SKILL.md's cheat sheet first** (it's what the AI sees by default), then the matching reference.
5. Edit only what changed — concise; never paste README sections verbatim.

## Known upcoming change — package location

Recipes live in `~/PROJECTS/PROD/cloudify/pkg/` now; production will move them to `$XDG_DATA_HOME/cloudify/pkg/`. The skill documents the current path and flags the move in `references/package-authoring.md` ("Path note"). When it ships:
1. Update the path note.
2. Update literal `pkg/` paths in SKILL.md / usage.md if CLI resolution changed.
3. Recipes stay portable via the `pkg_*` API — no recipe rewrites needed.

## Editing conventions

- Imperative voice, third person, token-efficient (mirror cloudify's own "min tokens, max signal").
- Forward-slash paths only.
- One term per concept (always "install", never mix install/add/set up).
- No time-sensitive facts without an "old patterns" home.
- Tables for command/flag references; code blocks for copy-paste recipes.
- Don't duplicate content between SKILL.md and references — link.

## Testing the skill

Skills are additions to a model; effectiveness is model-dependent. After edits, in a fresh session trigger the skill on:
- "install bat on myserver" → respects the missing-cloudify warner, then `cloudify --on myserver install bat`.
- "create a cloudify package for foo" → reads `references/package-authoring.md` before writing `pkg/foo/init.sh`.
- "cloudify isn't installed" → STOPS and pings the human, doesn't self-install.

Spot-check 2–3 commands against `cloudify --help` / README for accuracy.

## Out of scope

- cloudify internals (`lib/*.sh`, shadow implementation) — document what an author *uses*, not how it's built. Point to cloudify's README for internals.
- Installing cloudify itself — the human's job (the warner enforces it).
