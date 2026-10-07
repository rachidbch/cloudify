#!/usr/bin/env bash
# zitadel uninstall.sh - tear the stack down and remove ALL state:
# containers, network, both volumes (postgres data + bootstrap PATs) and the
# project dir incl. the local .env secrets. The instance is destroyed; the
# masterkey-encrypted data is unrecoverable. Reinstall = fresh instance.

DIR="${CLOUDIFY_ZITADEL_DIR:-$HOME/zitadel}"
COMPOSE_FILE="$DIR/docker-compose.yml"

if [[ -f "$COMPOSE_FILE" ]]; then
    sudo docker compose -f "$COMPOSE_FILE" down -v --remove-orphans \
        || die "zitadel: compose down failed - check 'sudo docker compose -f $COMPOSE_FILE logs'"
else
    log_warn "zitadel: no compose file at $COMPOSE_FILE - nothing to tear down."
fi

rm -rf "$DIR"
log_info "zitadel: uninstalled (volumes + $DIR removed)."
