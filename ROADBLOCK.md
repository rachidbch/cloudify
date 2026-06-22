# ROADBLOCK

## Separate-containers topology: DNS resolution (UNVERIFIED - recheck before acting)

### Symptom
`cloudify install` in separate-containers mode (open-webui on one host, hermes API on another, via Tailscale MagicDNS) is believed non-functional at the network layer.

### Stored reasoning (ZERO TRUST - recheck every claim)
The tension: open-webui Docker container needs BOTH public DNS (huggingface.co for model download, google.com generally) AND MagicDNS (hermes.ts.net for the API). One container, seemingly one resolver.

Hypothesized resolution (from Tailscale issues #14467, #12108, #18600):
1. Docker container inherits host `/etc/resolv.conf` when NO `dns:` directive is set.
2. systemd-resolved scopes `100.100.100.100` to the `tailscale0` interface, MERGING with the public resolver (per-interface DNS, not global override).
3. Tailscale 1.66+ stateful filtering drops Docker-range (172.17.x.x) packets to 100.100.100.100; fix = `tailscale set --stateful-filtering=false` on the host.
4. Cloudify's `dns: [100.100.100.100]` directive (removed in commit ee028af) was the CAUSE of breakage (overwrote the host merge inside the container), not a correct separate-containers setup.
5. `RAG_EMBEDDING_ENGINE=openai` (set when OPENAI_API_BASE_URL is) routes embeddings through the API, eliminating the huggingface.co download (the public-DNS need that ee028af's commit message names).

### Recheck before acting
- Verify each claim against current Tailscale docs + the cited issues (still open? still accurate in 2026?).
- Verify open-webui has NO other public-DNS dependency (telemetry, update checks, OAuth, lazy fetches).
- Verify by DOING a separate-containers install, not just reading code.
- Confirm conclusion: dns directive stays removed; separate-containers needs host-level Tailscale setup (MagicDNS on, systemd-resolved scoping, stateful filtering off) -> ivps/host-provisioning concern, not a cloudify pkg concern.

### Sources (re-read, don't trust the summary)
- tailscale/tailscale#14467
- tailscale/tailscale#12108
- tailscale/tailscale#18600
- https://tailscale.com/docs/reference/dns-in-tailscale
- cloudify commit ee028af (the dns removal)
