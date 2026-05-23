#!/usr/bin/env bash
# Observability stack: Elasticsearch + Kibana + Logstash + Filebeat (Elastic 8.x),
# plus Prometheus and Grafana. Security is DISABLED for this single-node box
# (access is gated by nginx + NSG). Memory-hungry — needs >= Standard_D4s_v3.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

apt_install openjdk-11-jre apt-transport-https wget gnupg curl

# --- Elastic 8.x repo (signed-by keyring) ------------------------------------
log "Adding Elastic repository..."
curl -fsSL https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/elastic.gpg
echo "deb [signed-by=/usr/share/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/elastic-8.x.list >/dev/null
sudo -E apt-get update

# Install one at a time with retries — these are large packages and a single
# timed-out download must not silently skip the whole stack.
install_pkg() {  # name
  for attempt in 1 2 3; do
    sudo -E DEBIAN_FRONTEND=noninteractive apt-get install -y "$1" && return 0
    warn "install $1 attempt $attempt failed; retrying..."; sleep 10
  done
  return 1
}
ELK_OK=true
for pkg in elasticsearch kibana logstash filebeat; do
  log "Installing $pkg..."
  install_pkg "$pkg" || { warn "$pkg FAILED to install"; ELK_OK=false; }
done

# --- Elasticsearch config: single-node, no security, bounded heap ------------
if [[ -d /etc/elasticsearch ]]; then
  log "Configuring Elasticsearch (single-node, security off)..."
  # ES 8.x ships a messy security auto-config block; rather than edit it, write a
  # clean minimal config (backing up the original once). Idempotent.
  [[ -f /etc/elasticsearch/elasticsearch.yml.orig ]] || \
    sudo cp /etc/elasticsearch/elasticsearch.yml /etc/elasticsearch/elasticsearch.yml.orig
  sudo tee /etc/elasticsearch/elasticsearch.yml >/dev/null <<'EOF'
# Managed by aza 60-elk.sh — single-node, internal (gated by nginx + NSG).
cluster.name: aza
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 127.0.0.1
http.port: 9200
discovery.type: single-node
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
EOF
  # Cap heap so ES coexists with Kibana/Splunk on a 16GB box.
  echo -e "-Xms2g\n-Xmx2g" | sudo tee /etc/elasticsearch/jvm.options.d/aza-heap.options >/dev/null
  # ES 8.x install seeds the keystore with TLS secure-passwords from its security
  # auto-config; with security disabled those entries make ES refuse to boot.
  # Reset to an empty keystore.
  sudo rm -f /etc/elasticsearch/elasticsearch.keystore
  sudo /usr/share/elasticsearch/bin/elasticsearch-keystore create >/dev/null 2>&1 || true
  sudo chown root:elasticsearch /etc/elasticsearch/elasticsearch.keystore 2>/dev/null || true
  sudo chmod 660 /etc/elasticsearch/elasticsearch.keystore 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo systemctl enable elasticsearch
  sudo systemctl restart elasticsearch
  log "Waiting for Elasticsearch to answer on :9200..."
  for i in $(seq 1 30); do
    curl -fs http://127.0.0.1:9200 >/dev/null 2>&1 && { ok "Elasticsearch up."; break; }
    sleep 5
  done
fi

# --- Kibana: bind all interfaces, point at local ES, serve under /kibana ------
if [[ -f /etc/kibana/kibana.yml ]]; then
  log "Configuring Kibana (sub-path /kibana)..."
  # Listens on all interfaces but the NSG keeps 5601 CLOSED by default; the portal
  # can open it on demand. Normal access is via nginx (/kibana) behind the AAD gate.
  sudo sed -i 's|^#*server.host:.*|server.host: "0.0.0.0"|' /etc/kibana/kibana.yml
  grep -q '^elasticsearch.hosts' /etc/kibana/kibana.yml \
    || echo 'elasticsearch.hosts: ["http://127.0.0.1:9200"]' | sudo tee -a /etc/kibana/kibana.yml >/dev/null
  sudo sed -i '/^server.basePath:/d;/^server.rewriteBasePath:/d' /etc/kibana/kibana.yml
  { echo 'server.basePath: "/kibana"'; echo 'server.rewriteBasePath: true'; } | sudo tee -a /etc/kibana/kibana.yml >/dev/null
  sudo systemctl enable kibana
  sudo systemctl restart kibana
