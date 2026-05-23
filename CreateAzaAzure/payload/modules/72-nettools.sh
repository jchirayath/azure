#!/usr/bin/env bash
# Real-time network troubleshooting tools. Runs after ELK/monitoring (60/62) so it
# can wire blackbox into Prometheus and import a Grafana dashboard.
#   - CLI: mtr iftop nload bmon nethogs iptraf-ng vnstat iperf3 speedtest-cli
#          tcptraceroute  (use interactively via the /shell web terminal)
#   - Netdata  (per-second metrics)      -> localhost:19999, nginx /netdata/ (AAD)
#   - ntopng   (live traffic analyzer)   -> localhost:3001,  nginx /ntopng/  (AAD; own login)
#   - blackbox_exporter (latency probes) -> localhost:9115, scraped by Prometheus + Grafana dash
#   - Uptime Kuma (uptime/probes)        -> Docker :3011, opened on demand from the portal (own login)
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

NIC="$(ip -o -4 route show to default | awk '{print $5}' | head -1)"; NIC="${NIC:-eth0}"

log "Installing CLI network toolkit (mtr/iftop/nload/bmon/nethogs/iptraf-ng/iperf3/...)..."
apt_install mtr-tiny iftop nload bmon nethogs iptraf-ng vnstat iperf3 tcptraceroute speedtest-cli

# --- Netdata (real-time metrics, localhost only; nginx /netdata/ gates via AAD) ---
log "Installing Netdata (localhost:19999)..."
apt_install netdata
# Netdata refuses to serve web files unless their owner matches config — pin it.
WEB_OWNER="$(stat -c '%U' /usr/share/netdata/web/index.html 2>/dev/null || echo root)"
WEB_GROUP="$(stat -c '%G' /usr/share/netdata/web/index.html 2>/dev/null || echo root)"
sudo tee /etc/netdata/netdata.conf >/dev/null <<CONF
[global]
    run as user = netdata
[web]
    bind to = 127.0.0.1
    web files owner = $WEB_OWNER
    web files group = $WEB_GROUP
CONF
sudo systemctl restart netdata || warn "netdata failed to start"

# --- ntopng + redis (live traffic; --http-prefix lets it sit behind nginx /ntopng/) ---
log "Installing ntopng + redis (localhost:3001)..."
apt_install redis-server ntopng
# NOTE: the Debian unit reads /etc/ntopng.conf (a FILE), not /etc/ntopng/ntopng.conf.
sudo tee /etc/ntopng.conf >/dev/null <<CONF
-i=$NIC
-w=127.0.0.1:3001
--http-prefix=/ntopng
-d=/var/lib/ntopng
CONF
sudo mkdir -p /var/lib/ntopng
# ntopng runs in the foreground; the packaged unit is Type=forking -> override to simple.
sudo mkdir -p /etc/systemd/system/ntopng.service.d
sudo tee /etc/systemd/system/ntopng.service.d/override.conf >/dev/null <<'CONF'
[Service]
Type=simple
Restart=always
RestartSec=5
CONF
sudo systemctl daemon-reload
sudo systemctl restart ntopng || warn "ntopng failed to start"

# --- blackbox_exporter (ICMP/TCP/HTTP/DNS latency probes -> Prometheus/Grafana) ---
log "Installing blackbox_exporter (localhost:9115)..."
BB_VER="0.25.0"
if [[ ! -x /opt/blackbox/blackbox_exporter ]]; then
  curl -fsSL -o /tmp/bb.tgz "https://github.com/prometheus/blackbox_exporter/releases/download/v${BB_VER}/blackbox_exporter-${BB_VER}.linux-amd64.tar.gz" \
    && sudo mkdir -p /opt/blackbox && sudo tar xzf /tmp/bb.tgz -C /opt/blackbox --strip-components=1 || warn "blackbox download failed"
fi
sudo tee /etc/systemd/system/blackbox_exporter.service >/dev/null <<'SVC'
[Unit]
Description=Prometheus blackbox exporter
After=network.target
[Service]
ExecStart=/opt/blackbox/blackbox_exporter --config.file=/opt/blackbox/blackbox.yml --web.listen-address=127.0.0.1:9115
Restart=always
[Install]
WantedBy=multi-user.target
SVC
sudo systemctl daemon-reload
sudo systemctl enable --now blackbox_exporter || warn "blackbox failed to start"

