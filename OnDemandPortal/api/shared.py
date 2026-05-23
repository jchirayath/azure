"""
Shared Azure logic for the on-demand portal API.

Runs inside an Azure Function App whose SYSTEM-ASSIGNED MANAGED IDENTITY has:
  - Contributor on the ephemeral VM resource group (VM_RESOURCE_GROUP)
  - DNS Zone Contributor on the DNS zone's resource group (DNS_ZONE_RG)
No secrets are stored anywhere; DefaultAzureCredential picks up the identity.

Config comes from App Settings (environment variables) — see 3-provision-portal.sh.
"""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path

try:
    from zoneinfo import ZoneInfo
except Exception:  # noqa: BLE001 — tzdata may be missing; scheduler degrades to UTC
    ZoneInfo = None

from azure.identity import DefaultAzureCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.dns import DnsManagementClient
from azure.keyvault.secrets import SecretClient

# ---- config from environment -------------------------------------------------
SUBSCRIPTION_ID = os.environ["SUBSCRIPTION_ID"]
RG = os.environ["VM_RESOURCE_GROUP"]
VM_NAME = os.environ.get("VM_HOSTNAME", "axa")
VM_SIZE = os.environ.get("VM_SIZE", "Standard_D4s_v3")
LOCATION = os.environ.get("VM_REGION", "westus3")
IMAGE_ID = os.environ["IMAGE_ID"]
VM_IDENTITY_ID = os.environ.get("VM_IDENTITY_ID", "")
DNS_ZONE = os.environ.get("DNS_ZONE", "")
DNS_RECORD = os.environ.get("DNS_RECORD", "")
DNS_ZONE_RG = os.environ.get("DNS_ZONE_RG", "")
KV_NAME = os.environ.get("KV_NAME", "")

# Persistent platform (gallery/image + this Function App) — used by the snapshot/
# image manager and the "set current image" action.
GALLERY_RG = os.environ.get("GALLERY_RG", "rg-platform")
GALLERY_NAME = os.environ.get("GALLERY_NAME", "galAxa")
IMAGE_DEF = os.environ.get("IMAGE_DEF", "axa-img")
FUNCTION_APP = os.environ.get("FUNCTION_APP", "aspl")
# Optional fixed hourly USD rate; if unset we fetch it from the public retail API.
VM_HOURLY_USD = float(os.environ.get("VM_HOURLY_USD", "0") or 0)

DEPLOYMENT_NAME = "portal-vm-deploy"
_TEMPLATE = json.loads((Path(__file__).parent / "vm-from-image.json").read_text())

_cred = DefaultAzureCredential()
_ARM = "https://management.azure.com"


def _arm(method, path, body=None, api="2021-04-01", query=None):
    """Call the Azure Resource Manager REST API with the managed-identity token."""
    token = _cred.get_token(f"{_ARM}/.default").token
    url = f"{_ARM}{path}?api-version={api}"
    if query:
        url += "&" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"ARM {method} {path} -> {e.code}: {e.read().decode()[:400]}") from e


def _compute():
    return ComputeManagementClient(_cred, SUBSCRIPTION_ID)


def _network():
    return NetworkManagementClient(_cred, SUBSCRIPTION_ID)


def custom_fqdn():
    return f"{DNS_RECORD}.{DNS_ZONE}" if DNS_ZONE and DNS_RECORD else ""


# ---- actions -----------------------------------------------------------------
def start_deploy():
    """Kick off the ARM deployment (non-blocking) via REST and return immediately."""
    # Ensure the target RG exists.
    _arm("PUT", f"/subscriptions/{SUBSCRIPTION_ID}/resourcegroups/{RG}", {"location": LOCATION})
    # Submit the deployment — ARM accepts it and provisions asynchronously.
    _arm(
        "PUT",
        f"/subscriptions/{SUBSCRIPTION_ID}/resourcegroups/{RG}"
        f"/providers/Microsoft.Resources/deployments/{DEPLOYMENT_NAME}",
        {
            "properties": {
                "mode": "Incremental",
                "template": _TEMPLATE,
                "parameters": {
                    "vmName": {"value": VM_NAME},
                    "vmSize": {"value": VM_SIZE},
                    "imageId": {"value": IMAGE_ID},
                    "vmIdentityId": {"value": VM_IDENTITY_ID},
                },
            }
        },
    )
    return {"state": "deploying", "message": "VM deployment started (~3-5 min)."}


def _vm_id():
    return (f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RG}"
            f"/providers/Microsoft.Compute/virtualMachines/{VM_NAME}")


def _tags_path():
    return f"{_vm_id()}/providers/Microsoft.Resources/tags/default"


def set_hold(days):
    """Keep the VM running (no idle auto-stop) for N days; days<=0 clears the hold.
    Stored as the VM tag keepUntil (epoch seconds), honored by the in-VM idle agent."""
    days = int(days or 0)
    until = int(time.time()) + days * 86400 if days > 0 else 0
    _arm("PATCH", _tags_path(),
         {"operation": "Merge", "properties": {"tags": {"keepUntil": str(until)}}},
         api="2021-04-01")
    return {"holdUntil": (until or None),
            "message": f"Holding for {days} day(s)." if days > 0 else "Hold cleared."}


def _get_hold():
    try:
        _, body = _arm("GET", _tags_path(), api="2021-04-01")
        v = body.get("properties", {}).get("tags", {}).get("keepUntil", "")
        if v.isdigit() and int(v) > int(time.time()):
            return int(v)
    except Exception:  # noqa: BLE001
        pass
    return None


