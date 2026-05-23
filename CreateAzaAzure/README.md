# CreateAzaAzure

One-touch, modular Azure VM builder. Spins up a resource group + Ubuntu VM with a
full toolchain (security, reverse proxy, Guacamole, observability, Splunk, a
pentesting toolkit), serves a tools landing page over HTTPS, tears it all down
with a single command, and backs up / restores your data.

It is a ground-up rewrite of the old `CreateAxa/CreateVM.sh`, designed around
three goals:

- **Fast** — all provisioning runs in **one cloud-init boot**, not a dozen serial
  Azure extensions with reboot-waits between each.
- **No secrets in git** — secrets live in `.env` (gitignored) and Azure Key Vault.
  The VM reads them at boot via its **managed identity**; nothing secret is ever
  embedded in the cloud-init payload, written to local disk, or committed.
- **Modular** — each service is a self-contained script in `payload/modules/`,
  toggled in `config.sh`. Adding a service is one file + one flag.

## Layout

```
CreateAzaAzure/
├── deploy.sh         # one-touch: create RG + VM, fully provision, wait until ready
├── destroy.sh        # one-touch: delete the whole VM RG (auto-purges its Key Vault)
├── backup.sh         # pull /home + scripts off the VM into ./backups (logs excluded)
├── restore.sh        # push a backup back onto the VM
├── config.sh         # non-secret config + service toggles (committed)
├── .env.example      # secrets template -> copy to .env (gitignored)
├── lib/common.sh     # helpers for the local scripts (logging, az preflight)
└── payload/          # everything that runs ON the VM (bundled into cloud-init)
    ├── orchestrate.sh   # boots, az-logs-in via identity, runs enabled modules in order
    ├── lib/remote.sh    # kv_get(), logging, apt helpers used by every module
    ├── files/index.html # the tools landing page served at /
    └── modules/         # NN-name.sh — one service each, run in numeric order
```

## Prerequisites

- Azure CLI (`az`) logged in: `az login`
- `rsync`, `openssl`, `ssh-keygen`, `tar` (all standard on macOS/Linux)
- A subscription where you can create resource groups, Key Vaults (RBAC), DNS
  zones, and role assignments

## Quick start

```bash
cp .env.example .env       # fill in CERTBOT_EMAIL / MAIL_USER
$EDITOR config.sh          # optional: region, size, which services to enable

./deploy.sh                # build everything; blocks until cloud-init finishes
./backup.sh                # snapshot user data locally (run before teardown)
./destroy.sh               # delete the resource group (prompts to confirm)
./restore.sh               # after a fresh deploy, push the data back
```

`deploy.sh` is **idempotent** — re-running only creates what's missing.

## Defaults (config.sh)

| Setting | Default | Notes |
|---|---|---|
| `VM_HOSTNAME` | `axa` | also the cloudapp DNS label |
| `VM_RESOURCE_GROUP` | `rg-axa` | everything except DNS lives here |
| `VM_REGION` | `westus3` | |
| `VM_SIZE` | `Standard_D4s_v3` | 16 GB — required because ELK + Splunk are on by default |
| `VM_SSH_KEY` | `~/.ssh/aza_ed25519` | passwordless; generated if missing |
| `KEY_VAULT_NAME` | `kv-axa-westus3` | globally unique, RBAC-enabled |
| `DNS_ZONE` / `DNS_RECORD` | `az.aspl.net` / `axa` | → custom FQDN `axa.az.aspl.net` |
| `DNS_ZONE_RG` | `rg-dns` | **separate persistent RG**, never deleted by `destroy.sh` |

Every value supports an env override, e.g. `VM_REGION=eastus VM_SIZE=Standard_D2s_v3 ./deploy.sh`.

## What you get

A landing page of troubleshooting/monitoring tools at `/`, plus services behind
nginx with a Let's Encrypt cert, at `https://axa.westus3.cloudapp.azure.com/`
(and `https://axa.az.aspl.net/` once the domain is delegated):

| Path | Service | Backend port |
|---|---|---|
| `/` | Tools landing page | nginx |
| `/guacamole/` | Apache Guacamole (Docker) | 8080 |
| `/webmin/` | Webmin (HTTPS) | 10000 |
| `/kibana/` | Kibana | 5601 |
| `/grafana/` | Grafana | 3000 |
| `/prometheus/` | Prometheus | 9090 |
| `/splunk/` | Splunk Free | 8000 |

Privoxy is a **forward** proxy on `:8118` (use it as an HTTP proxy, not a web path).

