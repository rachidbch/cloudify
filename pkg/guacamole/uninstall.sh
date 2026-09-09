#!/usr/bin/env bash
# guacamole - uninstall phase: tear down the stack AND its volume, then remove
# the project dir. `down -v` must run FIRST: removing the dir first orphans the
# postgres volume, and a later install reuses the stale role password (trap 3).

DIR="${CLOUDIFY_GUACAMOLE_DIR:-$HOME/guacamole}"
COMPOSE_FILE="$DIR/docker-compose.yml"

if command -v docker >/dev/null 2>&1 && [[ -f "$COMPOSE_FILE" ]]; then
    log_info "guacamole: docker compose down -v (stack + volume)..."
    sudo docker compose -f "$COMPOSE_FILE" down -v || die "guacamole: docker compose down -v failed"
fi

rm -rf "$DIR"
log_info "guacamole: uninstalled (stack, volume and project dir removed)."