def get_health():
    """Per-service up/down, read from the VM's published health.json. Empty if the
    VM is down/unreachable (frontend then shows everything red)."""
    fqdn = f"{VM_NAME}.{LOCATION}.cloudapp.azure.com"
    try:
        req = urllib.request.Request(f"https://{fqdn}/health.json",
                                     headers={"Cache-Control": "no-cache"})
        with urllib.request.urlopen(req, timeout=8) as r:  # noqa: S310
            return json.loads(r.read() or b"{}")
    except Exception:  # noqa: BLE001
        return {}


def get_secrets():
    """Return service credentials read from Key Vault (the Function's identity has
    Key Vault Secrets User). Only reachable by an authenticated portal user."""
    kc = SecretClient(vault_url=f"https://{KV_NAME}.vault.azure.net/", credential=_cred)

    def g(name):
        try:
            return kc.get_secret(name).value
        except Exception:  # noqa: BLE001
            return None

    guac_user = g("guacamoleUser") or "guacamoledb"
    guac_host = g("guacamoleHost") or ""
    # host/db populated only where a backing database applies (the Adminer rows).
    items = [
        {"service": "Guacamole", "path": "/guacamole/", "user": "guacadmin", "password": g("guacAdminPassword")},
        {"service": "Splunk", "path": "/splunk/", "user": "admin", "password": g("splunkAdminPassword")},
        {"service": "Grafana", "path": "/grafana/", "user": "admin", "password": g("grafanaAdminPassword")},
        {"service": "Webmin", "path": "/webmin/", "user": "root", "password": g("webminPassword")},
        {"service": "Mail relay (SMTP submission)", "path": "/", "user": "relay@axa.westus3.cloudapp.azure.com",
         "password": g("mailRelayPassword"), "host": "axa.westus3.cloudapp.azure.com:587",
         "note": "STARTTLS + AUTH LOGIN. Send as your relay domains (az.aspl.net, poker-mates.com)."},
        {"service": "Netdata (real-time metrics)", "path": "/netdata/", "user": None, "password": None,
         "note": "Azure AD-gated — no native login."},
        {"service": "ntopng (traffic analyzer)", "path": "/ntopng/", "user": "admin", "password": None,
         "note": "AAD-gated. ntopng login defaults to admin/admin and prompts you to set your own on first login."},
        {"service": "Uptime Kuma (uptime/probes)", "url": "https://uptime.az.aspl.net/",
         "host": "uptime.az.aspl.net", "user": "admin", "password": g("uptimeKumaPassword"),
         "note": "HTTPS behind nginx. Use this password to create the admin account on first visit (username admin)."},
        {"service": "Database — MySQL root (local)", "path": "/db/", "user": "root",
         "password": g("mysqlRootPassword"), "host": "172.17.0.1", "db": "(all)",
         "note": "Adminer: pick System MySQL, server 172.17.0.1"},
        {"service": "Database — Guacamole (external)", "path": "/db/", "user": guac_user,
         "password": g("guacamolePassword"), "host": guac_host, "db": "guacamoledb",
         "note": "Adminer: pick System MySQL"},
        {"service": "Kibana", "path": "/kibana/", "user": None, "password": None, "note": "AAD-protected (no password)"},
        {"service": "Prometheus", "path": "/prometheus/", "user": None, "password": None, "note": "AAD-protected (no password)"},
        {"service": "Web SSH / DB editor", "path": "/shell/", "user": None, "password": None, "note": "AAD-protected (Microsoft login)"},
    ]
    return {"secrets": items}


# ---- Azure Virtual Desktop (own RG; session host discovered dynamically) ----
# Session hosts get a UNIQUE name per deploy (prefix AVD_VM_PREFIX) so a redeploy
# never collides with a destroyed host's leftover Azure AD device object. The portal
# discovers the current host instead of relying on a fixed name.
AVD_RG = os.environ.get("AVD_RG", "")
AVD_HOSTPOOL = os.environ.get("AVD_HOSTPOOL", "")
AVD_WORKSPACE = os.environ.get("AVD_WORKSPACE", "")
AVD_VM_PREFIX = os.environ.get("AVD_VM_PREFIX", "avdh")
AVD_WEBCLIENT = os.environ.get("AVD_WEBCLIENT", "https://client.wvd.microsoft.com/arm/webclient/index.html")
AVD_IDLE_MINUTES = int(os.environ.get("AVD_IDLE_MINUTES", "30") or 30)
AVD_VM_SIZE = os.environ.get("AVD_VM_SIZE", "Standard_D4ds_v4")
AVD_ADMIN_USER = os.environ.get("AVD_ADMIN_USER", "avdadmin")
AVD_ADMIN_SECRET = os.environ.get("AVD_ADMIN_SECRET", "avdAdminPassword")


def _avd_host():
    """Name of the current session-host VM in the AVD RG (prefix AVD_VM_PREFIX), or None."""
    if not AVD_RG:
        return None
    try:
        for vm in _compute().virtual_machines.list(AVD_RG):
            if vm.name.startswith(AVD_VM_PREFIX):
                return vm.name
    except Exception:  # noqa: BLE001
        pass
    return None


def get_avd():
    """Power state of the current AVD session host (or 'down' if none deployed)."""
    if not (AVD_RG and AVD_HOSTPOOL):
        return {"configured": False}
    out = {"configured": True, "webclient": AVD_WEBCLIENT, "workspace": AVD_WORKSPACE}
    host = _avd_host()
    out["vm"] = host
    if not host:
        out["state"] = "down"
        return out
    try:
        iv = _compute().virtual_machines.instance_view(AVD_RG, host)
        power = next((s.code.replace("PowerState/", "")
                      for s in (iv.statuses or []) if s.code and s.code.startswith("PowerState/")),
                     "unknown")
        out["state"] = "running" if power == "running" else power
    except Exception:  # noqa: BLE001
        out["state"] = "down"
    return out