### Modules (run order)

| # | Module | What it does |
|---|---|---|
| 00 | base | apt upgrade, core tooling, Docker, hostname/timezone/locale |
| 10 | firewall | UFW (SSH allowed first) |
| 15 | fail2ban | hardened sshd jail |
| 20 | mysql | local MySQL; root password from Key Vault |
| 25 | guacamole | Guacamole via Docker; external DB by default (persists across rebuilds), guacadmin reset to vaulted password |
| 30 | nginx | reverse proxy + Certbot/TLS + landing page |
| 35 | privoxy | filtering forward proxy on :8118 |
| 40 | mail | Postfix + STARTTLS cert |
| 50 | lynis | security audit → `/etc/aza/lynis_report.txt` |
| 55 | webmin | admin UI on :10000 |
| 60 | elk | Elasticsearch + Kibana + Logstash + Filebeat (security off, single-node) + Prometheus + Grafana |
| 65 | splunk | Splunk Free; admin password from Key Vault |
| 70 | pentest | nmap, sqlmap, hydra, john, hashcat, nikto, gobuster, masscan, aircrack-ng, tshark, impacket, Metasploit, … |
| 90 | snapshot | initial Timeshift restore point |

Toggle any of these with the `ENABLE_*` flags in `config.sh`.

## SSH

```bash
ssh -i ~/.ssh/aza_ed25519 azureuser@axa.westus3.cloudapp.azure.com
```

The key **must be passwordless** so the automation (cloud-init wait, backup,
restore) can run non-interactively. `deploy.sh` generates one if missing and
**rejects a passphrase-protected key** rather than hanging.

## Secrets model

`deploy.sh` generates strong random passwords (or uses values you set in `.env`)
and stores them **only** in Key Vault:

| Key Vault secret | Used by |
|---|---|
| `mysqlRootPassword` | local MySQL root |
| `guacDbPassword` | local Guacamole DB user (only when `GUAC_USE_LOCAL_MYSQL=true`) |
| `guacamoleHost` / `guacamoleUser` / `guacamolePassword` | external Guacamole DB (when `GUAC_USE_LOCAL_MYSQL=false`, the default) |
| `guacAdminPassword` | Guacamole `guacadmin` web login (reset off the default each provision) |
| `splunkAdminPassword` | Splunk `admin` |

The VM's user-assigned managed identity holds **Key Vault Secrets User**, so each
module fetches what it needs at boot with `kv_get <name>`. No credential travels
through cloud-init or lands on local disk.

## Custom domain (Azure DNS)

The custom FQDN is `${DNS_RECORD}.${DNS_ZONE}` (default `axa.az.aspl.net`).

`deploy.sh` creates the DNS zone in a **separate persistent resource group**
(`rg-dns`) so `destroy.sh` never removes it — your delegation stays valid across
VM rebuilds. It adds an `A` record to the VM's static public IP and prints the 4
Azure name servers.

**One-time delegation** at your parent registrar (`aspl.net`): add `NS` records
for the `az` subdomain pointing to those Azure name servers, e.g.

```
az  NS  ns1-08.azure-dns.com.
az  NS  ns2-08.azure-dns.net.
az  NS  ns3-08.azure-dns.org.
az  NS  ns4-08.azure-dns.info.
```

