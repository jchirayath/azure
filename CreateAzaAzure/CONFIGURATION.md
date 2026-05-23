# AXA Cloud — Configuration Reference

Complete configuration of the on-demand `axa` VM and its portal. This file is part
of the base install: it is baked onto every VM at `/etc/aza/CONFIGURATION.md`.

Two projects make up the system:

| Project | Role |
|---|---|
| **CreateAzaAzure** | Builds + fully provisions the `axa` Ubuntu VM (all services, security, monitoring). |
| **OnDemandPortal** | Captures the box as a golden image and serves a web portal (`aspl`) to deploy/start/stop/destroy it on demand. |

---

## 1. Azure resources

| Resource | Name | RG | Notes |
|---|---|---|---|
| Subscription | `JacobAzure` | — | tenant `aspl.net` (`6308c3aa-…`) |
| VM (ephemeral) | `axa` (Standard_D4s_v3, Ubuntu 22.04, TrustedLaunch) | `rg-axa` | built/destroyed on demand |
| Key Vault (RBAC) | `kv-axa-westus3` | `rg-axa` | all secrets |
| Compute Gallery + image | `galAxa` / `axa-img` | `rg-platform` | golden image (persistent) |
| Portal Function App | `aspl` → `aspl.azurewebsites.net` | `rg-platform` | Python, Consumption, Easy Auth |
| DNS zone | `az.aspl.net` | `rg-dns` | delegated from BIND `aspl.net` |
| VM self-stop identity | `axa-vm-identity` | `rg-platform` | VM Contributor on rg-axa |
| Portal identity | system MI of `aspl` | — | Contributor on rg-axa, DNS Zone Contributor on rg-dns, KV Secrets User |

`rg-platform` and `rg-dns` are **persistent**; `rg-axa` is filled/emptied on demand (the RG itself is kept so role assignments survive).

---

## 2. Services & reverse proxy

All web services sit behind nginx on the VM with a Let's Encrypt cert for the
cloudapp FQDN. Base URL: `https://axa.westus3.cloudapp.azure.com/` (also
`https://axa.az.aspl.net/`).

| Path | Service | Backend | Auth | Secret (Key Vault) |
|---|---|---|---|---|
| `/` | Tools landing page | nginx static | none | — |
| `/guacamole/` | Apache Guacamole (Docker) | :8080 | guacadmin login | `guacAdminPassword` |
| `/db/` | Adminer DB editor (Docker) | :8085 | **Azure AD** (oauth2-proxy) | — |
| `/shell/` | ttyd web terminal | :7681 | **Azure AD** (oauth2-proxy) | — |
| `/webmin/` | Webmin | :10000 (https) | root login | `webminPassword` |
| `/kibana/` | Kibana | :5601 | **Azure AD** (oauth2-proxy) | — |
| `/grafana/` | Grafana | :3000 | admin login | `grafanaAdminPassword` |
| `/prometheus/` | Prometheus | :9090 (route-prefix /prometheus) | **Azure AD** (oauth2-proxy) | — |
| `/splunk/` | Splunk Free | :8000 (root_endpoint /splunk) | admin login | `splunkAdminPassword` |
| `/netdata/` | Netdata (real-time metrics) | :19999 | **Azure AD** (oauth2-proxy) | — |
| `/ntopng/` | ntopng (live traffic analyzer) | :3001 (http-prefix /ntopng) | **Azure AD** + own login (admin) | — |
| `/privoxy/` | Privoxy (note: forward proxy on :8118) | :8118 | — | — |
| `/health.json` | service health (for portal dots) | static file | none | — |
| `/oauth2/` | oauth2-proxy (AAD gate) | :4180 | — | — |

Other listeners: SSH :22, node_exporter :9100 (internal), guacd :4822 (internal),
Elasticsearch :9200 (internal), Postfix 25/587/465/143/993.

### Auth model
- **Azure AD (oauth2-proxy)** gates `/shell/`, `/db/`, `/kibana/`, `/prometheus/` —
  one Microsoft login (tenant-locked, AAD app `axa-vm-tools`). No passwords.
- **Service-native logins**: Guacamole, Grafana, Webmin, Splunk (passwords vaulted).
- **Forward proxy**: Privoxy is an HTTP proxy on `:8118` (not a reverse-proxied web app).

### Hardening & public attack surface
- **SSH**: key-only (`PasswordAuthentication no`, pubkey only, root login key-only).
- **fail2ban** (all services): `sshd` (SSH); `aza-weblogin` (failed POST logins to
  Guacamole/Grafana/Webmin/Splunk via the nginx access log — without false-banning the
  AAD/oauth2 GET redirect flow); `nginx-botsearch` (scanners); `postfix-sasl`/`dovecot`
  (mail); `recidive` (repeat offenders → 1-week all-ports ban). The AAD-gated tools
  (`/shell`,`/db`,`/kibana`,`/prometheus`) are brute-force-protected by Azure AD itself.
