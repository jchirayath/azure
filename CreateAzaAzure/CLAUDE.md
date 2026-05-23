# CLAUDE.md — CreateAzaAzure

Guidance for AI assistants working on this project. Read this before editing.
User-facing docs live in `README.md`; this file captures architecture, conventions,
and the **non-obvious gotchas** discovered while building and live-testing it (so
you don't re-debug them).

## What this is

A one-touch, modular Azure VM builder (rewrite of the old `../CreateAxa/CreateVM.sh`).
`deploy.sh` builds a resource group + Ubuntu 22.04 VM, provisions a full toolchain
in a **single cloud-init boot**, and `destroy.sh` tears it down. `backup.sh`/
`restore.sh` preserve user data. Secrets never touch git — they live in `.env`
(gitignored) and Azure Key Vault, read by the VM via its managed identity.

## Core design rules (do not break these)

1. **No secrets in git or in the cloud-init payload.** Generated passwords go to
   Key Vault only; modules fetch them at boot with `kv_get <name>`. `.env` and
   `backups/` are gitignored. Never echo a secret into `runtime.env`, the manifest,
   or a module file.
2. **Idempotent.** Every Azure resource creation is guarded by a `show`/`exists`
   check; every module is safe to re-run. Preserve this when editing.
3. **One cloud-init boot.** All on-VM work runs via `orchestrate.sh` → modules.
   Do not reintroduce per-service Azure extensions (that was the old script's slowness).
4. **Modules are self-contained.** Each `payload/modules/NN-*.sh` sources
   `$AZA_HOME/lib/remote.sh`, uses `set -uo pipefail` (NOT `-e` — a failing module
   should warn and let others continue), and must verify success rather than
   printing a blind "ok".

## Architecture / data flow

```
deploy.sh (local)
  ├─ az preflight, RG, user-assigned identity
  ├─ Key Vault (RBAC) + seed secrets  → KV
  ├─ public IP (Standard/static) + Azure DNS zone (in rg-dns) + A record
  ├─ NSG + rules (from NSG_RULES in config.sh)
  ├─ build payload: tar(payload/ + manifest.txt + runtime.env) | gzip | base64
  │     → cloud-init write_files (encoding gz+b64) → --custom-data
  └─ az vm create (TrustedLaunch) → SSH wait → cloud-init status --wait

On the VM at first boot:
cloud-init → /opt/aza/orchestrate.sh
  ├─ install az cli, az login --identity (retry)
  └─ for each module in manifest.txt: bash module  (env from runtime.env, AZA_HOME=/opt/aza)
        modules call kv_get <name> for secrets
```

- `runtime.env` (non-secret) carries `KV_NAME`, `CUSTOM_FQDN`, `CERTBOT_EMAIL`,
  `MAIL_USER`, `GUAC_USE_LOCAL_MYSQL`, `SPLUNK_DEB_URL`, `SPLUNK_WEB_PORT`.
- `manifest.txt` is generated from the `ENABLE_*` flags via `MODULE_MAP` in deploy.sh.

## Key files

| File | Role |
|---|---|
| `config.sh` | non-secret config + `ENABLE_*` toggles + `NSG_RULES` + `BACKUP_*` (committed) |
| `.env` / `.env.example` | secrets (gitignored) / template |
| `lib/common.sh` | local helpers: `log/ok/warn/die`, `load_config`, `az_preflight`, `vm_*` |
| `deploy.sh` | the orchestrator; `MODULE_MAP` maps flags→module files; `seed_secret`, `assign_role` |
| `destroy.sh` | deletes `VM_RESOURCE_GROUP`, purges its soft-deleted KV (leaves `rg-dns`) |
| `backup.sh` / `restore.sh` | rsync user data ↔ VM over SSH (sudo rsync remotely) |
| `payload/orchestrate.sh` | on-VM runner |
| `payload/lib/remote.sh` | on-VM helpers: `log/ok/warn/die`, `apt_install`, `kv_get`, `vm_fqdn` |
| `payload/modules/NN-*.sh` | one service each |
| `payload/files/index.html` | landing page served at `/` |

## Defaults (config.sh)

`VM_HOSTNAME=axa`, `VM_RESOURCE_GROUP=rg-axa`, `VM_REGION=westus3`,
`VM_SIZE=Standard_D4s_v3` (16 GB; needed for ELK+Splunk),
`VM_SSH_KEY=~/.ssh/aza_ed25519` (passwordless), `KEY_VAULT_NAME=kv-axa-westus3`,
`DNS_ZONE=az.aspl.net`, `DNS_RECORD=axa` → `CUSTOM_FQDN=axa.az.aspl.net`,
`DNS_ZONE_RG=rg-dns` (separate persistent RG).

Subscription: `JacobAzure` (id `599284ed-d012-4545-8018-48b27db20a7f`, tenant aspl.net).

## Common commands

```bash
./deploy.sh                      # full build (idempotent); waits for cloud-init
./destroy.sh                     # delete rg-axa (prompts; --yes to skip)
./backup.sh ; ./restore.sh       # data backup/restore
VM_SIZE=Standard_D2s_v3 ./deploy.sh   # env overrides any config value
bash -n <script>                 # syntax check before running

# On the VM
ssh -i ~/.ssh/aza_ed25519 azureuser@axa.westus3.cloudapp.azure.com
sudo tail -f /var/log/aza-provision.log
sudo cloud-init status --wait

# Re-run one module on a live VM (custom-data only applies at create time)
scp -i ~/.ssh/aza_ed25519 payload/modules/60-elk.sh azureuser@<vm>:/tmp/
ssh -i ~/.ssh/aza_ed25519 azureuser@<vm> '
  sudo cp /tmp/60-elk.sh /opt/aza/modules/
  sudo bash -c "set -a; source /opt/aza/runtime.env; set +a; export AZA_HOME=/opt/aza; bash /opt/aza/modules/60-elk.sh"'
```

## GOTCHAS (learned the hard way — keep these fixes in place)

- **TrustedLaunch**: `az vm create` with `--enable-secure-boot/--enable-vtpm`
  **requires** `--security-type TrustedLaunch`, else `Use of UEFI settings is not
  supported`. Already set.
- **SSH key must be passwordless.** A passphrase-protected key makes the SSH wait /
  backup / restore hang. deploy.sh generates `~/.ssh/aza_ed25519` if missing and
  rejects an encrypted key. Reset a live VM's key with `az vm user update`.
- **Key Vault soft-delete.** Deleting an RG soft-deletes its vault (90-day name
  hold). deploy.sh purges a soft-deleted same-named vault before recreating.
  `az keyvault purge --name <kv>` to do it manually.
- **Key Vault RBAC propagation.** After creating the vault + role assignments,
  data-plane access takes a minute. `seed_secret` retries the `secret set` (~3 min).
- **DNS A record TTL.** `az network dns record-set a add-record` does **not** accept
  `--ttl`. Use `record-set a create --ttl` then `add-record`.
- **DNS zone lives in `rg-dns`, not the VM RG** — so `destroy.sh` doesn't delete the
  zone and invalidate the one-time NS delegation.
- **Elasticsearch 8.x** enables security by default; this stack disables it for a
  single-node internal box. Two traps the module handles: (1) don't append
  `xpack.security.*` to the auto-config block (duplicate-key YAML error) — write a
  clean minimal `elasticsearch.yml`; (2) the install seeds the **keystore** with TLS
  secure-passwords that block boot when security is off — reset the keystore
  (`elasticsearch-keystore create`).
- **Filebeat modules** (`nginx`/`apache`) default to no enabled filesets and refuse
  to start; the module writes a self-contained `filebeat.yml` with explicit inputs.
- **Don't batch big apt installs.** A single unavailable package name aborts the
  whole `apt-get install`. The pentest + ELK modules install per-package with
  retries. (`seclists`/`exploitdb`/`impacket-scripts` are NOT in Ubuntu repos.)
- **Splunk** runs via a forking init script — `systemctl is-active splunk` may say
  inactive while `splunkd` runs; check `/opt/splunk/bin/splunk status`.
- **Privoxy** is a forward proxy; `permit-access` needs CIDR (`0.0.0.0/0`), not a
  bare `0.0.0.0`. `/privoxy/` via nginx returns 400 by design — use it on `:8118`.
- **Webmin** serves HTTPS on :10000, needs `webprefix=/webmin` for the subpath, and
  nginx must `proxy_pass https://...` with `proxy_ssl_verify off`. Install WITH
  recommends (don't use `--no-install-recommends` for webmin).
- **Don't edit `deploy.sh` while a deploy is running in the background** — bash reads
  scripts by byte offset; editing shifts offsets and corrupts the running process.
  Edit `config.sh`/modules freely (already consumed), defer `deploy.sh` edits.

## Conventions for changes

- Match the existing logging helpers (`log/ok/warn/die`) and `set -uo pipefail`.
- Verify, don't assume: after installing/starting something, check it (port,
  service active, HTTP code) and `warn`/`die` accordingly.
- Keep `bash -n` clean on every script before considering a change done.
- When adding a service, update all five spots (see README "Adding a service"):
  module file, `ENABLE_*` in config.sh, `MODULE_MAP` in deploy.sh, `seed_secret`
  (if it needs a secret), `NSG_RULES` + firewall module (if it needs a port).

## Validation status

Live-tested end-to-end on subscription `JacobAzure`: clean deploy of `axa`/`rg-axa`
brought up all 14 modules; all web services return healthy codes over HTTPS with a
valid Let's Encrypt cert; backup/restore verified; custom DNS (`axa.az.aspl.net`)
created and resolving via Azure NS (awaiting one-time registrar delegation of the
`az` subdomain at aspl.net).
