#!/usr/bin/env bash
# Патч t.sh: веб-доступ первым, диагностика ошибок, фолбэки, проверка портов
set -uo pipefail
cd "$(dirname "$0")"
[ -f t.sh ] || { echo "Нет t.sh рядом"; exit 1; }
cp t.sh t.sh.bak
python3 - <<'PYFIX'
import re,pathlib
p=pathlib.Path("t.sh"); s=p.read_text()

# 1. Трап ошибок + лог всего вывода
if "PM_INSTALL_LOG" not in s:
    s=s.replace('set -uo pipefail\nAPP=/opt/proxy-manager',
'''set -uo pipefail
APP=/opt/proxy-manager
PM_INSTALL_LOG=/root/pm-install.log
exec > >(tee -a "$PM_INSTALL_LOG") 2>&1
trap 'echo; echo "!!! ОШИБКА на строке $LINENO (шаг выше). Полный лог: $PM_INSTALL_LOG"; echo "!!! Веб-доступ, если уже поднят: https://$(curl -4 -s --max-time 5 https://api.ipify.org):2087"; echo "!!! Пароли: cat /etc/pm-web/cred"' ERR''',1)

# 2. Ранний подъём сети: вставляем блок сразу после определения IP
EARLY = '''
echo "=========== 2.5 РАННИЙ ВЕБ-ДОСТУП ==========="
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \\
  -keyout /etc/pm-web/self.key -out /etc/pm-web/self.crt \\
  -subj "/CN=${DOMAIN:-$SRV_IP}" -addext "subjectAltName=DNS:${DOMAIN:-$SRV_IP},IP:$SRV_IP,IP:127.0.0.1" 2>/dev/null
chmod 600 /etc/pm-web/self.key
cat > /etc/nginx/sites-available/early <<NGE
server { listen 80 default_server; server_name _;
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 200 "installing..."; } }
server { listen 2087 ssl default_server; server_name _;
  ssl_certificate /etc/pm-web/self.crt; ssl_certificate_key /etc/pm-web/self.key;
  location / { proxy_pass http://127.0.0.1:7681; proxy_http_version 1.1;
    proxy_set_header Upgrade \\$http_upgrade; proxy_set_header Connection "upgrade";
    proxy_set_header Host \\$host; proxy_read_timeout 86400; } }
server { listen 2083 ssl default_server; server_name _;
  ssl_certificate /etc/pm-web/self.crt; ssl_certificate_key /etc/pm-web/self.key;
  client_max_body_size 4096m;
  location / { proxy_pass http://127.0.0.1:8080; proxy_set_header Host \\$host; } }
NGE
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/early /etc/nginx/sites-enabled/early
nginx -t && systemctl restart nginx
echo "Ранний веб-доступ поднят (терминал/файлы заработают через ~1 мин)"
'''
if "РАННИЙ ВЕБ-ДОСТУП" not in s:
    a='echo "=========== 2. Генератор сетевой конфигурации ==========="'
    s=s.replace(a, EARLY.strip()+"\n\n"+a,1)

# 3. Фолбэк filebrowser на прямой бинарник
if "FB_FALLBACK" not in s:
    s=s.replace('''command -v filebrowser >/dev/null 2>&1 || \\
  curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash''',
'''if ! command -v filebrowser >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash || true
fi
if ! command -v filebrowser >/dev/null 2>&1; then
  echo "FB_FALLBACK: качаю бинарник напрямую"
  curl -fsSL -o /tmp/fb.tar.gz https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz
  tar -xzf /tmp/fb.tar.gz -C /usr/local/bin filebrowser && chmod +x /usr/local/bin/filebrowser
fi
command -v filebrowser >/dev/null || echo "!!! filebrowser НЕ установлен — файлы будут недоступны, терминал работает"''',1)

# 4. Проверка портов в финале
if "ПРОВЕРКА ПОРТОВ" not in s:
    a='BASE=$([ -n "$DOMAIN" ] && echo "$DOMAIN" || echo "$SRV_IP")'
    CHECK='''echo "--- ПРОВЕРКА ПОРТОВ ---"
for pp in 443 8443 2087 2083 2096 8444; do
  if ss -tln | grep -q ":$pp "; then echo "  $pp слушает"; else echo "  $pp НЕ слушает!"; fi
done
for u in http://127.0.0.1:7681 http://127.0.0.1:8080; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" || echo 000)
  echo "  $u -> $code"
done
'''
    s=s.replace(a, CHECK+a,1)

p.write_text(s); print("Патч применён. Бэкап: t.sh.bak")
PYFIX
bash t.sh
