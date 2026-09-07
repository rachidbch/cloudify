#!/usr/bin/env bash
# xfce - install phase (ADR-008 split). XFCE desktop + xrdp GUI endpoint on an
# Ubuntu guest. Owns: desktop pkgs, the GUI login account (human-given name;
# password env-passed or auto-generated+printed), .xsession, default-browser
# registration, xrdp service + key.pem. Does NOT own Incus/Tailscale/guacamole.
#
# Ground truth: plans/xfce-pkg-plan.md fact table (verified on the guac-gui
# oracle 2026-09-07). Mechanism rules as in plans/guacamole-pkg-description.md:
# no data piped through `sudo` - host files are staged to a temp file then
# `sudo install`'d (single-token args only); the password crosses sudo's stdin
# via chpasswd with a validated quote-free value (L1/L2).

# --- Resolve config: env first, then the on-guest state file (last install) ---
STATE_FILE=/etc/cloudify/xfce-user.env
if [[ -f "$STATE_FILE" ]]; then
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        val="${val%\'}"
        val="${val#\'}"
        export "_st_${key}=$val"
    done < <(grep -E '^XFCE_(USER|PASSWORD|SESSION|CHROME|RDP_PORT)=' "$STATE_FILE" 2>/dev/null || true)
fi

XFCE_USER="${CLOUDIFY_XFCE_USER:-${_st_XFCE_USER:-gui}}"
XFCE_SESSION="${CLOUDIFY_XFCE_SESSION:-${_st_XFCE_SESSION:-startxfce4}}"
XFCE_RDP_PORT="${CLOUDIFY_XFCE_RDP_PORT:-${_st_XFCE_RDP_PORT:-3389}}"
XFCE_CHROME="${CLOUDIFY_XFCE_INSTALL_CHROME:-${_st_XFCE_CHROME:-true}}"

