# OnDemandPortal

A public, AAD-gated web portal to build and tear down the `axa` VM **on demand**
in ~3–5 minutes, from a pre-baked **golden image** — no laptop, no secrets in the
browser, near-$0 when idle.

It sits on top of [`../CreateAzaAzure`](../CreateAzaAzure): that project builds and
fully provisions the box; you capture it once as a golden image; this portal then
clones a running VM from that image whenever you need it, and deletes it when done.

## Architecture

A **single Azure Function App** (Python, Consumption) serves both the portal page
and the API, gated by **App Service Easy Auth (Azure AD, tenant-locked)**. Its
**system managed identity** does all the Azure work — nothing secret reaches the browser.

```
 Browser ──▶ https://<app>.azurewebsites.net      Function App (Consumption, ~$0 idle)
   │            ├─ Easy Auth (AAD) gate ── unauthenticated ⇒ 302 to Microsoft login
   │            ├─ GET  /            → portal page
   │            ├─ GET  /api/status  → VM state (+ refreshes DNS A record when running)
   │            ├─ POST /api/deploy  → ARM deploy of VM from the golden image
   │            ├─ POST /api/start | /api/stop → resume / deallocate (cost control)
   │            └─ POST /api/destroy → delete the VM + its stack
   │                     │  system managed identity:
   │                     │   Contributor on rg-axa  +  DNS Zone Contributor on rg-dns
   ▼                     ▼
 sign in (AAD)    VM cloned from Compute Gallery image  (rg-platform / galAxa / axa-img)
                  into rg-axa, A record axa.az.aspl.net → new IP
```

- **Specialized golden image** — the captured box boots fully configured (services,
  certs, SSH key) with no cloud-init re-run, so deploys take minutes.
- **Persistent vs ephemeral**: `rg-platform` (gallery, image, Function App, storage)
  and `rg-dns` (DNS zone) are kept; `rg-axa` is the target the portal fills (deploy)
  and empties (destroy). The RG itself is kept so the identity's role stays valid.

## Layout

```
OnDemandPortal/
├── config.sh              # shared names (RGs, gallery, image, app)
├── 1-capture-image.sh     # snapshot the running VM → Compute Gallery image (non-destructive)
├── 3-provision-portal.sh  # create Function App + identity + roles + settings + Easy Auth, deploy code
├── infra/
│   └── vm-from-image.bicep # VM (TrustedLaunch) + pip/nsg/vnet/nic from the image
├── api/                   # Azure Functions (Python v2) — UI + API in one app
│   ├── function_app.py    #   GET / (landing), /vm (manager), /app.js; /api/{status,deploy,start,stop,destroy,hold}
│   ├── shared.py          #   Azure SDK logic (deploy template, delete stack, status, DNS, hold)
│   ├── vm-from-image.json #   compiled ARM template (generated)
│   ├── www/               #   web UI bundled in at deploy time (generated from web/)
│   ├── host.json · requirements.txt
└── web/                   # UI source (copied into api/www/ by the provision script)
    ├── index.html         #   landing page: VM status card + technical links
    ├── vm.html · app.js    #   the VM manager dashboard + its logic
```

The portal is two pages (both AAD-gated): `/` is the landing page (live VM
status, quick Start/Stop, and technical/service links) and `/vm` is the full VM
manager (deploy/start/stop/destroy, connect, services, keep-running hold).

## Setup (two commands)

```bash
# 0. Build + provision the box once (the other project), so there's something to image:
( cd ../CreateAzaAzure && ./deploy.sh )

# 1. Capture the golden image (non-destructive snapshot of the running VM):
./1-capture-image.sh

# 2. Stand up the whole portal — Function App, identity, roles, settings, code,
#    and AAD Easy Auth (registers the AAD app and locks sign-in to your tenant):
./3-provision-portal.sh
```

That's it. The script prints the portal URL. Open it, sign in with your Azure AD
account, and use **Deploy** / **Destroy**. Both scripts are idempotent.

## Auth

`3-provision-portal.sh` registers a single-tenant AAD app and configures Easy Auth
v2 (`unauthenticatedClientAction: RedirectToLoginPage`). Result: any browser hitting
the site is redirected to Microsoft sign-in and must be in your tenant
(`AzureADMyOrg`). No auth code, no stored secret in the app (the AAD client secret
lives only in an app setting referenced by the platform).