def start_avd():
    host = _avd_host()
    if not host:
        return {"error": "no AVD session host deployed"}
    _compute().virtual_machines.begin_start(AVD_RG, host)
    return {"state": "starting", "message": "AVD session host starting (~1-2 min). Then connect via the AVD client."}


def stop_avd():
    host = _avd_host()
    if not host:
        return {"error": "no AVD session host deployed"}
    _compute().virtual_machines.begin_deallocate(AVD_RG, host)
    return {"state": "deallocating", "message": "AVD session host deallocating (compute billing stops)."}


def _avd_tags_path(host):
    return (f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{AVD_RG}"
            f"/providers/Microsoft.Compute/virtualMachines/{host}"
            f"/providers/Microsoft.Resources/tags/default")


def _avd_tag(host, name):
    try:
        _, b = _arm("GET", _avd_tags_path(host), api="2021-04-01")
        return b.get("properties", {}).get("tags", {}).get(name)
    except Exception:  # noqa: BLE001
        return None


def _avd_set_tag(host, name, val):
    _arm("PATCH", _avd_tags_path(host),
         {"operation": "Merge", "properties": {"tags": {name: str(val)}}}, api="2021-04-01")


def _avd_active_sessions():
    """Count Active AVD user sessions on the host pool."""
    _, b = _arm("GET",
                f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{AVD_RG}"
                f"/providers/Microsoft.DesktopVirtualization/hostPools/{AVD_HOSTPOOL}/userSessions",
                api="2022-09-09")
    return sum(1 for s in b.get("value", [])
               if (s.get("properties", {}).get("sessionState") or "") == "Active")


