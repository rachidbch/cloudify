#!/usr/bin/env python3
"""
Host-header-rewriting reverse proxy for Hermes Dashboard.

WORKAROUND for missing --allowed-hosts flag (hermes-agent#34390):
  https://github.com/NousResearch/hermes-agent/issues/34390

The dashboard validates the Host header for DNS rebinding protection.
tailscale serve forwards the original tailnet hostname, which the
dashboard rejects (not loopback). This relay sits between tailscale
serve and the dashboard, rewriting Host → 127.0.0.1:9119.

REMOVE THIS RELAY when --allowed-hosts lands and replace with:
  hermes dashboard --host 127.0.0.1 --allowed-hosts hermes.komodo-everest.ts.net

Architecture:
  tailscale serve :443 → relay :9120 (rewrites Host) → dashboard :9119

Dependencies: aiohttp (already in hermes venv)
"""
import asyncio
import signal
import subprocess
import sys

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web

DASHBOARD_PORT = 9119
RELAY_PORT = 9120
UPSTREAM = f"http://127.0.0.1:{DASHBOARD_PORT}"

# Headers stripped from upstream response (hop-by-hop or problematic)
_RESPONSE_SKIP = {
    "transfer-encoding", "connection", "content-encoding",
}

# Headers stripped from downstream request before forwarding
_REQUEST_SKIP = {
    "host", "connection", "transfer-encoding", "upgrade",
}


async def proxy_http(request: web.Request) -> web.StreamResponse:
    """Forward HTTP request to dashboard, rewriting Host header.

    Also rewrites root-absolute asset paths (/assets/...) to include the
    path prefix (/dashboard/assets/...) so the dashboard works behind
    tailscale serve --path /dashboard.
    """
    method = request.method
    url = f"{UPSTREAM}{request.path_qs}"

    headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in _REQUEST_SKIP
    }
    headers["Host"] = f"127.0.0.1:{DASHBOARD_PORT}"

    body = await request.read()
    kwargs = {"headers": headers}
    if body:
        kwargs["data"] = body

    async with ClientSession() as session:
        async with session.request(method, url, **kwargs) as upstream_resp:
            content_type = upstream_resp.headers.get("Content-Type", "")
            is_html = "text/html" in content_type

            response = web.StreamResponse(status=upstream_resp.status)
            for key, val in upstream_resp.headers.items():
                if key.lower() not in _RESPONSE_SKIP:
                    response.headers[key] = val

            if is_html:
                # Buffer HTML body and rewrite asset paths for path-based routing.
                # The dashboard SPA uses absolute /assets/ references which break
                # when tailscale serve strips a path prefix.
                html_body = await upstream_resp.read()
                html_body = html_body.replace(b'"/assets/', b'"/dashboard/assets/')
                html_body = html_body.replace(b"'/assets/", b"'/dashboard/assets/")
                response.headers["Content-Length"] = str(len(html_body))
                await response.prepare(request)
                await response.write(html_body)
                await response.write_eof()
            else:
                await response.prepare(request)
                async for chunk in upstream_resp.content.iter_chunked(8192):
                    await response.write(chunk)
                await response.write_eof()

            return response


async def proxy_ws(request: web.Request) -> web.WebSocketResponse:
    """Bidirectional WebSocket bridge between client and dashboard."""
    ws_client = web.WebSocketResponse()
    await ws_client.prepare(request)

    headers = {
        k: v for k, v in request.headers.items()
        if k.lower() not in _REQUEST_SKIP
    }
    headers["Host"] = f"127.0.0.1:{DASHBOARD_PORT}"
    ws_url = f"ws://127.0.0.1:{DASHBOARD_PORT}{request.path_qs}".replace("https://", "ws://")

    async with ClientSession() as session:
        async with session.ws_connect(
            ws_url, headers=headers,
        ) as ws_upstream:

            async def forward(src, dst):
                async for msg in src:
                    if msg.type == WSMsgType.TEXT:
                        await dst.send_str(msg.data)
                    elif msg.type == WSMsgType.BINARY:
                        await dst.send_bytes(msg.data)
                    elif msg.type in (WSMsgType.CLOSE, WSMsgType.ERROR):
                        break

            await asyncio.gather(
                forward(ws_client, ws_upstream),
                forward(ws_upstream, ws_client),
            )

    return ws_client


async def handler(request: web.Request):
    """Route to HTTP or WebSocket proxy based on Upgrade header."""
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return await proxy_ws(request)
    return await proxy_http(request)


def main():
    # Start dashboard as subprocess
    proc = subprocess.Popen([
        "/usr/local/bin/hermes", "dashboard",
        "--no-open", "--host", "127.0.0.1", "--port", str(DASHBOARD_PORT),
    ])

    # Kill subprocess when relay exits
    def cleanup():
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        sys.exit(0)

    # Wire signals — SIGTERM from systemd stop, SIGINT for manual ^C
    loop = asyncio.get_event_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, cleanup)

    async def run():
        # Wait for dashboard to be ready (may need to build web UI on first launch)
        for i in range(30):
            try:
                async with ClientSession() as session:
                    async with session.get(
                        f"{UPSTREAM}/", timeout=ClientTimeout(total=2),
                    ):
                        break
            except Exception:
                await asyncio.sleep(1)
        else:
            print("relay: dashboard at :9119 did not become ready", file=sys.stderr)
            sys.exit(1)

        app = web.Application()
        app.router.add_route("*", "/{path:.*}", handler)

        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, "127.0.0.1", RELAY_PORT)
        await site.start()

        print(f"relay: 127.0.0.1:{RELAY_PORT} → 127.0.0.1:{DASHBOARD_PORT}")
        print("relay: waiting for connections...")

        # Keep running until signal
        await asyncio.Event().wait()

    try:
        loop.run_until_complete(run())
    except (SystemExit, KeyboardInterrupt):
        pass
    finally:
        cleanup()


if __name__ == "__main__":
    main()
