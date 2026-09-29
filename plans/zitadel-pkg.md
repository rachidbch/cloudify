# Plan: cloudify pkg `zitadel` + tailnet deployment

Date: 2026-09-29. Serves SecureVault Phase 8 T5 (identity anchor; ADR-009
there). No Zitadel on Rachid's workstation (RAM/disk stressed) - it runs as
an ivps instance on the tailnet.

## Package: pkg/zitadel (cloudify-pkg-dev skill governs authoring)

- Shape: `pkg/zitadel/{init.sh, verify.sh, README.md}` + `pkgs/zitadel.yaml`
  defaults. Depends on the existing `docker` pkg.
- Contents: docker compose on the instance - postgres:16 + ghcr.io/zitadel/zitadel
  (start-from-init, `--tlsmode external` behind the tailnet edge).
- Config keys (vars): zitadel_domain (tailnet name), zitadel_masterkey
  (secret reference, never plaintext), zitadel_port (default 8080).
- PAT bootstrap (the automation unlock): FirstInstance.Org.Machine block +
  FirstInstance.PatPath -> Zitadel writes the machine PAT to a file at
  instance creation. The pkg exports it as a deployment output + stores it
  in a cloudify secret (securevault-bootstrap-pat). No web login ever needed.
- verify.sh: poll /debug/health until green; call the Mgmt API with the PAT
  (GET /mgmt/v1/iam = 200). Fails the install otherwise.

## Deployment (ivps)

1. Node: cloudstation or cloudai (both adopted, both fit: Zitadel ~300MB +
   Postgres ~200MB RAM). Decision point for Rachid - recommend the node NOT
   running the GPU/LLM workload (cloudstation unless it is loaded).
2. `ivps launch <node>:zitadel` (Ubuntu 24.04 container OS).
3. TLS/issuer decision (the one open design point, settle at authoring):
   Zitadel issuer URL must be https. Options:
   a. Tailscale HTTPS (`ts cert` on the instance, zitadel behind it) - keeps
      everything tailnet-only. RECOMMENDED.
   b. Caddy public domain via ivps gateway - only if humans need login from
      outside the tailnet later.
4. `cloudify --on <node>:zitadel install zitadel` -> verify green.
5. Expose on the tailnet: `ivps expose-service zitadel zitadel 8080`
   (VIP service; no public exposure).

## SecureVault consumption (this repo, Phase 8)

- CLI: `securevault anchor add zitadel --issuer https://<ts-name> --jwks-url
  https://<ts-name>/oauth/v2/keys --client-id <cli-client>`.
- One-time provisioning (PAT from the deployment output): create project,
  CLI app (Native + Device Code), human users (alice/bob or real names) via
  Mgmt API. Script lands in scripts/ when T5 executes.
- e2e: SV_TEST_ZITADEL_URL + SV_TEST_ZITADEL_PAT env -> real-device-flow
  harness; skip cleanly when unset (workstation stays light).

## Execution order

pkg authoring (TDD in the Incus test container per cloudify SDLC) ->
node decision -> launch -> install+verify -> securevault anchor add ->
T5 harness wiring.
