# CLAUDE.md — OnDemandPortal

Guidance for AI assistants. User-facing docs are in `README.md`; this captures
architecture, conventions, and gotchas. Sibling project: `../CreateAzaAzure`
(builds/provisions the box; this project images it and serves it on demand).

## Purpose

A public, AAD-gated web portal to deploy/destroy the `axa` VM on demand in
~3–5 min from a golden image. Built and validated live alongside CreateAzaAzure.

## Architecture (single Function App + Easy Auth)

One **Azure Function App** (Python v2, Consumption) serves the UI **and** the API,
gated by **App Service Easy Auth (AAD, single-tenant)**. Its **system managed
identity** does the Azure work — no secrets in the browser or git.

```
Browser → https://aspl.azurewebsites.net
  Easy Auth (AAD) → unauthenticated browser ⇒ 302 to Microsoft login (tenant-locked)
  GET  /            → www/index.html        (catch-all GET route)
  GET  /app.js      → www/app.js
  GET  /api/status  → shared.get_status()   (VM instance-view + pip; refreshes DNS A record when running)
  POST /api/deploy  → shared.start_deploy()  (ARM deploy of infra/vm-from-image.bicep into rg-axa, non-blocking)
  POST /api/start   → shared.start_vm()      (begin_start)
  POST /api/stop    → shared.stop_vm()        (begin_deallocate — stops compute billing)
  POST /api/destroy → shared.start_destroy() (delete VM + nic/ip/nsg/vnet/disk by name; RG kept)
  identity: Contributor on rg-axa + DNS Zone Contributor on rg-dns
            + Cost Management Reader & Monitoring Reader (sub) + Contributor on
              galAxa gallery + Website Contributor on the aspl app (see Operations)

OPERATIONS PAGE (/ops) — control-plane features that work even when the VM is off:
  GET  /api/cost      → MTD spend (Cost Management) + session uptime/cost (retail price API)
  GET/POST /api/schedule → daily start/stop window stored as rg-axa RG TAGS
       (schedEnabled/Start/Stop/Days/Tz). A TIMER trigger (every 15 min,
       @app.timer_trigger) runs shared.run_schedule(): resume in-window, deallocate
       out-of-window (Hold overrides stop). Only resumes an existing VM — never deploys.
  GET  /api/snapshots ; POST /api/snapshot?action=create|delete|restore&name=
  GET  /api/images    ; POST /api/image?action=recapture|select&version=
       recapture = snapshot running VM → next gallery image version (async replication);
       select = rewrite THIS app's IMAGE_ID app setting (restarts the app).
  GET  /api/activity  → rg-axa control-plane events (Activity Log)
  GET/POST /api/dns   → list / upsert / delete (action=delete) A·CNAME·TXT·MX in az.aspl.net
  Schedule/tz needs tzdata in requirements (zoneinfo on the Linux host).

Lifecycle states surfaced to the UI: down | deploying | running | deallocated |
deallocating | starting. Buttons enable per state (deploy when down, start when
deallocated, stop when running, destroy unless down).

IDLE AUTO-STOP (cost control): each VM runs an in-VM agent baked into the image
(CreateAzaAzure module 80-idle-shutdown.sh): systemd timer aza-idle.timer every
5 min runs /usr/local/bin/aza-idle-check.sh, which deallocates the VM via
`az login --identity` + `az vm deallocate` after /etc/aza/idle-minutes (default 30)
with no interactive session (who + established conns on :22/:7681/:3389/:4822).
The VM gets a user-assigned identity `axa-vm-identity` (Virtual Machine Contributor
on rg-axa), attached by the bicep (param vmIdentityId, app setting VM_IDENTITY_ID).

KEEP-RUNNING HOLD: POST /api/hold?days=N → shared.set_hold() PATCHes the VM tag
`keepUntil`=epoch via the ARM Tags API (Merge); days<=0 sets it to 0 (clear). The
idle agent reads keepUntil via IMDS tagsList and skips auto-stop while now<keepUntil.
/api/status returns holdUntil (read via the tags API). Tags chosen over run-command
so the portal reads/writes fast and the VM reads via instance metadata (no SSH).
NOTE: IMDS reflects tag changes within ~minutes (fine for a days-long hold).
```

We did NOT use Static Web Apps: SWA Free can't use managed identity, and SWA+linked
Function App needs SWA Standard (~$9/mo). The single Function App + Easy Auth is
cheaper (≈$0 idle) and simpler. (An earlier `axa-portal` SWA was created then deleted.)

## Core design rules

1. **No secrets.** Function uses its managed identity (`DefaultAzureCredential`).
   The only secret (AAD client secret for Easy Auth) lives in an app setting
   referenced by the auth config, never in code/git.
2. **Specialized image** ⇒ VM template has **no `osProfile`**, no cloud-init re-run.
3. **Persistent vs ephemeral.** `rg-platform` (gallery, image, Function App, storage)
   and `rg-dns` (zone) are never torn down. `rg-axa` is the target; **keep the RG**
   (delete resources by name) so the identity's Contributor assignment survives.
4. **Idempotent** scripts; guard creates with `show` checks.
5. **Never block the HTTP call on a full deploy** — `/api/deploy` starts the ARM
   deployment without `.result()` and returns; the UI polls `/api/status`.

