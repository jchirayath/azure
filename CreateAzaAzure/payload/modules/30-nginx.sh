#!/usr/bin/env bash
# Nginx reverse proxy in front of every web service, with a Let's Encrypt cert.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

FQDN="$(vm_fqdn)"
[[ -z "$FQDN" || "$FQDN" == *localhost* ]] && die "Invalid FQDN: $FQDN"
log "Configuring Nginx for $FQDN"

# Apache often ships with the image and would fight for :80.
sudo systemctl disable --now apache2 2>/dev/null || true

apt_install nginx certbot python3-certbot-nginx

# Reverse-proxy map: every backend service under a clean path.
# Quoted heredoc -> nginx variables ($host etc.) are written literally.
sudo tee /etc/nginx/sites-available/aza >/dev/null <<'EOF'
server {
    listen 80 default_server;
    server_name _;

    root /var/www/html;
    index index.html;
    location / { try_files $uri $uri/ =404; }

    location /guacamole/ {
        proxy_pass http://127.0.0.1:8080/guacamole/;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $http_connection;
        access_log off;
    }
    location /webmin/    { proxy_pass https://127.0.0.1:10000/; proxy_ssl_verify off; proxy_set_header Host $host; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; }
    # Azure AD sign-on (oauth2-proxy) protects the shell + db editor — one
    # Microsoft login, no basic-auth. (vmtools-auth module runs oauth2-proxy.)
    location /oauth2/ {
        proxy_pass http://127.0.0.1:4180;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Auth-Request-Redirect $request_uri;
        # AAD auth code + oauth2-proxy session cookie are large — bigger buffers
        # avoid nginx "upstream sent too big header" (502) on /oauth2/callback.
        proxy_buffer_size 16k;
        proxy_buffers 8 16k;
        proxy_busy_buffers_size 32k;
    }
    location = /oauth2/auth {
        proxy_pass http://127.0.0.1:4180;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Content-Length "";
        proxy_pass_request_body off;
    }
    location @oauth2_signin { return 302 https://$host/oauth2/start?rd=$scheme://$host$request_uri; }
    location /shell/ {
        auth_request /oauth2/auth;
        error_page 401 = @oauth2_signin;
        proxy_pass http://127.0.0.1:7681/shell/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400;
    }
    location /db/ {
        auth_request /oauth2/auth;
        error_page 401 = @oauth2_signin;
        proxy_pass http://127.0.0.1:8085/;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
    location /privoxy/   { proxy_pass http://127.0.0.1:8118/;  proxy_set_header Host $host; }
    # NOTE: no trailing slash on proxy_pass below — the path prefix is preserved so
    # each app's sub-path config (basePath / root_url / external-url / root_endpoint)
    # generates correct links; stripping the prefix breaks their redirects.
    # Kibana + Prometheus have no native auth -> gate them with Azure AD (oauth2-proxy).
    location /kibana/    { auth_request /oauth2/auth; error_page 401 = @oauth2_signin; proxy_pass http://127.0.0.1:5601;  proxy_set_header Host $host; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; }
    location /grafana/   { proxy_pass http://127.0.0.1:3000;  proxy_set_header Host $host; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    location /prometheus/{ auth_request /oauth2/auth; error_page 401 = @oauth2_signin; proxy_pass http://127.0.0.1:9090;  proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto $scheme; }
    location /splunk/    { proxy_pass http://127.0.0.1:8000;  proxy_set_header Host $host; proxy_set_header X-Forwarded-Host $host; proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme; }
    # Real-time network tools (module 72). Netdata + ntopng have no/own auth -> AAD-gate.
    location /netdata/   { auth_request /oauth2/auth; error_page 401 = @oauth2_signin; proxy_pass http://127.0.0.1:19999/; proxy_set_header Host $host; proxy_http_version 1.1; proxy_set_header Connection ""; }
    location /ntopng/    { auth_request /oauth2/auth; error_page 401 = @oauth2_signin; proxy_pass http://127.0.0.1:3001;  proxy_set_header Host $host; proxy_set_header X-Forwarded-Proto $scheme; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; }
}
EOF

sudo ln -sf /etc/nginx/sites-available/aza /etc/nginx/sites-enabled/aza
sudo rm -f /etc/nginx/sites-enabled/default

# Landing page — the bundled tools dashboard (links to the proxied services).
log "Installing landing page (index.html)..."
sudo mkdir -p /var/www/html
[[ -f /var/www/html/index.html && ! -f /var/www/html/index.html.bak ]] && sudo mv /var/www/html/index.html /var/www/html/index.html.bak
sudo cp "$AZA_HOME/files/index.html" /var/www/html/index.html
sudo ln -sf /usr/share/apache2/icons /var/www/html/icons 2>/dev/null || true

sudo nginx -t && sudo systemctl enable --now nginx && sudo systemctl reload nginx

# TLS — non-fatal: DNS/rate-limit issues should not abort provisioning.
# Request a cert for the cloudapp FQDN and (if delegated/resolving) the custom FQDN.
if [[ -n "${CERTBOT_EMAIL:-}" ]]; then
  CERT_DOMAINS=( -d "$FQDN" )
  if [[ -n "${CUSTOM_FQDN:-}" ]]; then
    # Only add the custom name if it already resolves, else certbot fails the whole run.
    if getent hosts "$CUSTOM_FQDN" >/dev/null 2>&1 || host "$CUSTOM_FQDN" >/dev/null 2>&1; then
      CERT_DOMAINS+=( -d "$CUSTOM_FQDN" )
      log "Custom domain $CUSTOM_FQDN resolves; including it in the certificate."
    else
      warn "Custom domain $CUSTOM_FQDN does not resolve yet (finish NS delegation, then:"
      warn "  sudo certbot --nginx -d $FQDN -d $CUSTOM_FQDN --expand)."
    fi
  fi
  log "Requesting Let's Encrypt certificate..."
  sudo certbot --nginx "${CERT_DOMAINS[@]}" --non-interactive --agree-tos --redirect --expand --email "$CERTBOT_EMAIL" \
    && ok "TLS configured (${CERT_DOMAINS[*]})" \
    || warn "Certbot failed (check DNS/port 80); HTTP still serving."
else
  warn "CERTBOT_EMAIL not set; skipping TLS."
fi
ok "Nginx configured."
