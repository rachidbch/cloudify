#!/usr/bin/env bash
# octop - install phase (ADR-008 split): provision the self-hosted AI
# assistant (github.com/TencentCloud/Octop, PyPI `octop`) via the official
# installer, unattended-init the control plane, and register the systemd
# service through Octop's own `octop service` (user scope, affine precedent).
# Create-if-absent; converging live config is configure.sh's job.
#
# State layout (docs/configuration.md): everything under $OCTOP_HOME
# (default ~/.octop): venv, bin/octop wrapper, octop.db, config.json, env
# (dotenv the server loads itself), secrets/, agents/.
#
# Config (~/.config/cloudify/pkgs/octop.yaml or caller env):
#   OCTOP_VERSION (default 1.0.2b6, PyPI-style)
#   OCTOP_PORT (default 8088)   OCTOP_BIND_HOST (default 127.0.0.1)
#   OCTOP_LOG_LEVEL (default info)
#   OCTOP_ADMIN_USERNAME / OCTOP_ADMIN_PASSWORD - first-boot admin, secrets;
#     read from process env during `octop init`, NEVER written to disk here.

OCTOP_VERSION="${OCTOP_VERSION:-1.0.2b6}"
OCTOP_PORT="${OCTOP_PORT:-8088}"
OCTOP_BIND_HOST="${OCTOP_BIND_HOST:-127.0.0.1}"
OCTOP_LOG_LEVEL="${OCTOP_LOG_LEVEL:-info}"
OCTOP_HOME="${OCTOP_HOME:-$HOME/.octop}"
OCTOP_BIN="$OCTOP_HOME/bin/octop"
OCTOP_INSTALLER="https://finnie-1258344699.cos.ap-guangzhou.myqcloud.com/octop/install.sh"

# The installer + recipe resolve the wrapper through ~/.octop/bin.
export PATH="$OCTOP_HOME/bin:$PATH"

# --- Install guard -----------------------------------------------------------
if [[ -x "$OCTOP_BIN" ]] && systemctl --user is-active octop >/dev/null 2>&1 \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "octop already installed and running. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Clear data if requested --------------------------------------------------
# The whole OCTOP_HOME dies: venv + control-plane DB + admin + workspaces.
# A wiped admin is a dead admin - the next install re-inits from scratch.
if [[ "${CLOUDIFY_CLEAR_DATA:-}" == "true" ]] && [[ -d "$OCTOP_HOME" ]]; then
    log_info "octop: clearing $OCTOP_HOME (venv + database + workspaces)..."
    systemctl --user stop octop 2>/dev/null || true
    rm -rf "$OCTOP_HOME" || die "octop: cannot remove $OCTOP_HOME" 1
fi

# --- Install (official installer, pinned version) ------------------------------
if [[ ! -x "$OCTOP_BIN" ]]; then
    log_info "octop: running official installer (version $OCTOP_VERSION; uv venv under $OCTOP_HOME)..."
    _installer=$(mktemp) || die "octop: cannot create temp file" 1
    curl -fsSL "$OCTOP_INSTALLER" -o "$_installer" \
        || { rm -f "$_installer"; die "octop: cannot download the installer from $OCTOP_INSTALLER" 1; }
    bash "$_installer" --version "$OCTOP_VERSION"
    _rc=$?
    rm -f "$_installer"
    [[ $_rc -eq 0 ]] || die "octop: installer failed (see its output above; version '$OCTOP_VERSION' on PyPI?)" 1
else
    log_info "octop: wrapper already present at $OCTOP_BIN - keeping it (upgrade is OCTOP_VERSION + --clear-data)"
fi

# Postcondition: the wrapper answers.
[[ -x "$OCTOP_BIN" ]] || die "octop: $OCTOP_BIN missing after install" 1
"$OCTOP_BIN" version || die "octop: 'octop version' failed after install" 1

