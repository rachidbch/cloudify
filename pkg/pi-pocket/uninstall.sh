#!/usr/bin/env bash
# pi-pocket uninstall.sh - remove the unit and the source checkout.
# The data directory survives unless --clear-data (CLOUDIFY_CLEAR_DATA) is
# given: it holds the durable agents, threads and attachments the app exists
# for, and is not reproducible from the repo.

DIR="${PI_POCKET_DIR:-/opt/pi-pocket}"
DATA="${PI_POCKET_DATA:-/var/lib/pi-pocket}"
SERVICE="${PI_POCKET_SERVICE:-pi-pocket}"

systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
rm -f "/etc/systemd/system/${SERVICE}.service"
systemctl daemon-reload >/dev/null 2>&1 || true

if [[ "$CLOUDIFY_CLEAR_DATA" == "true" || "$CLOUDIFY_CLEAR_DATA" == "1" ]]; then
    log_info "pi-pocket: clearing data at $DATA (clear-data requested)."
    rm -rf "$DATA"
else
    log_info "pi-pocket: keeping $DATA (rerun with --clear-data to remove agent state)."
fi

rm -rf "$DIR"
log_info "pi-pocket: uninstalled (unit + $DIR removed)."