def run_avd_idle():
    """Timer entrypoint: deallocate the session host after AVD_IDLE_MINUTES with no
    Active sessions (tag avdIdleSince). No-op unless a host is running."""
    if not (AVD_RG and AVD_HOSTPOOL):
        return {"acted": False, "reason": "not configured"}
    host = _avd_host()
    if not host or get_avd().get("state") != "running":
        return {"acted": False, "reason": "not running"}
    try:
        active = _avd_active_sessions()
    except Exception as e:  # noqa: BLE001
        return {"acted": False, "error": str(e)[:120]}
    if active > 0:
        if _avd_tag(host, "avdIdleSince"):
            _avd_set_tag(host, "avdIdleSince", "")
        return {"acted": False, "active": active}
    now = int(time.time())
    since = _avd_tag(host, "avdIdleSince")
    if not (since and since.isdigit()):
        _avd_set_tag(host, "avdIdleSince", now)
        return {"acted": False, "active": 0, "idleStarted": True}
    if now - int(since) >= AVD_IDLE_MINUTES * 60:
        stop_avd()
        _avd_set_tag(host, "avdIdleSince", "")
        return {"acted": True, "action": "stop", "idleMinutes": (now - int(since)) // 60}
    return {"acted": False, "active": 0, "idleForMinutes": (now - int(since)) // 60}


def _avd_token():
    """Generate + retrieve a fresh host-pool registration token."""
    hp = (f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{AVD_RG}"
          f"/providers/Microsoft.DesktopVirtualization/hostPools/{AVD_HOSTPOOL}")
    exp = time.strftime("%Y-%m-%dT%H:%M:%S.0000000Z", time.gmtime(time.time() + 23 * 3600))
    _arm("PATCH", hp,
         {"properties": {"registrationInfo": {"expirationTime": exp, "registrationTokenOperation": "Update"}}},
         api="2022-09-09")
    _, b = _arm("POST", f"{hp}/retrieveRegistrationToken", None, api="2022-09-09")
    return b.get("token")


def avd_deploy():
    """Deploy a NEW uniquely-named AVD session host (Win11 multi-session, AAD-joined) that
    self-registers via the bicep CustomScript with a fresh token. Non-blocking; UI polls."""
    if not (AVD_RG and AVD_HOSTPOOL):
        return {"error": "AVD not configured"}
    if _avd_host():
        return {"error": "a session host already exists — destroy it first"}
    host = AVD_VM_PREFIX + os.urandom(3).hex()  # unique => no AAD device-name collision
    kc = SecretClient(vault_url=f"https://{KV_NAME}.vault.azure.net/", credential=_cred)
    pw = kc.get_secret(AVD_ADMIN_SECRET).value
    token = _avd_token()
    template = json.loads((Path(__file__).parent / "avd-sessionhost.json").read_text())
    subnet = (f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{AVD_RG}"
              f"/providers/Microsoft.Network/virtualNetworks/avd-vnet/subnets/hosts")
    _arm("PUT", f"/subscriptions/{SUBSCRIPTION_ID}/resourcegroups/{AVD_RG}", {"location": LOCATION})
    _arm("PUT",
         f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{AVD_RG}"
         f"/providers/Microsoft.Resources/deployments/avd-host-{host}",
         {"properties": {"mode": "Incremental", "template": template, "parameters": {
             "location": {"value": LOCATION}, "shName": {"value": host},
             "vmSize": {"value": AVD_VM_SIZE}, "adminUser": {"value": AVD_ADMIN_USER},
             "adminPassword": {"value": pw}, "subnetId": {"value": subnet},
             "registrationToken": {"value": token}}}})
    return {"state": "deploying", "vm": host,
            "message": f"AVD session host {host} deploying + registering (~8-12 min)."}


def avd_destroy():
    """Unregister + delete the current AVD session host (VM + NIC + OS disk). Control plane kept."""
    host = _avd_host()
    if not host:
        return {"state": "down", "message": "no session host to destroy"}
    cc, nc = _compute(), _network()
    hp = (f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{AVD_RG}"
          f"/providers/Microsoft.DesktopVirtualization/hostPools/{AVD_HOSTPOOL}")
    results = {}
    try:
        _arm("DELETE", f"{hp}/sessionHosts/{host}", api="2022-09-09", query={"force": "true"})
        results["sessionHost"] = "unregistered"
    except Exception:  # noqa: BLE001
        results["sessionHost"] = "skip"
    for fn, name, key in [
        (cc.virtual_machines.begin_delete, host, "vm"),
        (nc.network_interfaces.begin_delete, f"{host}-nic", "nic"),
        (cc.disks.begin_delete, f"{host}-osdisk", "disk"),
    ]:
        try:
            fn(AVD_RG, name).result()
            results[key] = "deleted"
        except Exception as e:  # noqa: BLE001
            results[key] = f"skip ({type(e).__name__})"
    return {"state": "down", "deleted": results}


def start_vm():
    """Resume a deallocated VM (non-blocking)."""
    _compute().virtual_machines.begin_start(RG, VM_NAME)
    return {"state": "starting", "message": "VM starting (~1-2 min)."}


def stop_vm():
    """Deallocate the VM — stops compute billing (non-blocking)."""
    _compute().virtual_machines.begin_deallocate(RG, VM_NAME)
    return {"state": "deallocating", "message": "VM deallocating (compute billing stops)."}


def start_destroy():
    """Delete the VM and its stack resources by name (RG itself is kept)."""
    cc, nc = _compute(), _network()
    results = {}
    try:
        cc.virtual_machines.begin_delete(RG, VM_NAME).result()
        results["vm"] = "deleted"
    except Exception as e:  # noqa: BLE001
        results["vm"] = f"skip ({type(e).__name__})"
    # NIC must go before its public IP / vnet.
    for fn, name, key in [
        (nc.network_interfaces.begin_delete, f"{VM_NAME}-nic", "nic"),
        (nc.public_ip_addresses.begin_delete, f"{VM_NAME}-ip", "ip"),
        (nc.network_security_groups.begin_delete, f"{VM_NAME}-nsg", "nsg"),
        (nc.virtual_networks.begin_delete, f"{VM_NAME}-vnet", "vnet"),
    ]:
        try:
            fn(RG, name).result()
            results[key] = "deleted"
        except Exception as e:  # noqa: BLE001
            results[key] = f"skip ({type(e).__name__})"
    try:
        _compute().disks.begin_delete(RG, f"{VM_NAME}-osdisk").result()
        results["disk"] = "deleted"
    except Exception as e:  # noqa: BLE001
        results["disk"] = f"skip ({type(e).__name__})"
    return {"state": "down", "deleted": results}


def _update_dns(ip):
    if not (DNS_ZONE and DNS_RECORD and DNS_ZONE_RG and ip):
        return None
    dns = DnsManagementClient(_cred, SUBSCRIPTION_ID)
    dns.record_sets.create_or_update(
        DNS_ZONE_RG, DNS_ZONE, DNS_RECORD, "A",
        {"ttl": 300, "arecords": [{"ipv4_address": ip}]},
    )
    return custom_fqdn()


def get_status():
    """Report VM power state + IP/FQDN; refresh the DNS A record when running."""
    cc, nc = _compute(), _network()
    try:
        iv = cc.virtual_machines.instance_view(RG, VM_NAME)
    except Exception:  # noqa: BLE001 — VM absent => down
        return {"state": "down", "vm": VM_NAME}

    power = next((s.code.replace("PowerState/", "")
                  for s in (iv.statuses or []) if s.code and s.code.startswith("PowerState/")),
                 "unknown")
    ip = fqdn = None
    try:
        pip = nc.public_ip_addresses.get(RG, f"{VM_NAME}-ip")
        ip = pip.ip_address
        fqdn = pip.dns_settings.fqdn if pip.dns_settings else None
    except Exception:  # noqa: BLE001
        pass

    cfqdn = _update_dns(ip) if power == "running" and ip else custom_fqdn()
    return {
        "state": "running" if power == "running" else power,
        "vm": VM_NAME,
        "publicIp": ip,
        "fqdn": fqdn,
        "customFqdn": cfqdn,
        "holdUntil": _get_hold(),
    }


# =============================================================================
# 1. Cost & running-hours
# =============================================================================
_rate_cache = {}


def _hourly_rate():
    """Best-effort hourly USD rate for the VM size from the PUBLIC Azure Retail
    Prices API (no auth). Falls back to VM_HOURLY_USD env, else 0 (unknown)."""
    if VM_HOURLY_USD > 0:
        return VM_HOURLY_USD
    key = f"{LOCATION}:{VM_SIZE}"
    if key in _rate_cache:
        return _rate_cache[key]
    rate = 0.0
    try:
        flt = (f"armRegionName eq '{LOCATION}' and armSkuName eq '{VM_SIZE}' "
               f"and priceType eq 'Consumption' and serviceName eq 'Virtual Machines'")
        url = "https://prices.azure.com/api/retail/prices?$filter=" + urllib.parse.quote(flt)
        with urllib.request.urlopen(url, timeout=8) as r:  # noqa: S310
            data = json.loads(r.read() or b"{}")
        for it in data.get("Items", []):
            blob = (it.get("productName", "") + " " + it.get("skuName", "") + " " + it.get("meterName", "")).lower()
            if any(w in blob for w in ("windows", "spot", "low priority")):
                continue
            if str(it.get("unitOfMeasure", "")).lower().startswith("1 hour") and it.get("retailPrice"):
                rate = float(it["retailPrice"])
                break
    except Exception:  # noqa: BLE001
        pass
    _rate_cache[key] = rate
    return rate


def _running_since():
    """Approx. epoch the VM last entered 'running' — newest successful start /
    create event from the Activity Log (30-day window). None if not found."""
    start = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 30 * 86400))
    try:
        _, body = _arm(
            "GET",
            f"/subscriptions/{SUBSCRIPTION_ID}/providers/Microsoft.Insights/eventtypes/management/values",
            api="2015-04-01",
            query={"$filter": f"eventTimestamp ge '{start}' and resourceGroupName eq '{RG}'"},
        )
    except Exception:  # noqa: BLE001
        return None
    best = None
    for ev in body.get("value", []):
        op = ((ev.get("operationName") or {}).get("value") or "").lower()
        st = ((ev.get("status") or {}).get("value") or "")
        if st != "Succeeded":
            continue
        if op in ("microsoft.compute/virtualmachines/start/action",
                  "microsoft.compute/virtualmachines/write"):
            ts = ev.get("eventTimestamp", "")
            if ts and (best is None or ts > best):
                best = ts
    if not best:
        return None
    try:
        return int(datetime.fromisoformat(best.replace("Z", "+00:00")[:32]).timestamp())
    except Exception:  # noqa: BLE001
        return None


