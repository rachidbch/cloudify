#!/usr/bin/env bash
# guacamole - install phase (ADR-008 split, k3s-server model).
# Apache Guacamole docker-compose stack: guacamole + guacd + postgres.
# Dep install (docker) + install guard, then: compose/.env provisioning,
# postgres start, one-time schema init (fresh/empty volume only) + admin
# creation. The run phase (configure.sh) starts the full stack and wires the
# RDP connection - `cloudify install` sources both phases in one subshell.
#
# Mechanism rules honored (plans/guacamole-pkg-description.md landmines):
#   - never pipe data through `sudo` (L2): psql always reads SQL from a file
#     that was docker cp'd into the container - args are single tokens only,
#     because the sudo shadow re-joins args with spaces into `bash -c`.
#   - never pass secrets in argv/stdout; secrets travel env -> .env (mode 600)
#     -> docker cp'd SQL files, deleted after use.
#   - install guard sits AFTER pkg_depends (dependency pulls run without FORCE).

# --- Dependency: docker (idempotent; adds the deploy user to the docker group
# for NEW sessions - so this recipe uses `sudo docker` throughout) ---
pkg_depends docker

pkg_apt_install curl jq iproute2

# --- Resolve config (env first, old .env fallback for secrets on reruns) ---
DIR="${CLOUDIFY_GUACAMOLE_DIR:-$HOME/guacamole}"
COMPOSE_FILE="$DIR/docker-compose.yml"
MARKER="$DIR/.guacamole-db-initialized"

# On a rerun the caller may only export the values that change; preserve the
# secrets + RDP target from the previous .env when the env left them unset.
if [[ -f "$DIR/.env" ]]; then
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        val="${val%\'}"
        val="${val#\'}"
        [[ -n "${!key:-}" ]] || export "$key=$val"
    done < <(grep -E '^(CLOUDIFY_GUACAMOLE_(DB_PASSWORD|ADMIN_PASSWORD|RDP_PASSWORD|RDP_HOST))=' "$DIR/.env" 2>/dev/null || true)
fi

# --- Required values ---
[[ -n "${CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD:-}" ]] || die "guacamole: CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD is required (env or ~/.config/cloudify/pkgs/guacamole.yaml)"
[[ -n "${CLOUDIFY_GUACAMOLE_DB_PASSWORD:-}" ]] || die "guacamole: CLOUDIFY_GUACAMOLE_DB_PASSWORD is required (env or ~/.config/cloudify/pkgs/guacamole.yaml)"
[[ -n "${CLOUDIFY_GUACAMOLE_RDP_PASSWORD:-}" ]] || die "guacamole: CLOUDIFY_GUACAMOLE_RDP_PASSWORD is required (env or ~/.config/cloudify/pkgs/guacamole.yaml)"
[[ -n "${CLOUDIFY_GUACAMOLE_RDP_HOST:-}" ]] || die "guacamole: CLOUDIFY_GUACAMOLE_RDP_HOST is required (env or ~/.config/cloudify/pkgs/guacamole.yaml)"
for _v in CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD CLOUDIFY_GUACAMOLE_DB_PASSWORD CLOUDIFY_GUACAMOLE_RDP_PASSWORD; do
    if [[ "${!_v:-}" == *"'"* ]] || [[ "${!_v:-}" == *$'\n'* ]] || [[ "${!_v:-}" == *$'\r'* ]]; then
        die "guacamole: $_v contains a single quote or control char - cloudify cannot forward it (see README)"
    fi
done

CLOUDIFY_GUACAMOLE_VERSION="${CLOUDIFY_GUACAMOLE_VERSION:-1.6.0}"
CLOUDIFY_GUACAMOLE_POSTGRES_VERSION="${CLOUDIFY_GUACAMOLE_POSTGRES_VERSION:-16}"
CLOUDIFY_GUACAMOLE_BIND="${CLOUDIFY_GUACAMOLE_BIND:-127.0.0.1}"
CLOUDIFY_GUACAMOLE_PORT="${CLOUDIFY_GUACAMOLE_PORT:-8080}"
CLOUDIFY_GUACAMOLE_DB_NAME="${CLOUDIFY_GUACAMOLE_DB_NAME:-guacamole_db}"
CLOUDIFY_GUACAMOLE_DB_USER="${CLOUDIFY_GUACAMOLE_DB_USER:-guacamole_user}"
CLOUDIFY_GUACAMOLE_ADMIN_USER="${CLOUDIFY_GUACAMOLE_ADMIN_USER:-rbc}"
CLOUDIFY_GUACAMOLE_RDP_PORT="${CLOUDIFY_GUACAMOLE_RDP_PORT:-3389}"
CLOUDIFY_GUACAMOLE_RDP_USER="${CLOUDIFY_GUACAMOLE_RDP_USER:-gui}"
CLOUDIFY_GUACAMOLE_CONNECTION_NAME="${CLOUDIFY_GUACAMOLE_CONNECTION_NAME:-GUI}"

