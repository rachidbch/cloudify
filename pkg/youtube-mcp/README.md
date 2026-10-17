# youtube-mcp

The HTTP MCP endpoint uses port `YOUTUBE_MCP_PORT` (default 8443).
The server generates its own bearer token on first start and stores it in `/var/lib/youtube-mcp/token` (0600).
The recipe ignores `API_TOKEN`; omitting it does not disable endpoint authentication.

Optional Google account tools need both `YT_GOOGLE_CLIENT_ID` and `YT_GOOGLE_CLIENT_SECRET` in the caller environment.
The client secret has an explicit `secret NAME` declaration; the client ID is ordinary.
The recipe writes supplied OAuth values into its service configuration.

Code lives in `/opt/youtube-mcp`; token and account state live in `/var/lib/youtube-mcp` and survive code reinstalls.
The recipe prints the generated endpoint token after installation; keep that output private and do not copy it into Cloudify inventory or run snapshots.