## API

| Method | Route | Action |
|---|---|---|
| GET | `/` , `/app.js` | portal UI |
| GET | `/api/status` | `{state, publicIp, fqdn, customFqdn}`; refreshes DNS A record when running |
| POST | `/api/deploy` | ARM deploy of the VM from the image (returns immediately) |
| POST | `/api/start` | start a deallocated VM (resume) |
| POST | `/api/stop` | **deallocate** the VM — stops compute billing |
| POST | `/api/destroy` | delete the VM + nic/ip/nsg/vnet/disk (keeps the RG) |

`state` ∈ `down | deploying | running | deallocated | deallocating | starting`. The UI
polls `/api/status` every 15 s while a transition is in flight, and enables the
Deploy/Start/Stop/Destroy buttons per state. Long actions never block the HTTP call —
they kick off the operation and return; the UI polls for completion.

### Lifecycle & cost control

- **Deploy** (create from image) · **Start** (resume) · **Stop** (deallocate — compute
  billing stops, ~disk-only cost) · **Destroy** (delete).
- **Idle auto-stop**: each deployed VM runs an in-VM agent (`aza-idle.timer`, every
  5 min) that **deallocates itself** after `/etc/aza/idle-minutes` (default 30) with no
  interactive session — checking SSH logins and established connections on ports 22
  (SSH), 7681 (web SSH), 3389 (RDP), 4822 (guacd). It uses the VM's attached
  user-assigned identity (`axa-vm-identity`, Virtual Machine Contributor on rg-axa).
  Set `/etc/aza/idle-minutes` to `0` to disable; resume any time with **Start**.
- **Keep running (hold)**: for a multi-day project, set a hold in the portal
  ("Keep running" → N days → **Hold**). This sets the VM tag `keepUntil` (epoch);
  the idle agent reads it via instance metadata and **skips auto-stop until it
  expires**, then idle behavior resumes automatically. **Clear hold** removes it.
  `POST /api/hold?days=N` (0 clears); `/api/status` returns `holdUntil`.

### Connect & services (shown when running)

When the VM is up, the portal reveals two panels:

- **Connect** —
  - **Web SSH** (one-click): opens `/shell/`, a browser terminal (ttyd) served over
    TLS behind HTTP basic auth. Login `webssh` / password in `/etc/aza/webssh.txt`
    on the box (baked into the image). Instant shell, no per-connection setup.
  - **Guacamole**: browser SSH/RDP (its own `guacadmin` login + a connection to add).
  - **Local SSH**: a copyable `ssh -i ~/.ssh/aza_ed25519 azureuser@<fqdn>` command.
- **Services** — a tiled list of every web service behind nginx (Website,
  Guacamole, Webmin, Kibana, Grafana, Prometheus, Splunk), each linking to
  `https://<fqdn>/<path>/`.

Both are driven by the `fqdn` from `/api/status`.

## Recapturing the image (after changing the box)

```bash
( cd ../CreateAzaAzure && ./deploy.sh )          # rebuild/adjust the box
IMAGE_VERSION=1.0.1 ./1-capture-image.sh         # capture a new version
az functionapp config appsettings set -g rg-platform -n aspl \
  --settings IMAGE_ID=$(az sig image-version show -g rg-platform -r galAxa \
    -i axa-img -e 1.0.1 --query id -o tsv)        # point the portal at it
```

Old snapshots in `rg-platform` can be deleted to save storage cost.

## Important: the portal owns rg-axa

The portal deploys/destroys VMs using its own resource names (`axa`, `axa-ip`,
`axa-nsg`, `axa-vnet`, `axa-nic`, `axa-osdisk`). The original always-on box built by
`../CreateAzaAzure` (with `az vm create`'s default names) was only the **source for
the image** — tear it down once so the portal manages `rg-axa` cleanly:

```bash
( cd ../CreateAzaAzure && ./backup.sh && ./destroy.sh )   # data is in the image anyway
```

After that, the portal is the single way the `axa` VM comes and goes.

## Cost

- **Idle (VM down)**: gallery image + snapshot storage (a few $/mo) and the
  Consumption Function App (≈ free). No always-on portal cost.
- **Up**: the VM (Standard_D4s_v3) bills normally; **Destroy** stops that.
