cat > /root/fix.sh <<'FIXEOF'
#!/usr/bin/env bash
# Диагностика двойников + уборка конфликтов + проверка модулей + подъём
APP=/opt/proxy-manager
R=/root/pm-diag.txt
[ "$(id -u)" = 0 ] || { echo "нужен root"; exit 1; }
exec > >(tee "$R") 2>&1
echo "############ ДИАГНОСТИКА $(date) ############"

echo; echo "===== 1. IP ====="
PUB=""; for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
  v=$(curl -4 -s --max-time 6 "$u" | tr -d '[:space:]'); case "$v" in *.*.*.*) PUB="$v"; break;; esac; done
LOC=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "публичный: ${PUB:-не определился}   локальный: ${LOC:-нет}"

echo; echo "===== 2. ДВОЙНИКИ NGINX (главный подозреваемый) ====="
echo "--- все listen из активных конфигов ---"
grep -rn "listen " /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | sed 's/^/  /'
echo "--- поиск дублей портов ---"
DUP=$(grep -rhoP 'listen\s+\K[0-9]+' /etc/nginx/sites-enabled/ /etc/nginx/conf.d/ 2>/dev/null | sort | uniq -d)
if [ -n "$DUP" ]; then echo "  ❌ ДУБЛИ ПОРТОВ: $DUP  <- nginx из-за этого не стартует"; else echo "  ✅ дублей портов нет"; fi
echo "--- nginx -t ---"; nginx -t 2>&1 | sed 's/^/  /'
echo "--- файлы conf.d ---"; ls -1 /etc/nginx/conf.d/ 2>/dev/null | sed 's/^/  /'
echo "--- файлы sites-enabled ---"; ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | sed 's/^/  /'

echo; echo "===== 3. ДВОЙНИКИ SYSTEMD ====="
systemctl list-unit-files 2>/dev/null | grep -Ei 'proxy|pm-|web-term|web-files|rescue|x-ui' | sed 's/^/  /'
echo "--- ExecStart всех наших юнитов ---"
grep -H ExecStart /etc/systemd/system/{proxy-*,pm-*,web-*,rescue-*}.service 2>/dev/null | sed 's/^/  /'

echo; echo "===== 4. КТО ЗАНЯЛ ПОРТЫ ====="
ss -tlnp 2>/dev/null | grep -E ':(80|443|2087|2083|8443|8444|2096|8002|8003|7681|8080) ' | sed 's/^/  /'
echo "--- процессы uvicorn/ttyd/filebrowser ---"
ps -eo pid,etime,cmd | grep -Ei 'uvicorn|ttyd|filebrowser|bot\.py|monitor\.py' | grep -v grep | sed 's/^/  /'

echo; echo "===== 5. ФАЙЛЫ ПРИЛОЖЕНИЯ ====="
ls -la "$APP" 2>/dev/null | head -30 | sed 's/^/  /'
echo "--- другие копии приложения (двойники) ---"
for d in /opt/pm /opt/proxy-manager /root/proxy-manager /opt/proxy-manager-old; do
  [ -d "$d" ] && echo "  $d: $(ls "$d"/*.py 2>/dev/null | wc -l) py-файлов, $(stat -c %y "$d" 2>/dev/null | cut -d. -f1)"
done

echo; echo "===== 6. СОВМЕСТИМОСТЬ МОДУЛЕЙ (смесь версий?) ====="
if [ -x "$APP/venv/bin/python" ]; then
cd "$APP" && ./venv/bin/python - <<'PY'
import importlib,traceback
need={
 "common":["S","setS","init_db","db","clients","client","rnd","now","gb","xui","host","pbase","cab","sub","ib",
           "ibcache","vless","tg","allowed","hasplan","qr","cookie","domains","plans","plan","cplan","promos",
           "mkpromo","reset","sync","save","activate","applyplan","applypromo","sign_ok","extzip","_run","report",
           "server_ip","ips","cert_list","best_cert","tlspaths","cert_trusted","tlson","apply_proxy_tls",
           "apply_web_creds","rescue_token","svc","svc_state"],
 "xui_api":["XUI","XUIError"],
 "admin_app":["app"], "web_app":["app"],
}
bad=0
for m,syms in need.items():
    try:
        mod=importlib.import_module(m)
        miss=[s for s in syms if not hasattr(mod,s)]
        if miss: print(f"  ❌ {m}: НЕТ функций {miss}  <- модуль от ДРУГОЙ версии"); bad+=1
        else: print(f"  ✅ {m}: все функции на месте")
    except Exception as e:
        print(f"  ❌ {m}: НЕ ИМПОРТИРУЕТСЯ -> {type(e).__name__}: {e}"); bad+=1
        traceback.print_exc(limit=3)