# --- Unattended first-boot init ------------------------------------------------
# docs/configuration.md: OCTOP_ADMIN_USERNAME/PASSWORD + REQUIRE_SETUP_PASSWORD=false
# is the sanctioned unattended bootstrap. Creds live in process env only -
# this recipe never writes them to $OCTOP_HOME/env or anywhere else.
if [[ ! -f "$OCTOP_HOME/octop.db" ]]; then
    if [[ -z "${OCTOP_ADMIN_USERNAME:-}" || -z "${OCTOP_ADMIN_PASSWORD:-}" ]]; then
        die "octop: no $OCTOP_HOME/octop.db and no OCTOP_ADMIN_USERNAME/OCTOP_ADMIN_PASSWORD - cannot run the unattended first-boot init (supply both; they are never persisted)" 1
    fi
    [[ "${OCTOP_ADMIN_PASSWORD}" != *"'"* && "${OCTOP_ADMIN_PASSWORD}" != *$'\n'* && "${OCTOP_ADMIN_PASSWORD}" != *$'\r'* ]] \
        || die "octop: OCTOP_ADMIN_PASSWORD contains a single quote or control char - cloudify cannot forward it (see README)" 1
    log_info "octop: unattended init (admin '${OCTOP_ADMIN_USERNAME}', creds never persisted)..."
    OCTOP_REQUIRE_SETUP_PASSWORD=false \
    OCTOP_ADMIN_USERNAME="$OCTOP_ADMIN_USERNAME" \
    OCTOP_ADMIN_PASSWORD="$OCTOP_ADMIN_PASSWORD" \
        "$OCTOP_BIN" init </dev/null \
        || die "octop: 'octop init' failed - see $OCTOP_HOME/octop.log" 1
else
    log_info "octop: $OCTOP_HOME/octop.db present - init skipped (existing users stand)"
fi

# --- Baseline runtime config (first converge, files only) ----------------------
# The server loads $OCTOP_HOME/env itself at start; install writes the baseline
# so the first boot serves on the declared port/bind. Later convergence is
# configure.sh's job (same upsert, never destructive to foreign keys).
mkdir -p "$OCTOP_HOME" || die "octop: cannot create $OCTOP_HOME" 1
touch "$OCTOP_HOME/env" && chmod 600 "$OCTOP_HOME/env"
_cloudify_octop_env_upsert() {
    local key="$1" value="$2" file="$OCTOP_HOME/env"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}
_cloudify_octop_env_upsert OCTOP_PORT "$OCTOP_PORT"
_cloudify_octop_env_upsert OCTOP_BIND_HOST "$OCTOP_BIND_HOST"
_cloudify_octop_env_upsert OCTOP_LOG_LEVEL "$OCTOP_LOG_LEVEL"

# --- systemd user service (Octop's own registration) ---------------------------
# `octop service start` installs the unit if missing (+ LimitNOFILE drop-in)
# and starts it. We force user scope for determinism (affine precedent).
export OCTOP_SERVICE_SCOPE=user
loginctl enable-linger "$USER" 2>/dev/null || true
"$OCTOP_BIN" service start || die "octop: 'octop service start' failed - see journalctl --user -u octop" 1
systemctl --user is-active octop >/dev/null 2>&1 \
    || die "octop: service not active after start" 1

# --- Wait for health ------------------------------------------------------------
_ok=""
for _ in $(seq 1 60); do
    _body=$(curl -s --max-time 3 "http://127.0.0.1:${OCTOP_PORT}/health" 2>/dev/null || true)
    [[ "$_body" == *'"status": "ok"'* || "$_body" == *'"status":"ok"'* ]] && { _ok=1; break; }
    sleep 2
done
if [[ -z "$_ok" ]]; then
    journalctl --user -u octop -n 20 --no-pager || true
    die "octop: no healthy /health on 127.0.0.1:${OCTOP_PORT} after install" 1
fi

# --- Post-install ----------------------------------------------------------------
msg ""
msg "${GREEN}octop running (systemd user unit 'octop')${RESET}"
msg "Health:   http://127.0.0.1:${OCTOP_PORT}/health"
msg "Dashboard: http://${OCTOP_BIND_HOST}:${OCTOP_PORT}/ (bind per OCTOP_BIND_HOST)"
msg "State:    $OCTOP_HOME (database, workspaces, env file)"
msg "Logs:     journalctl --user -u octop -f"
msg "Admin:    first admin '${OCTOP_ADMIN_USERNAME:-existing}' (creds supplied at init only; never stored by cloudify)"
msg ""
