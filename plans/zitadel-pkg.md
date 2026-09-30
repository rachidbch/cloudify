# Plan: cloudify pkg `zitadel` + tailnet deployment

Date: 2026-09-29. Serves SecureVault Phase 8 T5 (identity anchor; ADR-009
there). No Zitadel on Rachid's workstation (RAM/disk stressed) - it runs as
an ivps instance on the tailnet.

## Package: pkg/zitadel (cloudify-pkg-dev skill governs authoring)

- Shape: `pkg/zitadel/{install.sh, configure.sh, verify.sh, uninstall.sh,
  README.md, .version, .remote-vars}` (ADR-008 split, guacamole model).
  Depends on the existing `docker` pkg.
- Architecture (docs-anchored, 2026-10 revalidation via exa + upstream source;
  see HISTORY): the OFFICIAL v4 compose in external-TLS mode - traefik:v3.7.7
  (edge router, h2c to API, Login v2 path routing, root->login rewrite,
  /api strip alias) -> ghcr.io/zitadel/zitadel:v4.19.3 (API, start-from-init
  --masterkey) + ghcr.io/zitadel/zitadel-login:v4.19.3 (Login v2 UI, REQUIRED
  for new instances) -> postgres:17.10-alpine. Single-container merge is
  explicitly rejected upstream (deploy/compose/AGENTS.md). Canonical protocol
  paths (/.well-known, /oauth/v2) stay at root.
- TLS settled (the open point): terminating LB = Tailscale Serve via
  `ivps expose-direct cloudai:zitadel 8080`; Traefik publishes 127.0.0.1:8080
  only. ZITADEL_EXTERNALSECURE=true, EXTERNALPORT=443, TLS_ENABLED=false.
  Issuer: https://zitadel.komodo-everest.ts.net (tailnet-only, ts auto-cert).
  Empirical gate at deploy: serve must preserve Host + set
  X-Forwarded-Proto: https (else zitadel answers "Instance not found").
- Config keys (vars): zitadel_domain (default
  zitadel.komodo-everest.ts.net), zitadel_version (default v4.19.3),
  zitadel_masterkey / session_cookie_secret / postgres passwords (random-
  generated at install when unset, persisted 0600 in the pkg .env; a value may
  arrive via the standard var ladder - .remote-vars declares the names).
- PAT bootstrap (the automation unlock): FirstInstance machine user via
  ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_USERNAME +
  ZITADEL_FIRSTINSTANCE_PATPATH (the same env pattern the official compose
  uses for its login-client PAT) -> Zitadel writes the machine PAT as a raw
  token file (not JSON) into the shared bootstrap volume at instance creation.
  The SA carries IAM_OWNER. The pkg copies it into its 0600 state dir; the
  operator retrieves it once (ssh cat) and stores it as a workstation
  cloudify secret (securevault-bootstrap-pat). No web login ever needed.
- verify.sh: poll GET /debug/ready (NOT /debug/health - does not exist) to
  200 via local Traefik; GET /management/v1/iam with the PAT bearer = 200;
  login UI /ui/v2/login/healthy. Fails the install otherwise.

## Deployment (ivps)

1. Node: cloudai (owner decision 2026-09-29).
2. `ivps launch <node>:zitadel` (Ubuntu 24.04 container OS).
3. TLS/issuer decision: SETTLED - Tailscale Serve auto-TLS (option a);
  see Package section.
4. `cloudify --on <node>:zitadel install zitadel` -> verify green.
5. Expose on the tailnet: `ivps expose-direct cloudai:zitadel 8080`
   (per-container Tailscale Serve, auto-TLS, tailnet-only; no VIP/API-key
   dependency).

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
