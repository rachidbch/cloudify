---
targets: server
---

# Runbook: youtube-mcp - YouTube Transcript MCP server

App `youtube-mcp` (flavor `default`). One host, one package: the Streamable
HTTP MCP server (systemd unit `youtube-mcp.service`, port 8443 by recipe default).
The server generates its endpoint token on first start and stores it at `/var/lib/youtube-mcp/token` (0600).
`API_TOKEN` is ignored; do not add it as a runbook input or copy the generated token into an adoption record.

Playable: `cloudify app run youtube-mcp --name main --target server=<node>:<instance>`
(selects install then verify). Teardown is explicit: `--phase teardown`.

## Preconditions

- A tailnet-reachable host managed by cloudify (the operator provides it; this
  runbook never creates instances).
- Optional Google account inputs: `YT_GOOGLE_CLIENT_ID` and secret `YT_GOOGLE_CLIENT_SECRET`, supplied together through the caller environment.
- Endpoint authentication uses the server-owned token regardless of whether Google account inputs are supplied.

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