# --- Value hygiene (values cross the sudo shadow as argv and SQL files) ---
[[ "${CLOUDIFY_GUACAMOLE_DB_USER}" =~ ^[A-Za-z0-9_]+$ ]] || die "guacamole: CLOUDIFY_GUACAMOLE_DB_USER may only contain [A-Za-z0-9_]"
[[ "${CLOUDIFY_GUACAMOLE_DB_NAME}" =~ ^[A-Za-z0-9_]+$ ]] || die "guacamole: CLOUDIFY_GUACAMOLE_DB_NAME may only contain [A-Za-z0-9_]"
[[ "${CLOUDIFY_GUACAMOLE_ADMIN_USER}" =~ ^[A-Za-z0-9_.-]+$ ]] || die "guacamole: CLOUDIFY_GUACAMOLE_ADMIN_USER may only contain [A-Za-z0-9_.-]"
[[ "${CLOUDIFY_GUACAMOLE_PORT}" =~ ^[0-9]+$ ]] || die "guacamole: CLOUDIFY_GUACAMOLE_PORT must be numeric"
[[ "${CLOUDIFY_GUACAMOLE_RDP_PORT}" =~ ^[0-9]+$ ]] || die "guacamole: CLOUDIFY_GUACAMOLE_RDP_PORT must be numeric"

# --- Install guard (after pkg_depends) ---
_project_running() {
    [[ -f "$COMPOSE_FILE" ]] || return 1
    sudo docker compose -f "$COMPOSE_FILE" ps -q 2>/dev/null | grep -q .
}

if _project_running && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "guacamole already running. Skipping (use --clear-data to wipe the database and reinstall)."
    return 0
fi

if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]]; then
    log_warn "guacamole: --clear-data - dropping the postgres volume (destructive, no rollback)."
    if _project_running; then
        sudo docker compose -f "$COMPOSE_FILE" down -v
    fi
    rm -f "$MARKER"
fi

# Port conflict: die when something ELSE already listens on the port.
if ! _project_running && ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${CLOUDIFY_GUACAMOLE_PORT}\$"; then
    die "guacamole: port ${CLOUDIFY_GUACAMOLE_PORT} is already in use (bind ${CLOUDIFY_GUACAMOLE_BIND}). Free it or set CLOUDIFY_GUACAMOLE_PORT."
fi

mkdir -p "$DIR"

