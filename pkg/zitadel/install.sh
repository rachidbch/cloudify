#!/usr/bin/env bash
# zitadel - install phase (ADR-008 split, guacamole model).
# Zitadel IdP via the OFFICIAL v4 compose stack in external-TLS mode:
# traefik -> zitadel-api (start-from-init, h2c) + zitadel-login (Login v2)
# -> postgres. TLS is terminated OUTSIDE the stack (Tailscale Serve via
# `ivps expose-direct`); traefik publishes 127.0.0.1:<port> only.
# A bootstrap machine PAT (IAM_OWNER) is written by Zitadel's FirstInstance
# job into the shared bootstrap volume; install copies it to 0600 state.
#
# Design provenance: plans/zitadel-pkg.md (docs-anchored 2026-10).
# Mechanism rules honored:
#   - secrets travel env -> .env (mode 600) -> compose interpolation; never
#     argv outside the payload, never the repo, never stdout.
#   - install guard sits AFTER pkg_depends (dependency pulls run without FORCE).

pkg_depends docker
pkg_apt_install curl jq

# --- Resolve config (env first; old .env fallback keeps reruns secret-stable) ---
DIR="${CLOUDIFY_ZITADEL_DIR:-$HOME/zitadel}"
ENV_FILE="$DIR/.env"
COMPOSE_FILE="$DIR/docker-compose.yml"

if [[ -f "$ENV_FILE" ]]; then
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        val="${val%\'}"
        val="${val#\'}"
        [[ -n "${!key:-}" ]] || export "$key=$val"
    done < <(grep -E '^(CLOUDIFY_ZITADEL_(DOMAIN|VERSION|BIND|PORT|MASTERKEY|SESSION_COOKIE_SECRET|POSTGRES_PASSWORD))=' "$ENV_FILE" 2>/dev/null || true)
fi

[[ -n "${CLOUDIFY_ZITADEL_DOMAIN:-}" ]] || die "zitadel: CLOUDIFY_ZITADEL_DOMAIN is required (env or ~/.config/cloudify/pkgs/zitadel.yaml) - the public https name, e.g. zitadel.<tailnet>.ts.net"

CLOUDIFY_ZITADEL_VERSION="${CLOUDIFY_ZITADEL_VERSION:-v4.19.3}"
CLOUDIFY_ZITADEL_TRAEFIK_IMAGE="${CLOUDIFY_ZITADEL_TRAEFIK_IMAGE:-traefik:v3.7.7}"
CLOUDIFY_ZITADEL_POSTGRES_IMAGE="${CLOUDIFY_ZITADEL_POSTGRES_IMAGE:-postgres:17.10-alpine}"
CLOUDIFY_ZITADEL_BIND="${CLOUDIFY_ZITADEL_BIND:-127.0.0.1}"
CLOUDIFY_ZITADEL_PORT="${CLOUDIFY_ZITADEL_PORT:-8080}"
CLOUDIFY_ZITADEL_BOOTSTRAP_MACHINE="${CLOUDIFY_ZITADEL_BOOTSTRAP_MACHINE:-securevault-bootstrap}"
CLOUDIFY_ZITADEL_PAT_EXPIRATION="${CLOUDIFY_ZITADEL_PAT_EXPIRATION:-2099-01-01T00:00:00Z}"
CLOUDIFY_ZITADEL_TRUSTED_IPS="${CLOUDIFY_ZITADEL_TRUSTED_IPS:-127.0.0.1/32,::1/128,100.64.0.0/10}"

