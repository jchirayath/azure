# azure

Personal collection of **Azure infrastructure-as-code** — ARM templates and
Bash/Azure-CLI scripts to provision, operate, and tear down Azure resources on
demand. The centerpiece is an on-demand Linux **"AXA" lab VM** plus an
AAD-gated web portal that builds and destroys it from a golden image in minutes,
and an on-demand **Azure Virtual Desktop** stack.

> Personal tooling. Most workflows use the Azure CLI (`az`) and expect you to
> `az login` first. Secrets live in `.env` files and Azure Key Vault — never in
> git.

## Active sub-projects (each has its own README)

| Directory | What it does |
|-----------|--------------|
| [`CreateAzaAzure/`](CreateAzaAzure) | One-touch, modular Ubuntu VM builder — security toolchain, reverse proxy + Guacamole, observability, Splunk, and a pentest toolkit, served over HTTPS. Everything comes up in a **single cloud-init boot**; secrets via Key Vault + managed identity; one-command deploy / destroy / backup / restore. The current "AXA box". |
| [`OnDemandPortal/`](OnDemandPortal) | Public, **AAD-gated web portal** (Python Azure Function App on Consumption, managed identity) that clones the AXA VM from a pre-baked golden image on demand and deletes it when done — near-$0 when idle. |
| [`CreateAvdAzure/`](CreateAvdAzure) | On-demand **Azure Virtual Desktop** stack in its own resource group (`rg-avd`) — deploy / start / stop / destroy + idle auto-stop, Azure-AD-joined, reverse-connect (no inbound ports), portal-managed. |

## Standalone templates & scripts

| Path | What it does |
|------|--------------|
| `CreateAxa/`, `AxaCreate/`, `LinuxAXA/` | Earlier AXA VM build scripts + ARM template/parameters (predecessors to `CreateAzaAzure`). |
| `VMCreate/` | Assorted VM provisioning scripts (Windows Server 2016, multi-VM, test resource groups). |
| `NetCreate/` | Virtual network ARM template + parameters. |
| `LBCreate/` | Load balancer ARM template + parameters. |
| `createVM.sh` | Top-level VM creation helper. |

## Usage

Most sub-projects follow the same pattern:

```bash
az login
cd CreateAzaAzure        # or CreateAvdAzure, OnDemandPortal
./deploy.sh              # stand it up
./destroy.sh             # tear it down
```

For the raw ARM templates (`NetCreate/`, `LBCreate/`, `LinuxAXA/`) use
`az deployment group create --template-file <…>.json --parameters @<…>.parameters.json`.
See each sub-project's README for specifics.