# --- .env (single source of truth for compose interpolation + verify reads) ---
cat > "$DIR/.env" <<ENVEOF
# guacamole pkg - generated by cloudify. Secrets: mode 600, never commit.
GUACAMOLE_VERSION='${CLOUDIFY_GUACAMOLE_VERSION}'
GUACAMOLE_POSTGRES_VERSION='${CLOUDIFY_GUACAMOLE_POSTGRES_VERSION}'
GUACAMOLE_BIND='${CLOUDIFY_GUACAMOLE_BIND}'
GUACAMOLE_PORT='${CLOUDIFY_GUACAMOLE_PORT}'
POSTGRES_DATABASE='${CLOUDIFY_GUACAMOLE_DB_NAME}'
POSTGRES_USER='${CLOUDIFY_GUACAMOLE_DB_USER}'
POSTGRES_PASSWORD='${CLOUDIFY_GUACAMOLE_DB_PASSWORD}'
CLOUDIFY_GUACAMOLE_VERSION='${CLOUDIFY_GUACAMOLE_VERSION}'
CLOUDIFY_GUACAMOLE_POSTGRES_VERSION='${CLOUDIFY_GUACAMOLE_POSTGRES_VERSION}'
CLOUDIFY_GUACAMOLE_BIND='${CLOUDIFY_GUACAMOLE_BIND}'
CLOUDIFY_GUACAMOLE_PORT='${CLOUDIFY_GUACAMOLE_PORT}'
CLOUDIFY_GUACAMOLE_DB_NAME='${CLOUDIFY_GUACAMOLE_DB_NAME}'
CLOUDIFY_GUACAMOLE_DB_USER='${CLOUDIFY_GUACAMOLE_DB_USER}'
CLOUDIFY_GUACAMOLE_DB_PASSWORD='${CLOUDIFY_GUACAMOLE_DB_PASSWORD}'
CLOUDIFY_GUACAMOLE_ADMIN_USER='${CLOUDIFY_GUACAMOLE_ADMIN_USER}'
CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD='${CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD}'
CLOUDIFY_GUACAMOLE_RDP_HOST='${CLOUDIFY_GUACAMOLE_RDP_HOST}'
CLOUDIFY_GUACAMOLE_RDP_PORT='${CLOUDIFY_GUACAMOLE_RDP_PORT}'
CLOUDIFY_GUACAMOLE_RDP_USER='${CLOUDIFY_GUACAMOLE_RDP_USER}'
CLOUDIFY_GUACAMOLE_RDP_PASSWORD='${CLOUDIFY_GUACAMOLE_RDP_PASSWORD}'
CLOUDIFY_GUACAMOLE_CONNECTION_NAME='${CLOUDIFY_GUACAMOLE_CONNECTION_NAME}'
ENVEOF
chmod 600 "$DIR/.env"

# --- docker-compose.yml (quoted heredoc: \${} stay literal for compose .env
# interpolation at runtime; only compose reads .env) ---
cat > "$COMPOSE_FILE" <<'COMPOSEEOF'
services:
  postgres:
    image: postgres:${GUACAMOLE_POSTGRES_VERSION}
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DATABASE}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - guacamole_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DATABASE}"]
      interval: 5s
      timeout: 5s
      retries: 30
  guacd:
    image: guacamole/guacd:${GUACAMOLE_VERSION}
    restart: unless-stopped
  guacamole:
    image: guacamole/guacamole:${GUACAMOLE_VERSION}
    restart: unless-stopped
    ports:
      - "${GUACAMOLE_BIND}:${GUACAMOLE_PORT}:8080"
    environment:
      GUACD_HOSTNAME: guacd
      GUACD_PORT: 4822
      POSTGRESQL_ENABLED: "true"
      POSTGRESQL_HOSTNAME: postgres
      POSTGRESQL_PORT: "5432"
      POSTGRESQL_DATABASE: ${POSTGRES_DATABASE}
      POSTGRESQL_USERNAME: ${POSTGRES_USER}
      POSTGRESQL_PASSWORD: ${POSTGRES_PASSWORD}
      WEBAPP_CONTEXT: ROOT
    depends_on:
      postgres:
        condition: service_healthy
      guacd:
        condition: service_started
volumes:
  guacamole_pgdata:
COMPOSEEOF

# --- Start database + guacd (configure.sh starts the guacamole webapp) ---
log_info "guacamole: pulling images and starting postgres + guacd (first run downloads ~1 GiB)..."
sudo docker compose -f "$COMPOSE_FILE" up -d postgres guacd

# Wait until postgres accepts connections (first boot inits the empty volume).
_attempts=0
until sudo docker compose -f "$COMPOSE_FILE" exec -T postgres pg_isready -U "${CLOUDIFY_GUACAMOLE_DB_USER}" -d "${CLOUDIFY_GUACAMOLE_DB_NAME}" >/dev/null 2>&1; do
    _attempts=$((_attempts + 1))
    ((_attempts < 60)) || die "guacamole: postgres not ready after 180s - check 'docker compose -f $COMPOSE_FILE logs postgres'"
    sleep 3
done

# --- One-time schema init + admin creation (fresh or partial state only) ---
if [[ ! -f "$MARKER" ]]; then
    PG_CID="$(sudo docker compose -f "$COMPOSE_FILE" ps -q postgres | head -n1)"
    [[ -n "$PG_CID" ]] || die "guacamole: postgres container not found"

    # Partial-init detection: schema present but no marker (e.g. crash between
    # initdb and marker write) -> do NOT reseed; just ensure the admin.
    cat > "$DIR/.check.sql" <<'SQLEOF'