print("  ИТОГ:", "❌ модули несовместимы, нужна переустановка файлов" if bad else "✅ модули согласованы")
PY
else echo "  ❌ venv отсутствует"; fi

echo; echo "===== 7. БД ====="
if [ -f "$APP/proxy_manager.db" ]; then
  ls -la "$APP/proxy_manager.db" | sed 's/^/  /'
  "$APP/venv/bin/python" - <<'PY' 2>/dev/null
import sqlite3
c=sqlite3.connect("/opt/proxy-manager/proxy_manager.db")
print("  quick_check:",c.execute("PRAGMA quick_check").fetchone()[0])
for t in ("clients","settings","admins","plans","promos","registrations"):
    try: print(f"  {t}: {c.execute('SELECT COUNT(*) FROM '+t).fetchone()[0]}")
    except Exception as e: print(f"  {t}: нет таблицы")
PY
else echo "  БД не найдена"; fi

echo; echo "===== 8. ЛОГИ ПАДЕНИЙ ====="
for u in proxy-admin proxy-web nginx web-term web-files; do
  echo "--- $u ---"; journalctl -u $u -n 12 --no-pager 2>/dev/null | tail -12 | sed 's/^/  /'
done

echo; echo "############ УБОРКА ДВОЙНИКОВ ############"
BK=/root/pm-backup-$(date +%Y%m%d_%H%M%S); mkdir -p "$BK"
cp -a /etc/nginx/sites-enabled "$BK"/ 2>/dev/null
cp -a /etc/nginx/conf.d "$BK"/ 2>/dev/null
cp -a "$APP"/*.py "$BK"/ 2>/dev/null
cp -a "$APP/proxy_manager.db" "$BK"/ 2>/dev/null
echo "бэкап: $BK"

echo "--- убираю конфликтующие конфиги nginx ---"
for f in /etc/nginx/conf.d/pm-web.conf /etc/nginx/conf.d/proxy-sub.conf \
         /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/acme \
         /etc/nginx/sites-enabled/bootstrap /etc/nginx/sites-enabled/early; do
  [ -e "$f" ] && { mv "$f" "$BK"/$(basename "$f").removed 2>/dev/null; echo "  убран $f"; }
done

echo "--- убираю старые/дублирующие юниты ---"
for u in pm-web pm-admin pm-panel proxy-cabinet proxy-panel proxy-manager; do
  if [ -e "/etc/systemd/system/$u.service" ]; then
    systemctl disable --now "$u" 2>/dev/null
    mv "/etc/systemd/system/$u.service" "$BK"/ 2>/dev/null
    echo "  убран юнит $u"
  fi
done
systemctl daemon-reload

echo "--- освобождаю порты от висящих процессов ---"
for p in 8002 8003 7681 8080; do
  PIDS=$(ss -tlnpH "sport = :$p" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | sort -u)
  for pid in $PIDS; do
    CMD=$(ps -p "$pid" -o cmd= 2>/dev/null)
    case "$CMD" in *uvicorn*|*ttyd*|*filebrowser*) kill "$pid" 2>/dev/null; echo "  убит $pid ($p)";; esac
  done
done
sleep 2

echo "--- перезапуск ---"
systemctl restart web-term web-files 2>/dev/null
systemctl restart proxy-admin proxy-web proxy-bot proxy-monitor 2>/dev/null
if [ -f "$APP/net-setup.sh" ]; then bash "$APP/net-setup.sh" 2>&1 | tail -12; else nginx -t && systemctl restart nginx; fi
sleep 4

echo; echo "############ ПРОВЕРКА ПОСЛЕ УБОРКИ ############"
nginx -t 2>&1 | sed 's/^/  /'
for u in nginx web-term web-files proxy-admin proxy-web proxy-bot proxy-monitor rescue-agent; do
  printf "  %-16s %s\n" "$u" "$(systemctl is-active $u 2>/dev/null)"
done
echo "--- порты ---"
for p in 80 443 2087 2083 8443 8444 2096; do ss -tln | grep -q ":$p " && echo "  $p слушает" || echo "  $p НЕТ"; done
echo "--- локальные ответы ---"
for u in http://127.0.0.1:8002/ http://127.0.0.1:8003/login http://127.0.0.1:7681 http://127.0.0.1:8080; do
  echo "  $u -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$u" 2>/dev/null || echo 000)"
done
echo "--- снаружи по IP ---"
for u in "https://${PUB:-$LOC}/" "https://${PUB:-$LOC}:8443/login" "https://${PUB:-$LOC}:2087/"; do
  echo "  $u -> $(curl -sk -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null || echo 000)"
done
echo
echo "ОТЧЁТ СОХРАНЁН: $R"
echo "Пришли мне его целиком (или: tail -120 $R)"
FIXEOF
bash /root/fix.sh