def get_cost():
    """Month-to-date spend for the VM RG + current-session uptime/cost estimate."""
    rate = _hourly_rate()
    out = {"resourceGroup": RG, "hourlyRate": round(rate, 4), "currency": "USD"}

    # Month-to-date actual cost for the RG (Cost Management — data lags ~8-24h).
    try:
        _, body = _arm(
            "POST",
            f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RG}"
            f"/providers/Microsoft.CostManagement/query",
            {"type": "ActualCost", "timeframe": "MonthToDate",
             "dataset": {"granularity": "None",
                         "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}}}},
            api="2023-03-01",
        )
        props = body.get("properties", {})
        cols = [c.get("name") for c in props.get("columns", [])]
        rows = props.get("rows", [])
        if rows:
            row = rows[0]
            if "Cost" in cols:
                out["monthToDate"] = round(float(row[cols.index("Cost")]), 2)
            if "Currency" in cols:
                out["currency"] = row[cols.index("Currency")]
    except Exception as e:  # noqa: BLE001
        out["costError"] = str(e)[:200]

    # Current session (only meaningful when running).
    try:
        state = get_status().get("state")
    except Exception:  # noqa: BLE001
        state = None
    out["state"] = state
    if state == "running":
        since = _running_since()
        if since:
            hrs = max(0.0, (time.time() - since) / 3600.0)
            out["sessionSince"] = since
            out["sessionHours"] = round(hrs, 2)
            if rate > 0:
                out["sessionCost"] = round(hrs * rate, 2)

    # Subscription-wide MTD by resource group + budget headroom (display-only limit).
    budget = float(os.environ.get("MONTHLY_BUDGET_USD", "150") or 150)
    out["budget"] = round(budget, 2)
    try:
        _, body = _arm(
            "POST",
            f"/subscriptions/{SUBSCRIPTION_ID}/providers/Microsoft.CostManagement/query",
            {"type": "ActualCost", "timeframe": "MonthToDate",
             "dataset": {"granularity": "None",
                         "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
                         "grouping": [{"type": "Dimension", "name": "ResourceGroupName"}]}},
            api="2023-03-01",
        )
        props = body.get("properties", {})
        cols = [c.get("name") for c in props.get("columns", [])]
        ci = cols.index("Cost") if "Cost" in cols else 0
        gi = cols.index("ResourceGroupName") if "ResourceGroupName" in cols else 1
        groups = [{"name": (r[gi] or "(unassigned)"), "cost": round(float(r[ci]), 2)}
                  for r in props.get("rows", [])]
        groups.sort(key=lambda g: g["cost"], reverse=True)
        total = round(sum(g["cost"] for g in groups), 2)
        out["byResourceGroup"] = groups
        out["subscriptionMtd"] = total
        out["remaining"] = round(budget - total, 2)
        out["percentUsed"] = round(total / budget * 100, 1) if budget > 0 else None
    except Exception as e:  # noqa: BLE001
        out["subError"] = str(e)[:200]
    return out


# =============================================================================
# 2. Scheduled start/stop  (schedule stored as rg-axa RG tags; run by the timer)
# =============================================================================
def _rg_tags_path():
    return f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RG}/providers/Microsoft.Resources/tags/default"


def get_schedule():
    try:
        _, body = _arm("GET", _rg_tags_path(), api="2021-04-01")
        t = body.get("properties", {}).get("tags", {})
    except Exception:  # noqa: BLE001
        t = {}
    return {
        "enabled": t.get("schedEnabled", "false") == "true",
        "start": t.get("schedStart", ""),     # "HH:MM" local
        "stop": t.get("schedStop", ""),        # "HH:MM" local
        "days": t.get("schedDays", "1-5"),    # ISO weekdays, Mon=1..Sun=7
        "tz": t.get("schedTz", "America/Los_Angeles"),
    }


