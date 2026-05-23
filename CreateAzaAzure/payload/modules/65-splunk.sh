#!/usr/bin/env bash
# Splunk Free — single-instance install. Admin password from Key Vault.
# Splunk Free license activates automatically (no account needed) on first start.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

[[ -z "${SPLUNK_DEB_URL:-}" ]] && die "SPLUNK_DEB_URL not set in runtime config."
ADMIN_PW="$(kv_get splunkAdminPassword)"
[[ -z "$ADMIN_PW" ]] && die "splunkAdminPassword not found in Key Vault ($KV_NAME)."

if [[ ! -x /opt/splunk/bin/splunk ]]; then
  log "Downloading Splunk: $SPLUNK_DEB_URL"
  curl -fL -o /tmp/splunk.deb "$SPLUNK_DEB_URL" || die "Splunk download failed (check SPLUNK_DEB_URL)."
  sudo dpkg -i /tmp/splunk.deb || die "Splunk package install failed."
fi

# Seed admin credentials so first start is non-interactive.
sudo mkdir -p /opt/splunk/etc/system/local
sudo tee /opt/splunk/etc/system/local/user-seed.conf >/dev/null <<EOF
[user_info]
USERNAME = admin
PASSWORD = $ADMIN_PW
EOF

log "Starting Splunk and enabling boot-start (accepting Free license)..."
sudo /opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt
sudo /opt/splunk/bin/splunk enable boot-start -user root --accept-license --answer-yes --no-prompt || true

# Free license has no auth on Splunk Web by default in old builds; modern builds
# keep auth. Either way Web listens on the configured port.
sudo /opt/splunk/bin/splunk set web-port "${SPLUNK_WEB_PORT:-8000}" -auth "admin:$ADMIN_PW" 2>/dev/null || true

# Serve Splunk Web under /splunk and honor the reverse proxy's scheme/host so
# redirects keep the /splunk prefix and stay on https.
log "Configuring Splunk for the /splunk reverse-proxy path..."
sudo mkdir -p /opt/splunk/etc/system/local
sudo python3 - <<'PY'
import configparser, os
f="/opt/splunk/etc/system/local/web.conf"
c=configparser.ConfigParser(); c.optionxform=str
if os.path.exists(f): c.read(f)
if not c.has_section("settings"): c.add_section("settings")
c.set("settings","root_endpoint","/splunk")
c.set("settings","tools.proxy.on","true")
with open(f,"w") as fh: c.write(fh)
PY
sudo chown -R splunk:splunk /opt/splunk/etc/system/local 2>/dev/null || true

# Monitor key log files so Splunk collects logs from the installed services.
log "Configuring Splunk file monitors..."
sudo tee /opt/splunk/etc/system/local/inputs.conf >/dev/null <<'EOF'
[monitor:///var/log/syslog]
index = main
sourcetype = syslog

[monitor:///var/log/auth.log]
index = main
sourcetype = linux_secure

[monitor:///var/log/nginx]
index = main
sourcetype = nginx

[monitor:///var/log/mysql]
index = main
sourcetype = mysqld

[monitor:///var/log/fail2ban.log]
index = main
sourcetype = fail2ban
EOF
sudo chown -R splunk:splunk /opt/splunk/etc/system/local 2>/dev/null || true
sudo /opt/splunk/bin/splunk restart 2>/dev/null || true

ok "Splunk Free installed (proxied at /splunk/, user admin) with log monitors."