- **NSG (the public boundary)**: default-deny; **only `22`, `80`, `443`, `8118`, `587`
  (mail submission) are open to the internet.** Every other service is reached through
  nginx (TLS + the AAD gate).
- **node_exporter / Elasticsearch / MySQL / oauth2-proxy / ttyd / Adminer** bind to
  **localhost** — never public listeners.
- **UFW** allows the service ports so the NSG is the single effective gate; truly-internal
  backends stay localhost-bound regardless.
- **On-demand ports**: the portal can open/close the service ports
  (`8080`/`10000`/`3000`/`8000`/`5601`/`9090`/`3011` Uptime Kuma + mail) at the NSG on
  demand. Kibana & Prometheus have **no native auth** — opening them exposes them raw (the portal warns).
  See [On-demand ports](#on-demand-ports-firewall) under the portal.

### Mail relay (authenticated submission, multi-domain, DKIM)
Postfix is an **authenticated submission relay** on `:587` (STARTTLS required, cyrus
SASL — **not an open relay**) that **delivers directly** (outbound `:25` is open on this
subscription) and signs every message with **OpenDKIM**. Reverse DNS (PTR) is set on the
public IP (`reverseFqdn` → cloudapp FQDN) for valid FCrDNS.
- **SASL user**: `relay` (realm = cloudapp FQDN), password in Key Vault `mailRelayPassword`.
  Clients submit as `relay@<cloudapp-fqdn>` over `:587` with AUTH LOGIN/PLAIN + TLS.
- **Domains** (`MAIL_DOMAINS` in `config.sh`): each gets its own DKIM key/selector
  (`mail`). Currently **`az.aspl.net`** + **`poker-mates.com`**.
- **DNS per domain** (in each domain's zone): `mail._domainkey.<d>` (DKIM),
  `<d>` SPF `v=spf1 a:axa.az.aspl.net mx ~all`, `_dmarc.<d>` DMARC `p=none`. The module
  writes the exact records to **`/etc/aza/mail-dns.txt`**. `az.aspl.net` records are
  published in Azure DNS; external domains are published at their own DNS host.
- **fail2ban**: `postfix-sasl` jail covers `:587` brute-force. **Spamhaus**: the IP must
  stay unlisted (it cleared once PTR was set); re-check if delivery degrades.

---

## 3. Key Vault secrets (`kv-axa-westus3`)

| Secret | Used by |
|---|---|
| `mysqlRootPassword` | local MySQL root |
| `guacDbPassword` | local Guacamole DB user (only if `GUAC_USE_LOCAL_MYSQL=true`) |
| `guacamoleHost` / `guacamoleUser` / `guacamolePassword` | external Guacamole DB (default) |
| `guacAdminPassword` | Guacamole `guacadmin` web login |
| `grafanaAdminPassword` | Grafana `admin` |
| `webminPassword` | Webmin `root` |
| `splunkAdminPassword` | Splunk `admin` |
| `vmToolsClientId` / `vmToolsClientSecret` / `vmToolsCookieSecret` | oauth2-proxy (AAD gate for /shell, /db, /kibana, /prometheus) |

Read in the portal **Credentials** page (`/credentials`) via the Function's managed
identity (Key Vault Secrets User). The VM also keeps `webssh`/Guacamole creds in
`/etc/aza/` (root-only) for the keepalive and operator reference.

---

## 4. Guacamole

- Uses an **external MySQL** (persists connections/users across rebuilds): host/user
  from `guacamoleHost`/`guacamoleUser`/`guacamolePassword`. Toggle with
  `GUAC_USE_LOCAL_MYSQL` in `config.sh`.
- Container env: `GUACD_HOSTNAME=guacd`, `MYSQL_HOSTNAME=<host>`. `guacadmin` reset to
  `guacAdminPassword`. A 3-min keepalive (`aza-guac-keepalive.timer`) keeps the DB
  pool warm (external DBs drop idle connections).

---

## 5. DNS

- **cloudapp**: `axa.westus3.cloudapp.azure.com` (VM), `aspl.azurewebsites.net` (portal) — always valid TLS.
- **Custom (Azure DNS `az.aspl.net`, delegated from BIND `aspl.net`)**:
  - `axa.az.aspl.net` → A → VM public IP (updated by the portal on each deploy).
  - `portal.az.aspl.net` → CNAME → `aspl.azurewebsites.net`.
- **BIND `aspl.net`**: `portal.aspl.net` CNAME → `aspl.azurewebsites.net`; `az` NS delegation to Azure.
- Custom domains are bound on the `aspl` Function App; HTTPS on custom names needs a
  BYO cert (Consumption tier has no free managed cert).

---

## 6. Monitoring & log collection

### Metrics — Prometheus → Grafana
- `node_exporter` (:9100) → host CPU/mem/disk/network.
- Prometheus (`/opt/prometheus/prometheus.yml`) scrapes `node` (:9100) + `prometheus`
  (`/prometheus/metrics`). Served under `/prometheus/`.
- Grafana datasources provisioned (`/etc/grafana/provisioning/datasources/aza.yaml`):
  **Prometheus** (default) + **Elasticsearch** (`filebeat-*`). Dashboard: **Node
  Exporter Full** (`/grafana/d/.../node-exporter-full`).

### Logs — Filebeat → Elasticsearch/Kibana
- Filebeat ships `/var/log/{syslog,auth.log}`, nginx, mysql + the `system` module → ES.
- `filebeat setup` (with `setup.kibana.path=/kibana`) created the `filebeat-*` data
  view + dashboards. View in Kibana → Discover / Dashboards.

### Logs — Splunk
- `inputs.conf` monitors syslog, auth.log, nginx, mysql, fail2ban → index `main`.

---

## 7. On-demand portal (`aspl`)

`https://aspl.azurewebsites.net` — Azure AD Easy Auth (tenant-locked, app `aspl`).

- **Landing** (`/`): VM status card + quick Start/Stop, technical/service links (with
  live green/red **health dots** from `/api/health` ← VM `/health.json`), and the
  full external tools list.
- **VM Manager** (`/vm`): Deploy / Start / Stop / Destroy, Connect (web SSH / Guacamole
  / SSH cmd), Services, and the **keep-running Hold**.
- **Operations** (`/ops`): cost & running-hours, scheduled start/stop, snapshot &
  image manager, activity log, and DNS editor (see below).
- **Credentials** (`/credentials`): service passwords from Key Vault (masked, reveal/copy);
  DB rows also show host + database name.
- **Azure Virtual Desktop** (on-demand stack — see sibling project `CreateAvdAzure`):
  landing-page box with **Deploy / Start / Stop / Destroy** + live status + a **Connect**
  link to the AVD web client (`client.wvd.microsoft.com`). Own RG **`rg-avd`**: persistent
  control plane (host pool `hp-avd` Pooled multi-session, app group `ag-avd-desktop`,
  workspace `ws-avd`, vnet — reverse-connect, no inbound) + the ephemeral session host
  `avdhost0` (Win11 multi-session, AAD-joined). **Deploy** = ARM-deploy `avd-sessionhost.json`
  with a fresh registration token (a CustomScript installs/registers the AVD agent).
  **Idle auto-stop**: the `scheduler` timer's `run_avd_idle()` deallocates the host after
  `AVD_IDLE_MINUTES` (30) with **no Active** sessions (tag `avdIdleSince`). Portal MI:
  Virtual Machine Contributor + Desktop Virtualization Reader on `rg-avd`. Connect needs
  Desktop Virtualization User (app group) + Virtual Machine User Login (VM/RG) — granted
  by `CreateAvdAzure/deploy.sh`. The original `rg-avd-quickstart-…` was deleted (its host's
  machine token had expired after months off → `EXPIRED_MACHINE_TOKEN`).
- **API**: `/api/{status,deploy,start,stop,destroy,hold,secrets,health,cost,schedule,
  snapshots,snapshot,images,image,activity,dns,ports,avd}`. Long ops are non-blocking; the UI polls `/api/status`.

### Operations page (`/ops`)
- **Cost / hours**: month-to-date spend for `rg-axa` (Cost Management API) + current-session
  uptime and an estimated session cost (VM start time × retail hourly rate from the public
  Azure Retail Prices API). Cost data lags ~8–24h.
- **Scheduled start/stop**: a daily window (start/stop time, ISO weekdays Mon=1…Sun=7, tz)
  stored as **`rg-axa` RG tags** (`schedEnabled/Start/Stop/Days/Tz`). A Function **timer**
  (every 15 min) resumes a deallocated VM inside the window and deallocates a running VM
  outside it (a keep-running Hold overrides stop). It only *resumes* an existing VM — never deploys.
- **Snapshots & images**: list/create/delete OS-disk snapshots and **restore** (swaps the
  VM's OS disk from a snapshot; deallocates first). Lists gallery image versions, **recapture**
  (snapshot running VM → next image version), and **Set current** (repoints the portal's
  `IMAGE_ID`, restarts the app).
- **Activity log**: recent control-plane events for `rg-axa` (who started/stopped/deleted, when).
- **DNS**: view all records in `az.aspl.net`; add/update/delete A/CNAME/TXT/MX (NS/SOA read-only).

Extra portal MI roles for the above: **Cost Management Reader** + **Monitoring Reader**
(subscription), **Contributor** on the `galAxa` gallery (recapture), **Website Contributor**
on the `aspl` app (self-repoint `IMAGE_ID`).

### Lifecycle & cost control
- **Deploy** = ARM deploy of the VM from the golden image (specialized, ~3–5 min).
- **Stop** = deallocate (compute billing stops). **Start** = resume. **Destroy** = delete the VM stack (RG kept).
- **Idle auto-stop**: in-VM `aza-idle.timer` (every 5 min) deallocates the VM after
  `/etc/aza/idle-minutes` (default 30) with no interactive session (SSH/web-SSH/RDP/guacd).
- **Keep-running Hold**: portal sets VM tag `keepUntil` (epoch); the idle agent skips
  auto-stop while active. Set days in the portal; `0` clears.

---

## 8. Provisioning modules (run order)

`00`-base · `10`-firewall(UFW) · `15`-fail2ban · `20`-mysql · `25`-guacamole ·
`27`-dbeditor(Adminer) · `28`-vmtools-auth(oauth2-proxy) · `30`-nginx(+TLS) ·
`35`-privoxy · `40`-mail(relay+DKIM) · `50`-lynis · `55`-webmin · `60`-elk(ES/Kibana/
Logstash/Grafana/Prometheus) · `62`-monitoring(node_exporter/datasources/dashboard/
filebeat) · `65`-splunk · `70`-pentest · `72`-nettools(Netdata/ntopng/blackbox/Uptime
Kuma/CLI) · `75`-webssh(ttyd) · `80`-idle-shutdown · `85`-health · `90`-snapshot.
Toggle each with `ENABLE_*` in `config.sh`.

### Real-time network tools (module 72)
- **CLI** (via `/shell`): `mtr`, `iftop`, `nload`, `bmon`, `nethogs`, `iptraf-ng`, `vnstat`,
  `iperf3`, `speedtest-cli`, `tcptraceroute`.
- **Netdata** `/netdata/` — per-second host/network metrics (localhost:19999, AAD-gated).
- **ntopng** `/ntopng/` — live traffic/flow analyzer (localhost:3001, AAD-gated; own admin login).
- **blackbox_exporter** (localhost:9115) — ICMP/TCP/HTTP/DNS latency probes scraped by
  Prometheus; **Blackbox** Grafana dashboard (id 13659) imported. Latency/uptime in Grafana.
- **Uptime Kuma** (Docker, `:3011`) — uptime/probe monitors with its own login; **closed by
  default**, opened on demand from the portal (Operations → Ports). No TLS on the raw port.

---

## 9. Backup / restore

`OnDemandPortal` uses a golden image, so the box rebuilds identically. For user data,
`CreateAzaAzure/backup.sh` rsyncs `/home`, `/root`, `/usr/local/bin`, `/etc/aza`
(logs excluded) to `./backups`; `restore.sh` pushes it back. Guacamole data persists
in the external DB regardless.

---

## 10. Operational runbook

```bash
# Portal: open https://aspl.azurewebsites.net (AAD sign-in) → Deploy / Start / Stop / Destroy

# SSH to the VM
ssh -i ~/.ssh/aza_ed25519 azureuser@axa.westus3.cloudapp.azure.com

# On the VM
sudo systemctl status <svc>            # nginx, mysql, grafana-server, prometheus, kibana, ttyd, fail2ban
sudo docker ps                         # some-guacamole, some-guacd, adminer, oauth2-proxy
cat /etc/aza/CONFIGURATION.md          # this file
cat /etc/aza/idle-minutes              # idle timeout (0 disables auto-stop)

# Recapture the golden image after changing the box (OnDemandPortal/)
IMAGE_VERSION=1.0.x ./1-capture-image.sh
az functionapp config appsettings set -g rg-platform -n aspl --settings \
  IMAGE_ID=$(az sig image-version show -g rg-platform -r galAxa -i axa-img -e 1.0.x --query id -o tsv)
```

---

## 11. Known limitations
- **Custom-domain HTTPS** (`portal.aspl.net`) needs a BYO cert (Consumption tier).
- **External Guacamole DB** (GearHost) drops idle connections — mitigated by the keepalive.
- **Kibana/Prometheus** have no native auth — gated by Azure AD (oauth2-proxy) instead.
- Per-service metric exporters (mysqld/nginx) and Splunk apps are not installed (base config only).
