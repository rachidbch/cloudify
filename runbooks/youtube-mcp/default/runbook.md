---
targets: server
---

# Runbook: youtube-mcp - YouTube Transcript MCP server

App `youtube-mcp` (flavor `default`). One host, one package: the Streamable
HTTP MCP server (systemd unit `youtube-mcp.service`, port 8443 by recipe
default). The bearer token (`API_TOKEN`) is a secret: it lives in the
deployment store or the operator's password manager, never in this file or in
an adoption record.

Playable: `cloudify app run youtube-mcp --name main --target server=<node>:<instance>`
(selects install then verify). Teardown is explicit: `--phase teardown`.

## Preconditions

- A tailnet-reachable host managed by cloudify (the operator provides it; this
  runbook never creates instances).
- Optional inputs: `API_TOKEN` (secret - supply via the store or stdin), else
  the server runs unauthenticated.

## Steps

### 1. Install the server

```bash step=install target=server pkg=youtube-mcp
cloudify --on "$TARGET_SERVER" install youtube-mcp
```
```bash step=verify target=server pkg=youtube-mcp
cloudify --on "$TARGET_SERVER" verify youtube-mcp
```
```bash
cloudify --on "$TARGET_SERVER" configure youtube-mcp
```
```bash step=uninstall target=server pkg=youtube-mcp id=teardown-youtube-mcp
cloudify --on "$TARGET_SERVER" --clear-data uninstall youtube-mcp
```

The bare `configure` fence (no step id) is intentionally excluded from phase
selection: configure is an explicit reconfigure, never part of a bare run.