def set_schedule(enabled, start, stop, days, tz):
    tags = {
        "schedEnabled": "true" if enabled else "false",
        "schedStart": (start or "").strip(),
        "schedStop": (stop or "").strip(),
        "schedDays": (days or "1-5").strip(),
        "schedTz": (tz or "America/Los_Angeles").strip(),
    }
    _arm("PUT", f"/subscriptions/{SUBSCRIPTION_ID}/resourcegroups/{RG}", {"location": LOCATION})
    _arm("PATCH", _rg_tags_path(),
         {"operation": "Merge", "properties": {"tags": tags}}, api="2021-04-01")
    return get_schedule()


def _parse_days(s):
    out = set()
    for part in (s or "1-5").split(","):
        part = part.strip()
        if "-" in part:
            try:
                a, b = part.split("-")
                out.update(range(int(a), int(b) + 1))
            except Exception:  # noqa: BLE001
                pass
        elif part.isdigit():
            out.add(int(part))
    return out or {1, 2, 3, 4, 5}


def _hhmm(s):
    h, m = s.split(":")
    return int(h) * 60 + int(m)


def run_schedule():
    """Timer entrypoint. Within the daily window -> resume a deallocated VM;
    outside it -> deallocate a running VM (unless a keep-running hold is active).
    Never deploys/destroys: a scheduled 'start' only resumes an existing VM."""
    sc = get_schedule()
    if not (sc["enabled"] and sc["start"] and sc["stop"]):
        return {"acted": False, "reason": "disabled or incomplete"}
    tz = ZoneInfo(sc["tz"]) if (ZoneInfo and sc["tz"]) else None
    now = datetime.now(tz)
    cur = now.hour * 60 + now.minute
    try:
        in_window = (now.isoweekday() in _parse_days(sc["days"])
                     and _hhmm(sc["start"]) <= cur < _hhmm(sc["stop"]))
    except Exception:  # noqa: BLE001
        return {"acted": False, "reason": "bad schedule values"}

    state = get_status().get("state")
    if in_window and state in ("deallocated", "stopped"):
        start_vm()
        return {"acted": True, "action": "start", "state": state}
    if (not in_window) and state == "running" and not _get_hold():
        stop_vm()
        return {"acted": True, "action": "stop", "state": state}
    return {"acted": False, "state": state, "inWindow": in_window}


# =============================================================================
# 3. Snapshot & image manager
# =============================================================================
def list_snapshots():
    cc = _compute()
    out = []
    try:
        for s in cc.snapshots.list_by_resource_group(RG):
            out.append({
                "name": s.name,
                "sizeGb": s.disk_size_gb,
                "created": s.time_created.isoformat() if s.time_created else None,
                "state": s.provisioning_state,
            })
    except Exception as e:  # noqa: BLE001
        return {"snapshots": [], "error": str(e)[:200]}
    out.sort(key=lambda x: x["created"] or "", reverse=True)
    return {"snapshots": out}


def create_snapshot():
    cc = _compute()
    disk = cc.disks.get(RG, f"{VM_NAME}-osdisk")  # raises if the VM is down
    name = f"{VM_NAME}-snap-{time.strftime('%Y%m%d-%H%M%S')}"
    cc.snapshots.begin_create_or_update(RG, name, {
        "location": LOCATION, "incremental": True,
        "creation_data": {"create_option": "Copy", "source_resource_id": disk.id},
    })
    return {"name": name, "message": "Snapshot started."}


def delete_snapshot(name):
    if not name:
        raise ValueError("snapshot name required")
    _compute().snapshots.begin_delete(RG, name)  # scoped to rg-axa
    return {"deleted": name}


def restore_snapshot(name):
    """Swap the VM's OS disk for a new disk created from snapshot <name>. The VM is
    deallocated first; afterwards it stays stopped (start it to boot the restore).
    Heavier op (deallocate + disk copy + VM update) — can take several minutes."""
    if not name:
        raise ValueError("snapshot name required")
    cc = _compute()
    snap = cc.snapshots.get(RG, name)
    try:
        cc.virtual_machines.begin_deallocate(RG, VM_NAME).result()
    except Exception:  # noqa: BLE001
        pass
    new_disk = f"{VM_NAME}-osdisk-r{time.strftime('%Y%m%d-%H%M%S')}"
    cc.disks.begin_create_or_update(RG, new_disk, {
        "location": LOCATION,
        "creation_data": {"create_option": "Copy", "source_resource_id": snap.id},
    }).result()
    vm = cc.virtual_machines.get(RG, VM_NAME)
    disk_id = (f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RG}"
               f"/providers/Microsoft.Compute/disks/{new_disk}")
    vm.storage_profile.os_disk.managed_disk.id = disk_id
    vm.storage_profile.os_disk.name = new_disk
    vm.storage_profile.os_disk.create_option = "Attach"
    cc.virtual_machines.begin_create_or_update(RG, VM_NAME, vm).result()
    return {"message": f"OS disk restored from {name}. Start the VM to boot it.", "disk": new_disk}


def _ver_key(v):
    try:
        return tuple(int(x) for x in v.split("."))
    except Exception:  # noqa: BLE001
        return (0,)


def list_images():
    cc = _compute()
    out = []
    try:
        for v in cc.gallery_image_versions.list_by_gallery_image(GALLERY_RG, GALLERY_NAME, IMAGE_DEF):
            pub = getattr(v, "publishing_profile", None)
            out.append({
                "version": v.name,
                "state": v.provisioning_state,
                "published": pub.published_date.isoformat() if pub and pub.published_date else None,
            })
    except Exception as e:  # noqa: BLE001
        return {"images": [], "error": str(e)[:200], "current": (IMAGE_ID.split("/")[-1] if IMAGE_ID else "")}
    out.sort(key=lambda x: _ver_key(x["version"]), reverse=True)
    return {"images": out, "current": (IMAGE_ID.split("/")[-1] if IMAGE_ID else "")}