# --- Value hygiene (values cross the payload as single-quoted env + compose) ---
[[ "${CLOUDIFY_ZITADEL_DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]] || die "zitadel: CLOUDIFY_ZITADEL_DOMAIN may only contain [A-Za-z0-9.-]"
[[ "${CLOUDIFY_ZITADEL_PORT}" =~ ^[0-9]+$ ]] || die "zitadel: CLOUDIFY_ZITADEL_PORT must be numeric"
[[ "${CLOUDIFY_ZITADEL_BOOTSTRAP_MACHINE}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "zitadel: CLOUDIFY_ZITADEL_BOOTSTRAP_MACHINE may only contain [A-Za-z0-9_.-]"
for _v in CLOUDIFY_ZITADEL_MASTERKEY CLOUDIFY_ZITADEL_SESSION_COOKIE_SECRET CLOUDIFY_ZITADEL_POSTGRES_PASSWORD; do
    if [[ "${!_v:-}" == *"'"* ]] || [[ "${!_v:-}" == *$'\n'* ]] || [[ "${!_v:-}" == *$'\r'* ]]; then
        die "zitadel: $_v contains a single quote or control char - cloudify cannot forward it (see README)"
    fi
done
if [[ -n "${CLOUDIFY_ZITADEL_MASTERKEY:-}" ]] && (( ${#CLOUDIFY_ZITADEL_MASTERKEY} != 32 )); then
    die "zitadel: CLOUDIFY_ZITADEL_MASTERKEY must be exactly 32 characters (upstream contract)"
fi

# --- Generate secrets once when unset (docs hardening recipe; alnum only) ---
_gen32() { tr -dc A-Za-z0-9 </dev/urandom | head -c 32; }
[[ -n "${CLOUDIFY_ZITADEL_MASTERKEY:-}" ]] || CLOUDIFY_ZITADEL_MASTERKEY="$(_gen32)"
[[ -n "${CLOUDIFY_ZITADEL_SESSION_COOKIE_SECRET:-}" ]] || CLOUDIFY_ZITADEL_SESSION_COOKIE_SECRET="$(_gen32)"
[[ -n "${CLOUDIFY_ZITADEL_POSTGRES_PASSWORD:-}" ]] || CLOUDIFY_ZITADEL_POSTGRES_PASSWORD="$(_gen32)"

# --- Install guard (after pkg_depends) ---
_project_running() {
    [[ -f "$COMPOSE_FILE" ]] || return 1
    sudo docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .
}

if _project_running && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "zitadel already running. Skipping (use --clear-data to drop all data and reinstall)."
    return 0
fi

if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_warn "zitadel: --clear-data - dropping ALL state (postgres + bootstrap volumes; the instance is destroyed, the masterkey-encrypted data is unrecoverable)."
    if _project_running; then
        sudo docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
    fi
    rm -f "$DIR/bootstrap.pat"
fi

# Port conflict: die when something ELSE already listens on the port.
if ! _project_running && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${CLOUDIFY_ZITADEL_PORT}\$"; then
    die "zitadel: port ${CLOUDIFY_ZITADEL_PORT} is already in use (bind ${CLOUDIFY_ZITADEL_BIND}). Free it or set CLOUDIFY_ZITADEL_PORT."
fi

mkdir -p "$DIR"

# --- .env (single source of truth for compose interpolation + verify reads).
# Create-if-absent: install never mutates existing config; configure rewrites it. ---
if [[ ! -f "$ENV_FILE" ]]; then
cat > "$ENV_FILE" <<ENVEOF
# zitadel pkg - generated by cloudify. Secrets: mode 600, never commit.
# The masterkey cannot be changed after init without losing encrypted data.
ZITADEL_VERSION='${CLOUDIFY_ZITADEL_VERSION}'
ZITADEL_TRAEFIK_IMAGE='${CLOUDIFY_ZITADEL_TRAEFIK_IMAGE}'
ZITADEL_POSTGRES_IMAGE='${CLOUDIFY_ZITADEL_POSTGRES_IMAGE}'
ZITADEL_DOMAIN='${CLOUDIFY_ZITADEL_DOMAIN}'
ZITADEL_BIND='${CLOUDIFY_ZITADEL_BIND}'
ZITADEL_PORT='${CLOUDIFY_ZITADEL_PORT}'
ZITADEL_MASTERKEY='${CLOUDIFY_ZITADEL_MASTERKEY}'
ZITADEL_SESSION_COOKIE_SECRET='${CLOUDIFY_ZITADEL_SESSION_COOKIE_SECRET}'
ZITADEL_POSTGRES_PASSWORD='${CLOUDIFY_ZITADEL_POSTGRES_PASSWORD}'
ZITADEL_DATABASE_POSTGRES_DSN='postgresql://postgres:${CLOUDIFY_ZITADEL_POSTGRES_PASSWORD}@postgres:5432/zitadel?sslmode=disable'
ZITADEL_BOOTSTRAP_MACHINE='${CLOUDIFY_ZITADEL_BOOTSTRAP_MACHINE}'
ZITADEL_PAT_EXPIRATION='${CLOUDIFY_ZITADEL_PAT_EXPIRATION}'
ZITADEL_TRUSTED_IPS='${CLOUDIFY_ZITADEL_TRUSTED_IPS}'
CLOUDIFY_ZITADEL_VERSION='${CLOUDIFY_ZITADEL_VERSION}'
CLOUDIFY_ZITADEL_DOMAIN='${CLOUDIFY_ZITADEL_DOMAIN}'
CLOUDIFY_ZITADEL_BIND='${CLOUDIFY_ZITADEL_BIND}'
CLOUDIFY_ZITADEL_PORT='${CLOUDIFY_ZITADEL_PORT}'
ENVEOF
chmod 600 "$ENV_FILE"
fi

# --- docker-compose.yml (quoted heredoc: \${} stay literal for compose .env
# interpolation at runtime; only compose reads .env). Create-if-absent. ---
if [[ ! -f "$COMPOSE_FILE" ]]; then
cat > "$COMPOSE_FILE" <<'COMPOSEEOF'
services:
  proxy:
    image: ${ZITADEL_TRAEFIK_IMAGE}
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=zitadel
      - --entrypoints.web.address=:80
      - --entrypoints.web.forwardedHeaders.trustedIPs=${ZITADEL_TRUSTED_IPS}
      - --api.dashboard=false
      - --api.insecure=false
      - --ping=true
      - --ping.entrypoint=web
      - --log.level=INFO
      - --accesslog=true
    ports:
      - "${ZITADEL_BIND}:${ZITADEL_PORT}:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    depends_on:
      zitadel-api:
        condition: service_healthy
      zitadel-login:
        condition: service_healthy
    networks:
      - zitadel
  zitadel-api:
    image: ghcr.io/zitadel/zitadel:${ZITADEL_VERSION}
    restart: unless-stopped
    user: "0"
    command: start-from-init --masterkey "${ZITADEL_MASTERKEY}"
    environment:
      ZITADEL_PORT: 8080
      ZITADEL_EXTERNALDOMAIN: ${ZITADEL_DOMAIN}
      ZITADEL_EXTERNALPORT: 443
      ZITADEL_EXTERNALSECURE: "true"
      ZITADEL_TLS_ENABLED: "false"
      ZITADEL_DATABASE_POSTGRES_DSN: ${ZITADEL_DATABASE_POSTGRES_DSN}
      ZITADEL_LOGSTORE_ACCESS_STDOUT_ENABLED: "true"
      ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_REQUIRED: "true"
      ZITADEL_DEFAULTINSTANCE_FEATURES_LOGINV2_BASEURI: https://${ZITADEL_DOMAIN}/ui/v2/login/
      ZITADEL_OIDC_DEFAULTLOGINURLV2: https://${ZITADEL_DOMAIN}/ui/v2/login/login?authRequest=
      ZITADEL_OIDC_DEFAULTLOGOUTURLV2: https://${ZITADEL_DOMAIN}/ui/v2/login/logout?post_logout_redirect=
      ZITADEL_SAML_DEFAULTLOGINURLV2: https://${ZITADEL_DOMAIN}/ui/v2/login/login?samlRequest=
      ZITADEL_FIRSTINSTANCE_LOGINCLIENTPATPATH: /zitadel/bootstrap/login-client.pat
      ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINE_USERNAME: login-client
      ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_MACHINE_NAME: Automatically Initialized IAM_LOGIN_CLIENT
      ZITADEL_FIRSTINSTANCE_ORG_LOGINCLIENT_PAT_EXPIRATIONDATE: ${ZITADEL_PAT_EXPIRATION}
      ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_USERNAME: ${ZITADEL_BOOTSTRAP_MACHINE}
      ZITADEL_FIRSTINSTANCE_ORG_MACHINE_MACHINE_NAME: cloudify bootstrap IAM_OWNER
      ZITADEL_FIRSTINSTANCE_ORG_MACHINE_PAT_EXPIRATIONDATE: ${ZITADEL_PAT_EXPIRATION}
      ZITADEL_FIRSTINSTANCE_PATPATH: /zitadel/bootstrap/securevault-bootstrap.pat
    healthcheck:
      test: ["CMD", "/app/zitadel", "ready"]
      interval: 10s
      timeout: 30s
      retries: 12
      start_period: 20s
    volumes:
      - zitadel-bootstrap:/zitadel/bootstrap:rw
    networks:
      - zitadel
    depends_on:
      postgres:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - traefik.docker.network=zitadel
      - traefik.http.services.zitadel-api.loadbalancer.server.port=8080
      - traefik.http.services.zitadel-api.loadbalancer.server.scheme=h2c
      - traefik.http.middlewares.zitadel-strip-api.stripprefix.prefixes=/api
      - traefik.http.middlewares.zitadel-strip-api.stripprefix.forceSlash=false
      - traefik.http.routers.zitadel-api-alias-web.rule=Host(`${ZITADEL_DOMAIN}`) && PathPrefix(`/api`)
      - traefik.http.routers.zitadel-api-alias-web.entrypoints=web
      - traefik.http.routers.zitadel-api-alias-web.middlewares=zitadel-strip-api
      - traefik.http.routers.zitadel-api-alias-web.service=zitadel-api
      - traefik.http.routers.zitadel-api-alias-web.priority=200
      - traefik.http.routers.zitadel-canonical-web.rule=Host(`${ZITADEL_DOMAIN}`) && !PathPrefix(`/ui/v2/login`) && !PathPrefix(`/api`) && !Path(`/`)
      - traefik.http.routers.zitadel-canonical-web.entrypoints=web
      - traefik.http.routers.zitadel-canonical-web.service=zitadel-api
      - traefik.http.routers.zitadel-canonical-web.priority=100
  zitadel-login:
    image: ghcr.io/zitadel/zitadel-login:${ZITADEL_VERSION}
    restart: unless-stopped
    user: "0"
    environment:
      ZITADEL_API_URL: http://zitadel-api:8080
      NEXT_PUBLIC_BASE_PATH: /ui/v2/login
      ZITADEL_SERVICE_USER_TOKEN_FILE: /zitadel/bootstrap/login-client.pat
      ZITADEL_SESSION_COOKIE_SECRET: ${ZITADEL_SESSION_COOKIE_SECRET}
      CUSTOM_REQUEST_HEADERS: Host:${ZITADEL_DOMAIN},X-Forwarded-Proto:https
    healthcheck:
      test: ["CMD", "/bin/sh", "-c", "node /app/healthcheck.mjs http://localhost:3000/ui/v2/login/healthy"]
      interval: 10s
      timeout: 30s
      retries: 12
      start_period: 20s
    volumes:
      - zitadel-bootstrap:/zitadel/bootstrap:ro
    networks:
      - zitadel
    depends_on:
      zitadel-api:
        condition: service_healthy
    labels:
      - traefik.enable=true
      - traefik.docker.network=zitadel
      - traefik.http.services.zitadel-login.loadbalancer.server.port=3000
      - traefik.http.middlewares.zitadel-root-rewrite.replacepath.path=/ui/v2/login/
      - traefik.http.routers.zitadel-root-web.rule=Host(`${ZITADEL_DOMAIN}`) && Path(`/`)
      - traefik.http.routers.zitadel-root-web.entrypoints=web
      - traefik.http.routers.zitadel-root-web.middlewares=zitadel-root-rewrite
      - traefik.http.routers.zitadel-root-web.service=zitadel-login
      - traefik.http.routers.zitadel-root-web.priority=400
      - traefik.http.routers.zitadel-login-web.rule=Host(`${ZITADEL_DOMAIN}`) && PathPrefix(`/ui/v2/login`)
      - traefik.http.routers.zitadel-login-web.entrypoints=web
      - traefik.http.routers.zitadel-login-web.service=zitadel-login
      - traefik.http.routers.zitadel-login-web.priority=250
  postgres:
    image: ${ZITADEL_POSTGRES_IMAGE}
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${ZITADEL_POSTGRES_PASSWORD}
      POSTGRES_USER: postgres
      POSTGRES_DB: zitadel
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d zitadel -U postgres"]
      interval: 10s
      timeout: 30s
      retries: 10
      start_period: 20s
    volumes:
      - zitadel-postgres:/var/lib/postgresql/data:rw
    networks:
      - zitadel
networks:
  zitadel:
    name: zitadel
volumes:
  zitadel-postgres:
  zitadel-bootstrap:
COMPOSEEOF
fi

# --- Start the stack (first run pulls ~1.5 GiB of images) ---
log_info "zitadel: pulling images and starting the stack (first run downloads ~1.5 GiB)..."
sudo docker compose -f "$COMPOSE_FILE" up -d --wait --wait-timeout 600 \
    || die "zitadel: stack did not become healthy within 600s - check 'sudo docker compose -f $COMPOSE_FILE logs'"

# --- Wait for readiness through the stack's own proxy (Host-routed) ---
log_info "zitadel: waiting for /debug/ready through traefik..."
_attempts=0
until curl -fsS -o /dev/null -H "Host: ${CLOUDIFY_ZITADEL_DOMAIN}" "http://127.0.0.1:${CLOUDIFY_ZITADEL_PORT}/debug/ready" 2>/dev/null; do
    _attempts=$((_attempts + 1))
    ((_attempts < 60)) || die "zitadel: /debug/ready not green after 180s - check 'sudo docker compose -f $COMPOSE_FILE logs zitadel-api'"
    sleep 3
done

# --- Copy the bootstrap PAT out of the volume into 0600 state (no stdout) ---
_pat_file="$DIR/bootstrap.pat"
if sudo docker compose -f "$COMPOSE_FILE" exec -T zitadel-api cat /zitadel/bootstrap/securevault-bootstrap.pat 2>/dev/null | tr -d '\r\n' > "$_pat_file"; then
    chmod 600 "$_pat_file"
    [[ -s "$_pat_file" ]] || die "zitadel: bootstrap PAT file is empty - instance init did not write it"
else
    die "zitadel: could not read the bootstrap PAT from the volume - did instance init run? (--clear-data reinstalls fresh)"
fi

msg ""
msg "${GREEN}Zitadel ${CLOUDIFY_ZITADEL_VERSION} installed and healthy on 127.0.0.1:${CLOUDIFY_ZITADEL_PORT}.${RESET}"
msg ""
msg "Issuer (once exposed):  https://${CLOUDIFY_ZITADEL_DOMAIN}"
msg "Bootstrap PAT:          ${_pat_file} (IAM_OWNER machine '${CLOUDIFY_ZITADEL_BOOTSTRAP_MACHINE}')"
msg "Tailnet exposure:       ivps expose-direct <node>:zitadel ${CLOUDIFY_ZITADEL_PORT}"
msg ""
msg "Service management:"
msg "  sudo docker compose -f ${COMPOSE_FILE} ps|logs"
msg ""
