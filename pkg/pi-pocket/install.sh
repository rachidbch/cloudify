#!/usr/bin/env bash
# pi-pocket - install phase (ADR-008 split).
# Pi Pocket is a durable, multiplayer, mobile-first web app for Pi agents
# (upstream: github.com/TannerMidd/pi-pocket), a Node service behind its own
# systemd unit. Level 1 adoption of a running host: this recipe converges the
# same shape the host already has, and never invents a second deployment path.
#
# Deployed source (as observed 2026-10-20): the host keeps a bare repo at
# /srv/pi-pocket.git and a checkout at /opt/pi-pocket (v0.15.0, node v22).
# PI_POCKET_REPO points at the repository the host pulls from; on a host where
# the checkout already exists, install converges (fetch, hard reset to the
# requested ref, npm ci) instead of cloning again.
pkg_depends node

DIR="${PI_POCKET_DIR:-/opt/pi-pocket}"
REPO="${PI_POCKET_REPO:-}"
REF="${PI_POCKET_REF:-main}"
DATA="${PI_POCKET_DATA:-/var/lib/pi-pocket}"
PORT="${PI_POCKET_PORT:-8787}"
ACCESS="${PI_POCKET_ACCESS:-lan}"
SERVICE="${PI_POCKET_SERVICE:-pi-pocket}"
NODE_BIN="${PI_POCKET_NODE:-/usr/bin/node}"

[[ -n "$REPO" ]] ||
    die "pi-pocket: PI_POCKET_REPO is required (the git repository the host deploys from)."

# --- Source -------------------------------------------------------------------
if [[ -d "$DIR/.git" ]]; then
    # Converge an existing checkout: the host's own deploy model is
    # pull-then-install, so install must be able to run it again.
    git -C "$DIR" fetch --all --prune || die "pi-pocket: git fetch failed in $DIR"
    git -C "$DIR" reset --hard "origin/$REF" || die "pi-pocket: cannot reset $DIR to origin/$REF"
else
    [[ -d "$DIR" ]] && die "pi-pocket: $DIR exists and is not a git checkout; refusing to overwrite it."
    mkdir -p "$(dirname "$DIR")"
    git clone --branch "$REF" "$REPO" "$DIR" || die "pi-pocket: git clone failed from $REPO"
fi

# --- Dependencies ---------------------------------------------------------------
cd "$DIR" || die "pi-pocket: cannot enter $DIR"
if [[ -f package-lock.json ]]; then
    npm ci --omit=dev || die "pi-pocket: npm ci failed"
else
    npm install --omit=dev || die "pi-pocket: npm install failed"
fi

# --- State + unit ---------------------------------------------------------------
mkdir -p "$DATA"
chmod 700 "$DATA"

UNIT="/etc/systemd/system/${SERVICE}.service"
cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=Pi Pocket
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=${DIR}
ExecStart=${NODE_BIN} ${DIR}/bin/pi-pocket.js --access ${ACCESS} -y --port ${PORT} --data ${DATA}
Restart=always
RestartSec=5
StandardOutput=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

systemctl daemon-reload || die "pi-pocket: daemon-reload failed"
systemctl enable --now "$SERVICE" || die "pi-pocket: cannot enable/start $SERVICE"
msg "pi-pocket: ${SERVICE} on port ${PORT} (access ${ACCESS}), data ${DATA}"
