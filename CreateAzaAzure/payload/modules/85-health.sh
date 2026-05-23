#!/usr/bin/env bash
# Publishes per-service up/down to /var/www/html/health.json every 30s (by
# listening port). The portal reads it (GET /health.json) to show green/red dots.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

log "Installing service-health publisher..."
sudo tee /usr/local/bin/aza-health.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# service path -> backend listening port
declare -A P=( ["/"]=443 ["/shell/"]=7681 ["/db/"]=8085 ["/guacamole/"]=8080 ["/webmin/"]=10000 ["/kibana/"]=5601 ["/grafana/"]=3000 ["/prometheus/"]=9090 ["/splunk/"]=8000 ["/netdata/"]=19999 ["/ntopng/"]=3001 ["uptime-kuma"]=3011 ["mail-relay"]=587 )
json="{"; first=1
for path in "${!P[@]}"; do
  if ss -ltnH 2>/dev/null | grep -q ":${P[$path]} "; then st=true; else st=false; fi
  [ $first -eq 1 ] || json+=","; first=0
  json+="\"$path\":$st"
done
json+="}"
printf "%s" "$json" > /var/www/html/health.json
EOF
sudo chmod +x /usr/local/bin/aza-health.sh

sudo tee /etc/systemd/system/aza-health.service >/dev/null <<'EOF'
[Unit]
Description=aza service health publisher
[Service]
Type=oneshot
ExecStart=/usr/local/bin/aza-health.sh
EOF
sudo tee /etc/systemd/system/aza-health.timer >/dev/null <<'EOF'
[Unit]
Description=Publish service health every 30s
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
[Install]
WantedBy=timers.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now aza-health.timer
sudo /usr/local/bin/aza-health.sh
ok "Health publisher running (/health.json updated every 30s)."