def _next_version():
    vers = [v["version"] for v in list_images().get("images", [])]
    best = max((_ver_key(v) for v in vers), default=(1, 0, 0))
    a, b, c = (list(best) + [0, 0, 0])[:3]
    return f"{a}.{b}.{c + 1}"


def recapture_image():
    """Snapshot the running VM's OS disk and create the NEXT gallery image version
    (specialized). The image-version creation runs async (replication ~5-15 min);
    once it succeeds, use set_image(version) to point the portal at it."""
    cc = _compute()
    disk = cc.disks.get(RG, f"{VM_NAME}-osdisk")
    snap = f"{VM_NAME}-recap-{time.strftime('%Y%m%d-%H%M%S')}"
    cc.snapshots.begin_create_or_update(RG, snap, {
        "location": LOCATION,
        "creation_data": {"create_option": "Copy", "source_resource_id": disk.id},
    }).result()
    snap_id = (f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{RG}"
               f"/providers/Microsoft.Compute/snapshots/{snap}")
    ver = _next_version()
    cc.gallery_image_versions.begin_create_or_update(
        GALLERY_RG, GALLERY_NAME, IMAGE_DEF, ver, {
            "location": LOCATION,
            "publishing_profile": {"target_regions": [{"name": LOCATION}]},
            "storage_profile": {"os_disk_image": {"source": {"id": snap_id}}},
        })
    return {"version": ver,
            "message": f"Recapture started → image {ver} (replication ~5-15 min). "
                       f"Select it here once it shows Succeeded."}


def set_image(version):
    """Repoint the portal (this Function App's IMAGE_ID app setting) at a gallery
    image version. Writing app settings restarts the app."""
    if not version:
        raise ValueError("version required")
    img = (f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{GALLERY_RG}"
           f"/providers/Microsoft.Compute/galleries/{GALLERY_NAME}/images/{IMAGE_DEF}/versions/{version}")
    site = (f"/subscriptions/{SUBSCRIPTION_ID}/resourceGroups/{GALLERY_RG}"
            f"/providers/Microsoft.Web/sites/{FUNCTION_APP}")
    _, cur = _arm("POST", f"{site}/config/appsettings/list", api="2022-03-01")
    props = cur.get("properties", {})
    props["IMAGE_ID"] = img
    _arm("PUT", f"{site}/config/appsettings", {"properties": props}, api="2022-03-01")
    return {"image": version, "message": f"Portal now deploys image {version} (app restarting)."}


# =============================================================================
# 4. Activity log
# =============================================================================
_OP_LABELS = {
    "microsoft.compute/virtualmachines/start/action": "Start VM",
    "microsoft.compute/virtualmachines/deallocate/action": "Stop (deallocate)",
    "microsoft.compute/virtualmachines/poweroff/action": "Power off",
    "microsoft.compute/virtualmachines/restart/action": "Restart VM",
    "microsoft.compute/virtualmachines/delete": "Delete VM",
    "microsoft.compute/virtualmachines/write": "Create/Update VM",
    "microsoft.resources/deployments/write": "Deployment",
    "microsoft.compute/disks/delete": "Delete disk",
    "microsoft.compute/disks/write": "Create disk",
    "microsoft.network/networkinterfaces/delete": "Delete NIC",
    "microsoft.network/publicipaddresses/delete": "Delete public IP",
    "microsoft.network/networksecuritygroups/delete": "Delete NSG",
    "microsoft.network/virtualnetworks/delete": "Delete vnet",
}


def get_activity(days=7, top=40):
    start = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(days) * 86400))
    try:
        _, body = _arm(
            "GET",
            f"/subscriptions/{SUBSCRIPTION_ID}/providers/Microsoft.Insights/eventtypes/management/values",
            api="2015-04-01",
            query={"$filter": f"eventTimestamp ge '{start}' and resourceGroupName eq '{RG}'"},
        )
    except Exception as e:  # noqa: BLE001
        return {"events": [], "error": str(e)[:200]}
    out = []
    for ev in body.get("value", []):
        op = ((ev.get("operationName") or {}).get("value") or "").lower()
        st = ((ev.get("status") or {}).get("value") or "")
        if op not in _OP_LABELS or st not in ("Succeeded", "Failed"):
            continue
        out.append({
            "time": ev.get("eventTimestamp"),
            "action": _OP_LABELS[op],
            "status": st,
            "caller": ev.get("caller") or "—",
        })
        if len(out) >= int(top):
            break
    return {"events": out}


# =============================================================================
# 5. DNS records view/edit
# =============================================================================
_DNS_EDIT_TYPES = {"A", "CNAME", "TXT", "MX"}


def _dns_client():
    return DnsManagementClient(_cred, SUBSCRIPTION_ID)


def _dns_values(rs, rtype):
    if rtype == "A":
        return [r.ipv4_address for r in (rs.a_records or [])]
    if rtype == "CNAME":
        return [rs.cname_record.cname] if rs.cname_record else []
    if rtype == "TXT":
        return ["".join(r.value) for r in (rs.txt_records or [])]
    if rtype == "MX":
        return [f"{r.preference} {r.exchange}" for r in (rs.mx_records or [])]
    if rtype == "NS":
        return [r.nsdname for r in (rs.ns_records or [])]
    if rtype == "SOA":
        return ["(soa)"]
    return []