## Key files

| File | Role |
|---|---|
| `config.sh` | one source of truth for names; values pushed to Function App settings |
| `1-capture-image.sh` | non-destructive: snapshot OS disk → Compute Gallery specialized image |
| `3-provision-portal.sh` | Function App (system MI) + roles + settings + code zip-deploy + bundles `web/`→`api/www/` + Easy Auth |
| `infra/vm-from-image.bicep` | VM template the Function deploys (compiled to `api/vm-from-image.json`) |
| `api/function_app.py` | v2 routes: UI (`/`, `/app.js`) + API (lifecycle + Operations) + `scheduler` timer |
| `api/shared.py` | Azure SDK + ARM-REST logic; config from env (App Settings) |
| `api/host.json` | `routePrefix: ""` so routes are literal paths (UI at root, not under /api) |
| `web/index.html`, `web/vm.html`, `web/ops.html`, `web/credentials.html`, `web/app.js` | UI source; copied into `api/www/` at deploy |

## Config / names (config.sh)

`AZURE_SUBSCRIPTION=JacobAzure` (id `599284ed-d012-4545-8018-48b27db20a7f`),
tenant `6308c3aa-e6d7-42c0-a597-135be8c5d6af` (aspl.net).
`VM_RESOURCE_GROUP=rg-axa`, `VM_HOSTNAME=axa`, `VM_SIZE=Standard_D4s_v3`,
`VM_REGION=westus3`. Platform: `PLATFORM_RG=rg-platform`, `GALLERY_NAME=galAxa`,
`IMAGE_DEF=axa-img`, `IMAGE_VERSION=1.0.0`. DNS: `DNS_ZONE=az.aspl.net`,
`DNS_RECORD=axa`, `DNS_ZONE_RG=rg-dns`. App: `FUNCTION_APP=aspl`,
`PORTAL_REGION=westus2`. Portal AAD app: `aspl` (id `2464bc62-0715-45f6-8370-4e2914da777a`); VM-tools AAD app: `axa-vm-tools`.

## Commands

```bash
./1-capture-image.sh                 # capture/refresh golden image (bump IMAGE_VERSION)
./3-provision-portal.sh              # stand up / update the portal (idempotent, incl. Easy Auth)
az bicep build --file infra/vm-from-image.bicep --outfile api/vm-from-image.json
python3 -m py_compile api/*.py
# Test the live portal (browser-style → expect 302 to login):
curl -sI -A Mozilla https://aspl.azurewebsites.net/   # 302 to login.windows.net
```

## GOTCHAS (hit and solved during the live build)

- **TrustedLaunch must match end-to-end.** Image def created with
  `--features SecurityType=TrustedLaunch`; VM template sets
  `securityProfile.securityType=TrustedLaunch`. Source VM is TrustedLaunch.
- **Specialized image** = no `osProfile` in the VM template. Switching to a
  generalized image would require adding admin user + SSH key + (re)deprovision.
- **Image version replication takes 5–15 min** (`provisioningState=Creating`);
  deploys from it fail until `Succeeded`.
- **Easy Auth via CLI is interactive / v1-v2 conflicted.** `az webapp auth microsoft
  update` prompts (NoTTYException in scripts) and `az webapp auth set` refuses when
  the app shows "auth v1". Solution: PUT `authsettingsV2` via the **management REST
  API** (`az rest --method put .../config/authsettingsV2?api-version=2022-03-01`),
  with the client secret stored in app setting `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`.
- **Easy Auth 401 vs 302.** Unauthenticated *API/curl* requests get `401`; only
  *browser* navigations (Accept: text/html, browser UA) get `302` to login. Don't
  mistake the 401 for a misconfig — test with a browser UA.
- **SWA Free can't use managed identity**; that's why we abandoned SWA for a single
  Function App + Easy Auth.
- **routePrefix must be `""`** (host.json) to serve the UI at `/`. With the default
  `api` prefix the page can't live at the root. API routes then include `api/` literally.
- **Portal owns rg-axa naming.** Deploy/destroy use `axa`, `axa-ip`, `axa-nsg`,
  `axa-vnet`, `axa-nic`, `axa-osdisk` (from the Bicep). The original CreateAzaAzure
  box used `az vm create` default names — tear it down once (it's in the image) so
  the portal manages rg-axa cleanly. Don't `az group delete rg-axa` (breaks the role).
- **Storage account name** must be deterministic (was `$RANDOM` — broke idempotency);
  now derived from the subscription id in the provision script.

## Validation status (live)

Golden image `rg-platform/galAxa/axa-img:1.0.0` captured and `Succeeded`. A VM
clone deployed from it (test RG) booted the full stack — nginx/mysql/docker+guacamole/
ELK/splunk all came up with no cloud-init — then was deleted. Function App live at
`https://aspl.azurewebsites.net`: `/api/status` returned live VM data via
managed identity; Easy Auth gates the site (browser → 302 to tenant AAD login).
Not yet exercised: a full deploy→destroy cycle *through the authenticated UI* (needs
a real browser sign-in) and tearing down the original CreateAzaAzure box.
