#!/usr/bin/env bash
# One-click browser terminal (ttyd) at /shell/. ttyd listens only on localhost;
# nginx exposes it over TLS at /shell/ behind HTTP basic auth (htpasswd). Gives
# instant web SSH with no per-connection setup. Shell runs as the admin user.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

ADMIN_USER="${VM_ADMIN_USER:-azureuser}"

# --- install ttyd (apt where available, else the official static binary) -----
if ! command -v ttyd >/dev/null 2>&1; then
  log "Installing ttyd..."
  if ! apt_install ttyd; then
    warn "ttyd not in apt; downloading static binary..."
    curl -fsSL -o /tmp/ttyd "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.x86_64"
    sudo install -m 0755 /tmp/ttyd /usr/bin/ttyd
  fi
fi

# --- credential (baked into the image; recorded for the operator) ------------
CRED_FILE=/etc/aza/webssh.txt
sudo mkdir -p /etc/aza
if [[ -f "$CRED_FILE" ]]; then
  WEBSSH_USER="$(sudo awk -F= '/^user/{print $2}' "$CRED_FILE")"
  WEBSSH_PASS="$(sudo awk -F= '/^pass/{print $2}' "$CRED_FILE")"
else
  WEBSSH_USER="webssh"
  WEBSSH_PASS="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  printf 'user=%s\npass=%s\n' "$WEBSSH_USER" "$WEBSSH_PASS" | sudo tee "$CRED_FILE" >/dev/null
  sudo chmod 600 "$CRED_FILE"
fi

# --- nginx basic-auth file for /shell/ (the /shell/ proxy lives in the nginx module) ---
log "Writing nginx basic-auth file for /shell/..."
printf '%s:%s\n' "$WEBSSH_USER" "$(openssl passwd -apr1 "$WEBSSH_PASS")" | sudo tee /etc/nginx/.htpasswd-shell >/dev/null

# --- ttyd service: localhost only, base path /shell, admin shell (nginx gates auth) ---
log "Configuring ttyd service..."
sudo tee /etc/systemd/system/ttyd.service >/dev/null <<EOF
[Unit]
Description=ttyd web terminal
After=network.target

[Service]
User=${ADMIN_USER}
ExecStart=/usr/bin/ttyd --port 7681 --interface 127.0.0.1 --base-path /shell --writable bash
Restart=always

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now ttyd
sudo systemctl restart ttyd

# Reload nginx so the htpasswd file is picked up (the /shell/ location is already
# in the nginx config from the nginx module).
sudo nginx -t && sudo systemctl reload nginx 2>/dev/null || true

sleep 2
if sudo ss -ltn | grep -q '127.0.0.1:7681'; then
  ok "ttyd running. Web SSH at /shell/ (basic auth user '${WEBSSH_USER}', pass in ${CRED_FILE})."
else
  die "ttyd did not start."
fi