def list_dns():
    if not (DNS_ZONE and DNS_ZONE_RG):
        return {"zone": "", "records": []}
    out = []
    for rs in _dns_client().record_sets.list_by_dns_zone(DNS_ZONE_RG, DNS_ZONE):
        rtype = (rs.type or "").split("/")[-1]
        out.append({"name": rs.name, "type": rtype, "ttl": rs.ttl,
                    "values": _dns_values(rs, rtype),
                    "editable": rtype in _DNS_EDIT_TYPES})
    order = {"A": 0, "CNAME": 1, "TXT": 2, "MX": 3, "NS": 8, "SOA": 9}
    out.sort(key=lambda r: (order.get(r["type"], 5), r["name"]))
    return {"zone": DNS_ZONE, "records": out}


def upsert_dns(name, rtype, ttl, values):
    rtype = (rtype or "").upper()
    if rtype not in _DNS_EDIT_TYPES:
        raise ValueError("type must be one of " + ", ".join(sorted(_DNS_EDIT_TYPES)))
    name = (name or "").strip() or "@"
    if name == "@" and rtype == "CNAME":
        raise ValueError("a CNAME at the zone apex (@) is not allowed")
    vals = values if isinstance(values, list) else str(values or "").split(",")
    vals = [v.strip() for v in vals if v.strip()]
    if not vals:
        raise ValueError("at least one value is required")
    params = {"ttl": int(ttl or 300)}
    if rtype == "A":
        params["a_records"] = [{"ipv4_address": v} for v in vals]
    elif rtype == "CNAME":
        params["cname_record"] = {"cname": vals[0]}
    elif rtype == "TXT":
        params["txt_records"] = [{"value": [v]} for v in vals]
    elif rtype == "MX":
        recs = []
        for v in vals:
            pref, _, exch = v.partition(" ")
            recs.append({"preference": int(pref), "exchange": exch.strip()})
        params["mx_records"] = recs
    _dns_client().record_sets.create_or_update(DNS_ZONE_RG, DNS_ZONE, name, rtype, params)
    return {"name": name, "type": rtype, "ttl": int(ttl or 300), "values": vals}


def delete_dns(name, rtype):
    rtype = (rtype or "").upper()
    if rtype not in _DNS_EDIT_TYPES:
        raise ValueError("only A, CNAME, TXT, MX records can be deleted here")
    name = (name or "").strip() or "@"
    _dns_client().record_sets.delete(DNS_ZONE_RG, DNS_ZONE, name, rtype)
    return {"deleted": f"{name} {rtype}"}


# =============================================================================
# 6. On-demand ports — open/close service ports at the NSG (default: closed)
# =============================================================================
# The VM's NSG exposes only 22/80/443/8118 by default. These service ports are
# CLOSED until the portal opens them on demand (added as NSG allow rules). The
# 'auth' flag is False for services with NO native authentication — opening those
# exposes them raw to the internet (UI warns).
NSG_NAME = os.environ.get("NSG_NAME", f"{VM_NAME}-nsg")
ONDEMAND_PORTS = {
    "guacamole":  {"label": "Guacamole",  "ports": ["8080"],  "priority": 1200, "auth": True},
    "webmin":     {"label": "Webmin",     "ports": ["10000"], "priority": 1210, "auth": True},
    "grafana":    {"label": "Grafana",    "ports": ["3000"],  "priority": 1220, "auth": True},
    "splunk":     {"label": "Splunk",     "ports": ["8000"],  "priority": 1230, "auth": True},
    "kibana":     {"label": "Kibana",     "ports": ["5601"],  "priority": 1240, "auth": False},
    "prometheus": {"label": "Prometheus", "ports": ["9090"],  "priority": 1250, "auth": False},
    # 587 (submission) is permanently open as the relay entry point; this group
    # is for inbound SMTP / IMAP, opened only if the box also receives mail.
    "mail":       {"label": "Mail (inbound SMTP/IMAP)", "ports": ["25", "465", "143", "993"],
                   "priority": 1260, "auth": True},
}


def get_ports():
    nc = _network()
    existing = set()
    try:
        for r in nc.security_rules.list(RG, NSG_NAME):
            existing.add(r.name)
    except Exception:  # noqa: BLE001 — NSG absent (VM down) => all closed
        pass
    items = [{
        "key": k, "label": s["label"], "ports": s["ports"], "auth": s["auth"],
        "open": f"ondemand-{k}" in existing,
    } for k, s in ONDEMAND_PORTS.items()]
    return {"nsg": NSG_NAME, "alwaysOpen": ["22", "80", "443", "8118"], "ports": items}


def set_port(key, want_open):
    spec = ONDEMAND_PORTS.get(key)
    if not spec:
        raise ValueError(f"unknown port group {key}")
    nc = _network()
    name = f"ondemand-{key}"
    if want_open:
        params = {
            "protocol": "Tcp", "access": "Allow", "direction": "Inbound",
            "priority": spec["priority"], "source_address_prefix": "*",
            "source_port_range": "*", "destination_address_prefix": "*",
            "description": "on-demand (portal-managed)",
        }
        if len(spec["ports"]) == 1:
            params["destination_port_range"] = spec["ports"][0]
        else:
            params["destination_port_ranges"] = spec["ports"]
        nc.security_rules.begin_create_or_update(RG, NSG_NAME, name, params).result()
        return {"key": key, "open": True, "ports": spec["ports"]}
    try:
        nc.security_rules.begin_delete(RG, NSG_NAME, name).result()
    except Exception:  # noqa: BLE001 — already closed
        pass
    return {"key": key, "open": False, "ports": spec["ports"]}
