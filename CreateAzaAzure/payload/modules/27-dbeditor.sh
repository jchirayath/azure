#!/usr/bin/env bash
# Web database editor (Adminer) — a single-page UI for MySQL/Postgres/SQLite.
# Runs as a container on localhost:8085; nginx exposes it at /db/ behind basic
# auth (the same .htpasswd-shell as the web shell). Connect to the local MySQL
# (172.17.0.1) or any external DB from the Adminer login screen.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

log "Starting Adminer database editor..."
sudo docker rm -f adminer >/dev/null 2>&1 || true
sudo docker run -d --name adminer --restart unless-stopped \
  -p 127.0.0.1:8085:8080 adminer >/dev/null

sleep 4
code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8085/ || true)"
[[ "$code" == "200" ]] && ok "Adminer up (proxied at /db/, basic auth)." || warn "Adminer HTTP check returned $code."
