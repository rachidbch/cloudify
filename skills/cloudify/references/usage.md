# Daily Usage Reference

SKILL.md has the cheat sheet; this has the depth.

## Local vs remote

```bash
cloudify install neovim                 # local
cloudify install default                # all @default packages
cloudify --on srv install bat           # remote (--on FIRST)
cloudify --on srv1 srv2 install git     # multiple, parallel
cloudify --on @web install nginx        # by tag
cloudify uninstall neovim               # remote: prepend --on <host>
```

**Remote flow:** cloudify SSHes in → bootstrap gist clones/pulls `~/cloudify` from **GitHub** → `cloudify init` → `cloudify install <pkg>` (auto-installs `@default` first). Remote runs GitHub code, **not your checkout** → push before testing remote changes.

## Host inventory

Hosts are directories under `inventory/`; tags are empty `@<tag>` files inside:

```
inventory/myserver/@web
inventory/localhost/@local
```

```bash
cloudify hosts | cloudify hosts @web | cloudify host myserver
cloudify myserver shell          # open a shell
cloudify exec myserver 'uptime'  # run a command
```

## Package tags

Empty files in `pkg/<name>/`:

| File | Effect |
|------|--------|
| `@default` | auto-installed before any requested package, on every host |
| `@<tag>` | grouping — `cloudify install @web` installs the set |
| `#<tag>` | platform filter — install only on matching OS (e.g. `#linux`) |

Tags travel with the repo, so they resolve identically on remote clones.

## Verification

Install verifies by default via an optional `verify.sh` (retry loop, default 30s timeout).

```bash
cloudify --no-verify install <pkg>    # skip
cloudify verify <pkg>                 # verify-only
cloudify --verify install <pkg>       # verify-only
```

Slow first-starts → raise the timeout in `~/.config/cloudify/pkgs/<pkg>.yaml`:
```yaml
PKG_VERIFY_TIMEOUT: 120
```

## Credentials

Stored in `~/.config/cloudify/credentials` (XDG, chmod 600); three sections: `remote`, `github`, `gitlab`.

```bash
cloudify credentials                 # set all interactively
cloudify credentials remote          # one section
cloudify credentials --check         # status
```

Env vars override the file. Skip loading in automation: `export CLOUDIFY_SKIPCREDENTIALS=true`.

## Package config (per-package vars)

`~/.config/cloudify/pkgs/<pkg>.yaml` (flat `KEY: value`, chmod 600) is the **single source of truth** for both var names and values. Forwarded to the remote host when installing that package via `--on`. Missing files are silently ignored.

```yaml
WEBUI_ADMIN_EMAIL: "admin@example.com"
```

**Always-forward vars:** `~/.config/cloudify/remote-vars.yaml` — forwarded on every `--on` call regardless of package. Env vars take precedence over all config files.

## Key environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CLOUDIFY_TMP` | `/tmp/cloudify` | logs, exit codes, backups |
| `CLOUDIFY_DIR` | `~/cloudify` | repo path (`pkg/`, `inventory/`) |
| `CLOUDIFY_CREDENTIALS_DIR` | `~/.config/cloudify` | XDG config dir |
| `CLOUDIFY_SKIPCREDENTIALS` | `false` | skip cred loading |
| `CLOUDIFY_FORCE_UPDATE` | `false` | force git pull on remote hosts |
| `CLOUDIFY_UPDATE_DELAY` | `30` | minutes before auto-updating remote repo |
| `CLOUDIFY_LOG_LEVEL` | `INFO` | `SILENT`…`DEBUG` |
| `DEBUG` | unset | preserve all temp files |

## Containers

```bash
cloudify launch mybox                      # default image ubuntu/24.04/cloud
cloudify launch remote:mybox ubuntu/24.04  # on a remote host
cloudify delete mybox
```