fi

# --- Logstash / Filebeat -----------------------------------------------------
[[ -f /etc/logstash/logstash.yml ]] && sudo systemctl enable --now logstash || true
if command -v filebeat >/dev/null 2>&1; then
  # Self-contained config (explicit log inputs) — avoids the module "no enabled
  # filesets" startup failures and ships straight to local ES.
  sudo tee /etc/filebeat/filebeat.yml >/dev/null <<'EOF'
filebeat.inputs:
  - type: filestream
    id: syslog
    enabled: true
    paths: ["/var/log/syslog", "/var/log/auth.log"]
  - type: filestream
    id: nginx
    enabled: true
    paths: ["/var/log/nginx/*.log"]
output.elasticsearch:
  hosts: ["http://127.0.0.1:9200"]
setup.ilm.enabled: false
setup.template.enabled: false
EOF
  sudo systemctl reset-failed filebeat 2>/dev/null || true
  sudo systemctl enable --now filebeat || warn "filebeat failed to start"
fi

# --- Prometheus (binary release) ---------------------------------------------
FQDN="$(vm_fqdn)"
PROM_VERSION="2.54.1"
log "Installing Prometheus $PROM_VERSION (sub-path /prometheus)..."
curl -fsSL -o /tmp/prom.tgz "https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
sudo rm -rf /opt/prometheus && sudo mkdir -p /opt/prometheus
sudo tar xzf /tmp/prom.tgz -C /opt/prometheus --strip-components=1
# --web.external-url makes Prometheus generate links/redirects under /prometheus/.
sudo tee /etc/systemd/system/prometheus.service >/dev/null <<EOF
[Unit]
Description=Prometheus
After=network.target
[Service]
Type=simple
ExecStart=/opt/prometheus/prometheus --config.file=/opt/prometheus/prometheus.yml --storage.tsdb.path=/opt/prometheus/data --web.external-url=https://${FQDN}/prometheus/
Restart=always
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus || warn "prometheus failed to start"

# --- Grafana -----------------------------------------------------------------
log "Installing Grafana..."
curl -fsSL https://apt.grafana.com/gpg.key | sudo gpg --dearmor --yes -o /usr/share/keyrings/grafana.gpg
echo "deb [signed-by=/usr/share/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list >/dev/null
sudo -E apt-get update
install_pkg grafana || warn "grafana failed to install"
# Serve Grafana under /grafana (sub-path) so its links/redirects are correct.
if [[ -f /etc/grafana/grafana.ini ]]; then
  sudo sed -i "s|^;*[[:space:]]*root_url =.*|root_url = https://${FQDN}/grafana/|; s|^;*[[:space:]]*serve_from_sub_path =.*|serve_from_sub_path = true|" /etc/grafana/grafana.ini
fi
sudo systemctl enable --now grafana-server || warn "grafana failed to start"
sudo systemctl restart grafana-server 2>/dev/null || true
# Reset Grafana admin off the default admin/admin to the vaulted password.
GRAFANA_PW="$(kv_get grafanaAdminPassword)"
if [[ -n "$GRAFANA_PW" ]]; then
  sleep 5
  sudo grafana cli --homepath /usr/share/grafana admin reset-admin-password "$GRAFANA_PW" 2>/dev/null \
    || sudo grafana-cli --homepath /usr/share/grafana admin reset-admin-password "$GRAFANA_PW" 2>/dev/null \
    || warn "grafana admin password reset failed"
fi

# --- Report actual service health --------------------------------------------
log "Observability service status:"
for s in elasticsearch kibana logstash filebeat prometheus grafana-server; do
  printf '    %-16s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null)"
done
[[ "$ELK_OK" == true ]] && ok "Observability stack installed." || warn "Some ELK components failed; see status above."
