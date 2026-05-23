// Portal frontend. Easy Auth gates the whole app at the platform layer, so by
// the time this page loads the user is already authenticated. This script never
// triggers a login redirect itself (that caused a post-login loop) — it just
// shows VM state and calls the managed-identity API using the auth cookie.

const $ = (id) => document.getElementById(id);
const log = (m) => { $("log").textContent = `${new Date().toLocaleTimeString()}  ${m}\n` + $("log").textContent; };

let polling = null;

async function showWho() {
  try {
    const r = await fetch("/.auth/me", { headers: { accept: "application/json" } });
    if (r.ok) {
      const { clientPrincipal } = await r.json();
      if (clientPrincipal) {
        $("who").innerHTML = `${clientPrincipal.userDetails} · <a href="/.auth/logout">sign out</a>`;
        return;
      }
    }
  } catch { /* ignore */ }
  $("who").innerHTML = `<a href="/.auth/logout">sign out</a>`;
}

// Web services exposed by the VM behind nginx (matches the reverse-proxy paths).
const SERVICES = [
  ["Website",    "/",            "tools landing page"],
  ["Web SSH",    "/shell/",      "browser terminal"],
  ["Database",   "/db/",         "Adminer DB editor"],
  ["Guacamole",  "/guacamole/",  "browser SSH / RDP"],
  ["Webmin",     "/webmin/",     "system admin UI"],
  ["Kibana",     "/kibana/",     "log search"],
  ["Grafana",    "/grafana/",    "dashboards"],
  ["Prometheus", "/prometheus/", "metrics"],
  ["Splunk",     "/splunk/",     "SIEM (:8000)"],
  ["Netdata",    "/netdata/",    "real-time metrics"],
  ["ntopng",     "/ntopng/",     "live traffic analyzer"],
];

const SSH_KEY = "~/.ssh/aza_ed25519";
const SSH_USER = "azureuser";

function render(s) {
  const state = (s.state || "unknown").toLowerCase();
  $("dot").className = "dot " + state;
  $("state").textContent = s.state || "unknown";

  const rows = [];
  if (s.publicIp) rows.push(["Public IP", s.publicIp]);
  if (s.fqdn) rows.push(["Cloud FQDN", `<a href="https://${s.fqdn}/" target="_blank">${s.fqdn}</a>`]);
  if (s.customFqdn) rows.push(["Custom FQDN", `<a href="https://${s.customFqdn}/" target="_blank">${s.customFqdn}</a>`]);
  $("details").innerHTML = rows.map(([k, v]) => `<tr><td>${k}</td><td>${v}</td></tr>`).join("");

  // State-aware buttons.
  const isRunning = state === "running";
  const isDown = state === "down";
  const isStopped = state === "deallocated" || state === "stopped";
  const busy = state === "deploying" || state === "deallocating" || state === "starting";
  $("btnDeploy").disabled  = busy || !isDown;                 // create only when nothing exists
  $("btnStart").disabled   = busy || !isStopped;              // resume a deallocated VM
  $("btnStop").disabled    = busy || !isRunning;              // deallocate a running VM
  $("btnDestroy").disabled = busy || isDown;                  // delete unless already gone

  // Keep-running hold (pause idle auto-stop). Visible whenever a VM exists.
  $("holdCard").style.display = isDown ? "none" : "";
  if (s.holdUntil) {
    const d = new Date(s.holdUntil * 1000);
    $("holdStatus").innerHTML = `🟢 Held until <b>${d.toLocaleString()}</b> — idle auto-stop paused.`;
  } else {
    $("holdStatus").textContent = "Idle auto-stop active — stops after ~30 min idle.";
  }

  // Connect + Services are only meaningful when the box is up and reachable.
  const host = s.fqdn || s.publicIp;
  const up = state === "running" && host;
  $("connect").style.display = up ? "" : "none";
  $("servicesCard").style.display = up ? "" : "none";
  if (up) {
    const base = `https://${host}`;
    $("webSsh").href = `${base}/shell/`;
    $("webConsole").href = `${base}/guacamole/`;
    $("website").href = `${base}/`;
    $("sshCmd").textContent = `ssh -i ${SSH_KEY} ${SSH_USER}@${host}`;
    $("services").innerHTML = SERVICES.map(([name, path, desc]) =>
      `<a class="svc" href="${base}${path}" target="_blank" rel="noopener"><b><span class="hdot unk" data-path="${path}"></span>${name}</b><span>${desc}</span></a>`
    ).join("");
    loadHealth();
  }
}

async function loadHealth() {
  try {
    const h = await (await fetch("/api/health", { headers: { accept: "application/json" } })).json();
    document.querySelectorAll("#services .hdot").forEach(d => {
      const up = h[d.dataset.path];
      d.className = "hdot " + (up === true ? "up" : up === false ? "down" : "unk");
    });
  } catch { /* ignore */ }
}

async function refresh() {
  let r;
  try { r = await fetch("/api/status", { headers: { accept: "application/json" } }); }
  catch (e) { log("network error: " + e); return; }
  const text = await r.text();
  let s;
  try { s = JSON.parse(text); }
  catch {
    $("state").textContent = r.status === 401 ? "session expired — reload" : "error " + r.status;
    log("status not JSON (" + r.status + ")");
    return;
  }
  if (s.error) { log("status: " + s.error); return; }
  render(s);
  return s;
}

function startPolling() {
  if (polling) return;
  polling = setInterval(async () => {
    const s = await refresh();
    const settled = s && ["running", "down", "deallocated", "stopped"].includes(s.state);
    if (settled) { clearInterval(polling); polling = null; }
  }, 15000);
}

async function action(path, label) {
  if (!confirm(`${label} the VM?`)) return;
  log(label + "…");
  for (const b of ["btnDeploy", "btnStart", "btnStop", "btnDestroy"]) $(b).disabled = true;
  try {
    const r = await fetch(path, { method: "POST", headers: { accept: "application/json" } });
    log(label + ": " + (await r.text()).slice(0, 300));
    await refresh();
    startPolling();
  } catch (e) { log(label + " error: " + e); }
}

$("btnDeploy").onclick = () => action("/api/deploy", "Deploy");
$("btnStart").onclick = () => action("/api/start", "Start");
$("btnStop").onclick = () => action("/api/stop", "Stop");
$("btnDestroy").onclick = () => action("/api/destroy", "Destroy");
$("btnRefresh").onclick = refresh;

async function hold(days, label) {
  log(label + "…");
  try {
    const r = await fetch(`/api/hold?days=${days}`, { method: "POST", headers: { accept: "application/json" } });
    log(label + ": " + (await r.text()).slice(0, 200));
    await refresh();
  } catch (e) { log(label + " error: " + e); }
}
$("btnHold").onclick = () => hold(parseInt($("holdDays").value, 10) || 1, "Hold");
$("btnClearHold").onclick = () => hold(0, "Clear hold");
$("btnCopy").onclick = async () => {
  try { await navigator.clipboard.writeText($("sshCmd").textContent); $("btnCopy").textContent = "Copied"; }
  catch { /* clipboard blocked */ }
  setTimeout(() => ($("btnCopy").textContent = "Copy"), 1500);
};

showWho();
refresh().then(startPolling);
