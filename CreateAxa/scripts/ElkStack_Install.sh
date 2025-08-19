#!/bin/bash

# Exit on error
set -e

echo "Updating package lists..."
sudo apt-get update

echo "Installing Java (required for Elasticsearch and Logstash)..."
sudo apt-get install -y openjdk-11-jre

# --- Install Elasticsearch ---
echo "Installing Elasticsearch..."
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo apt-key add -
sudo apt-get install -y apt-transport-https
echo "deb https://artifacts.elastic.co/packages/7.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-7.x.list
sudo apt-get update
sudo apt-get install -y elasticsearch

sudo systemctl enable elasticsearch
sudo systemctl start elasticsearch

# --- Install Logstash ---
echo "Installing Logstash..."
sudo apt-get install -y logstash
sudo systemctl enable logstash
sudo systemctl start logstash

# --- Install Kibana ---
echo "Installing Kibana..."
sudo apt-get install -y kibana
# Allow remote hosts to access Kibana
sudo sed -i "s|#server.host: \"localhost\"|server.host: \"0.0.0.0\"|g" /etc/kibana/kibana.yml
sudo systemctl enable kibana
sudo systemctl start kibana

sudo systemctl enable kibana
sudo systemctl start kibana

# --- Install Filebeat (for log shipping) ---
echo "Installing Filebeat..."
sudo apt-get install -y filebeat

# --- Configure Filebeat for Tomcat, Apache, Nginx, Privoxy ---
echo "Configuring Filebeat modules..."

sudo filebeat modules enable apache nginx
# Tomcat and Privoxy are not default modules, so use Filebeat prospectors for their logs

sudo tee /etc/filebeat/filebeat.yml > /dev/null <<EOF
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/tomcat*.log
  fields:
    service: tomcat

- type: log
  enabled: true
  paths:
    - /var/log/privoxy/logfile
  fields:
    service: privoxy

output.elasticsearch:
  hosts: ["localhost:9200"]
setup.kibana:
  host: "localhost:5601"
EOF

sudo systemctl enable filebeat
sudo systemctl restart filebeat

# --- Install Prometheus ---
echo "Installing Prometheus..."
PROM_VERSION="2.52.0"
wget https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz
tar xvf prometheus-${PROM_VERSION}.linux-amd64.tar.gz
sudo mv prometheus-${PROM_VERSION}.linux-amd64 /opt/prometheus

sudo tee /etc/systemd/system/prometheus.service > /dev/null <<EOF
[Unit]
Description=Prometheus
After=network.target

[Service]
Type=simple
ExecStart=/opt/prometheus/prometheus --config.file=/opt/prometheus/prometheus.yml --storage.tsdb.path=/opt/prometheus/data
Restart=always

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable prometheus
sudo systemctl start prometheus

# --- Install Grafana ---
echo "Installing Grafana..."
sudo apt-get install -y apt-transport-https software-properties-common wget
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt-get update
sudo apt-get install -y grafana

sudo systemctl enable grafana-server
sudo systemctl start grafana-server

echo "ELK stack, Prometheus, and Grafana installation complete."
echo "Access Kibana at http://localhost:5601"
echo "Access Prometheus at http://localhost:9090"
echo "Access Grafana at http://localhost:3000"