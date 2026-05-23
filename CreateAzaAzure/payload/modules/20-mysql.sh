#!/usr/bin/env bash
# Local MySQL server. Root password comes from Key Vault (seeded by deploy.sh).
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

ROOT_PW="$(kv_get mysqlRootPassword)"
[[ -z "$ROOT_PW" ]] && die "mysqlRootPassword not found in Key Vault ($KV_NAME)."

if ! dpkg-query -W -f='${Status}' mysql-server 2>/dev/null | grep -q "ok installed"; then
  log "Installing MySQL server..."
  apt_install mysql-server
fi

log "Starting MySQL..."
sudo systemctl enable --now mysql
sudo systemctl restart mysql

log "Setting MySQL root password..."
SQL="ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '$ROOT_PW'; FLUSH PRIVILEGES;"
# Fresh Ubuntu installs let root in via auth_socket; fall back to an existing password.
if ! sudo mysql -e "$SQL" 2>/dev/null; then
  sudo mysql -u root -p"$ROOT_PW" -e "$SQL" || die "Could not set MySQL root password."
fi

log "Verifying MySQL..."
sudo mysql -u root -p"$ROOT_PW" -e "SHOW DATABASES;" >/dev/null && ok "MySQL is up." || die "MySQL verification failed."
