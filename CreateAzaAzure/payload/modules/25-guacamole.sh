#!/usr/bin/env bash
# Apache Guacamole via Docker, backed by the local MySQL (or an external DB).
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

GUAC_DB_PW="$(kv_get guacDbPassword)"
[[ -z "$GUAC_DB_PW" ]] && die "guacDbPassword not found in Key Vault ($KV_NAME)."

DB_NAME="guacamole_db"
DB_USER="guacamole_user"

if [[ "${GUAC_USE_LOCAL_MYSQL:-true}" == "true" ]]; then
  DB_HOST="172.17.0.1"   # docker0 bridge gateway -> reach host MySQL from the container
  ROOT_PW="$(kv_get mysqlRootPassword)"

  log "Preparing local Guacamole database..."
  # Make MySQL reachable from the Docker bridge: bind all interfaces AND open the
  # firewall for the docker subnet (UFW otherwise blocks container -> host:3306).
  sudo sed -i 's/^bind-address.*/bind-address = 0.0.0.0/' /etc/mysql/mysql.conf.d/mysqld.cnf 2>/dev/null || true
  sudo systemctl restart mysql
  sudo ufw allow from 172.17.0.0/16 to any port 3306 proto tcp 2>/dev/null || true
  sudo ufw reload 2>/dev/null || true
  sudo mysql -u root -p"$ROOT_PW" <<SQL
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${GUAC_DB_PW}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
else
  DB_HOST="$(kv_get guacamoleHost)"
  DB_USER="$(kv_get guacamoleUser)"
  GUAC_DB_PW="$(kv_get guacamolePassword)"
  DB_NAME="guacamoledb"
  [[ -z "$DB_HOST" ]] && die "External Guacamole DB selected but guacamoleHost is empty."
fi

log "(Re)starting Guacamole containers..."
sudo docker rm -f some-guacd some-guacamole 2>/dev/null || true
sudo docker run --name some-guacd -d --restart unless-stopped guacamole/guacd

# Initialise schema (idempotent: only loads if the tables are absent).
log "Initialising Guacamole schema if needed..."
if ! sudo mysql -h "${DB_HOST/172.17.0.1/127.0.0.1}" -u "$DB_USER" -p"$GUAC_DB_PW" "$DB_NAME" \
      -e "SELECT 1 FROM guacamole_user LIMIT 1;" >/dev/null 2>&1; then
  sudo docker run --rm guacamole/guacamole /opt/guacamole/bin/initdb.sh --mysql > /tmp/guac-initdb.sql
  mysql -h "${DB_HOST/172.17.0.1/127.0.0.1}" -u "$DB_USER" -p"$GUAC_DB_PW" "$DB_NAME" < /tmp/guac-initdb.sql \
    || warn "Schema load reported an error (may already exist)."
fi

sudo docker run --name some-guacamole --link some-guacd:guacd --restart unless-stopped \
  -e GUACD_HOSTNAME=guacd -e GUACD_PORT=4822 \
  -e MYSQL_HOSTNAME="$DB_HOST" \
  -e MYSQL_DATABASE="$DB_NAME" \
  -e MYSQL_USER="$DB_USER" \
  -e MYSQL_PASSWORD="$GUAC_DB_PW" \
  -d -p 8080:8080 guacamole/guacamole

# Reset the guacadmin web password to the vaulted value (off the insecure default).
GUAC_ADMIN_PW="$(kv_get guacAdminPassword)"
if [[ -n "$GUAC_ADMIN_PW" ]]; then
  log "Resetting guacadmin password from Key Vault (Guacamole salted-SHA256 scheme)..."
  mysql -h "${DB_HOST/172.17.0.1/127.0.0.1}" -u "$DB_USER" -p"$GUAC_DB_PW" "$DB_NAME" <<SQL || warn "guacadmin reset failed"
SET @salt = UNHEX(SHA2(CONCAT(UUID(),UUID()),256));
UPDATE guacamole_user SET password_hash=UNHEX(SHA2(CONCAT('${GUAC_ADMIN_PW}',HEX(@salt)),256)), password_salt=@salt, password_date=NOW()
WHERE entity_id=(SELECT entity_id FROM guacamole_entity WHERE name='guacadmin' AND type='USER');
SQL
fi

# Keepalive: an external DB (e.g. GearHost) may close idle connections, leaving
# Guacamole's pool stale so the next login hangs. A periodic valid login keeps
# the pool warm. Harmless with local MySQL too.
if [[ -n "$GUAC_ADMIN_PW" ]]; then
  log "Installing Guacamole DB-pool keepalive timer..."
  printf '%s' "$GUAC_ADMIN_PW" | sudo tee /etc/aza/guacadmin >/dev/null; sudo chmod 600 /etc/aza/guacadmin
  sudo tee /usr/local/bin/aza-guac-keepalive.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
PW="$(cat /etc/aza/guacadmin 2>/dev/null)" || exit 0
curl -s -o /dev/null --max-time 20 -d "username=guacadmin&password=$PW" http://localhost:8080/guacamole/api/tokens
EOF
  sudo chmod +x /usr/local/bin/aza-guac-keepalive.sh
  sudo tee /etc/systemd/system/aza-guac-keepalive.service >/dev/null <<'EOF'
[Unit]
Description=Guacamole DB pool keepalive
[Service]
Type=oneshot
ExecStart=/usr/local/bin/aza-guac-keepalive.sh
EOF
  sudo tee /etc/systemd/system/aza-guac-keepalive.timer >/dev/null <<'EOF'
[Unit]
Description=Run Guacamole keepalive every 3 minutes
[Timer]
OnBootSec=3min
OnUnitActiveSec=3min
[Install]
WantedBy=timers.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now aza-guac-keepalive.timer 2>/dev/null || true
fi

sleep 10
code="$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/guacamole/ || true)"
[[ "$code" == "200" ]] && ok "Guacamole is up (http :8080/guacamole/)." || warn "Guacamole HTTP check returned $code."
