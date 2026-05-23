#!/usr/bin/env bash
# Idle auto-stop: a systemd timer checks every 5 min for active interactive
# sessions (SSH, web-SSH/ttyd, RDP/guacd). After IDLE_MINUTES with none, the VM
# deallocates ITSELF (compute billing stops) using its attached managed identity.
# Tune the threshold by editing /etc/aza/idle-minutes (default 30); set to 0 to disable.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

sudo mkdir -p /etc/aza
[[ -f /etc/aza/idle-minutes ]] || echo "30" | sudo tee /etc/aza/idle-minutes >/dev/null

log "Installing idle auto-stop agent..."
sudo tee /usr/local/bin/aza-idle-check.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
# Deallocate this VM if it has been idle (no interactive sessions) long enough.
set -uo pipefail
INTERVAL=5                                   # must match the systemd timer cadence
THRESHOLD="$(cat /etc/aza/idle-minutes 2>/dev/null || echo 30)"
STATE=/var/lib/aza-idle-mins
META='http://169.254.169.254/metadata/instance/compute'
[[ "$THRESHOLD" -le 0 ]] 2>/dev/null && { echo 0 >"$STATE"; exit 0; }   # 0 disables

# "Keep running until" hold — set by the portal as the VM tag keepUntil (epoch
# seconds). While now < keepUntil, never auto-stop (multi-day project window).
KEEP="$(curl -s -H Metadata:true "$META/tagsList?api-version=2021-02-01" 2>/dev/null \
  | python3 -c "import sys,json;print(next((t['value'] for t in json.load(sys.stdin) if t['name']=='keepUntil'),''))" 2>/dev/null || true)"
if [[ "$KEEP" =~ ^[0-9]+$ ]] && [[ "$(date +%s)" -lt "$KEEP" ]]; then echo 0 >"$STATE"; exit 0; fi

active() {
  who | grep -q . && return 0                                          # SSH logins
  # established connections on interactive ports: 22 ssh, 7681 ttyd, 3389 rdp, 4822 guacd
  ss -tnH state established 2>/dev/null \
    | grep -Eq '(:22|:7681|:3389|:4822)\b' && return 0
  return 1
}

if active; then echo 0 >"$STATE"; exit 0; fi

mins=$(( $(cat "$STATE" 2>/dev/null || echo 0) + INTERVAL ))
echo "$mins" >"$STATE"
[[ "$mins" -lt "$THRESHOLD" ]] && exit 0

# Idle long enough — deallocate self.
META='http://169.254.169.254/metadata/instance/compute'
RG="$(curl -s -H Metadata:true "$META/resourceGroupName?api-version=2021-02-01&format=text")"
NAME="$(curl -s -H Metadata:true "$META/name?api-version=2021-02-01&format=text")"
[[ -z "$RG" || -z "$NAME" ]] && exit 0
logger -t aza-idle "idle ${mins}m >= ${THRESHOLD}m — deallocating $RG/$NAME"
az login --identity >/dev/null 2>&1 || { logger -t aza-idle "az identity login failed"; exit 0; }
az vm deallocate -g "$RG" -n "$NAME" --no-wait
EOF
sudo chmod +x /usr/local/bin/aza-idle-check.sh

sudo tee /etc/systemd/system/aza-idle.service >/dev/null <<'EOF'
[Unit]
Description=aza idle auto-stop check
[Service]
Type=oneshot
ExecStart=/usr/local/bin/aza-idle-check.sh
EOF

sudo tee /etc/systemd/system/aza-idle.timer >/dev/null <<'EOF'
[Unit]
Description=Run aza idle check every 5 minutes
[Timer]
OnBootSec=10min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now aza-idle.timer
ok "Idle auto-stop enabled (threshold $(cat /etc/aza/idle-minutes) min; edit /etc/aza/idle-minutes, 0=off)."
