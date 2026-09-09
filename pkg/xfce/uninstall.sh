#!/usr/bin/env bash
# xfce - uninstall phase: remove the desktop/RDP packages and the xrdp service.
# The GUI account is removed ONLY with explicit intent
# (CLOUDIFY_XFCE_UNINSTALL_USER=true), and never with -r: the home is preserved.

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
XFCE_CHROME="${CLOUDIFY_XFCE_INSTALL_CHROME:-${_st_XFCE_CHROME:-true}}"

log_info "xfce: stopping xrdp..."
sudo systemctl disable --now xrdp >/dev/null 2>&1 || true
if [[ -e /etc/xrdp/key.pem ]]; then
    sudo rm -f /etc/xrdp/key.pem
fi

log_info "xfce: purging desktop/RDP packages..."
# Wait for a concurrent dpkg lock (unattended-upgrades) instead of failing.
sudo apt-get -o DPkg::Lock::Timeout=300 purge -y xrdp xorgxrdp xfce4 xfce4-goodies || die "xfce: apt purge failed"
if [[ "$XFCE_CHROME" == "true" ]]; then
    sudo apt-get -o DPkg::Lock::Timeout=300 purge -y google-chrome-stable || true
    sudo rm -f /etc/apt/sources.list.d/google-chrome.sources /usr/share/keyrings/google-chrome.gpg
fi
sudo apt-get -o DPkg::Lock::Timeout=300 autoremove -y || true
sudo rm -f "$STATE_FILE"

if [[ "${CLOUDIFY_XFCE_UNINSTALL_USER:-}" == "true" ]]; then
    if getent passwd "$XFCE_USER" >/dev/null 2>&1; then
        log_info "xfce: removing account $XFCE_USER (home preserved)..."
        sudo userdel "$XFCE_USER" || die "xfce: userdel failed for $XFCE_USER"
    fi
else
    log_info "xfce: account $XFCE_USER and its home preserved (set CLOUDIFY_XFCE_UNINSTALL_USER=true to remove the account; the home is never removed)."
fi

log_info "xfce: uninstalled."
