#!/usr/bin/env bash
# Base observability config: host metrics (node_exporter -> Prometheus -> Grafana
# dashboard) and log collection (Filebeat -> Elasticsearch/Kibana). Runs after the
# ELK module (60) which installs Prometheus/Grafana/Kibana/Filebeat.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

# --- host metrics: node_exporter ---------------------------------------------
log "Installing node_exporter (host metrics on :9100, localhost-only)..."
apt_install prometheus-node-exporter
# Bind to localhost — Prometheus scrapes it locally; it is never a public listener.
echo 'ARGS="--web.listen-address=127.0.0.1:9100"' | sudo tee /etc/default/prometheus-node-exporter >/dev/null
sudo systemctl enable --now prometheus-node-exporter || warn "node_exporter failed to start"
sudo systemctl restart prometheus-node-exporter 2>/dev/null || true

# --- Prometheus scrape config (node + self; self is under /prometheus) --------
sudo tee /opt/prometheus/prometheus.yml >/dev/null <<'EOF'
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: node
    static_configs:
      - targets: ["localhost:9100"]
  - job_name: prometheus
    metrics_path: /prometheus/metrics
    static_configs:
      - targets: ["localhost:9090"]
EOF
sudo systemctl restart prometheus || warn "prometheus restart failed"

# --- Grafana datasources (Prometheus default + Elasticsearch) -----------------
sudo mkdir -p /etc/grafana/provisioning/datasources
sudo tee /etc/grafana/provisioning/datasources/aza.yaml >/dev/null <<'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:9090/prometheus
    isDefault: true
  - name: Elasticsearch
    type: elasticsearch
    access: proxy
    url: http://localhost:9200
    jsonData:
      index: 'filebeat-*'
      timeField: '@timestamp'
EOF
sudo systemctl restart grafana-server || warn "grafana restart failed"
sleep 8

# --- import the Node Exporter Full dashboard (id 1860) ------------------------
GRAF_PW="$(kv_get grafanaAdminPassword)"
if [[ -n "$GRAF_PW" ]]; then
  if curl -fsSL -o /tmp/n1860.json https://grafana.com/api/dashboards/1860/revisions/latest/download; then
    python3 -c "import json;d=json.load(open('/tmp/n1860.json'));open('/tmp/imp.json','w').write(json.dumps({'dashboard':d,'overwrite':True,'inputs':[{'name':'DS_PROMETHEUS','type':'datasource','pluginId':'prometheus','value':'Prometheus'}]}))"
    curl -s -u "admin:${GRAF_PW}" -H 'Content-Type: application/json' -d @/tmp/imp.json \
      http://localhost:3000/api/dashboards/import >/dev/null && ok "Grafana node dashboard imported."
  fi
fi

# --- Filebeat -> Elasticsearch + Kibana setup (data view + dashboards) --------
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
  - type: filestream
    id: mysql
    enabled: true
    paths: ["/var/log/mysql/*.log"]
setup.template.settings:
  index.number_of_shards: 1
setup.kibana:
  host: "localhost:5601"
  path: "/kibana"
output.elasticsearch:
  hosts: ["localhost:9200"]
EOF
# NOTE: we deliberately do NOT enable the filebeat 'system' module — in this
# filebeat build its default filesets aren't enabled and it aborts with
# "module system is configured but has no enabled filesets". The explicit
# filestream inputs above already cover syslog/auth/nginx/mysql.
sudo filebeat setup --index-management --dashboards \
  -E setup.kibana.host="localhost:5601" -E setup.kibana.path="/kibana" \
  -E output.elasticsearch.hosts=["localhost:9200"] 2>/dev/null || warn "filebeat Kibana setup partial"
sudo systemctl restart filebeat || warn "filebeat restart failed"

ok "Monitoring base configured (Prometheus/Grafana metrics + Filebeat/Kibana logs)."
