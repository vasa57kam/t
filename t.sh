#!/usr/bin/env bash
# ==============================================
#  telnet.sh — авторазвёртывание Telnet-сервера (Ubuntu/Debian)
#  Запуск:      curl -sL <URL> | bash
#  Свой порт:   TELNET_PORT=2323 curl -sL <URL> | bash
# ==============================================
set -u
PORT="${TELNET_PORT:-23}"
ok(){ echo -e "\033[32m[OK]\033[0m $1"; }
err(){ echo -e "\033[31m[FAIL]\033[0m $1"; }

echo "== [1/6] Проверка прав =="
[ "$(id -u)" = 0 ] || { err "Запусти под root"; exit 1; }
ok "root есть"

echo "== [2/6] Установка пакетов =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq telnetd openbsd-inetd >/dev/null 2>&1 \
  || { err "apt не смог поставить пакеты — проверь исходящую сеть"; exit 1; }
ok "telnetd + openbsd-inetd установлены"

echo "== [3/6] Настройка inetd =="
BIN=""
for b in /usr/sbin/in.telnetd /usr/sbin/telnetd; do [ -x "$b" ] && BIN="$b"; done
[ -n "$BIN" ] || { err "Бинарник telnetd не найден"; exit 1; }
# Удаляем старые/битые строки telnet и пишем одну правильную (идемпотентно)
sed -i -e '/^[[:space:]]*#*[[:space:]]*telnet[[:space:]]/d' -e '/in\.telnetd/d' /etc/inetd.conf
printf '%s\tstream\ttcp\tnowait\troot\t%s\tin.telnetd\n' "$PORT" "$BIN" >> /etc/inetd.conf
ok "конфиг записан (порт $PORT, бинарник $BIN)"

echo "== [4/6] Запуск службы =="
systemctl enable openbsd-inetd >/dev/null 2>&1
systemctl restart openbsd-inetd
sleep 1

echo "== [5/6] Файрвол =="
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "$PORT/tcp" >/dev/null && ok "ufw: порт $PORT открыт"
else
  ok "ufw не активен — пропускаю"
fi

echo "== [6/6] Проверка порта =="
if ss -tln | grep -q ":$PORT "; then
  ok "Порт $PORT СЛУШАЕТСЯ — telnet поднят"
  echo "Подключение: telnet <IP> $PORT  (или PuTTY: тип Telnet, порт $PORT)"
else
  err "Порт $PORT не слушается. Включаю фолбэк через xinetd..."
  apt-get install -y -qq xinetd >/dev/null 2>&1
  cat > /etc/xinetd.d/telnet <<EOF
service telnet
{
    disable     = no
    socket_type = stream
    wait        = no
    user        = root
    server      = $BIN
    port        = $PORT
}
EOF
  systemctl disable openbsd-inetd >/dev/null 2>&1
  systemctl restart xinetd
  sleep 1
  if ss -tln | grep -q ":$PORT "; then
    ok "xinetd поднял порт $PORT — telnet работает"
  else
    err "Всё равно не слушается. Диагноз:"
    journalctl -u openbsd-inetd -u xinetd -n 20 --no-pager
    exit 1
  fi
fi
echo "== Готово =="