# Wire blackbox into Prometheus (idempotent) — runs after 62-monitoring writes prometheus.yml.
if [[ -f /opt/prometheus/prometheus.yml ]] && ! grep -q "job_name: blackbox-http" /opt/prometheus/prometheus.yml; then
  FQDN="$(vm_fqdn)"
  sudo tee -a /opt/prometheus/prometheus.yml >/dev/null <<YML
  - job_name: blackbox-http
    metrics_path: /probe
    params: { module: [http_2xx] }
    static_configs:
      - targets: ["https://${FQDN}/health.json"]
    relabel_configs:
      - { source_labels: [__address__], target_label: __param_target }
      - { source_labels: [__param_target], target_label: instance }
      - { target_label: __address__, replacement: 127.0.0.1:9115 }
  - job_name: blackbox-icmp
    metrics_path: /probe
    params: { module: [icmp] }
    static_configs:
      - targets: ["8.8.8.8","1.1.1.1"]
    relabel_configs:
      - { source_labels: [__address__], target_label: __param_target }
      - { source_labels: [__param_target], target_label: instance }
      - { target_label: __address__, replacement: 127.0.0.1:9115 }
YML
  sudo systemctl restart prometheus || warn "prometheus restart failed"
fi
# Import the Blackbox Grafana dashboard (grafana.com id 13659).
GRAF_PW="$(kv_get grafanaAdminPassword)"
if [[ -n "$GRAF_PW" ]] && curl -fsSL -o /tmp/bb.json https://grafana.com/api/dashboards/13659/revisions/latest/download 2>/dev/null; then
  python3 -c "import json;d=json.load(open('/tmp/bb.json'));open('/tmp/bbimp.json','w').write(json.dumps({'dashboard':d,'overwrite':True,'inputs':[{'name':'DS_PROMETHEUS','type':'datasource','pluginId':'prometheus','value':'Prometheus'}]}))" \
    && curl -s -u "admin:${GRAF_PW}" -H 'Content-Type: application/json' -d @/tmp/bbimp.json \
       http://localhost:3000/api/dashboards/import >/dev/null && ok "Blackbox Grafana dashboard imported."
fi

# --- Uptime Kuma (uptime/probe monitors) -------------------------------------
# Runs on localhost:3011 and is published behind nginx+TLS at uptime.<zone> (its
# SPA uses absolute asset paths, so it must sit at a vhost ROOT, not a subpath).
log "Installing Uptime Kuma (Docker, localhost:3011)..."
if ! sudo docker ps -a --format '{{.Names}}' | grep -q '^uptime-kuma$'; then
  sudo docker run -d --restart unless-stopped --name uptime-kuma \
    -p 127.0.0.1:3011:3001 -v uptime-kuma:/app/data louislam/uptime-kuma:1 || warn "uptime-kuma failed to start"
fi

if [[ -n "${CUSTOM_FQDN:-}" ]]; then
  UPTIME_FQDN="uptime.${CUSTOM_FQDN#*.}"          # e.g. uptime.az.aspl.net
  CONF=/etc/nginx/sites-available/aza
  if [[ -f "$CONF" ]] && ! grep -q "server_name $UPTIME_FQDN" "$CONF"; then
    log "Publishing Uptime Kuma at https://$UPTIME_FQDN ..."
    sudo tee -a "$CONF" >/dev/null <<NGX
server {
    listen 80;
    server_name $UPTIME_FQDN;
    location / {
        proxy_pass http://127.0.0.1:3011/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
    }
}
NGX
    sudo nginx -t && sudo systemctl reload nginx
    # DNS for $UPTIME_FQDN (CNAME -> the VM's custom FQDN) must resolve to this VM.
    sudo certbot --nginx -d "$UPTIME_FQDN" --expand --non-interactive --agree-tos \
      -m "${CERTBOT_EMAIL:-${MAIL_USER:-admin@${CUSTOM_FQDN#*.}}}" --redirect 2>/dev/null \
      || warn "Uptime Kuma TLS cert failed — ensure $UPTIME_FQDN resolves to this VM."
  fi
fi

ok "Network tools ready: Netdata /netdata/, ntopng /ntopng/, blackbox->Grafana, Uptime Kuma https://uptime.<zone>, CLI in /shell."
