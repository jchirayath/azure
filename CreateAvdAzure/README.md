# CreateAvdAzure — on-demand Azure Virtual Desktop

A self-contained AVD stack in its own resource group (`rg-avd`), managed like the AXA
VM: **deploy / start / stop / destroy** + **idle auto-stop**, from scripts and the
`aspl` web portal. Pooled multi-session, **Azure AD-joined**, **reverse-connect** (no
inbound ports). No password is stored in git — the session host's local-admin password
lives in Key Vault.

## Quick start
```bash
az login
./deploy.sh            # build rg-avd: host pool + app group + workspace + session host (registers the agent)
./destroy.sh           # remove the session host (keeps the control plane); --all deletes the RG
```

## Connect
Open **https://client.wvd.microsoft.com/arm/webclient/index.html**, sign in with the
assigned Azure AD account (`ASSIGN_PRINCIPAL` in `config.sh`), and launch **SessionDesktop**.
The session host must be **running** (start it from the portal or `az vm start`) and
report **Available** first.

## Lifecycle from the portal
The `aspl` portal (OnDemandPortal) has an **Azure Virtual Desktop** box:
Deploy / Start / Stop / Destroy + live status + Connect link. It auto-stops the host
after 30 min with no active sessions. See `../OnDemandPortal` and `../CreateAzaAzure/CONFIGURATION.md`.

## Config
Edit `config.sh` (names, region, `POOL_TYPE`, `VM_SIZE`, `VM_IMAGE`, `MAX_SESSIONS`,
`ASSIGN_PRINCIPAL`). Everything supports env override, e.g. `VM_SIZE=Standard_D2as_v5 ./deploy.sh`.

See `CLAUDE.md` for architecture + gotchas.
