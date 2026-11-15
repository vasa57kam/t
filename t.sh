#!/usr/bin/env bash
# Веб-терминал + файловый менеджер на HTTPS. SSH не нужен.
set -euo pipefail
DOMAIN="${DOMAIN:-vps.ddns.net}"
WU="${WU:-admin}"
WP="${WP:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)}"
[ "$(id -u)" = 0 ] || { echo "нужен root"; exit 1; }

echo "==> пакеты"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx certbot curl git python3 openssl ca-certificates ufw

echo "==> веб-терминал ttyd"
if ! command -v ttyd >/dev/null 2>&1; then
  curl -fsSL -o /usr/local/bin/ttyd \
    https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64
  chmod +x /usr/local/bin/ttyd
fi

echo "==> файловый менеджер filebrowser"
if ! command -v filebrowser >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash
fi

mkdir -p /etc/pm-web /var/www/certbot
printf '%s\n' "$WU" "$WP" > /etc/pm-web/cred; chmod 600 /etc/pm-web/cred

echo "==> сертификат"
cat > /etc/nginx/sites-available/acme <<NG
server { listen 80; server_name ${DOMAIN};
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 200 "ok"; } }
NG
ln -sf /etc/nginx/sites-available/acme /etc/nginx/sites-enabled/acme
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx && systemctl restart nginx

CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
if [ ! -f "$CERT" ]; then
  certbot certonly --webroot -w /var/www/certbot -d "$DOMAIN" --non-interactive \
    --agree-tos --register-unsafely-without-email --deploy-hook "systemctl reload nginx" || true
fi
if [ ! -f "$CERT" ]; then
  echo "!!! Let's Encrypt не выдался — делаю самоподписанный (браузер ругнётся, но работает)"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout /etc/pm-web/self.key -out /etc/pm-web/self.crt -subj "/CN=${DOMAIN}"
  CERT=/etc/pm-web/self.crt; KEY=/etc/pm-web/self.key
fi

echo "==> сервисы"
cat > /etc/systemd/system/web-term.service <<U
[Unit]
Description=Web Terminal (ttyd)
After=network-online.target
[Service]
ExecStart=/usr/local/bin/ttyd -W -i 127.0.0.1 -p 7681 -c ${WU}:${WP} /bin/bash
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
U

filebrowser config init -d /etc/pm-web/fb.db >/dev/null 2>&1 || true
filebrowser users add "$WU" "$WP" --perm.admin -d /etc/pm-web/fb.db >/dev/null 2>&1 \
  || filebrowser users update "$WU" -p "$WP" -d /etc/pm-web/fb.db >/dev/null 2>&1 || true

cat > /etc/systemd/system/web-files.service <<U
[Unit]
Description=Web File Manager (filebrowser)
After=network-online.target
[Service]
ExecStart=/usr/local/bin/filebrowser -r / -a 127.0.0.1 -p 8080 -d /etc/pm-web/fb.db
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
U

systemctl daemon-reload
systemctl enable --now web-term web-files

echo "==> nginx: 2087 терминал, 2083 файлы"
cat > /etc/nginx/conf.d/pm-web.conf <<NG
server {
  listen 2087 ssl;
  server_name ${DOMAIN};
  ssl_certificate ${CERT};
  ssl_certificate_key ${KEY};
  ssl_protocols TLSv1.2 TLSv1.3;
  location / {
    proxy_pass http://127.0.0.1:7681;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host;
    proxy_read_timeout 86400;
    proxy_send_timeout 86400;
  }
}
server {
  listen 2083 ssl;
  server_name ${DOMAIN};
  ssl_certificate ${CERT};
  ssl_certificate_key ${KEY};
  ssl_protocols TLSv1.2 TLSv1.3;
  client_max_body_size 4096m;
  location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 3600;
  }
}
NG
nginx -t && systemctl reload nginx
command -v ufw >/dev/null && { ufw allow 2087/tcp; ufw allow 2083/tcp; ufw allow 443/tcp; ufw allow 80/tcp; } || true

sleep 2
echo
echo "============================================================"
echo " ВЕБ-ТЕРМИНАЛ:  https://${DOMAIN}:2087"
echo " ФАЙЛЫ:         https://${DOMAIN}:2083"
echo " Логин: ${WU}"
echo " Пароль: ${WP}"
echo "============================================================"
echo "Пароль также в /etc/pm-web/cred"
systemctl is-active web-term web-files nginx