# --- Value hygiene (values cross the sudo shadow as argv or stdin) ---
[[ "$XFCE_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "xfce: CLOUDIFY_XFCE_USER '$XFCE_USER' is not a valid POSIX username"
[[ "$XFCE_SESSION" =~ ^[A-Za-z0-9_./-]+$ ]] || die "xfce: CLOUDIFY_XFCE_SESSION '$XFCE_SESSION' contains unsafe characters"
[[ "$XFCE_RDP_PORT" =~ ^[0-9]+$ ]] || die "xfce: CLOUDIFY_XFCE_RDP_PORT must be numeric"
if [[ -n "${CLOUDIFY_XFCE_USER_PASSWORD:-}" ]]; then
    if [[ "${CLOUDIFY_XFCE_USER_PASSWORD}" == *"'"* ]] || [[ "${CLOUDIFY_XFCE_USER_PASSWORD}" == *$'\n'* ]] || [[ "${CLOUDIFY_XFCE_USER_PASSWORD}" == *$'\r'* ]]; then
        die "xfce: CLOUDIFY_XFCE_USER_PASSWORD contains a single quote or control char (payload landmine)"
    fi
fi

# --- Install guard (BEFORE heavy apt; explicit installs are FORCE and re-run) ---
_xfce_user_exists() { getent passwd "$1" >/dev/null 2>&1; }
if _xfce_user_exists "$XFCE_USER" && [[ -f "$STATE_FILE" ]] && systemctl is-active --quiet xrdp 2>/dev/null \
   && [[ -z "${CLOUDIFY_FORCE:-}" ]] && [[ -z "${CLOUDIFY_CLEAR_DATA:-}" ]]; then
    log_info "xfce already installed for user $XFCE_USER. Skipping (use --clear-data to reinstall)."
    return 0
fi

# --- Packages (oracle fact table). Heartbeat between batches so long apt runs
# are visible as progress, not silence. NOTE: recipes run sourced inside
# pkg_depends' `if ! ( ... )` subshell, so errexit is SUSPENDED - every
# failure-prone command needs explicit `|| die`; never rely on set -e here.
log_info "xfce: installing desktop packages (xfce4, goodies) - first install takes minutes..."
pkg_apt_install xfce4 xfce4-goodies xdg-utils || die "xfce: apt install of the desktop failed"
log_info "xfce: installing RDP server packages (xrdp, xorgxrdp, dbus-x11)..."
pkg_apt_install xrdp xorgxrdp dbus-x11 || die "xfce: apt install of xrdp failed"

# --- Chrome via the google-chrome apt repo (oracle fact: DEB822 + keyring).
# Key: dl.google.com serves an ASCII-armored key; apt needs a DEARMORED binary
# keyring (oracle: /usr/share/keyrings/google-chrome.gpg, key 7721F63BD38B4796).
# The repo file is written once; the key is (re)installed every run so a bad
# previous key cannot wedge a rerun.
if [[ "$XFCE_CHROME" == "true" ]]; then
    log_info "xfce: adding google-chrome apt repo..."
    command -v gpg >/dev/null 2>&1 || pkg_apt_install gnupg || die "xfce: gnupg required for the chrome keyring"
    sudo install -d -m 755 /usr/share/keyrings || die "xfce: cannot create /usr/share/keyrings"
    _tmpkey=$(mktemp)
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub -o "$_tmpkey" \
        || die "xfce: failed to fetch the google-chrome signing key"
    _tmpkg=$(mktemp)
    gpg --dearmor < "$_tmpkey" > "$_tmpkg" \
        || die "xfce: failed to dearmor the google-chrome signing key"
    rm -f "$_tmpkey"
    sudo install -o root -g root -m 644 "$_tmpkg" /usr/share/keyrings/google-chrome.gpg \
        || die "xfce: failed to install the chrome keyring"
    rm -f "$_tmpkg"
    if [[ ! -f /etc/apt/sources.list.d/google-chrome.sources ]]; then
        _tmpsrc=$(mktemp)
        cat > "$_tmpsrc" <<'EOF'
Types: deb
URIs: https://dl.google.com/linux/chrome-stable/deb/
Suites: stable
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/google-chrome.gpg
EOF
        sudo install -o root -g root -m 644 "$_tmpsrc" /etc/apt/sources.list.d/google-chrome.sources \
            || die "xfce: failed to write the google-chrome sources file"
        rm -f "$_tmpsrc"
    fi
    pkg_apt_update --force || die "xfce: apt update failed (google-chrome repo unusable?)"
    log_info "xfce: installing google-chrome-stable..."
    pkg_apt_install google-chrome-stable || die "xfce: google-chrome-stable install failed"
    command -v google-chrome >/dev/null 2>&1 \
        || die "xfce: google-chrome not found after install - postcondition failed"
fi

# --- GUI account (created once; password never changes on reruns) ---
if ! _xfce_user_exists "$XFCE_USER"; then
    log_info "xfce: creating user $XFCE_USER..."
    sudo useradd -m -s /bin/bash "$XFCE_USER" || die "xfce: useradd failed for $XFCE_USER"
    # Password: env-passed (preserved, never printed) else generated + printed.
    XFCE_PASSWORD="${CLOUDIFY_XFCE_USER_PASSWORD:-}"
    _printed=false
    if [[ -z "$XFCE_PASSWORD" ]]; then
        XFCE_PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
        _printed=true
    fi
    printf '%s:%s\n' "$XFCE_USER" "$XFCE_PASSWORD" | sudo chpasswd \
        || die "xfce: chpasswd failed for $XFCE_USER"
    # On-guest record (mode 600) + print only the generated password.
    _tmpstate=$(mktemp)
    cat > "$_tmpstate" <<EOF
# xfce pkg state - generated by cloudify. mode 600, never commit.
XFCE_USER='${XFCE_USER}'
XFCE_PASSWORD='${XFCE_PASSWORD}'
XFCE_SESSION='${XFCE_SESSION}'
XFCE_CHROME='${XFCE_CHROME}'
XFCE_RDP_PORT='${XFCE_RDP_PORT}'
EOF
    sudo install -d -o root -g root -m 755 /etc/cloudify
    sudo install -o root -g root -m 600 "$_tmpstate" "$STATE_FILE"
    rm -f "$_tmpstate"
    if [[ "$_printed" == "true" ]]; then
        log_info "xfce: GENERATED password for user '$XFCE_USER' (no password was passed):"
        log_info "xfce: >>> $XFCE_PASSWORD <<<"
        log_info "xfce: store it now; recovery copy is $STATE_FILE (root-only). Use it as CLOUDIFY_GUACAMOLE_RDP_PASSWORD."
    fi
else
    # User exists: preserve their password. Refresh state record only.
    _st_pw="${_st_XFCE_PASSWORD:-}"
    _tmpstate=$(mktemp)
    cat > "$_tmpstate" <<EOF
# xfce pkg state - generated by cloudify. mode 600, never commit.
XFCE_USER='${XFCE_USER}'
XFCE_PASSWORD='${_st_pw}'
XFCE_SESSION='${XFCE_SESSION}'
XFCE_CHROME='${XFCE_CHROME}'
XFCE_RDP_PORT='${XFCE_RDP_PORT}'
EOF
    sudo install -d -o root -g root -m 755 /etc/cloudify
    sudo install -o root -g root -m 600 "$_tmpstate" "$STATE_FILE"
    rm -f "$_tmpstate"
    log_info "xfce: user $XFCE_USER already exists - password preserved (never changed on reruns)."
fi

# --- Session + default-browser registration (staged temp -> sudo install) ---
_home="$(getent passwd "$XFCE_USER" | cut -d: -f6)"
_tmpfile=$(mktemp)
printf '%s\n' "$XFCE_SESSION" > "$_tmpfile"
sudo install -o "$XFCE_USER" -g "$XFCE_USER" -m 644 "$_tmpfile" "$_home/.xsession"
rm -f "$_tmpfile"

if [[ "$XFCE_CHROME" == "true" ]]; then
    _tmpfile=$(mktemp)
    cat > "$_tmpfile" <<'EOF'
WebBrowser=google-chrome
EOF
    sudo install -d -o "$XFCE_USER" -g "$XFCE_USER" -m 755 "$_home/.config/xfce4"
    sudo install -o "$XFCE_USER" -g "$XFCE_USER" -m 600 "$_tmpfile" "$_home/.config/xfce4/helpers.rc"
    rm -f "$_tmpfile"

    log_info "xfce: registering google-chrome as the default browser (mimeapps.list)..."
    sudo -u "$XFCE_USER" env "HOME=$_home" xdg-mime default google-chrome.desktop x-scheme-handler/http
    sudo -u "$XFCE_USER" env "HOME=$_home" xdg-mime default google-chrome.desktop x-scheme-handler/https
    sudo -u "$XFCE_USER" env "HOME=$_home" xdg-mime default google-chrome.desktop text/html
fi

# --- XRDP: service + key.pem (oracle: symlink to snakeoil, xrdp in ssl-cert) ---
log_info "xfce: configuring xrdp..."
sudo usermod -aG ssl-cert xrdp 2>/dev/null || true
_restart=false
if [[ ! -e /etc/xrdp/key.pem ]]; then
    sudo ln -sf /etc/ssl/private/ssl-cert-snakeoil.key /etc/xrdp/key.pem
    _restart=true
fi
sudo systemctl enable --now xrdp >/dev/null 2>&1
if [[ "$_restart" == "true" ]]; then
    sudo systemctl restart xrdp
fi

log_info "xfce: install phase done for user $XFCE_USER (xrdp on port $XFCE_RDP_PORT)."
