#!/usr/bin/env bash
# xfce - run phase (ADR-008 split): re-assert session + default-browser files
# and the xrdp service from the current config. Guard-free, re-runnable,
# NEVER touches the user password (password ops are install-time only).
# Requires the install phase to have run (state file present).

STATE_FILE=/etc/cloudify/xfce-user.env
[[ -f "$STATE_FILE" ]] || die "xfce: no state file at $STATE_FILE - run 'cloudify install xfce' first"

while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    val="${val%\'}"
    val="${val#\'}"
    export "_st_${key}=$val"
done < <(grep -E '^XFCE_(USER|PASSWORD|SESSION|CHROME|RDP_PORT)=' "$STATE_FILE" || true)

XFCE_USER="${CLOUDIFY_XFCE_USER:-${_st_XFCE_USER:-gui}}"
XFCE_SESSION="${CLOUDIFY_XFCE_SESSION:-${_st_XFCE_SESSION:-startxfce4}}"
XFCE_CHROME="${CLOUDIFY_XFCE_INSTALL_CHROME:-${_st_XFCE_CHROME:-true}}"

# --- Re-assert the session + registration files for the configured user ---
_home="$(getent passwd "$XFCE_USER" | cut -d: -f6)"
[[ -n "$_home" && -d "$_home" ]] || die "xfce: home for user $XFCE_USER not found"

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
    sudo -u "$XFCE_USER" env "HOME=$_home" xdg-mime default google-chrome.desktop x-scheme-handler/http || true
    sudo -u "$XFCE_USER" env "HOME=$_home" xdg-mime default google-chrome.desktop x-scheme-handler/https || true
    sudo -u "$XFCE_USER" env "HOME=$_home" xdg-mime default google-chrome.desktop text/html || true
fi

# --- XRDP service + key.pem always ensured ---
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

log_info "xfce: configure phase complete for user $XFCE_USER."
