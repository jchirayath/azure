# CLAUDE.md — CreateAvdAzure

On-demand **Azure Virtual Desktop** in its own RG, with deploy/start/stop/destroy +
idle auto-stop driven by the `aspl` portal — mirroring the AXA VM model. Built after
the original `rg-avd-quickstart-…` AVD broke (its session host sat deallocated ~7
months and the machine token expired → `EXPIRED_MACHINE_TOKEN`, host `Unavailable`).

## Architecture
- **`rg-avd`** (kept). Persistent control plane: host pool `hp-avd` (Pooled,
  BreadthFirst), app group `ag-avd-desktop` (Desktop), workspace `ws-avd`, vnet/subnet
  (no public IP — AVD uses **reverse connect**, zero inbound). The **session host VM**
  (`avdhost0`, Win11 multi-session, TrustedLaunch, **Azure AD-joined**) is the
  deploy/destroy target.
- **Agent registration** uses a fresh host-pool **registration token**, applied two ways
  (both proven):
  - `deploy.sh` → installs the AVD Agent + BootLoader via **run-command** after the VM is up.
  - Portal **Deploy** → the `infra/sessionhost.bicep` **CustomScript** extension installs
    them during provisioning (param `registrationToken`), so it's one non-blocking ARM deploy.
- **Connect**: AVD web client `https://client.wvd.microsoft.com/arm/webclient/index.html`,
  sign in with the assigned AAD user. No inbound RDP port.

## Files
| File | Role |
|---|---|
| `config.sh` | names, region, pool type, image, sizes, assigned principal, agent URLs |
| `deploy.sh` | foundation (RG/network/host pool/app group/workspace/roles) + session host + register + wait Available |
| `destroy.sh` | unregister + delete session host VM/NIC/disk (`--all` deletes the RG) |
| `infra/sessionhost.bicep` | VM + AAD-join + (optional) CustomScript agent install |

## Connect prerequisites (all set by deploy.sh)
1. **Desktop Virtualization User** on the app group (to see/launch the desktop).
2. **Virtual Machine User Login** on the VM **and** at the `rg-avd` scope (so AAD sign-in
   works on redeployed hosts; the portal MI can't assign roles, so this is granted to the
   user at RG scope once).
3. Host pool custom RDP property **`enablerdsaadauth:i:1`** (AAD auth for AAD-joined hosts).

## Portal integration (OnDemandPortal)
- `/api/avd?action=deploy|destroy|start|stop` + GET status. `shared.avd_deploy()` generates
  a token, reads the local-admin password from Key Vault (`avdAdminPassword`), and ARM-deploys
  `api/avd-sessionhost.json` (compiled from the bicep). `avd_destroy()` unregisters + deletes.
- **Idle auto-stop**: the `scheduler` timer calls `run_avd_idle()` — deallocates after
  `AVD_IDLE_MINUTES` (30) with no **Active** sessions (tag `avdIdleSince`).
- MI roles on `rg-avd`: Virtual Machine Contributor + Desktop Virtualization Reader.
- App settings: `AVD_RG/AVD_VM/AVD_HOSTPOOL/AVD_WORKSPACE/AVD_VM_SIZE/AVD_ADMIN_USER/AVD_ADMIN_SECRET/AVD_IDLE_MINUTES`.

## GOTCHAS
- **Stale AAD device object on redeploy (error `0x801c0083`, "hostnames already exists")**:
  destroying an AAD-joined host does NOT remove its Azure AD device object, so redeploying
  with the **same computer name** fails AAD join → host stays `Unavailable` → can't connect.
  Deleting device objects needs a directory role the automation lacks. **Fix: unique host
  name per deploy** (`SH_NAME=avdh$(openssl rand -hex 3)`; the portal generates `avdh<rand>`
  and discovers the current host by prefix). Old device objects linger harmlessly; an admin
  can prune them in Entra ID → Devices.
- **EXPIRED_MACHINE_TOKEN**: a session host off longer than its token lifetime won't start
  the agent (`RDAgentBootLoader` starts then stops). Fix = re-register with a fresh token.
  The idle auto-stop keeps it cycling so it won't sit off for months.
- **`az network vnet subnet show` uses `--vnet-name`, not `-v`** (empty subnet id → bicep
  `LinkedInvalidPropertyId`).
- **Win11 needs TrustedLaunch** (secureBoot + vTPM) — set in the bicep `securityProfile`.
- **AVD agent download links** (`config.sh`): the cms `RWrmXv` (Agent) / `RWrxrH`
  (BootLoader) are the stable "latest" URLs — avoids the versioned DSC artifact zip.
- **Bicep CustomScript quoting**: single quotes are `\'`, backslashes `\\` (bicep escapes).
- **AVD metadata region** must support AVD (host pool/app group/workspace) — `westus3` works.
- **Portal MI can't assign RBAC** (only Contributor) → user login role is granted at RG scope
  by `deploy.sh`/an admin, not by the portal at deploy time.