SELECT count(*) FROM information_schema.tables WHERE table_name = 'guacamole_entity';
SQLEOF
    sudo docker cp "$DIR/.check.sql" "$PG_CID":/tmp/.check.sql
    _schema_present="$(sudo docker exec "$PG_CID" psql -U "${CLOUDIFY_GUACAMOLE_DB_USER}" -d "${CLOUDIFY_GUACAMOLE_DB_NAME}" -tA -f /tmp/.check.sql 2>/dev/null | tr -d '[:space:]')"
    sudo docker exec "$PG_CID" rm -f /tmp/.check.sql

    if [[ "$_schema_present" != "1" ]]; then
        log_info "guacamole: initializing database schema (empty volume)..."
        # shellcheck disable=SC2024  # intentional: docker run needs root (sudo); the SQL output file is owned by the invoking user, not root
        sudo docker run --rm "guacamole/guacamole:${CLOUDIFY_GUACAMOLE_VERSION}" /opt/guacamole/bin/initdb.sh --postgresql > "$DIR/initdb.sql" \
            || die "guacamole: initdb.sh failed"
        sudo docker cp "$DIR/initdb.sql" "$PG_CID":/tmp/initdb.sql
        sudo docker exec "$PG_CID" psql -U "${CLOUDIFY_GUACAMOLE_DB_USER}" -d "${CLOUDIFY_GUACAMOLE_DB_NAME}" -v ON_ERROR_STOP=1 -q -f /tmp/initdb.sql \
            || die "guacamole: schema load failed - see 'docker compose -f $COMPOSE_FILE logs postgres'"
        sudo docker exec "$PG_CID" rm -f /tmp/initdb.sql
        rm -f "$DIR/initdb.sql"
    fi

    # Admin: exact oracle hash formula (SOP) - sha256(password + UPPERCASE_HEX_SALT).
    # Salt = 32 random bytes as uppercase hex; hash bytes stored via decode(hex).
    # Idempotent: matches guacadmin OR the configured admin user, renames guacadmin.
    _SALT_HEX="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')"
    _HASH_HEX="$(printf '%s%s' "${CLOUDIFY_GUACAMOLE_ADMIN_PASSWORD}" "$_SALT_HEX" | sha256sum | cut -d' ' -f1)"
    _ADMIN_SQL_USER="$(printf '%s' "${CLOUDIFY_GUACAMOLE_ADMIN_USER}" | sed "s/'/''/g")"
    cat > "$DIR/.admin.sql" <<SQLEOF
UPDATE guacamole_user
   SET password_hash = decode('${_HASH_HEX}', 'hex'),
       password_salt = decode('${_SALT_HEX}', 'hex')
 WHERE user_id = (
       SELECT u.user_id FROM guacamole_user u
         JOIN guacamole_entity e ON u.entity_id = e.entity_id
        WHERE e.name IN ('guacadmin', '${_ADMIN_SQL_USER}')
        ORDER BY CASE WHEN e.name = '${_ADMIN_SQL_USER}' THEN 0 ELSE 1 END
        LIMIT 1);
UPDATE guacamole_entity SET name = '${_ADMIN_SQL_USER}' WHERE name = 'guacadmin';
SQLEOF
    chmod 600 "$DIR/.admin.sql"
    sudo docker cp "$DIR/.admin.sql" "$PG_CID":/tmp/.admin.sql
    sudo docker exec "$PG_CID" psql -U "${CLOUDIFY_GUACAMOLE_DB_USER}" -d "${CLOUDIFY_GUACAMOLE_DB_NAME}" -v ON_ERROR_STOP=1 -q -f /tmp/.admin.sql \
        || die "guacamole: admin setup failed"
    sudo docker exec "$PG_CID" rm -f /tmp/.admin.sql
    rm -f "$DIR/.admin.sql" "$DIR/.check.sql"

    touch "$MARKER"
    log_info "guacamole: database initialized, administrator '${CLOUDIFY_GUACAMOLE_ADMIN_USER}' created."
fi

log_info "guacamole: install phase done - the configure phase starts the webapp and creates the RDP connection."