(your zone's actual NS values are printed by `deploy.sh`). Until delegation
propagates, the nginx module skips the custom name from the cert and uses the
cloudapp FQDN. Once it resolves, bind the cert:

```bash
ssh -i ~/.ssh/aza_ed25519 azureuser@axa.westus3.cloudapp.azure.com \
  'sudo certbot --nginx -d axa.westus3.cloudapp.azure.com -d axa.az.aspl.net \
     --expand --non-interactive --agree-tos --redirect -m you@example.com'
```

(or just re-run `./deploy.sh` after delegation — it includes the custom name automatically).

## Backup & restore

`backup.sh` rsyncs the paths in `BACKUP_SOURCES` (default `/home`, `/root`,
`/usr/local/bin`, `/etc/aza`) into `./backups/<host>-<timestamp>/` over SSH, using
`sudo rsync` remotely so it can read all home dirs. Logs and caches
(`BACKUP_EXCLUDES`) are skipped. A `<host>-latest` symlink points at the newest.

```bash
./backup.sh                                  # snapshot now
./restore.sh                                 # push newest backup to the VM
./restore.sh backups/axa-20260522-101500     # push a specific snapshot
```

`./backups` is gitignored. Teardown does **not** auto-backup — run `backup.sh`
first if you want to keep anything.

## How provisioning works

`deploy.sh` tars `payload/` (plus a generated `manifest.txt` of enabled modules
and a non-secret `runtime.env`), gzip+base64-encodes it into a cloud-init
`write_files` entry, and passes it as `--custom-data`. On first boot cloud-init
extracts it and runs `orchestrate.sh`, which installs the Azure CLI, logs in with
the managed identity, and runs each module from the manifest in order.

Watch it on the VM:

```bash
sudo tail -f /var/log/aza-provision.log
sudo cloud-init status --wait
```

The payload is ~22 KB (well under Azure's ~64 KB custom-data limit). `deploy.sh`
warns if you enable enough modules to approach the limit.

## Adding a service

1. Create `payload/modules/NN-myservice.sh` (`NN` sets run order):
   ```bash
   #!/usr/bin/env bash
   set -uo pipefail
   source "$AZA_HOME/lib/remote.sh"
   apt_install myservice
   # secrets, if any:  pw="$(kv_get myServiceSecret)"
   ```
2. Add a toggle to `config.sh`: `ENABLE_MYSERVICE="${ENABLE_MYSERVICE:-true}"`.
3. Add a line to `MODULE_MAP` in `deploy.sh`: `"ENABLE_MYSERVICE:NN-myservice.sh"`.
4. If it needs a secret, add a `seed_secret myServiceSecret ""` call in `deploy.sh`.
5. If it needs an inbound port, add it to `NSG_RULES` (config.sh) and to the
   firewall module's port list.

## Re-provisioning an existing VM

cloud-init custom-data only applies at **VM creation**. To re-run provisioning on
a live box without rebuilding, copy the updated module and run it with the same
runtime env cloud-init uses:

```bash
scp -i ~/.ssh/aza_ed25519 payload/modules/30-nginx.sh azureuser@<vm>:/tmp/
ssh -i ~/.ssh/aza_ed25519 azureuser@<vm> '
  sudo cp /tmp/30-nginx.sh /opt/aza/modules/
  sudo bash -c "set -a; source /opt/aza/runtime.env; set +a; export AZA_HOME=/opt/aza; bash /opt/aza/modules/30-nginx.sh"'
```

Modules are written to be idempotent. For a full clean rebuild: `./destroy.sh && ./deploy.sh`.

## Troubleshooting

- **`Permission denied (publickey)` / automation hangs** — your `VM_SSH_KEY` is
  passphrase-protected. Point `VM_SSH_KEY` at a passwordless key (`ssh-keygen -t
  ed25519 -f ~/.ssh/aza_ed25519 -N ''`). To fix a running VM:
  `az vm user update -g rg-axa -n axa -u azureuser --ssh-key-value "$(cat ~/.ssh/aza_ed25519.pub)"`.
- **`A vault with the same name already exists in deleted state`** — a prior
  Key Vault is soft-deleted. `deploy.sh` auto-purges it; to do it manually:
  `az keyvault purge --name kv-axa-westus3`.
- **VM create: `Use of UEFI settings is not supported`** — needs
  `--security-type TrustedLaunch` (already set in `deploy.sh`).
- **Elasticsearch won't start** — ES 8.x ships security on by default; this stack
  disables it for a single-node internal box. If you edited the config, ensure
  there are no duplicate `xpack.security.*` keys and reset the keystore:
  `sudo rm -f /etc/elasticsearch/elasticsearch.keystore && sudo /usr/share/elasticsearch/bin/elasticsearch-keystore create`.
- **Splunk shows `inactive` under systemd but works** — Splunk uses a forking init
  script; check `sudo /opt/splunk/bin/splunk status` instead.
- **Provision log**: `sudo tail -f /var/log/aza-provision.log` on the VM.

## Notes / caveats

- **VM size**: ELK + Splunk are memory-hungry — keep `Standard_D4s_v3` (16 GB) or
  larger when they're enabled.
- **Splunk URL**: `SPLUNK_DEB_URL` in `config.sh` pins a version; update it if the
  download 404s.
- **Mail deliverability** needs PTR/SPF/DKIM DNS records, which are outside this repo.
- **Pentest tools** are for authorized testing only. Kali metapackages aren't on
  Ubuntu; this installs the practical repo-available equivalents + Metasploit.
- The Azure resource names use `axa` (`rg-axa`, VM `axa`, `kv-axa-westus3`); the
  public custom FQDN is `axa.az.aspl.net`.
