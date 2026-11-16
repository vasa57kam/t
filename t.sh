#!/usr/bin/env bash
# =====================================================================
#  PROXY MANAGER — единый установщик v5 (IP-first, отказоустойчивый)
#  Веб-консоль + файлы + шифрованный прокси + биллинг + бот + резерв
#  Запуск: bash t.sh
#          DOMAIN=example.com bash t.sh   (если домен уже на этом IP)
# =====================================================================
set -uo pipefail
APP=/opt/proxy-manager
WU="${WU:-admin}"
WP="${WP:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)}"
LOG=/root/pm-install.log
ERRF=/root/pm-install.err
[ "$(id -u)" = 0 ] || { echo "Нужен root"; exit 1; }
exec > >(tee -a "$LOG") 2>&1
trap 'echo "строка $LINENO: команда завершилась с ошибкой" >> "$ERRF"' ERR
rm -f "$ERRF"

echo "=========== 1. Пакеты и определение IP ==========="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip \
  nginx certbot curl git zip tar openssl ufw ca-certificates openssh-client dnsutils
mkdir -p "$APP/templates" "$APP/extension" /etc/pm-web /var/www/certbot /opt/rescue-agent
SRV_IP=$(curl -4 -s --max-time 8 https://api.ipify.org || true)
[ -z "$SRV_IP" ] && SRV_IP=$(curl -4 -s --max-time 8 https://ifconfig.me || true)
[ -z "$SRV_IP" ] && SRV_IP=$(hostname -I | awk '{print $1}')
DOMAIN="${DOMAIN:-}"
echo "Публичный IP: $SRV_IP"
[ -n "$DOMAIN" ] && echo "Домен: $DOMAIN" || echo "Домен не задан — работаем по IP"

echo "=========== 2. ВЕБ-ДОСТУП (поднимаем первым) ==========="
printf '%s\n' "$WU" "$WP" > /etc/pm-web/cred; chmod 600 /etc/pm-web/cred
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /etc/pm-web/self.key -out /etc/pm-web/self.crt \
  -subj "/CN=${DOMAIN:-$SRV_IP}" \
  -addext "subjectAltName=DNS:${DOMAIN:-$SRV_IP},IP:$SRV_IP,IP:127.0.0.1" 2>/dev/null
chmod 600 /etc/pm-web/self.key

if ! command -v ttyd >/dev/null 2>&1; then
  curl -fsSL -o /usr/local/bin/ttyd https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 \
    && chmod +x /usr/local/bin/ttyd || echo "!!! ttyd не скачался"
fi
if ! command -v filebrowser >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash || true
fi
if ! command -v filebrowser >/dev/null 2>&1; then
  echo "Фолбэк: качаю filebrowser напрямую"
  curl -fsSL -o /tmp/fb.tar.gz https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz \
    && tar -xzf /tmp/fb.tar.gz -C /usr/local/bin filebrowser && chmod +x /usr/local/bin/filebrowser || true
fi

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
Description=Web File Manager
After=network-online.target
[Service]
ExecStart=/usr/local/bin/filebrowser -r / -a 127.0.0.1 -p 8080 -d /etc/pm-web/fb.db
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
U

cat > /etc/nginx/sites-available/proxy-manager <<NG
server { listen 80 default_server; server_name _;
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 200 "Proxy Manager: установка идёт..."; } }
server { listen 2087 ssl default_server; server_name _;
  ssl_certificate /etc/pm-web/self.crt; ssl_certificate_key /etc/pm-web/self.key;
  ssl_protocols TLSv1.2 TLSv1.3;
  location / { proxy_pass http://127.0.0.1:7681; proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host; proxy_read_timeout 86400; proxy_send_timeout 86400; } }
server { listen 2083 ssl default_server; server_name _;
  ssl_certificate /etc/pm-web/self.crt; ssl_certificate_key /etc/pm-web/self.key;
  ssl_protocols TLSv1.2 TLSv1.3; client_max_body_size 4096m;
  location / { proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https; proxy_read_timeout 3600; } }
NG
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/proxy-manager /etc/nginx/sites-enabled/proxy-manager
nginx -t && systemctl enable --now nginx && systemctl restart nginx
systemctl daemon-reload && systemctl enable --now web-term web-files
command -v ufw >/dev/null && { for p in 22 2222 80 443 2087 2083 8443 8444 2096; do ufw allow $p/tcp; done; ufw allow 20000:21000/tcp; } || true
sleep 2
echo
echo "############################################################"
echo "#  ВЕБ-ДОСТУП УЖЕ РАБОТАЕТ (дальше можно из браузера):"
echo "#  КОНСОЛЬ:  https://${SRV_IP}:2087"
echo "#  ФАЙЛЫ:    https://${SRV_IP}:2083"
echo "#  Логин: ${WU}   Пароль: ${WP}"
echo "#  Сертификат самоподписанный: Дополнительно -> Перейти"
echo "############################################################"
echo

echo "=========== 3. Генератор сетевой конфигурации ==========="
cat > "$APP/net-setup.sh" <<'NETSETUP'
#!/usr/bin/env bash
# Пересобирает сертификат (при необходимости) и конфиг nginx.
# Вызывается установщиком и из админки при смене домена/сертификата.
set -uo pipefail
APP=/opt/proxy-manager
cd "$APP" || exit 1
read -r DOMAIN CERT KEY <<<"$(./venv/bin/python - <<'PY'
import common as cm
s=cm.S(); c,k=cm.tlspaths(s)
print((s.get("domain") or "-"), (c or "-"), (k or "-"))
PY
)"
[ "$DOMAIN" = "-" ] && DOMAIN=""
[ "$CERT" = "-" ] && CERT=""
[ "$KEY" = "-" ] && KEY=""
IP=$(curl -4 -s --max-time 6 https://api.ipify.org || true)
[ -z "$IP" ] && IP=$(hostname -I | awk '{print $1}')
SN="${DOMAIN:-$IP}"
[ -z "$SN" ] && { echo "Не определить ни домен, ни IP"; exit 1; }
if [ -z "$CERT" ] || [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
  echo "Валидного сертификата нет — самоподписанный для $SN $IP"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout /etc/pm-web/self.key -out /etc/pm-web/self.crt \
    -subj "/CN=$SN" -addext "subjectAltName=DNS:$SN,IP:$IP,IP:127.0.0.1" 2>/dev/null
  chmod 600 /etc/pm-web/self.key
  CERT=/etc/pm-web/self.crt; KEY=/etc/pm-web/self.key
fi
echo "Сертификат: $CERT"
cat > /etc/nginx/sites-available/proxy-manager <<NG
server { listen 80 default_server; server_name ${DOMAIN:-_};
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; } }
server { listen 443 ssl default_server; server_name ${DOMAIN:-_};
  ssl_certificate ${CERT}; ssl_certificate_key ${KEY};
  ssl_protocols TLSv1.2 TLSv1.3; client_max_body_size 4096m;
  location / { proxy_pass http://127.0.0.1:8002; proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https; } }
server { listen 8443 ssl; server_name ${DOMAIN:-_};
  ssl_certificate ${CERT}; ssl_certificate_key ${KEY};
  ssl_protocols TLSv1.2 TLSv1.3; client_max_body_size 4096m;
  location / { proxy_pass http://127.0.0.1:8003; proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https; } }
server { listen 2096 ssl; server_name ${DOMAIN:-_};
  ssl_certificate ${CERT}; ssl_certificate_key ${KEY}; ssl_protocols TLSv1.2 TLSv1.3;
  location / { proxy_pass http://127.0.0.1:8002; proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https; } }
server { listen 2087 ssl; server_name ${DOMAIN:-_};
  ssl_certificate ${CERT}; ssl_certificate_key ${KEY}; ssl_protocols TLSv1.2 TLSv1.3;
  location / { proxy_pass http://127.0.0.1:7681; proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host; proxy_read_timeout 86400; proxy_send_timeout 86400; } }
server { listen 2083 ssl; server_name ${DOMAIN:-_};
  ssl_certificate ${CERT}; ssl_certificate_key ${KEY};
  ssl_protocols TLSv1.2 TLSv1.3; client_max_body_size 4096m;
  location / { proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https; proxy_read_timeout 3600; } }
NG
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/acme
ln -sf /etc/nginx/sites-available/proxy-manager /etc/nginx/sites-enabled/proxy-manager
nginx -t && systemctl reload nginx || { echo "ОШИБКА КОНФИГА NGINX"; nginx -t; exit 1; }
./venv/bin/python - <<PY
import common as cm
d="${DOMAIN}"; ip="${IP}"; base=d or ip
cm.setS({"public_url":"https://"+base,"admin_url":"https://"+base+":8443","sub_url_base":"https://"+base+":2096"})
print("URL обновлены: https://"+base)
PY
systemctl restart rescue-agent 2>/dev/null || true
echo "Сеть настроена для: $SN"
NETSETUP
chmod +x "$APP/net-setup.sh"

echo "=========== 4. Модули Proxy Manager ==========="
cd "$APP"

cat > common.py <<'PY_COMMON'
import json,sqlite3,time,secrets,hmac,hashlib,base64,io,zipfile,os,re,string,subprocess,socket
from contextlib import contextmanager
from pathlib import Path
from urllib.parse import quote
import requests
from passlib.hash import bcrypt

BASE=Path(__file__).resolve().parent; DBP=BASE/"proxy_manager.db"
PRESETS={"Telegram":["telegram.org","t.me","telegra.ph","telesco.pe"],
"YouTube":["youtube.com","youtu.be","googlevideo.com","ytimg.com"],
"Instagram":["instagram.com","cdninstagram.com"],"Discord":["discord.com","discord.gg","discordapp.com","discord.media"],
"Twitter/X":["twitter.com","x.com","twimg.com","t.co"],"Facebook":["facebook.com","fbcdn.net"],
"WhatsApp":["whatsapp.com","whatsapp.net"],"Reddit":["reddit.com","redd.it"],
"Wikipedia":["wikipedia.org","wikimedia.org"],"Google":["google.com","gstatic.com","googleapis.com","googleusercontent.com"]}
DEF={"panel_name":"Proxy Manager","bot_token":"","admin_tg_id":"","bot_username":"",
"xui_url":"http://127.0.0.1:2053","xui_user":"admin","xui_pass":"admin","xui_api_token":"","inbound_id":"1",
"domain":"","sni":"","vless_port":"443","reality_pbk":"","reality_sid":"","fp":"chrome","reality_spx":"/",
"billing_enabled":"0","price":"100","period_days":"30","billing_secret":secrets.token_hex(16),
"http_port_start":"20000","http_port_end":"21000","inbounds_cache":"{}","require_plan":"1",
"public_url":"","admin_url":"","sub_url_base":"","proxy_tls":"1","tls_cert":"","tls_key":"","le_email":"",
"stat_clients":"","stat_clients_label":"пользователей","stat_presets":"","stat_presets_label":"сервисов",
"stat_third":"24/7","stat_third_label":"поддержка","guest_enabled":"0","guest_token":secrets.token_urlsafe(24),
"ext_presets":json.dumps(PRESETS,ensure_ascii=False),"ext_lists":json.dumps({"telegram_actual":"","all_ru_blocked":""})}
SCHEMA="""
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT);
CREATE TABLE IF NOT EXISTS admins(id INTEGER PRIMARY KEY AUTOINCREMENT,username TEXT UNIQUE,password_hash TEXT);
CREATE TABLE IF NOT EXISTS clients(id INTEGER PRIMARY KEY AUTOINCREMENT,tg_id TEXT UNIQUE,name TEXT,email TEXT UNIQUE,
 uuid TEXT,balance REAL DEFAULT 0,limit_gb REAL DEFAULT 0,used_bytes INTEGER DEFAULT 0,enabled INTEGER DEFAULT 1,
 notified INTEGER DEFAULT 0,paid_until INTEGER DEFAULT 0,ext_key TEXT UNIQUE,http_port INTEGER DEFAULT 0,
 http_user TEXT DEFAULT '',http_pass TEXT DEFAULT '',http_inbound_id INTEGER DEFAULT 0,inbound_id INTEGER DEFAULT 0,
 plan_id INTEGER DEFAULT 0,sub_id TEXT DEFAULT '',access_code TEXT DEFAULT '',created_at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS payments(id INTEGER PRIMARY KEY AUTOINCREMENT,tg_id TEXT,amount REAL,source TEXT DEFAULT 'admin',
 status TEXT DEFAULT 'paid',external_id TEXT DEFAULT '',created_at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS suggestions(id INTEGER PRIMARY KEY AUTOINCREMENT,ext_key TEXT,name TEXT,domains TEXT,created_at TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS registrations(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT,phone TEXT,email TEXT DEFAULT '',
 tg_id TEXT DEFAULT '',comment TEXT DEFAULT '',code TEXT UNIQUE,status TEXT DEFAULT 'pending',client_id INTEGER DEFAULT 0,
 created_at TEXT DEFAULT (datetime('now')),decided_at TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS plans(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT,price REAL DEFAULT 0,period_days INTEGER DEFAULT 30,
 limit_gb REAL DEFAULT 0,description TEXT DEFAULT '',enabled INTEGER DEFAULT 1,sort_order INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS promos(id INTEGER PRIMARY KEY AUTOINCREMENT,code TEXT UNIQUE,kind TEXT,value REAL DEFAULT 0,
 max_uses INTEGER DEFAULT 0,used_count INTEGER DEFAULT 0,expires_at INTEGER DEFAULT 0,enabled INTEGER DEFAULT 1,note TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS promo_uses(id INTEGER PRIMARY KEY AUTOINCREMENT,promo_id INTEGER,client_id INTEGER,detail TEXT,created_at TEXT DEFAULT (datetime('now')));
"""

@contextmanager
def db():
    c=sqlite3.connect(DBP,timeout=15); c.row_factory=sqlite3.Row
    c.execute("PRAGMA journal_mode=WAL"); c.execute("PRAGMA busy_timeout=10000")
    try:
        yield c; c.commit()
    finally:
        c.close()

def rnd(n,up=False):
    al=(string.ascii_uppercase+string.digits) if up else (string.ascii_lowercase+string.digits)
    return "".join(secrets.choice(al) for _ in range(n))

def server_ip():
    for u in ("https://api.ipify.org","https://ifconfig.me"):
        try:
            r=requests.get(u,timeout=6)
            if r.ok and re.match(r"^\d+\.\d+\.\d+\.\d+$",r.text.strip()): return r.text.strip()
        except Exception: pass
    try: return socket.gethostbyname(socket.gethostname())
    except Exception: return "127.0.0.1"

def init_db():
    with db() as c:
        c.executescript(SCHEMA)
        for k,v in DEF.items(): c.execute("INSERT OR IGNORE INTO settings VALUES(?,?)",(k,v))
        if not c.execute("SELECT 1 FROM admins LIMIT 1").fetchone():
            c.execute("INSERT INTO admins(username,password_hash) VALUES(?,?)",("admin",bcrypt.hash("admin")))
        if not c.execute("SELECT 1 FROM plans LIMIT 1").fetchone():
            c.executemany("INSERT INTO plans(name,price,period_days,limit_gb,description,sort_order) VALUES(?,?,?,?,?,?)",
                [("Старт",100,30,50,"Браузер и мессенджеры",1),("Стандарт",200,30,200,"На каждый день",2),("Безлимит",350,30,0,"Без лимита трафика",3)])
        for r in [dict(x) for x in c.execute("SELECT id,sub_id,access_code FROM clients")]:
            if not r["sub_id"]: c.execute("UPDATE clients SET sub_id=? WHERE id=?",(rnd(16),r["id"]))
            if not r["access_code"]: c.execute("UPDATE clients SET access_code=? WHERE id=?",(rnd(6,True),r["id"]))

def S():
    s=dict(DEF)
    with db() as c:
        for r in c.execute("SELECT key,value FROM settings"): s[r["key"]]=r["value"]
    return s

def setS(d):
    with db() as c:
        c.executemany("INSERT INTO settings VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[(k,str(v)) for k,v in d.items()])

def clients():
    with db() as c: return [dict(r) for r in c.execute("SELECT * FROM clients ORDER BY id")]

def client(**kw):
    ok={"id","tg_id","email","ext_key","uuid","sub_id"}; cond={k:v for k,v in kw.items() if k in ok}
    if not cond: return None
    w=" AND ".join(f"{k}=?" for k in cond)
    with db() as c:
        r=c.execute(f"SELECT * FROM clients WHERE {w} LIMIT 1",tuple(cond.values())).fetchone()
        return dict(r) if r else None

def now(): return int(time.time())
def gb(b): return f"{(b or 0)/2**30:.2f}"

def xui(s,t=15):
    from xui_api import XUI
    return XUI(s["xui_url"],s["xui_user"],s["xui_pass"],s.get("xui_api_token",""),timeout=t)

def host(s): return s.get("domain") or server_ip()
def pbase(s): return (s.get("public_url") or f"https://{host(s)}").rstrip("/")
def cab(c,s): return f"{pbase(s)}/client/{c['tg_id']}"
def subbase(s): return (s.get("sub_url_base") or pbase(s)).rstrip("/")
def sub(c,s): return f"{subbase(s)}/sub/{c.get('sub_id') or c['tg_id']}"

def ib(c,s):
    try: i=int(c.get("inbound_id") or 0)
    except Exception: i=0
    return i or int(s["inbound_id"])

def tlspaths(s):
    c=(s.get("tls_cert") or "").strip(); k=(s.get("tls_key") or "").strip()
    if c and k and os.path.exists(c) and os.path.exists(k): return c,k
    d=s.get("domain") or ""
    if d:
        for c,k in ((f"/etc/letsencrypt/live/{d}/fullchain.pem",f"/etc/letsencrypt/live/{d}/privkey.pem"),
                    (f"/root/cert/{d}/fullchain.pem",f"/root/cert/{d}/privkey.pem")):
            if os.path.exists(c) and os.path.exists(k): return c,k
    if os.path.exists("/etc/pm-web/self.crt") and os.path.exists("/etc/pm-web/self.key"):
        return "/etc/pm-web/self.crt","/etc/pm-web/self.key"
    return "",""

def cert_trusted(s):
    """Chrome принимает HTTPS-прокси только с валидным (не самоподписанным) сертификатом."""
    c,_=tlspaths(s)
    return bool(c) and not c.endswith("self.crt")

def tlson(s):
    if s.get("proxy_tls")!="1": return False
    return cert_trusted(s)

def ibcache(s,force=False):
    try: ca=json.loads(s.get("inbounds_cache") or "{}")
    except Exception: ca={}
    if not force and ca.get("_ts",0)>time.time()-300 and len(ca)>1: return ca
    try:
        new={"_ts":int(time.time())}
        for b in xui(s,10).get_inbounds():
            ss=b.get("streamSettings") or {}; st=b.get("settings") or {}
            if isinstance(ss,str): ss=json.loads(ss or "{}")
            if isinstance(st,str): st=json.loads(st or "{}")
            rs=ss.get("realitySettings") or {}; inner=rs.get("settings") or {}
            sn=rs.get("serverNames") or []; si=rs.get("shortIds") or []
            new[str(b.get("id"))]={"port":b.get("port"),"protocol":b.get("protocol"),"remark":b.get("remark") or "",
                "security":ss.get("security") or "","sni":next((v for v in sn if v),""),"pbk":inner.get("publicKey") or "",
                "sid":next((v for v in si if v),""),"fp":inner.get("fingerprint") or "chrome","spx":inner.get("spiderX") or "/",
                "encryption":st.get("encryption") or "","clients":len(st.get("clients") or [])}
        setS({"inbounds_cache":json.dumps(new,ensure_ascii=False)}); return new
    except Exception: return ca

def vless(c,s):
    ca=ibcache(s); p=ca.get(str(ib(c,s))) or {}
    enc=p.get("encryption") or "none"; pbk=p.get("pbk") or s.get("reality_pbk") or ""
    q={"type":"tcp","encryption":enc,"security":"reality" if pbk else "none",
       "sni":p.get("sni") or s.get("sni",""),"fp":p.get("fp") or s.get("fp","chrome"),"spx":p.get("spx") or "/"}
    if "mlkem768" in enc: q["support-x25519mlkem768"]="true"
    else: q["flow"]="xtls-rprx-vision"
    if pbk: q["pbk"]=pbk
    sid=p.get("sid") or s.get("reality_sid") or ""
    if sid: q["sid"]=sid
    qs="&".join(f"{k}={quote(str(v),safe='')}" for k,v in q.items() if v)
    return f"vless://{c['uuid']}@{host(s)}:{p.get('port') or s.get('vless_port','443')}?{qs}#{quote(c['email'])}"

def tg(s,chat,text):
    t=s.get("bot_token","")
    if not t or not chat: return False
    try: return requests.post(f"https://api.telegram.org/bot{t}/sendMessage",json={"chat_id":chat,"text":text},timeout=10).ok
    except Exception: return False

def allowed(c,s):
    if not c: return False,"Клиент не найден"
    if not c["enabled"]: return False,"Доступ отключён"
    if (s.get("billing_enabled")=="1" or c.get("plan_id")) and int(c["paid_until"] or 0)<=now():
        return False,"Подписка не оплачена"
    l=float(c["limit_gb"] or 0)
    if l>0 and int(c["used_bytes"] or 0)>=l*2**30: return False,"Лимит трафика исчерпан"
    return True,""

def hasplan(c): return bool(c.get("plan_id"))

def qr(text):
    try:
        import qrcode
        b=io.BytesIO(); qrcode.make(str(text)).save(b,format="PNG")
        return "data:image/png;base64,"+base64.b64encode(b.getvalue()).decode()
    except Exception: return ""

def mstat(k,d=""):
    v=str(S().get("stat_"+k,"") or "").strip(); return v or str(d)

def cookie(c): return hashlib.sha256((str(c.get("access_code",""))+":"+str(c["tg_id"])).encode()).hexdigest()[:32]

def domains(raw,limit=500):
    out=[]
    for x in re.split(r"[\s,;]+",str(raw or "")[:20000]):
        x=re.sub(r"^https?://","",x.strip().lower()).split("/")[0].strip(".")
        if x and re.match(r"^[a-z0-9.-]+\.[a-z]{2,}$",x) and x not in out: out.append(x)
        if len(out)>=limit: break
    return out

def plans(only=True):
    q="SELECT * FROM plans"+(" WHERE enabled=1" if only else "")+" ORDER BY sort_order,id"
    with db() as c: return [dict(r) for r in c.execute(q)]

def plan(pid):
    try: pid=int(pid or 0)
    except Exception: return None
    if not pid: return None
    with db() as c:
        r=c.execute("SELECT * FROM plans WHERE id=?",(pid,)).fetchone(); return dict(r) if r else None

def cplan(c): return plan(c.get("plan_id"))

def promos():
    with db() as c: return [dict(r) for r in c.execute("SELECT * FROM promos ORDER BY id DESC")]

def mkpromo(code,kind,val,mx=0,exp=0,note=""):
    code=str(code or "").strip().upper()
    if not code or kind not in ("balance","plan","days"): return False,"Неверные параметры"
    with db() as c:
        if c.execute("SELECT 1 FROM promos WHERE code=?",(code,)).fetchone(): return False,"Промокод уже есть"
        c.execute("INSERT INTO promos(code,kind,value,max_uses,expires_at,note) VALUES(?,?,?,?,?,?)",(code,kind,float(val),int(mx),int(exp),note))
    return True,f"Промокод {code} создан"

def reset(c,s,x):
    e=[]
    try: x.reset_client_traffic(ib(c,s),c["email"])
    except Exception as ex: e.append(str(ex))
    if c["http_inbound_id"]:
        try: x.reset_inbound_traffic(c["http_inbound_id"])
        except Exception as ex: e.append(str(ex))
    if e: raise RuntimeError("; ".join(e))

def sync(c,s,x):
    tot=int(float(c["limit_gb"] or 0)*2**30)
    exp=int(c["paid_until"])*1000 if (s["billing_enabled"]=="1" or c.get("plan_id")) else 0
    x.update_client(ib(c,s),c["uuid"],enable=bool(c["enabled"]),totalGB=tot,expiryTime=exp)
    if c["http_inbound_id"]:
        b=x.get_inbound(c["http_inbound_id"]); b["enable"]=bool(c["enabled"]); b["total"]=tot; b["expiryTime"]=exp
        x.update_inbound(b)

def save(c):
    with db() as con:
        con.execute("UPDATE clients SET balance=?,paid_until=?,enabled=?,notified=?,used_bytes=?,limit_gb=?,plan_id=? WHERE id=?",
            (c["balance"],c["paid_until"],c["enabled"],c["notified"],c["used_bytes"],c["limit_gb"],c.get("plan_id",0),c["id"]))

def activate(c,s,x=None,notify=True):
    c=dict(c); m=[]; p=cplan(c)
    price=float(p["price"]) if p else float(s["price"] or 0)
    period=int(p["period_days"]) if p else int(s["period_days"] or 30)
    bill=(s["billing_enabled"]=="1" or bool(p)); t=now()
    if bill and c["paid_until"]<=t:
        if c["balance"]>=price:
            c["balance"]=round(c["balance"]-price,2); c["paid_until"]=t+period*86400
            c["enabled"],c["notified"],c["used_bytes"]=1,0,0
            if p: c["limit_gb"]=float(p["limit_gb"] or 0)
            if x:
                try: reset(c,s,x)
                except Exception as e: m.append(str(e))
            u=time.strftime("%d.%m.%Y",time.localtime(c["paid_until"])); m.append(f"продлено до {u}")
            if notify: tg(s,c["tg_id"],f"✅ Подписка продлена до {u}. Баланс: {c['balance']:.2f} ₽")
        else:
            if c["enabled"]:
                c["enabled"]=0
                if notify: tg(s,c["tg_id"],f"⛔ Подписка истекла. Пополните: {cab(c,s)}")
            m.append("недостаточно средств")
    if c["enabled"] and float(c["limit_gb"] or 0)>0 and c["used_bytes"]>=float(c["limit_gb"])*2**30:
        c["enabled"]=0; m.append("лимит трафика")
    save(c)
    if x:
        try: sync(c,s,x)
        except Exception as e: m.append(f"3x-ui: {e}")
    return "; ".join(m) or "ок"

def applyplan(c,p,s,x=None,notify=True,free=False):
    c=dict(c); price=0.0 if free else float(p["price"])
    if c["balance"]<price: return False,f"Нужно {price:.2f} ₽, на балансе {c['balance']:.2f} ₽"
    c["balance"]=round(c["balance"]-price,2)
    c["paid_until"]=max(int(c["paid_until"] or 0),now())+int(p["period_days"])*86400
    c["plan_id"]=p["id"]; c["limit_gb"]=float(p["limit_gb"] or 0)
    c["enabled"],c["notified"],c["used_bytes"]=1,0,0
    save(c)
    if price>0:
        with db() as con: con.execute("INSERT INTO payments(tg_id,amount,source,status) VALUES(?,?,?,?)",(c["tg_id"],-price,"plan:"+p["name"],"paid"))
    if x:
        try: reset(c,s,x)
        except Exception: pass
        try: sync(c,s,x)
        except Exception: pass
    u=time.strftime("%d.%m.%Y",time.localtime(c["paid_until"]))
    msg=f"Тариф «{p['name']}» до {u}"+(" (бесплатно)" if free else "")
    if notify: tg(s,c["tg_id"],f"✅ {msg}\nБаланс: {c['balance']:.2f} ₽")
    return True,msg

def applypromo(c,code,s,x=None,notify=True):
    c=dict(c); code=str(code or "").strip().upper()
    if not code: return False,"Введите промокод"
    with db() as con: r=con.execute("SELECT * FROM promos WHERE code=?",(code,)).fetchone()
    if not r: return False,"Промокод не найден"
    p=dict(r)
    if not p["enabled"]: return False,"Промокод отключён"
    if p["expires_at"] and p["expires_at"]<now(): return False,"Срок промокода истёк"
    if p["max_uses"] and p["used_count"]>=p["max_uses"]: return False,"Промокод исчерпан"
    with db() as con:
        if con.execute("SELECT 1 FROM promo_uses WHERE promo_id=? AND client_id=?",(p["id"],c["id"])).fetchone():
            return False,"Вы уже использовали этот промокод"
    k,v=p["kind"],float(p["value"] or 0)
    if k=="balance":
        with db() as con:
            con.execute("UPDATE clients SET balance=ROUND(balance+?,2) WHERE id=?",(v,c["id"]))
            con.execute("INSERT INTO payments(tg_id,amount,source,status) VALUES(?,?,?,?)",(c["tg_id"],v,"promo:"+code,"paid"))
        c["balance"]=round(c["balance"]+v,2); d=f"+{v:.2f} ₽"
    elif k=="plan":
        pl=plan(int(v))
        if not pl: return False,"Тариф промокода не найден"
        ok,m=applyplan(c,pl,s,x,notify=False,free=True)
        if not ok: return False,m
        d=f"тариф «{pl['name']}» бесплатно"
    elif k=="days":
        u=max(int(c["paid_until"] or 0),now())+int(v)*86400
        with db() as con: con.execute("UPDATE clients SET paid_until=?,enabled=1 WHERE id=?",(u,c["id"]))
        c["paid_until"]=u; c["enabled"]=1
        if x:
            try: sync(c,s,x)
            except Exception: pass
        d=f"+{int(v)} дн."
    else: return False,"Неизвестный тип"
    with db() as con:
        con.execute("UPDATE promos SET used_count=used_count+1 WHERE id=?",(p["id"],))
        con.execute("INSERT INTO promo_uses(promo_id,client_id,detail) VALUES(?,?,?)",(p["id"],c["id"],d))
    if notify: tg(s,c["tg_id"],f"🎁 {code}: {d}")
    return True,"🎁 Промокод применён: "+d

def sign_ok(sec,tg_id,amt,sg):
    w=hmac.new(str(secret:=sec).encode(),f"{tg_id}:{amt}".encode(),hashlib.sha256).hexdigest()
    return hmac.compare_digest(w,str(sg or ""))

def extzip(s,h):
    url=pbase(s); b=io.BytesIO()
    with zipfile.ZipFile(b,"w",zipfile.ZIP_DEFLATED) as z:
        for p in sorted((BASE/"extension").rglob("*")):
            if p.is_file(): z.writestr("proxy-manager-extension/"+str(p.relative_to(BASE/"extension")),p.read_bytes().replace(b"__SERVER_URL__",url.encode()))
    return b.getvalue()

def _run(cmd,t=6):
    try:
        r=subprocess.run(cmd,shell=True,capture_output=True,text=True,timeout=t); return (r.stdout+r.stderr).strip()
    except Exception as e: return f"(err {e})"

def report():
    s=S(); L=["=== PROXY MANAGER REPORT ===",time.strftime("%F %T"),
              f"domain={s.get('domain') or '(по IP)'} ip={server_ip()}",
              f"public={s.get('public_url')} cert={tlspaths(s)[0] or 'нет'} trusted={cert_trusted(s)} tls_proxy={tlson(s)}"]
    try:
        for v in ["proxy-admin","proxy-web","proxy-bot","proxy-monitor","nginx","x-ui","web-term","web-files","rescue-agent"]:
            L.append("svc %-15s %s"%(v,_run("systemctl is-active "+v,4)))
        for p in (8002,8003,7681,8080,443,8443,2096,2087,2083,8444):
            try:
                with socket.create_connection(("127.0.0.1",p),timeout=1): o="open"
            except Exception: o="closed"
            L.append("port %-5s %s"%(p,o))
    except Exception as e: L.append("svc err %s"%e)
    try:
        for k,v in ibcache(s,True).items():
            if k!="_ts": L.append("inbound %s %s port=%s clients=%s enc=%s sni=%s"%(k,v.get("protocol"),v.get("port"),v.get("clients"),(v.get("encryption") or "none")[:40],v.get("sni")))
        L.append("3x-ui clients: %d"%len(xui(s,10).clients_list()))
    except Exception as e: L.append("3x-ui ERROR: %s"%e)
    try:
        with db() as c:
            L.append("DB clients=%s regs=%s plans=%s promos=%s"%(c.execute("SELECT COUNT(*) FROM clients").fetchone()[0],
                c.execute("SELECT COUNT(*) FROM registrations").fetchone()[0],c.execute("SELECT COUNT(*) FROM plans").fetchone()[0],
                c.execute("SELECT COUNT(*) FROM promos").fetchone()[0]))
            for r in c.execute("SELECT id,name,email,plan_id,paid_until,enabled,balance,http_port,inbound_id FROM clients LIMIT 25"):
                L.append("  #%s %s %s plan=%s paid=%s on=%s bal=%s http=%s ib=%s"%tuple(r))
    except Exception as e: L.append("db err %s"%e)
    for v in ["proxy-admin","proxy-web","proxy-bot","proxy-monitor"]:
        L.append("--- %s ---"%v); L.append(_run(f"journalctl -u {v} -n 12 --no-pager 2>&1 | tail -12",6))
    return "\n".join(L)
PY_COMMON

cat > xui_api.py <<'PY_XUI'
import json,secrets,time,uuid as U
import requests,urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

class XUIError(Exception):
    def __init__(s,m,code=0):
        super().__init__(m); s.status=code

_F={}; CD=60

def _j(v):
    if isinstance(v,str):
        try: return json.loads(v)
        except Exception: return {}
    return v or {}

class XUI:
    def __init__(s,base,user="",pw="",token="",timeout=15):
        s.base=(base or "").rstrip("/"); s.user=user; s.pw=pw; s.token=token; s.t=timeout
        s.s=requests.Session(); s.s.verify=False; s.csrf=None; s.ok=False

    def u(s,p): return s.base+"/"+p.lstrip("/")

    def login(s):
        if s.token: s.ok=True; return
        k=(s.base,s.user); un,err=_F.get(k,(0,""))
        if time.time()<un: raise XUIError("пауза после неудачного входа: "+err)
        cs=None
        try:
            j=s.s.get(s.u("/csrf-token"),timeout=s.t).json()
            if j.get("success"): cs=j.get("obj")
        except Exception: pass
        s.csrf=cs; ok=False; code=0; body=""
        for kw in ({"data":{"username":s.user,"password":s.pw}},{"json":{"username":s.user,"password":s.pw}}):
            try:
                h={"X-CSRF-Token":cs} if cs else {}
                r=s.s.post(s.u("/login"),headers=h,timeout=s.t,allow_redirects=False,**kw)
                code=r.status_code; body=r.text[:200]; ok=bool(r.json().get("success"))
            except Exception as e: body=str(e)[:200]
            if ok: break
        if not ok:
            _F[k]=(time.time()+CD,f"HTTP {code} {body}")
            raise XUIError(f"вход в 3x-ui не удался (HTTP {code}): {body}",code)
        _F.pop(k,None); s.ok=True

    def req(s,m,p,retry=True,headers=None,**kw):
        if not s.ok: s.login()
        orig=dict(headers or {}); h=dict(orig); h.setdefault("Accept","application/json")
        if s.token: h["Authorization"]="Bearer "+s.token
        if s.csrf and m.upper()!="GET": h["X-CSRF-Token"]=s.csrf
        try: r=s.s.request(m,s.u(p),headers=h,timeout=s.t,allow_redirects=False,**kw)
        except requests.RequestException as e: raise XUIError("сеть: %s"%e)
        if r.status_code in (401,403,302,307) and retry and not s.token:
            s.ok=False; return s.req(m,p,False,orig,**kw)
        try: j=r.json()
        except Exception:
            if retry and not s.token and r.status_code!=404:
                s.ok=False; return s.req(m,p,False,orig,**kw)
            raise XUIError("неожиданный ответ (HTTP %s) %s"%(r.status_code,p),r.status_code)
        if not j.get("success"): raise XUIError(str(j.get("msg") or j),r.status_code)
        return j.get("obj")

    def any(s,m,paths,**kw):
        last=None
        for p in paths:
            try: return s.req(m,p,**kw)
            except XUIError as e:
                last=e
                if e.status!=404: raise
        raise last

    def get_inbounds(s): return s.req("GET","/panel/api/inbounds/list") or []
    def get_inbound(s,i): return s.req("GET","/panel/api/inbounds/get/%s"%i)

    def clients_list(s):
        try: return s.req("GET","/panel/api/clients/list") or []
        except XUIError:
            out=[]
            for b in s.get_inbounds():
                for c in _j(b.get("settings")).get("clients",[]) or []:
                    c=dict(c); c.setdefault("uuid",c.get("id")); out.append(c)
            return out

    def find(s,email=None,cu=None):
        for c in s.clients_list():
            if email and str(c.get("email"))==str(email): return c
            if cu and (str(c.get("uuid"))==str(cu) or str(c.get("id"))==str(cu)): return c
        return None

    def add_client(s,inbound_id,email,client_uuid=None,total_gb=0,expiry_ms=0,enable=True,flow="xtls-rprx-vision"):
        cu=client_uuid or str(U.uuid4()); iid=int(inbound_id)
        try:
            st=_j(s.get_inbound(iid).get("settings"))
            if "mlkem768" in str(st.get("encryption") or ""): flow=""
        except Exception: pass
        flat={"email":email,"uuid":cu,"flow":flow,"limitIp":0,"totalGB":int(float(total_gb)*2**30),
              "expiryTime":int(expiry_ms),"enable":bool(enable),"tgId":0,"reset":0,"comment":"",
              "subId":secrets.token_hex(8),"inboundIds":[iid]}
        errs=[]
        for body in (flat,dict(flat,id=cu),{"client":flat,"inboundIds":[iid]}):
            try: s.req("POST","/panel/api/clients/add",json=body)
            except XUIError as e: errs.append(str(e)[:110]); continue
            if s.find(email=email,cu=cu): return cu
            errs.append("ok, но клиента нет в списке")
        leg={"id":iid,"settings":json.dumps({"clients":[dict(flat,id=cu)]})}
        for p in ("/panel/api/inbounds/addClient","/panel/api/inbounds/%s/addClient"%iid):
            try:
                s.req("POST",p,json=leg)
                if s.find(email=email,cu=cu): return cu
            except XUIError as e: errs.append(str(e)[:70])
        raise XUIError("создание клиента не удалось: "+" | ".join(errs))

    def update_client(s,inbound_id,cu,**ch):
        c=s.find(cu=cu)
        if not c: raise XUIError("клиент %s не найден"%cu)
        b=dict(c); b.update(ch); b.pop("traffic",None); b["inboundIds"]=c.get("inboundIds") or [int(inbound_id)]
        s.any("POST",["/panel/api/clients/update/%s"%c.get("email"),"/panel/api/clients/update/%s"%cu,
                      "/panel/api/inbounds/updateClient/%s"%cu],json=b)

    def del_client(s,inbound_id,cu):
        c=s.find(cu=cu); k=(c or {}).get("email") or cu
        s.any("POST",["/panel/api/clients/del/%s"%k,"/panel/api/inbounds/%s/delClient/%s"%(inbound_id,cu)])

    def reset_client_traffic(s,*a,**kw):
        iid=None; em=kw.get("email")
        for x in a:
            if isinstance(x,str) and not x.isdigit(): em=x
            else: iid=x
        s.any("POST",["/panel/api/clients/resetTraffic/%s"%em,"/panel/api/inbounds/%s/resetClientTraffic/%s"%(iid or 0,em)])

    def get_client_stats(s,*a,**kw):
        em=kw.get("email")
        if not em:
            for x in a:
                if isinstance(x,str) and not x.isdigit(): em=x
        if not em and a: em=str(a[-1])
        c=s.find(email=em)
        if c:
            t=c.get("traffic") or {}
            if isinstance(t,list): return {"up":sum(int(i.get("up") or 0) for i in t),"down":sum(int(i.get("down") or 0) for i in t)}
            return {"up":int(t.get("up") or 0),"down":int(t.get("down") or 0)}
        try: return s.any("GET",["/panel/api/clients/traffics/%s"%em,"/panel/api/inbounds/getClientTraffics/%s"%em])
        except XUIError: return {"up":0,"down":0}

    def add_http_inbound(s,port,user,pw,remark,total_bytes=0,expiry_ms=0,enable=True,tls_cert="",tls_key=""):
        ss={"network":"tcp","security":"none"}
        if tls_cert and tls_key:
            ss={"network":"tcp","security":"tls","tlsSettings":{"certificates":[{"certificateFile":tls_cert,"keyFile":tls_key}],"alpn":["http/1.1"],"minVersion":"1.2"}}
        s.req("POST","/panel/api/inbounds/add",json={"enable":bool(enable),"remark":remark,"listen":"","port":int(port),
            "protocol":"http","expiryTime":int(expiry_ms),"total":int(total_bytes),
            "settings":json.dumps({"accounts":[{"user":user,"pass":pw}],"allowTransparent":False}),
            "streamSettings":json.dumps(ss),"sniffing":json.dumps({"enabled":True,"destOverride":["http","tls"]})})
        for b in s.get_inbounds():
            if b.get("port")==int(port) and b.get("protocol")=="http": return b["id"]
        raise XUIError("http inbound не найден после создания")

    def update_inbound(s,b):
        p=dict(b)
        for k in ("settings","streamSettings","sniffing"):
            if not isinstance(p.get(k),str): p[k]=json.dumps(p.get(k) or {})
        p.pop("clientStats",None); s.req("POST","/panel/api/inbounds/update/%s"%b["id"],json=p)

    def reset_inbound_traffic(s,i): s.req("POST","/panel/api/inbounds/%s/resetTraffic"%i)
    def del_inbound(s,i): s.req("POST","/panel/api/inbounds/del/%s"%i)

    def status(s):
        try: return s.req("GET","/panel/api/server/status")
        except XUIError: return s.req("POST","/panel/api/server/status")

    def probe(s):
        try:
            if not s.ok: s.login()
        except Exception: pass
        out={}
        for p,ms in [("/panel/api/inbounds/list",("GET",)),("/panel/api/clients/list",("GET",)),
                     ("/panel/api/server/status",("GET",)),("/panel/api/clients/add",("POST",))]:
            r={}
            for m in ms:
                try:
                    h={"Accept":"application/json"}
                    if s.token: h["Authorization"]="Bearer "+s.token
                    if s.csrf and m=="POST": h["X-CSRF-Token"]=s.csrf
                    q=s.s.request(m,s.u(p),headers=h,json={} if m=="POST" else None,timeout=8,allow_redirects=False)
                    r[m]=str(q.status_code)+" "+q.text[:130].replace("\n"," ")
                except Exception as e: r[m]="err "+str(e)[:60]
            out[p]=r
        return out
PY_XUI

cat > admin_app.py <<'PY_ADMIN'
import asyncio,json,secrets,time,os,re,subprocess,shutil,tempfile,zipfile,py_compile,socket,uuid as U
from pathlib import Path
from urllib.parse import quote
from fastapi import FastAPI,Request
from fastapi.responses import RedirectResponse,JSONResponse,Response
from fastapi.templating import Jinja2Templates
from passlib.hash import bcrypt
import common as cm
from xui_api import XUIError

app=FastAPI(docs_url=None,redoc_url=None)
T=Jinja2Templates(directory=str(Path(__file__).parent/"templates"))
SES={}; TTL=12*3600

@app.on_event("startup")
def _st(): cm.init_db()

def auth(r):
    s=SES.get(r.cookies.get("pm_admin"))
    return s[0] if s and s[1]>time.time() else None

def rd(m="",to="/"): return RedirectResponse(to+("?msg="+quote(m) if m else ""),status_code=303)

def _regs():
    with cm.db() as c: return [dict(r) for r in c.execute("SELECT * FROM registrations ORDER BY id DESC LIMIT 100")]

T.env.globals.update(get_plans=cm.plans,get_plan=cm.plan,get_promos=cm.promos,
    get_regs=_regs,get_clients_full=cm.clients,load_json=json.loads,
    server_ip=cm.server_ip,cert_path=lambda: cm.tlspaths(cm.S())[0] or "нет",
    cert_ok=lambda: cm.cert_trusted(cm.S()),tls_on=lambda: cm.tlson(cm.S()))

@app.get("/login")
def lp(r:Request,msg:str=""): return T.TemplateResponse(r,"login.html",{"msg":msg})

@app.post("/login")
async def li(r:Request):
    f=await r.form(); u=str(f.get("username","")); p=str(f.get("password",""))
    with cm.db() as c: row=c.execute("SELECT * FROM admins WHERE username=?",(u,)).fetchone()
    if not row or not bcrypt.verify(p,row["password_hash"]):
        await asyncio.sleep(1); return rd("Неверный логин или пароль","/login")
    t=secrets.token_urlsafe(32); SES[t]=(u,time.time()+TTL)
    x=RedirectResponse("/",status_code=303); x.set_cookie("pm_admin",t,httponly=True,samesite="lax",max_age=TTL); return x

@app.get("/logout")
def lo(r:Request):
    SES.pop(r.cookies.get("pm_admin"),None); x=RedirectResponse("/login",status_code=303); x.delete_cookie("pm_admin"); return x

@app.get("/")
def dash(r:Request,msg:str=""):
    u=auth(r)
    if not u: return RedirectResponse("/login",status_code=303)
    s=cm.S(); cs=cm.clients()
    for c in cs:
        l=float(c["limit_gb"] or 0); c["used_gb"]=cm.gb(c["used_bytes"])
        c["percent"]=min(100,round(c["used_bytes"]/(l*2**30)*100)) if l>0 else 0
        c["paid_str"]=time.strftime("%d.%m.%Y",time.localtime(c["paid_until"])) if c["paid_until"] else "—"
    with cm.db() as con: sg=[dict(x) for x in con.execute("SELECT * FROM suggestions ORDER BY id DESC LIMIT 50")]
    return T.TemplateResponse(r,"admin.html",{"s":s,"clients":cs,"suggestions":sg,"msg":msg,"user":u})

@app.post("/settings")
async def st(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); up={}
    for k in cm.DEF:
        if k in f: up[k]=str(f[k]).strip()
    for j in ("ext_presets","ext_lists"):
        if j in up:
            try: json.loads(up[j])
            except Exception: return rd(f"{j}: невалидный JSON")
    cm.setS(up); return rd("Настройки сохранены")

def _browser(c,s,x,notes):
    used={y["http_port"] for y in cm.clients()}
    port=next((p for p in range(int(s["http_port_start"]),int(s["http_port_end"])+1) if p not in used),None)
    if port is None: notes.append("нет свободных портов"); return
    c["http_port"]=port; c["http_user"]="u"+cm.rnd(6); c["http_pass"]=secrets.token_hex(8)
    cert,key=cm.tlspaths(s) if cm.tlson(s) else ("","")
    try: c["http_inbound_id"]=x.add_http_inbound(port,c["http_user"],c["http_pass"],"browser-"+c["email"],tls_cert=cert,tls_key=key)
    except Exception as e: notes.append("HTTP: %s"%e); c["http_port"]=0; c["http_inbound_id"]=0

def _ins(c):
    with cm.db() as con:
        cur=con.execute("INSERT INTO clients(tg_id,name,email,uuid,balance,limit_gb,used_bytes,enabled,notified,paid_until,"
            "ext_key,http_port,http_user,http_pass,http_inbound_id,inbound_id,plan_id,sub_id,access_code) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (c["tg_id"],c["name"],c["email"],c["uuid"],c["balance"],c["limit_gb"],0,1,0,0,c["ext_key"],c["http_port"],
             c["http_user"],c["http_pass"],c["http_inbound_id"],c.get("inbound_id",0),0,cm.rnd(16),cm.rnd(6,True)))
        c["id"]=cur.lastrowid
        r=con.execute("SELECT sub_id,access_code FROM clients WHERE id=?",(c["id"],)).fetchone()
        c["sub_id"]=r["sub_id"]; c["access_code"]=r["access_code"]

@app.post("/clients/add")
async def ca(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); tg=str(f.get("tg_id","")).strip() or "u_"+cm.rnd(8)
    nm=str(f.get("name","")).strip(); em=str(f.get("email","")).strip()
    if not nm or not em: return rd("Заполните имя и email")
    if cm.client(tg_id=tg) or cm.client(email=em): return rd("tg_id или email уже заняты")
    s=cm.S()
    try:
        bal=float(f.get("balance",0) or 0); lim=float(f.get("limit_gb",0) or 0); ibid=int(f.get("inbound_id",0) or 0)
    except ValueError: return rd("Числа введены неверно")
    c={"tg_id":tg,"name":nm,"email":em,"uuid":str(U.uuid4()),"balance":bal,"limit_gb":lim,"used_bytes":0,
       "enabled":1,"notified":0,"paid_until":0,"ext_key":cm.rnd(8,True),"inbound_id":ibid,"plan_id":0,
       "http_port":0,"http_user":"","http_pass":"","http_inbound_id":0}
    x=cm.xui(s); notes=[]
    try: x.add_client(cm.ib(c,s),em,client_uuid=c["uuid"],total_gb=lim)
    except Exception as e: notes.append("VLESS: %s"%e)
    if f.get("browser"): _browser(c,s,x,notes)
    _ins(c); cm.activate(c,s,x)
    cm.tg(s,tg,f"👋 Доступ создан.\nКабинет: {cm.cab(c,s)}\nКод входа: {c['access_code']}\nКлюч: {c['ext_key']}")
    return rd("Клиент добавлен. "+"; ".join(notes))

@app.post("/clients/{cid}/topup")
async def tp(r:Request,cid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    c=cm.client(id=cid)
    if not c: return rd("Клиент не найден")
    f=await r.form()
    try: a=float(f.get("amount",0) or 0)
    except ValueError: a=0
    if a<=0: return rd("Сумма > 0")
    with cm.db() as con:
        con.execute("UPDATE clients SET balance=ROUND(balance+?,2) WHERE id=?",(a,cid))
        con.execute("INSERT INTO payments(tg_id,amount,source,status) VALUES(?,?,?,?)",(c["tg_id"],a,"admin","paid"))
    c=cm.client(id=cid); s=cm.S(); res=cm.activate(c,s,cm.xui(s))
    cm.tg(s,c["tg_id"],f"💰 +{a:.2f} ₽. Баланс: {c['balance']:.2f} ₽"); return rd("Пополнено. "+res)

@app.post("/clients/{cid}/reset")
def rs(r:Request,cid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    c=cm.client(id=cid)
    if not c: return rd("Нет клиента")
    s=cm.S(); x=cm.xui(s); n=[]
    try: cm.reset(c,s,x)
    except Exception as e: n.append(str(e))
    c["used_bytes"]=0; c["notified"]=0
    return rd("Трафик сброшен. "+cm.activate(c,s,x)+"; ".join(n))

@app.post("/clients/{cid}/toggle")
def tgl(r:Request,cid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    c=cm.client(id=cid)
    if not c: return rd("Нет клиента")
    c["enabled"]=0 if c["enabled"] else 1
    with cm.db() as con: con.execute("UPDATE clients SET enabled=? WHERE id=?",(c["enabled"],cid))
    s=cm.S(); n=""
    try: cm.sync(c,s,cm.xui(s))
    except Exception as e: n=" (3x-ui: %s)"%e
    return rd(("Включён" if c["enabled"] else "Отключён")+n)

@app.post("/clients/{cid}/sync")
def sy(r:Request,cid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    c=cm.client(id=cid)
    if not c: return rd("Нет клиента")
    s=cm.S(); x=cm.xui(s)
    try: cm.sync(c,s,x)
    except XUIError:
        try:
            x.add_client(cm.ib(c,s),c["email"],client_uuid=c["uuid"],total_gb=c["limit_gb"]); cm.sync(c,s,x)
        except Exception as e: return rd("Ошибка: %s"%e)
    except Exception as e: return rd("Ошибка: %s"%e)
    return rd("Синхронизировано")

@app.post("/clients/{cid}/delete")
def dl(r:Request,cid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    c=cm.client(id=cid)
    if not c: return rd("Нет клиента")
    s=cm.S(); x=cm.xui(s); n=[]
    try: x.del_client(cm.ib(c,s),c["uuid"])
    except Exception as e: n.append(str(e))
    if c["http_inbound_id"]:
        try: x.del_inbound(c["http_inbound_id"])
        except Exception as e: n.append(str(e))
    with cm.db() as con: con.execute("DELETE FROM clients WHERE id=?",(cid,))
    return rd("Удалён. "+"; ".join(n))

@app.post("/clients/{cid}/browser")
def br(r:Request,cid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    c=cm.client(id=cid)
    if not c: return rd("Нет клиента")
    if c["http_inbound_id"]: return rd("Уже есть")
    s=cm.S(); n=[]; _browser(c,s,cm.xui(s),n)
    with cm.db() as con:
        con.execute("UPDATE clients SET http_port=?,http_user=?,http_pass=?,http_inbound_id=? WHERE id=?",
            (c["http_port"],c["http_user"],c["http_pass"],c["http_inbound_id"],cid))
    return rd("Браузер-прокси: порт %s. %s"%(c["http_port"],"; ".join(n)))

@app.post("/clients/{cid}/code")
async def cd(r:Request,cid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); v=str(f.get("code","")).strip().upper() or cm.rnd(6,True)
    with cm.db() as con: con.execute("UPDATE clients SET access_code=? WHERE id=?",(v,cid))
    return rd("Код: "+v)

@app.post("/clients/{cid}/codeoff")
def co(r:Request,cid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    with cm.db() as con: con.execute("UPDATE clients SET access_code='' WHERE id=?",(cid,))
    return rd("Защита кабинета отключена")

@app.post("/clients/{cid}/setplan/{pid}")
def sp(r:Request,cid:int,pid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    c=cm.client(id=cid); p=cm.plan(pid)
    if not c or not p: return rd("Нет клиента/тарифа")
    s=cm.S(); ok,m=cm.applyplan(c,p,s,cm.xui(s),free=True); return rd(m)

@app.post("/security")
async def sec(r:Request):
    u=auth(r)
    if not u: return RedirectResponse("/login",status_code=303)
    f=await r.form(); o,n,n2=str(f.get("old","")),str(f.get("new","")),str(f.get("new2",""))
    with cm.db() as con: row=con.execute("SELECT * FROM admins WHERE username=?",(u,)).fetchone()
    if not row or not bcrypt.verify(o,row["password_hash"]): return rd("Старый пароль неверен")
    if len(n)<6 or n!=n2: return rd("Минимум 6 символов, поля должны совпадать")
    with cm.db() as con: con.execute("UPDATE admins SET password_hash=? WHERE username=?",(bcrypt.hash(n),u))
    SES.clear(); return RedirectResponse("/login?msg="+quote("Пароль изменён"),status_code=303)

@app.get("/api/xui_status")
def xs(r:Request):
    if not auth(r): return JSONResponse({"ok":False},status_code=401)
    s=cm.S()
    try:
        st=cm.xui(s,6).status() or {}; x=st.get("xray") or {}
        return {"ok":True,"xray":x.get("state","?"),"cpu":round(float(st.get("cpu",0)),1)}
    except Exception as e: return {"ok":False,"error":str(e)}

@app.get("/xui/inbounds")
def xi(r:Request):
    if not auth(r): return JSONResponse({"ok":False},status_code=401)
    s=cm.S()
    try:
        ca=cm.ibcache(s,True)
        return {"ok":True,"inbounds":[dict(v,id=k) for k,v in ca.items() if k!="_ts" and v.get("protocol")=="vless"]}
    except Exception as e: return {"ok":False,"error":str(e)}

@app.post("/xui/autoconfig")
async def ac(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); s=cm.S()
    try: ibs=cm.xui(s,10).get_inbounds()
    except Exception as e: return rd("3x-ui недоступен: %s"%e)
    vl=[b for b in ibs if b.get("protocol")=="vless"]
    if not vl: return rd("Нет VLESS inbound")
    cm.ibcache(s,True); pick=str(f.get("inbound_id","")).strip()
    ch=next((b for b in vl if str(b.get("id"))==pick),None) if pick else None
    if ch is None:
        def ncl(b):
            st=b.get("settings")
            if isinstance(st,str):
                try: st=json.loads(st)
                except Exception: st={}
            return len((st or {}).get("clients") or [])
        ch=max(vl,key=ncl)
    ca=cm.ibcache(s); p=ca.get(str(ch["id"])) or {}
    up={"inbound_id":str(ch["id"]),"vless_port":str(p.get("port") or ch.get("port"))}
    for k,v in (("sni",p.get("sni")),("reality_pbk",p.get("pbk")),("reality_sid",p.get("sid")),("fp",p.get("fp"))):
        if v: up[k]=v
    cm.setS(up); return rd(f"Готово: inbound №{ch['id']}, порт {up['vless_port']}, SNI {up.get('sni','—')}")

@app.post("/clients/import")
async def im(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); s=cm.S()
    try: src=int(f.get("inbound_id",0) or 0) or int(s["inbound_id"])
    except ValueError: src=int(s["inbound_id"])
    try: cl=cm.xui(s,15).clients_list()
    except Exception as e: return rd("Ошибка чтения: %s"%e)
    add=skip=0
    for c in cl:
        em=str(c.get("email") or "").strip(); cu=str(c.get("uuid") or c.get("id") or "")
        if not em or cm.client(email=em) or (cu and cm.client(uuid=cu)): skip+=1; continue
        tot=int(c.get("totalGB") or 0); exp=int(c.get("expiryTime") or 0)
        t=c.get("traffic") or {}; used=int(t.get("up") or 0)+int(t.get("down") or 0) if isinstance(t,dict) else 0
        tg=str(c.get("tgId") or "").strip()
        if not tg or tg=="0" or cm.client(tg_id=tg): tg="imp_"+cm.rnd(8)
        with cm.db() as con:
            con.execute("INSERT INTO clients(tg_id,name,email,uuid,balance,limit_gb,used_bytes,enabled,notified,paid_until,ext_key,inbound_id,sub_id,access_code) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (tg,em,em,cu or str(U.uuid4()),0,round(tot/2**30,2) if tot else 0,used,1 if c.get("enable",True) else 0,0,
                 exp//1000 if exp>0 else 0,cm.rnd(8,True),src,cm.rnd(16),cm.rnd(6,True)))
        add+=1
    return rd(f"Импорт из №{src}: добавлено {add}, пропущено {skip}")

@app.post("/registrations/{rid}/approve")
async def ra(r:Request,rid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form()
    with cm.db() as con: row=con.execute("SELECT * FROM registrations WHERE id=?",(rid,)).fetchone()
    if not row: return rd("Заявка не найдена")
    if row["status"]!="pending": return rd("Уже обработана")
    g=dict(row); s=cm.S()
    try:
        bal=float(f.get("balance",0) or 0); lim=float(f.get("limit_gb",0) or 0)
        ibid=int(f.get("inbound_id",0) or 0); pid=int(f.get("plan_id",0) or 0)
    except ValueError: bal=lim=ibid=pid=0
    p=cm.plan(pid)
    if p: lim=float(p["limit_gb"] or 0)
    dg=re.sub(r"\D","",g["phone"]); em="u"+(dg or cm.rnd(6))
    while cm.client(email=em): em="u"+cm.rnd(6)
    tg=g["tg_id"] or "u_"+cm.rnd(8)
    if cm.client(tg_id=tg): tg="u_"+cm.rnd(8)
    c={"tg_id":tg,"name":g["name"],"email":em,"uuid":str(U.uuid4()),"balance":bal,"limit_gb":lim,"used_bytes":0,
       "enabled":1,"notified":0,"paid_until":0,"ext_key":cm.rnd(8,True),"inbound_id":ibid,"plan_id":0,
       "http_port":0,"http_user":"","http_pass":"","http_inbound_id":0}
    x=cm.xui(s); n=[]
    try: x.add_client(cm.ib(c,s),em,client_uuid=c["uuid"],total_gb=lim)
    except Exception as e: n.append("VLESS: %s"%e)
    if f.get("browser"): _browser(c,s,x,n)
    _ins(c)
    with cm.db() as con: con.execute("UPDATE registrations SET status='approved',client_id=?,decided_at=datetime('now') WHERE id=?",(c["id"],rid))
    if p: cm.applyplan(c,p,s,x,notify=False,free=True); c=cm.client(id=c["id"])
    else: cm.activate(c,s,x)
    if g["tg_id"]: cm.tg(s,g["tg_id"],f"✅ Одобрено!\nКабинет: {cm.cab(c,s)}\nКод: {c['access_code']}\nКлюч: {c['ext_key']}")
    return rd("Одобрено: "+c["email"]+"; ".join(n))

@app.post("/registrations/{rid}/reject")
def rj(r:Request,rid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    with cm.db() as con:
        row=con.execute("SELECT * FROM registrations WHERE id=?",(rid,)).fetchone()
        if row and row["status"]=="pending": con.execute("UPDATE registrations SET status='rejected',decided_at=datetime('now') WHERE id=?",(rid,))
    if row and row["tg_id"]: cm.tg(cm.S(),row["tg_id"],"❌ Заявка отклонена")
    return rd("Отклонена")

@app.post("/registrations/{rid}/delete")
def rdel(r:Request,rid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    with cm.db() as con: con.execute("DELETE FROM registrations WHERE id=?",(rid,))
    return rd("Заявка удалена")

@app.post("/registrations/clear")
def rcl(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    with cm.db() as con: n=con.execute("DELETE FROM registrations WHERE status!='pending'").rowcount
    return rd("Удалено: %s"%n)

@app.post("/plans/add")
async def pa(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); nm=str(f.get("name","")).strip()
    if not nm: return rd("Название обязательно")
    try: pr=float(f.get("price",0) or 0); dy=int(f.get("period_days",30) or 30); lm=float(f.get("limit_gb",0) or 0)
    except ValueError: return rd("Числа неверны")
    with cm.db() as con: con.execute("INSERT INTO plans(name,price,period_days,limit_gb,description,sort_order) VALUES(?,?,?,?,?,?)",(nm,pr,dy,lm,str(f.get("description","")).strip(),100))
    return rd("Тариф добавлен")

@app.post("/plans/{pid}/save")
async def psv(r:Request,pid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form()
    try: pr=float(f.get("price",0) or 0); dy=int(f.get("period_days",30) or 30); lm=float(f.get("limit_gb",0) or 0)
    except ValueError: return rd("Числа неверны")
    with cm.db() as con: con.execute("UPDATE plans SET name=?,price=?,period_days=?,limit_gb=?,description=? WHERE id=?",(str(f.get("name","")).strip(),pr,dy,lm,str(f.get("description","")).strip(),pid))
    return rd("Сохранено")

@app.post("/plans/{pid}/toggle")
def pt(r:Request,pid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    with cm.db() as con: con.execute("UPDATE plans SET enabled=1-enabled WHERE id=?",(pid,))
    return rd("Переключено")

@app.post("/plans/{pid}/delete")
def pd(r:Request,pid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    with cm.db() as con:
        con.execute("DELETE FROM plans WHERE id=?",(pid,)); con.execute("UPDATE clients SET plan_id=0 WHERE plan_id=?",(pid,))
    return rd("Тариф удалён")

@app.post("/promos/add")
async def pra(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form()
    try: v=float(f.get("value",0) or 0); mx=int(f.get("max_uses",0) or 0); vd=int(f.get("valid_days",0) or 0)
    except ValueError: return rd("Числа неверны")
    ok,m=cm.mkpromo(f.get("code",""),str(f.get("kind","balance")),v,mx,cm.now()+vd*86400 if vd>0 else 0,str(f.get("note","")))
    return rd(m)

@app.post("/promos/{pid}/toggle")
def prt(r:Request,pid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    with cm.db() as con: con.execute("UPDATE promos SET enabled=1-enabled WHERE id=?",(pid,))
    return rd("Переключено")

@app.post("/promos/{pid}/delete")
def prd(r:Request,pid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    with cm.db() as con: con.execute("DELETE FROM promos WHERE id=?",(pid,))
    return rd("Удалено")

@app.post("/presets/add")
async def psa(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); nm=str(f.get("name","")).strip()[:40]; ds=cm.domains(f.get("domains",""))
    if not nm or not ds: return rd("Нужны название и домены вида example.com")
    s=cm.S()
    try: pr=json.loads(s["ext_presets"] or "{}")
    except Exception: pr={}
    pr[nm]=sorted(set(pr.get(nm,[])+ds)); cm.setS({"ext_presets":json.dumps(pr,ensure_ascii=False)})
    return rd(f"Пресет «{nm}»: {len(pr[nm])} доменов")

@app.post("/presets/delete")
async def psd(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); s=cm.S()
    try: pr=json.loads(s["ext_presets"] or "{}")
    except Exception: pr={}
    pr.pop(str(f.get("name","")),None); cm.setS({"ext_presets":json.dumps(pr,ensure_ascii=False)}); return rd("Пресет удалён")

@app.post("/suggestions/{sid}/approve")
def sga(r:Request,sid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    s=cm.S()
    with cm.db() as con:
        row=con.execute("SELECT * FROM suggestions WHERE id=?",(sid,)).fetchone()
        if row:
            pr=json.loads(s["ext_presets"] or "{}"); ds=[d.strip() for d in (row["domains"] or "").split(",") if d.strip()]
            pr[row["name"]]=sorted(set(pr.get(row["name"],[])+ds)); cm.setS({"ext_presets":json.dumps(pr,ensure_ascii=False)})
            con.execute("DELETE FROM suggestions WHERE id=?",(sid,))
    return rd("Пресет обновлён")

@app.post("/suggestions/{sid}/delete")
def sgd(r:Request,sid:int):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    with cm.db() as con: con.execute("DELETE FROM suggestions WHERE id=?",(sid,))
    return rd("Удалено")

@app.post("/webhook/payment")
async def wh(r:Request):
    try: d=await r.json()
    except Exception: return JSONResponse({"ok":False,"error":"bad json"},status_code=400)
    s=cm.S(); tg=str(d.get("tg_id","")); a=d.get("amount",0)
    if not cm.sign_ok(s["billing_secret"],tg,a,d.get("sign","")): return JSONResponse({"ok":False,"error":"bad sign"},status_code=403)
    try: a=float(a)
    except Exception: return JSONResponse({"ok":False,"error":"bad amount"},status_code=400)
    c=cm.client(tg_id=tg)
    if not c or a<=0: return JSONResponse({"ok":False,"error":"client/amount"},status_code=400)
    eid=str(d.get("payment_id",""))
    with cm.db() as con:
        if eid and con.execute("SELECT 1 FROM payments WHERE external_id=? AND source='webhook'",(eid,)).fetchone():
            return {"ok":True,"duplicate":True}
        con.execute("UPDATE clients SET balance=ROUND(balance+?,2) WHERE id=?",(a,c["id"]))
        con.execute("INSERT INTO payments(tg_id,amount,source,status,external_id) VALUES(?,?,?,?,?)",(tg,a,"webhook","paid",eid))
    c=cm.client(tg_id=tg); cm.activate(c,s,cm.xui(s)); cm.tg(s,tg,f"💰 Оплата {a:.2f} ₽")
    return {"ok":True,"balance":c["balance"]}

@app.post("/proxy/tls_all")
def tlsall(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    s=cm.S(); cert,key=cm.tlspaths(s)
    if not cert: return rd("Сертификат не найден")
    if not cm.cert_trusted(s):
        return rd("Сертификат самоподписанный — Chrome не примет его для HTTPS-прокси. Сначала получи Let's Encrypt во вкладке «Домен и HTTPS».")
    x=cm.xui(s); ok=0; er=[]
    for c in cm.clients():
        if not c["http_inbound_id"]: continue
        try:
            b=x.get_inbound(c["http_inbound_id"]); ss=b.get("streamSettings")
            if isinstance(ss,str): ss=json.loads(ss or "{}")
            ss=dict(ss or {}); ss["security"]="tls"; ss.pop("realitySettings",None)
            ss["tlsSettings"]={"certificates":[{"certificateFile":cert,"keyFile":key}],"alpn":["http/1.1"],"minVersion":"1.2"}
            b["streamSettings"]=ss; x.update_inbound(b); ok+=1
        except Exception as e: er.append(str(e)[:60])
    return rd(f"TLS включён на {ok} прокси. "+"; ".join(er))

@app.post("/proxy/tls_off")
def tlsoff(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    s=cm.S(); x=cm.xui(s); ok=0
    for c in cm.clients():
        if not c["http_inbound_id"]: continue
        try:
            b=x.get_inbound(c["http_inbound_id"]); ss=b.get("streamSettings")
            if isinstance(ss,str): ss=json.loads(ss or "{}")
            ss=dict(ss or {}); ss["security"]="none"; ss.pop("tlsSettings",None); ss.pop("realitySettings",None)
            b["streamSettings"]=ss; x.update_inbound(b); ok+=1
        except Exception: pass
    return rd(f"TLS снят с {ok} прокси (обычный HTTP)")

@app.post("/guest/toggle")
def gt(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    s=cm.S(); cm.setS({"guest_enabled":"0" if s.get("guest_enabled")=="1" else "1"}); return rd("Гостевой доступ переключён")

@app.post("/guest/rotate")
def gr(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    cm.setS({"guest_token":secrets.token_urlsafe(24),"guest_enabled":"0"}); return rd("Токен обновлён, доступ выключен")

@app.get("/api/diagnostics")
def dg(r:Request):
    if not auth(r): return JSONResponse({"ok":False},status_code=401)
    return {"ok":True,"report":cm.report()}

@app.get("/api/probe")
def pb(r:Request):
    if not auth(r): return JSONResponse({"ok":False},status_code=401)
    try: return {"ok":True,"routes":cm.xui(cm.S(),10).probe()}
    except Exception as e: return {"ok":False,"error":str(e)}

RES="/opt/proxy-manager/update_result.txt"

@app.post("/update/upload")
async def uu(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); up=f.get("file")
    if up is None or not getattr(up,"filename",""): return rd("Файл не выбран")
    data=await up.read(); nm=up.filename; tmp=tempfile.mkdtemp(prefix="pmu_"); files={}
    try:
        if nm.endswith(".zip"):
            zp=os.path.join(tmp,"u.zip"); open(zp,"wb").write(data)
            with zipfile.ZipFile(zp) as z:
                for n in z.namelist():
                    if n.endswith("/") or ".." in n or n.startswith("/"): continue
                    files[n]=z.read(n)
        else: files[nm]=data
        if not files: return rd("Пустой архив")
        errs=[]
        for n,b in files.items():
            tp=os.path.join(tmp,"chk_"+n.replace("/","_")); open(tp,"wb").write(b)
            if n.endswith(".py"):
                try: py_compile.compile(tp,doraise=True)
                except Exception as e: errs.append(f"{n}: {e}")
            if n.endswith(".html"):
                try:
                    from jinja2 import Environment
                    Environment().parse(b.decode("utf-8","replace"))
                except Exception as e: errs.append(f"{n}: {e}")
        if errs:
            open(RES,"w").write("ОШИБКА ПРОВЕРКИ:\n"+"\n".join(errs)); return rd("Отклонено: "+"; ".join(errs)[:300])
        bd="/opt/proxy-manager/backups/"+time.strftime("%Y%m%d_%H%M%S"); os.makedirs(bd,exist_ok=True)
        for n in files:
            d0=os.path.join("/opt/proxy-manager",n)
            if os.path.exists(d0):
                bp=os.path.join(bd,n); os.makedirs(os.path.dirname(bp),exist_ok=True); shutil.copy2(d0,bp)
        for n,b in files.items():
            d0=os.path.join("/opt/proxy-manager",n); os.makedirs(os.path.dirname(d0),exist_ok=True); open(d0,"wb").write(b)
        open(RES,"w").write("ПРИМЕНЯЕТСЯ…")
        sc=("sleep 1; systemctl restart proxy-admin proxy-web proxy-bot proxy-monitor; sleep 6; "
            "A=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8003/login); "
            "B=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8002/); "
            f"if [ \"$A\" = 200 ] && [ \"$B\" = 200 ]; then echo \"УСПЕХ admin=$A web=$B\" > {RES}; "
            f"else cp -rf {bd}/* /opt/proxy-manager/ 2>/dev/null; systemctl restart proxy-admin proxy-web proxy-bot proxy-monitor; "
            f"{{ echo \"ОШИБКА admin=$A web=$B — откат\"; journalctl -u proxy-admin -n 25 --no-pager; }} > {RES}; fi")
        subprocess.Popen(["bash","-c",sc],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        return rd("Применено, перезапуск. Жми «Статус» через 10 сек")
    except Exception as e:
        open(RES,"w").write("ОШИБКА: %s"%e); return rd("Ошибка: %s"%e)

@app.get("/update/status")
def us(r:Request):
    if not auth(r): return JSONResponse({"ok":False},status_code=401)
    try: return {"ok":True,"text":open(RES).read()}
    except Exception: return {"ok":True,"text":"Обновлений не было"}

@app.get("/extension.zip")
def ez(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    s=cm.S(); return Response(cm.extzip(s,s.get("domain") or r.url.hostname),media_type="application/zip",
        headers={"Content-Disposition":"attachment; filename=proxy-manager-extension.zip"})

# ================= ДОМЕН И HTTPS =================
NETLOG="/opt/proxy-manager/net_result.txt"
CERTLOG="/opt/proxy-manager/cert_result.txt"

@app.post("/net/apply")
async def net_apply(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form()
    dom=re.sub(r"^https?://","",str(f.get("domain","")).strip().lower()).split("/")[0]
    cm.setS({"domain":dom,"tls_cert":str(f.get("tls_cert","")).strip(),
             "tls_key":str(f.get("tls_key","")).strip(),"le_email":str(f.get("le_email","")).strip()})
    open(NETLOG,"w").write("ПРИМЕНЯЕТСЯ…")
    subprocess.Popen(["bash","-c",f"bash {cm.BASE}/net-setup.sh > {NETLOG} 2>&1"],
                     stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return rd("Применяю. Нажми «Статус сети» через 5 сек. Адрес админки мог измениться!")

@app.get("/net/status")
def net_status(r:Request):
    if not auth(r): return JSONResponse({"ok":False},status_code=401)
    s=cm.S(); c,k=cm.tlspaths(s)
    info=(f"IP сервера: {cm.server_ip()}\nДомен: {s.get('domain') or '(не задан)'}\n"
          f"Сертификат: {c or 'нет'}\nВалидный (не self-signed): {cm.cert_trusted(s)}\n"
          f"Шифрованный браузер-прокси активен: {cm.tlson(s)}\n"
          f"Кабинет: {s.get('public_url')}\nАдминка: {s.get('admin_url')}\n")
    try: info+="\n--- последний запуск ---\n"+open(NETLOG).read()
    except Exception: info+="\n(настроек сети ещё не применяли)"
    return {"ok":True,"text":info}

@app.post("/net/cert")
async def net_cert(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    s=cm.S(); d=(s.get("domain") or "").strip()
    if not d: return rd("Сначала укажи домен и нажми «Применить и перенастроить»")
    ip=cm.server_ip()
    try: dip=socket.gethostbyname(d)
    except Exception: dip=None
    warn="" if dip==ip else f"\nВНИМАНИЕ: {d} -> {dip}, а IP сервера {ip}. Если DNS не обновился — выпуск не удастся.\n"
    em=(s.get("le_email") or "").strip()
    mail=f"-m {em}" if em else "--register-unsafely-without-email"
    open(CERTLOG,"w").write("ЗАПРОС ВЫПОЛНЯЕТСЯ…"+warn)
    sc=(f"{{ echo 'certbot для {d}'; "
        f"certbot certonly --webroot -w /var/www/certbot -d {d} --non-interactive --agree-tos {mail} "
        f"--deploy-hook 'systemctl reload nginx' 2>&1; "
        f"if [ -f /etc/letsencrypt/live/{d}/fullchain.pem ]; then echo 'СЕРТИФИКАТ ПОЛУЧЕН'; "
        f"bash {cm.BASE}/net-setup.sh 2>&1; "
        f"else echo 'НЕ УДАЛОСЬ. Проверь: домен указывает на {ip}, порт 80 открыт.'; fi; }} > {CERTLOG} 2>&1")
    subprocess.Popen(["bash","-c",sc],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return rd("Запрос запущен. «Статус сертификата» через 15-30 сек."+warn)

@app.get("/net/certstatus")
def net_certstatus(r:Request):
    if not auth(r): return JSONResponse({"ok":False},status_code=401)
    try: return {"ok":True,"text":open(CERTLOG).read()}
    except Exception: return {"ok":True,"text":"Запросов ещё не было."}
PY_ADMIN

cat > web_app.py <<'PY_WEB'
import base64,json,re,time,secrets
from pathlib import Path
from urllib.parse import quote
from fastapi import FastAPI,Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse,JSONResponse,Response,PlainTextResponse
from fastapi.templating import Jinja2Templates
import common as cm

app=FastAPI(docs_url=None,redoc_url=None)
app.add_middleware(CORSMiddleware,allow_origins=["*"],allow_methods=["*"],allow_headers=["*"])
T=Jinja2Templates(directory=str(Path(__file__).parent/"templates"))

@app.on_event("startup")
def _s(): cm.init_db()

T.env.globals.update(qr=cm.qr,has_plan=cm.hasplan,get_plans=cm.plans,get_plan=cm.plan,mstat=cm.mstat)

def used(c,s):
    try:
        x=cm.xui(s,6); u=0; st=x.get_client_stats(c["email"])
        if st: u+=int(st.get("up",0))+int(st.get("down",0))
        if c["http_inbound_id"]:
            b=x.get_inbound(c["http_inbound_id"]); u+=int(b.get("up",0))+int(b.get("down",0))
        with cm.db() as con: con.execute("UPDATE clients SET used_bytes=? WHERE id=?",(u,c["id"]))
        return u
    except Exception: return c["used_bytes"]

@app.get("/")
def idx(r:Request,msg:str=""):
    s=cm.S(); cs=cm.clients()
    au=s.get("admin_url") or ("https://%s:8443"%cm.host(s))
    try: np=len(json.loads(s.get("ext_presets") or "{}"))
    except Exception: np=0
    return T.TemplateResponse(r,"landing.html",{"s":s,"msg":msg,"admin_url":au,"n_clients":len(cs),"n_presets":np})

@app.get("/login")
def lr(): return RedirectResponse("/#login")

@app.post("/login")
async def cl(r:Request):
    f=await r.form(); v=str(f.get("credential","")).strip()
    if not v: return RedirectResponse("/?msg="+quote("Введите ключ или телефон")+"#login",status_code=303)
    c=cm.client(ext_key=v.upper()) or cm.client(tg_id=v)
    if not c:
        d=re.sub(r"\D","",v)
        if d:
            with cm.db() as con:
                row=con.execute("SELECT client_id FROM registrations WHERE phone=? AND status='approved' AND client_id>0 ORDER BY id DESC LIMIT 1",(d,)).fetchone()
            if row: c=cm.client(id=row["client_id"])
    if not c: return RedirectResponse("/?msg="+quote("Клиент не найден. Проверьте ключ или подайте заявку.")+"#login",status_code=303)
    return RedirectResponse("/client/"+c["tg_id"],status_code=303)

@app.middleware("http")
async def guard(r:Request,nxt):
    p=r.url.path; s=cm.S()
    if p.startswith("/sub/"):
        sid=p.split("/")[2] if len(p.split("/"))>2 else ""
        c=cm.client(sub_id=sid) or cm.client(tg_id=sid)
        if not c: return PlainTextResponse("",status_code=404)
        ok,_=cm.allowed(c,s)
        if not ok: return PlainTextResponse("",status_code=403)
    if p.startswith("/client/") and not p.endswith("/unlock") and not p.endswith("/setcode"):
        tg=p.split("/")[2] if len(p.split("/"))>2 else ""
        c=cm.client(tg_id=tg)
        if c and c.get("access_code") and r.cookies.get("pm_c_"+tg)!=cm.cookie(c):
            return T.TemplateResponse(r,"lock.html",{"s":s,"c":c,"msg":r.query_params.get("msg","")})
    return await nxt(r)

@app.post("/client/{tg}/unlock")
async def ul(r:Request,tg:str):
    c=cm.client(tg_id=tg)
    if not c: return PlainTextResponse("нет",status_code=404)
    f=await r.form()
    if str(f.get("code","")).strip().upper()!=str(c.get("access_code","")).upper():
        return RedirectResponse(f"/client/{tg}?msg="+quote("Неверное кодовое слово"),status_code=303)
    x=RedirectResponse(f"/client/{tg}",status_code=303)
    x.set_cookie("pm_c_"+tg,cm.cookie(c),httponly=True,samesite="lax",path="/",max_age=30*86400); return x

@app.get("/enter/{tg}/{code}")
def ent(tg:str,code:str):
    c=cm.client(tg_id=tg)
    if not c: return PlainTextResponse("нет",status_code=404)
    if str(c.get("access_code") or "") and code.strip().upper()!=str(c["access_code"]).upper():
        return RedirectResponse(f"/client/{tg}?msg="+quote("Неверный код"),status_code=303)
    x=RedirectResponse(f"/client/{tg}",status_code=303)
    x.set_cookie("pm_c_"+tg,cm.cookie(c),httponly=True,samesite="lax",path="/",max_age=30*86400); return x

@app.get("/client/{tg}")
def cab(r:Request,tg:str,msg:str=""):
    c=cm.client(tg_id=tg)
    if not c: return PlainTextResponse("Клиент не найден",status_code=404)
    s=cm.S(); u=used(c,s); l=float(c["limit_gb"] or 0)
    return T.TemplateResponse(r,"client.html",{"c":c,"s":s,"msg":msg,"used_gb":cm.gb(u),
        "percent":min(100,round(u/(l*2**30)*100)) if l>0 else 0,
        "paid_str":time.strftime("%d.%m.%Y",time.localtime(c["paid_until"])) if c["paid_until"] else "—",
        "vless":cm.vless(c,s),"sub":cm.sub(c,s)})

@app.post("/client/{tg}/setcode")
async def sc(r:Request,tg:str):
    c=cm.client(tg_id=tg)
    if not c: return PlainTextResponse("нет",status_code=404)
    f=await r.form(); n=str(f.get("new","")).strip().upper()
    if len(n)<3: return RedirectResponse(f"/client/{tg}?msg="+quote("Минимум 3 символа"),status_code=303)
    with cm.db() as con: con.execute("UPDATE clients SET access_code=? WHERE id=?",(n,c["id"]))
    c["access_code"]=n
    x=RedirectResponse(f"/client/{tg}?msg="+quote("Код изменён"),status_code=303)
    x.set_cookie("pm_c_"+tg,cm.cookie(c),httponly=True,samesite="lax",path="/",max_age=30*86400); return x

@app.post("/client/{tg}/plan/{pid}")
def cp(tg:str,pid:int):
    c=cm.client(tg_id=tg)
    if not c: return PlainTextResponse("нет",status_code=404)
    s=cm.S(); p=cm.plan(pid)
    if not p or not p["enabled"]: return RedirectResponse(f"/client/{tg}?msg="+quote("Тариф не найден"),status_code=303)
    ok,m=cm.applyplan(c,p,s,cm.xui(s))
    return RedirectResponse(f"/client/{tg}?msg="+quote(m),status_code=303)

@app.post("/client/{tg}/promo")
async def cpr(r:Request,tg:str):
    c=cm.client(tg_id=tg)
    if not c: return PlainTextResponse("нет",status_code=404)
    f=await r.form(); s=cm.S(); ok,m=cm.applypromo(c,f.get("code",""),s,cm.xui(s))
    return RedirectResponse(f"/client/{tg}?msg="+quote(m),status_code=303)

@app.post("/client/{tg}/topup")
def ct(tg:str):
    c=cm.client(tg_id=tg)
    if not c: return PlainTextResponse("нет",status_code=404)
    s=cm.S()
    with cm.db() as con: con.execute("INSERT INTO payments(tg_id,amount,source,status) VALUES(?,?,?,?)",(tg,float(s["price"] or 0),"client","pending"))
    cm.tg(s,s.get("admin_tg_id"),f"💳 {c['name']} ({tg}) просит пополнение")
    return RedirectResponse(f"/client/{tg}?msg="+quote("Заявка на пополнение отправлена администратору"),status_code=303)

@app.get("/sub/{sid}")
def sb(sid:str):
    c=cm.client(sub_id=sid) or cm.client(tg_id=sid)
    if not c: return PlainTextResponse("",status_code=404)
    s=cm.S(); ok,_=cm.allowed(c,s)
    if not ok: return PlainTextResponse("",status_code=403)
    return PlainTextResponse(base64.b64encode(cm.vless(c,s).encode()).decode(),
        headers={"Profile-Title":base64.b64encode(s["panel_name"].encode()).decode(),
            "Subscription-Userinfo":f"upload=0; download={c['used_bytes']}; total={int(float(c['limit_gb'] or 0)*2**30)}; expire={c['paid_until']}"})

@app.get("/register")
def rg(r:Request,msg:str=""): return T.TemplateResponse(r,"register.html",{"s":cm.S(),"msg":msg})

@app.post("/register")
async def rgp(r:Request):
    f=await r.form(); nm=str(f.get("name","")).strip()[:60]; dg=re.sub(r"\D","",str(f.get("phone","")))
    em=str(f.get("email","")).strip()[:100]; cmt=str(f.get("comment","")).strip()[:300]
    if not nm or not (10<=len(dg)<=15): return RedirectResponse("/register?msg="+quote("Укажите имя и телефон (10-15 цифр)"),status_code=303)
    with cm.db() as con:
        ex=con.execute("SELECT code FROM registrations WHERE phone=? AND status IN ('pending','approved')",(dg,)).fetchone()
        if ex: return RedirectResponse("/register/status/"+ex["code"],status_code=303)
        code=cm.rnd(10,True); con.execute("INSERT INTO registrations(name,phone,email,comment,code) VALUES(?,?,?,?,?)",(nm,dg,em,cmt,code))
    s=cm.S(); cm.tg(s,s.get("admin_tg_id"),f"📝 Заявка: {nm}, {dg}. Код {code}")
    return RedirectResponse("/register/status/"+code,status_code=303)

@app.get("/register/status/{code}")
def rgs(r:Request,code:str):
    with cm.db() as con: row=con.execute("SELECT * FROM registrations WHERE code=?",(code.upper(),)).fetchone()
    if not row: return PlainTextResponse("Заявка не найдена",status_code=404)
    g=dict(row); s=cm.S(); c=cm.client(id=g["client_id"]) if g["client_id"] else None
    bu=s.get("bot_username","")
    if not bu and s.get("bot_token"):
        try:
            import requests
            j=requests.get("https://api.telegram.org/bot"+s["bot_token"]+"/getMe",timeout=5).json()
            if j.get("ok"): bu=j["result"]["username"]; cm.setS({"bot_username":bu})
        except Exception: pass
    return T.TemplateResponse(r,"reg_status.html",{"reg":g,"s":s,"client":c,
        "tg_link":f"https://t.me/{bu}?start=reg_{g['code']}" if bu else "","cabinet":cm.cab(c,s) if c else "",
        "code_word":c["access_code"] if c else ""})

def extc(key):
    c=cm.client(ext_key=str(key or "").strip().upper())
    if not c or not c["http_inbound_id"]: return None
    ok,_=cm.allowed(c,cm.S()); return c if ok else None

@app.get("/api/get_config")
def gc(key:str=""):
    c=extc(key)
    if not c: return JSONResponse({"success":False,"error":"Ключ недействителен или доступ не оплачен"},status_code=403)
    s=cm.S()
    try: pr=json.loads(s["ext_presets"] or "{}"); ls=json.loads(s["ext_lists"] or "{}")
    except Exception: pr,ls={},{}
    return {"base_config":{"host":cm.host(s),"port":c["http_port"],"use_auth":True,
        "scheme":"https" if cm.tlson(s) else "http","username":c["http_user"],"password":c["http_pass"],"name":s["panel_name"]},
        "catalog":{"presets":pr,"remote_lists":ls}}

@app.get("/api/ping")
def pg(key:str=""):
    return {"success":True} if extc(key) else JSONResponse({"success":False},status_code=403)

@app.post("/api/suggest_preset")
async def sp(r:Request):
    try: d=await r.json()
    except Exception: return JSONResponse({"success":False,"error":"Некорректный запрос"},status_code=400)
    c=extc(d.get("key"))
    if not c: return JSONResponse({"success":False,"error":"Ключ недействителен"},status_code=403)
    nm=re.sub(r"[^\wа-яА-ЯёЁ /-]","",str(d.get("name","")))[:40].strip()
    if not nm: return JSONResponse({"success":False,"error":"Укажите название"},status_code=400)
    ds=cm.domains(d.get("domains",""))
    if not ds: return JSONResponse({"success":False,"error":"Не найдено доменов. Формат: example.com, site.ru"},status_code=400)
    with cm.db() as con: con.execute("INSERT INTO suggestions(ext_key,name,domains) VALUES(?,?,?)",(c["ext_key"],nm,",".join(ds)))
    return {"success":True}

@app.get("/extension.zip")
def ez(r:Request):
    s=cm.S(); return Response(cm.extzip(s,s.get("domain") or r.url.hostname),media_type="application/zip",
        headers={"Content-Disposition":"attachment; filename=proxy-manager-extension.zip"})

@app.get("/guest/{t}")
def gu(t:str):
    s=cm.S()
    if s.get("guest_enabled")!="1" or t!=s.get("guest_token"): return PlainTextResponse("disabled",status_code=403)
    return PlainTextResponse(cm.report())

@app.get("/guest/{t}/probe")
def gp(t:str):
    s=cm.S()
    if s.get("guest_enabled")!="1" or t!=s.get("guest_token"): return PlainTextResponse("disabled",status_code=403)
    try: return JSONResponse(cm.xui(s,10).probe())
    except Exception as e: return JSONResponse({"error":str(e)})
PY_WEB

cat > bot.py <<'PY_BOT'
import asyncio,logging,time
from aiogram import Bot,Dispatcher,Router,F
from aiogram.filters import Command,CommandStart
from aiogram.types import Message,CallbackQuery
from aiogram.utils.keyboard import InlineKeyboardBuilder
import common as cm

logging.basicConfig(level=logging.INFO,format="%(asctime)s %(levelname)s %(message)s")
log=logging.getLogger("bot"); R=Router()

def S(): return cm.S()
def adm(u): return str(u)==str(S().get("admin_tg_id","")).strip()
def me(u): return cm.client(tg_id=str(u))

def kb():
    b=InlineKeyboardBuilder()
    for t,c in (("📊 Мой кабинет","me"),("💰 Тарифы","plans"),("🎁 Промокод","promo"),("🔑 Ключ и ссылки","key")):
        b.button(text=t,callback_data=c)
    b.adjust(1); return b.as_markup()

def pkb():
    b=InlineKeyboardBuilder()
    for p in cm.plans():
        l=("%g ГБ"%p["limit_gb"]) if p["limit_gb"] else "безлимит"
        b.button(text=f"{p['name']} · {p['price']:g}₽/{p['period_days']}д · {l}",callback_data="buy:%d"%p["id"])
    b.button(text="⬅️ Меню",callback_data="menu"); b.adjust(1); return b.as_markup()

def mtext(c,s):
    p=cm.cplan(c); l=("%g ГБ"%c["limit_gb"]) if c["limit_gb"] else "∞"
    u=time.strftime("%d.%m.%Y",time.localtime(c["paid_until"])) if c["paid_until"] else "—"
    return (f"📊 {c['name']}\n\nСтатус: {'🟢 активен' if c['enabled'] else '🔴 отключён'}\nБаланс: {c['balance']:.2f} ₽\n"
            f"Тариф: {p['name'] if p else 'не выбран'}\nТрафик: {cm.gb(c['used_bytes'])} / {l}\nОплачено до: {u}\n\n"
            f"🌐 Кабинет:\n{cm.cab(c,s)}\n🔐 Код входа: {c['access_code']}")

def ktext(c,s): return f"🔑 Ключ расширения:\n{c['ext_key']}\n\n📱 VLESS:\n{cm.vless(c,s)}\n\n🔄 Подписка:\n{cm.sub(c,s)}"

async def bind(m,code):
    code=(code or "").strip().upper()
    with cm.db() as con:
        row=con.execute("SELECT * FROM registrations WHERE code=?",(code,)).fetchone()
        if row: con.execute("UPDATE registrations SET tg_id=? WHERE id=?",(str(m.from_user.id),row["id"]))
    await m.answer("✅ Telegram подтверждён для заявки "+code if row else "❌ Заявка не найдена")

@R.message(CommandStart())
async def start(m:Message):
    s=S(); p=(m.text or "").split(maxsplit=1)
    if len(p)>1 and p[1].startswith("reg_"): await bind(m,p[1][4:]); return
    if adm(m.from_user.id):
        await m.answer("👋 Админ\n\n/status /stats /clients /regs\n/approve <id> [тариф] /reject <id>\n/topup <email|tg> <сумма>\n/on /off /reset <email>\n/plans /promos\n/newpromo <код> <balance|plan|days> <знач> [лимит] [дней]\n/settings"); return
    c=me(m.from_user.id)
    if c: await m.answer(mtext(c,s),reply_markup=kb())
    else: await m.answer(f"Вы не зарегистрированы.\nID: {m.from_user.id}\n\nЗаявка: {cm.pbase(s)}/register")

@R.message(Command("reg"))
async def reg(m:Message):
    p=(m.text or "").split(maxsplit=1)
    if len(p)>1: await bind(m,p[1])
    else: await m.answer("Использование: /reg КОД")

@R.message(Command("me"))
async def mme(m:Message):
    c=me(m.from_user.id)
    if c: await m.answer(mtext(c,S()),reply_markup=kb())
    else: await m.answer("Вы не зарегистрированы")

@R.message(Command("key"))
async def mkey(m:Message):
    c=me(m.from_user.id)
    if c: await m.answer(ktext(c,S()))
    else: await m.answer("Нет доступа")

@R.message(Command("plans"))
async def mpl(m:Message):
    ps=cm.plans()
    if not ps: await m.answer("Тарифы не настроены"); return
    t="💰 Тарифы:\n\n"+"".join(f"• {p['name']} — {p['price']:g} ₽ / {p['period_days']} дн. ({'%g ГБ'%p['limit_gb'] if p['limit_gb'] else 'безлимит'})\n" for p in ps)
    c=me(m.from_user.id)
    if c: await m.answer(t+f"\nБаланс: {c['balance']:.2f} ₽",reply_markup=pkb())
    else: await m.answer(t)

@R.message(Command("promo"))
async def mpr(m:Message):
    c=me(m.from_user.id)
    if not c: await m.answer("Сначала зарегистрируйтесь"); return
    p=(m.text or "").split(maxsplit=1)
    if len(p)<2: await m.answer("Использование: /promo КОД"); return
    s=S(); ok,msg=await asyncio.to_thread(cm.applypromo,c,p[1],s,cm.xui(s))
    await m.answer(("✅ " if ok else "❌ ")+msg,reply_markup=kb())

@R.callback_query(F.data.in_({"menu","me"}))
async def cme(q:CallbackQuery):
    c=me(q.from_user.id)
    if c:
        try: await q.message.edit_text(mtext(c,S()),reply_markup=kb())
        except Exception: pass
    await q.answer()

@R.callback_query(F.data=="plans")
async def cpl(q:CallbackQuery):
    c=me(q.from_user.id)
    try: await q.message.edit_text("💰 Выберите тариф:\nБаланс: %.2f ₽"%(c["balance"] if c else 0),reply_markup=pkb())
    except Exception: pass
    await q.answer()

@R.callback_query(F.data=="promo")
async def cpr2(q:CallbackQuery):
    await q.answer(); await q.message.answer("🎁 Отправьте: /promo КОД")

@R.callback_query(F.data=="key")
async def ck(q:CallbackQuery):
    c=me(q.from_user.id); await q.answer()
    if c: await q.message.answer(ktext(c,S()))

@R.callback_query(F.data.startswith("buy:"))
async def cbuy(q:CallbackQuery):
    c=me(q.from_user.id); p=cm.plan(q.data.split(":")[1])
    if not c or not p: await q.answer("Ошибка",show_alert=True); return
    b=InlineKeyboardBuilder(); b.button(text=f"✅ Подтвердить ({p['price']:g} ₽)",callback_data="ok:%d"%p["id"])
    b.button(text="⬅️ Назад",callback_data="plans"); b.adjust(1)
    try: await q.message.edit_text(f"Тариф «{p['name']}»\nЦена: {p['price']:g} ₽\nСрок: {p['period_days']} дн.\nБаланс: {c['balance']:.2f} ₽",reply_markup=b.as_markup())
    except Exception: pass
    await q.answer()

@R.callback_query(F.data.startswith("ok:"))
async def cok(q:CallbackQuery):
    c=me(q.from_user.id); p=cm.plan(q.data.split(":")[1])
    if not c or not p: await q.answer("Ошибка",show_alert=True); return
    await q.answer("Подключаю…"); s=S()
    ok,msg=await asyncio.to_thread(cm.applyplan,c,p,s,cm.xui(s))
    try: await q.message.edit_text(("✅ " if ok else "❌ ")+msg,reply_markup=kb())
    except Exception: await q.message.answer(msg,reply_markup=kb())

@R.message(Command("status"))
async def ast(m:Message):
    if not adm(m.from_user.id): return
    s=S()
    with cm.db() as c:
        n=c.execute("SELECT COUNT(*) FROM clients").fetchone()[0]
        a=c.execute("SELECT COUNT(*) FROM clients WHERE enabled=1").fetchone()[0]
        p=c.execute("SELECT COUNT(*) FROM registrations WHERE status='pending'").fetchone()[0]
    t=f"📊 Клиенты: {a}/{n}\n📝 Заявок: {p}\n"
    try:
        r=await asyncio.to_thread(cm.xui(s,8).status); x=(r or {}).get("xray",{})
        t+=f"🟢 xray {x.get('state','?')} {x.get('version','')}"
    except Exception as e: t+=f"🔴 3x-ui: {e}"
    await m.answer(t)

@R.message(Command("stats"))
async def astats(m:Message):
    if not adm(m.from_user.id): return
    with cm.db() as c:
        f=lambda q:c.execute(q).fetchone()[0]
        await m.answer("📈 Клиентов: %d (активных %d)\nБалансы: %.2f ₽\nПополнений: %.2f ₽\nСписаний: %.2f ₽\nЗаявок: %d\nТарифов: %d\nПромокодов: %d"%(
            f("SELECT COUNT(*) FROM clients"),f("SELECT COUNT(*) FROM clients WHERE enabled=1"),
            f("SELECT COALESCE(SUM(balance),0) FROM clients"),f("SELECT COALESCE(SUM(amount),0) FROM payments WHERE amount>0"),
            f("SELECT COALESCE(SUM(-amount),0) FROM payments WHERE amount<0"),f("SELECT COUNT(*) FROM registrations WHERE status='pending'"),
            f("SELECT COUNT(*) FROM plans"),f("SELECT COUNT(*) FROM promos")))

@R.message(Command("clients"))
async def acl(m:Message):
    if not adm(m.from_user.id): return
    cs=cm.clients()
    if not cs: await m.answer("Клиентов нет"); return
    t="\n".join(f"{'🟢' if c['enabled'] else '🔴'} {c['email']} | {c['name']} | {c['balance']:.0f}₽ | {cm.gb(c['used_bytes'])}GB" for c in cs)
    for i in range(0,len(t),3500): await m.answer(t[i:i+3500])

@R.message(Command("topup"))
async def atp(m:Message):
    if not adm(m.from_user.id): return
    p=(m.text or "").split()
    if len(p)<3: await m.answer("/topup <email|tg_id> <сумма>"); return
    c=cm.client(email=p[1]) or cm.client(tg_id=p[1])
    if not c: await m.answer("Не найден"); return
    try: a=float(p[2].replace(",","."))
    except ValueError: await m.answer("Сумма — число"); return
    with cm.db() as con:
        con.execute("UPDATE clients SET balance=ROUND(balance+?,2) WHERE id=?",(a,c["id"]))
        con.execute("INSERT INTO payments(tg_id,amount,source,status) VALUES(?,?,?,?)",(c["tg_id"],a,"bot","paid"))
    c=cm.client(id=c["id"]); s=S(); r=await asyncio.to_thread(cm.activate,c,s,cm.xui(s))
    cm.tg(s,c["tg_id"],f"💰 +{a:.2f} ₽"); await m.answer(f"✅ {c['email']}: +{a:.2f} ₽. {r}")

async def _sw(m,v):
    if not adm(m.from_user.id): return
    p=(m.text or "").split()
    if len(p)<2: await m.answer("/on или /off <email>"); return
    c=cm.client(email=p[1])
    if not c: await m.answer("Не найден"); return
    with cm.db() as con: con.execute("UPDATE clients SET enabled=? WHERE id=?",(v,c["id"]))
    c["enabled"]=v; s=S()
    try: await asyncio.to_thread(cm.sync,c,s,cm.xui(s))
    except Exception as e: await m.answer("⚠️ %s"%e)
    await m.answer(("🟢 включён " if v else "🔴 отключён ")+c["email"])

@R.message(Command("on"))
async def aon(m:Message): await _sw(m,1)

@R.message(Command("off"))
async def aoff(m:Message): await _sw(m,0)

@R.message(Command("reset"))
async def ars(m:Message):
    if not adm(m.from_user.id): return
    p=(m.text or "").split()
    if len(p)<2: await m.answer("/reset <email>"); return
    c=cm.client(email=p[1])
    if not c: await m.answer("Не найден"); return
    s=S(); x=cm.xui(s)
    try: await asyncio.to_thread(cm.reset,c,s,x)
    except Exception as e: await m.answer("⚠️ %s"%e)
    c["used_bytes"]=0; c["notified"]=0
    await m.answer("✅ сброшен. "+await asyncio.to_thread(cm.activate,c,s,x))

@R.message(Command("regs"))
async def arg(m:Message):
    if not adm(m.from_user.id): return
    with cm.db() as c: rows=[dict(r) for r in c.execute("SELECT * FROM registrations WHERE status='pending' ORDER BY id DESC LIMIT 20")]
    if not rows: await m.answer("Новых заявок нет"); return
    await m.answer("📝 Заявки:\n\n"+"".join(f"#{r['id']} {r['name']} · {r['phone']}{' · TG✅' if r['tg_id'] else ''}\n" for r in rows)+"\n/approve <id> [тариф] · /reject <id>")

@R.message(Command("approve"))
async def aap(m:Message):
    if not adm(m.from_user.id): return
    p=(m.text or "").split()
    if len(p)<2: await m.answer("/approve <id> [id тарифа]"); return
    import uuid as U
    with cm.db() as con: row=con.execute("SELECT * FROM registrations WHERE id=?",(int(p[1]),)).fetchone()
    if not row or row["status"]!="pending": await m.answer("Заявка не найдена/обработана"); return
    g=dict(row); s=S(); pl=cm.plan(int(p[2])) if len(p)>2 else None
    em="u"+"".join(ch for ch in g["phone"] if ch.isdigit())
    while cm.client(email=em): em="u"+cm.rnd(6)
    tg=g["tg_id"] or "u_"+cm.rnd(8)
    c={"tg_id":tg,"name":g["name"],"email":em,"uuid":str(U.uuid4()),"balance":0,
       "limit_gb":float(pl["limit_gb"]) if pl else 0,"ext_key":cm.rnd(8,True),"inbound_id":0}
    x=cm.xui(s)
    try: x.add_client(cm.ib(c,s),em,client_uuid=c["uuid"],total_gb=c["limit_gb"])
    except Exception as e: await m.answer("⚠️ VLESS: %s"%e)
    with cm.db() as con:
        cur=con.execute("INSERT INTO clients(tg_id,name,email,uuid,balance,limit_gb,used_bytes,enabled,notified,paid_until,ext_key,inbound_id,sub_id,access_code) VALUES(?,?,?,?,0,?,0,1,0,0,?,0,?,?)",
            (tg,g["name"],em,c["uuid"],c["limit_gb"],c["ext_key"],cm.rnd(16),cm.rnd(6,True)))
        c["id"]=cur.lastrowid
        con.execute("UPDATE registrations SET status='approved',client_id=?,decided_at=datetime('now') WHERE id=?",(c["id"],g["id"]))
    if pl: cm.applyplan(c,pl,s,x,notify=False,free=True)
    c=cm.client(id=c["id"])
    if g["tg_id"]: cm.tg(s,g["tg_id"],f"✅ Одобрено!\n{cm.cab(c,s)}\nКод: {c['access_code']}\nКлюч: {c['ext_key']}")
    await m.answer("✅ Создан "+c["email"])

@R.message(Command("reject"))
async def arj(m:Message):
    if not adm(m.from_user.id): return
    p=(m.text or "").split()
    if len(p)<2: await m.answer("/reject <id>"); return
    with cm.db() as con:
        row=con.execute("SELECT * FROM registrations WHERE id=?",(int(p[1]),)).fetchone()
        if row: con.execute("UPDATE registrations SET status='rejected' WHERE id=?",(int(p[1]),))
    if row and row["tg_id"]: cm.tg(S(),row["tg_id"],"❌ Заявка отклонена")
    await m.answer("Отклонена")

@R.message(Command("newpromo"))
async def anp(m:Message):
    if not adm(m.from_user.id): return
    p=(m.text or "").split()
    if len(p)<4: await m.answer("/newpromo <код> <balance|plan|days> <знач> [лимит] [дней]\nПример: /newpromo START100 balance 100 50 30"); return
    try:
        v=float(p[3].replace(",",".")); mx=int(p[4]) if len(p)>4 else 0; vd=int(p[5]) if len(p)>5 else 0
    except ValueError: await m.answer("Числа неверны"); return
    ok,msg=cm.mkpromo(p[1],p[2],v,mx,cm.now()+vd*86400 if vd>0 else 0,"из бота")
    await m.answer(("✅ " if ok else "❌ ")+msg)

@R.message(Command("promos"))
async def apr(m:Message):
    if not adm(m.from_user.id): return
    ps=cm.promos()
    if not ps: await m.answer("Промокодов нет"); return
    await m.answer("🎁 Промокоды:\n\n"+"".join(f"{'🟢' if p['enabled'] else '🔴'} {p['code']} · {p['kind']} {p['value']:g} · {p['used_count']}/{p['max_uses'] or '∞'}\n" for p in ps))

@R.message(Command("settings"))
async def ast2(m:Message):
    if not adm(m.from_user.id): return
    s=S()
    await m.answer(f"⚙️ 3x-ui: {s['xui_url']} (inbound {s['inbound_id']})\nАдрес: {cm.host(s)}\nБиллинг: {'вкл' if s['billing_enabled']=='1' else 'выкл'}\nШифр. прокси: {'вкл' if cm.tlson(s) else 'выкл (нужен валидный сертификат)'}\nТарифов: {len(cm.plans())}")

async def run(token):
    b=Bot(token); d=Dispatcher(); d.include_router(R)
    log.info("бот запущен")
    try: await d.start_polling(b,handle_signals=False)
    finally: await b.session.close()

async def main():
    cm.init_db()
    while True:
        t=S().get("bot_token","").strip()
        if not t: await asyncio.sleep(20); continue
        task=asyncio.create_task(run(t))
        while True:
            await asyncio.sleep(20); cur=S().get("bot_token","").strip()
            if cur!=t or task.done():
                task.cancel()
                try: await task
                except Exception: pass
                if cur==t: await asyncio.sleep(20)
                break

if __name__=="__main__":
    try: asyncio.run(main())
    except KeyboardInterrupt: pass
PY_BOT

cat > monitor.py <<'PY_MON'
import logging
from apscheduler.schedulers.blocking import BlockingScheduler
from datetime import datetime
import common as cm

logging.basicConfig(level=logging.INFO,format="%(asctime)s %(levelname)s %(message)s")
log=logging.getLogger("monitor")

def traffic():
    s=cm.S(); x=cm.xui(s)
    for c in cm.clients():
        try:
            u=0; st=x.get_client_stats(c["email"])
            if st: u+=int(st.get("up",0))+int(st.get("down",0))
            if c["http_inbound_id"]:
                b=x.get_inbound(c["http_inbound_id"]); u+=int(b.get("up",0))+int(b.get("down",0))
        except Exception as e:
            log.warning("трафик %s: %s",c["email"],e); continue
        with cm.db() as con: con.execute("UPDATE clients SET used_bytes=? WHERE id=?",(u,c["id"]))
        l=float(c["limit_gb"] or 0)
        if l<=0 or not c["enabled"]: continue
        lb=l*2**30
        if u>=lb:
            c["used_bytes"]=u; c["enabled"]=0; cm.save(c)
            try: cm.sync(c,s,x)
            except Exception as e: log.warning("sync %s: %s",c["email"],e)
            cm.tg(s,c["tg_id"],f"⛔ Лимит {l:g} GB исчерпан. {cm.cab(c,s)}")
        elif u>=0.9*lb and not c["notified"]:
            cm.tg(s,c["tg_id"],f"⚠️ {cm.gb(u)} из {l:g} GB (90%). {cm.cab(c,s)}")
            with cm.db() as con: con.execute("UPDATE clients SET notified=1 WHERE id=?",(c["id"],))

def billing():
    s=cm.S(); x=cm.xui(s); t=cm.now()
    for c in cm.clients():
        if (s["billing_enabled"]=="1" or c.get("plan_id")) and c["paid_until"]<=t:
            log.info("биллинг %s: %s",c["email"],cm.activate(c,s,x))

if __name__=="__main__":
    cm.init_db(); sc=BlockingScheduler()
    sc.add_job(traffic,"interval",minutes=30,next_run_time=datetime.now(),id="t",max_instances=1,coalesce=True)
    sc.add_job(billing,"interval",minutes=5,next_run_time=datetime.now(),id="b",max_instances=1,coalesce=True)
    log.info("монитор запущен")
    try: sc.start()
    except KeyboardInterrupt: pass
PY_MON

echo "=========== 5. Шаблоны ==========="
python3 - <<'PY_TPL'
import pathlib
d=pathlib.Path("templates"); d.mkdir(exist_ok=True)
CSS='''*{box-sizing:border-box;margin:0}body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#060913;color:#e7ecf5;line-height:1.55;background-image:radial-gradient(1000px 700px at 10% -10%,rgba(59,130,246,.20),transparent 60%),radial-gradient(900px 700px at 95% 5%,rgba(139,92,246,.16),transparent 60%);background-attachment:fixed}
::-webkit-scrollbar{width:10px;height:10px}::-webkit-scrollbar-track{background:#0a0f1f}::-webkit-scrollbar-thumb{background:linear-gradient(#3b82f6,#8b5cf6);border-radius:8px}
a{color:#22d3ee;text-decoration:none}.card{background:linear-gradient(160deg,rgba(255,255,255,.06),rgba(255,255,255,.02));border:1px solid rgba(148,163,184,.16);border-radius:18px;padding:22px;margin-bottom:16px;backdrop-filter:blur(10px)}
h1,h2,h3{font-weight:600}h2{font-size:15px;margin-bottom:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
label{font-size:12px;color:#93a0b8;display:block;margin-bottom:5px}
input,select,textarea{width:100%;padding:10px 12px;border:1px solid rgba(148,163,184,.2);border-radius:11px;font-size:14px;font-family:inherit;background:rgba(6,9,19,.55);color:#e7ecf5}
input:focus,select:focus,textarea:focus{outline:none;border-color:#22d3ee}select option{background:#141a2e}
textarea{min-height:110px;font-family:ui-monospace,monospace;font-size:12px}
.btn{display:inline-flex;align-items:center;gap:6px;padding:10px 17px;border:0;border-radius:11px;background:linear-gradient(90deg,#22d3ee,#3b82f6);color:#04121f;font-weight:600;font-size:14px;cursor:pointer;font-family:inherit}
.btn:hover{filter:brightness(1.1)}.btn.gray{background:rgba(255,255,255,.08);color:#e7ecf5;border:1px solid rgba(148,163,184,.2)}
.btn.red{background:linear-gradient(90deg,#f87171,#ef4444);color:#fff}.btn.green{background:linear-gradient(90deg,#34d399,#10b981);color:#04231a}.btn.sm{padding:6px 10px;font-size:12px}
.msg{background:rgba(59,130,246,.14);border:1px solid rgba(59,130,246,.4);color:#bfdbfe;border-radius:12px;padding:12px 16px;margin-bottom:16px;font-size:14px}
.hint{font-size:12px;color:#93a0b8;margin-top:8px;line-height:1.55}
code{background:rgba(6,9,19,.6);border:1px solid rgba(148,163,184,.2);border-radius:7px;padding:2px 7px;font-size:12px;color:#6ee7b7}
.badge{padding:3px 10px;border-radius:99px;font-size:11px;font-weight:600}.badge.on{background:rgba(52,211,153,.18);color:#6ee7b7}.badge.off{background:rgba(248,113,113,.16);color:#fca5a5}
table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:9px 8px;border-bottom:1px solid rgba(148,163,184,.16);text-align:left;vertical-align:top}th{color:#93a0b8;font-size:12px}
.tablewrap{overflow-x:auto}.actions{display:flex;gap:6px;flex-wrap:wrap;align-items:center}.actions form{display:flex;gap:4px;align-items:center;margin:0}.actions input{width:88px;padding:6px 8px;font-size:12px}
.bar{height:6px;background:rgba(148,163,184,.2);border-radius:4px;margin-top:5px}.bar i{display:block;height:6px;border-radius:4px;background:linear-gradient(90deg,#22d3ee,#8b5cf6)}'''
def page(t,b,e=""):
    return '<!doctype html><html lang=ru><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>'+t+'</title><style>'+CSS+e+'</style></head><body>'+b+'</body></html>'
(d/"login.html").write_text(page("Вход",'<form class=card method=post action=/login><h1 style="font-size:21px;margin-bottom:6px">🔐 Proxy Manager</h1><p class=hint style="margin-bottom:18px">Панель управления</p>{% if msg %}<div class=msg>{{ msg }}</div>{% endif %}<label>Логин</label><input name=username required style="margin-bottom:12px"><label>Пароль</label><input name=password type=password required style="margin-bottom:16px"><button class=btn style="width:100%">Войти</button></form>',' body{display:flex;min-height:100vh;align-items:center;justify-content:center;padding:20px}.card{width:min(380px,94vw)}'))
(d/"lock.html").write_text(page("Вход",'<form class=card method=post action="/client/{{ c.tg_id }}/unlock"><div style="font-size:34px">🔐</div><h1 style="font-size:20px;margin:8px 0">{{ s.panel_name }}</h1><p class=hint style="margin-bottom:16px">Кабинет {{ c.name }} защищён кодовым словом</p>{% if msg %}<div class=msg>{{ msg }}</div>{% endif %}<input name=code placeholder="КОДОВОЕ СЛОВО" required autofocus style="margin-bottom:14px"><button class=btn style="width:100%">Войти</button></form>',' body{display:flex;min-height:100vh;align-items:center;justify-content:center;padding:20px}.card{width:min(380px,94vw)}input{text-align:center;letter-spacing:.15em;text-transform:uppercase;font-size:17px}'))
(d/"register.html").write_text(page("Регистрация",'<main><div class=card><h1 style="font-size:22px;margin-bottom:6px">🛰️ {{ s.panel_name }}</h1><p class=hint style="margin-bottom:18px">Заявка на подключение</p>{% if msg %}<div class=msg>{{ msg }}</div>{% endif %}<form method=post action=/register><label>Имя *</label><input name=name required style="margin-bottom:12px"><label>Телефон *</label><input name=phone required placeholder="+7 900 123-45-67" style="margin-bottom:12px"><label>Email</label><input name=email style="margin-bottom:12px"><label>Комментарий</label><input name=comment style="margin-bottom:16px"><button class=btn style="width:100%">Отправить заявку</button></form><p class=hint>Администратор проверит контакты и одобрит заявку.</p></div></main>',' main{max-width:520px;margin:40px auto;padding:0 16px}'))
(d/"reg_status.html").write_text(page("Заявка",'<main><div class=card><h1 style="font-size:20px;margin-bottom:10px">Заявка {{ reg.code }}</h1>{% if reg.status=="pending" %}<span class="badge off">⏳ На проверке</span><p class=hint>Администратор проверит телефон {{ reg.phone }}.</p>{% elif reg.status=="approved" %}<span class="badge on">✅ Одобрена</span>{% else %}<span class="badge off">❌ Отклонена</span>{% endif %}</div>{% if reg.status=="pending" %}<div class=card><h2>📲 Подтвердить Telegram</h2>{% if reg.tg_id %}<span class="badge on">✅ Подтверждён</span>{% else %}{% if tg_link %}<a class=btn href="{{ tg_link }}">Подтвердить Telegram</a>{% endif %}<p class=hint>Или отправьте боту <code>/reg {{ reg.code }}</code></p>{% endif %}</div>{% endif %}{% if reg.status=="approved" and client %}<div class=card><h2>🎉 Доступ готов</h2><p><a class="btn green" href="{{ cabinet }}">Открыть кабинет</a></p><p style="margin-top:12px">Кодовое слово: <code>{{ code_word }}</code></p><p style="margin-top:8px">Ключ расширения: <code>{{ client.ext_key }}</code></p><p style="margin-top:14px"><a class=btn href="/extension.zip">⬇ Расширение</a></p></div>{% endif %}</main>',' main{max-width:520px;margin:40px auto;padding:0 16px}'))
(d/"client.html").write_text(page("Кабинет",'<main><div class=card><div style="display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:10px"><h1 style="font-size:21px">🛰️ {{ c.name }}</h1>{% if c.enabled %}<span class="badge on">● активен</span>{% else %}<span class="badge off">● отключён</span>{% endif %}</div>{% if msg %}<div class=msg style="margin-top:14px">{{ msg }}</div>{% endif %}<div class=grid style="margin-top:16px"><div class=stat><span>Баланс</span><b>{{ "%.2f"|format(c.balance) }} ₽</b></div><div class=stat><span>Тариф</span><b>{% set mp=get_plan(c.plan_id) %}{{ mp.name if mp else "—" }}</b></div><div class=stat><span>Трафик</span><b>{{ used_gb }} ГБ</b></div><div class=stat><span>Оплачено до</span><b>{{ paid_str }}</b></div></div>{% if c.limit_gb %}<p class=hint>Лимит {{ "%g"|format(c.limit_gb) }} ГБ · {{ percent }}%</p><div class=bar><i style="width:{{ percent }}%"></i></div>{% endif %}</div><div class=card><h2>💰 Тарифы</h2>{% for p in get_plans() %}<div class=plan><div><b>{{ p.name }}</b> — {{ "%g"|format(p.price) }} ₽ / {{ p.period_days }} дн.<div class=hint>{% if p.limit_gb %}{{ "%g"|format(p.limit_gb) }} ГБ{% else %}безлимит{% endif %}{% if p.description %} · {{ p.description }}{% endif %}</div></div><form method=post action="/client/{{ c.tg_id }}/plan/{{ p.id }}"><button class=btn>Подключить</button></form></div>{% else %}<p class=hint>Тарифы не настроены</p>{% endfor %}<div style="display:flex;gap:8px;margin-top:14px;flex-wrap:wrap"><form method=post action="/client/{{ c.tg_id }}/promo" style="display:flex;gap:8px;flex:1"><input name=code placeholder="Промокод" style="flex:1;text-transform:uppercase"><button class="btn green">🎁</button></form><form method=post action="/client/{{ c.tg_id }}/topup"><button class="btn gray">💳 Пополнить</button></form></div></div>{% if has_plan(c) or s.require_plan!="1" %}<div class=card><h2>📱 Подключение — сканируйте QR</h2><div class=qrs><div class=qr><img src="{{ qr(vless) }}"><span>VLESS · v2rayNG / Hiddify</span></div><div class=qr><img src="{{ qr(sub) }}"><span>Подписка · автообновление</span></div></div><div class=linkbox><input id=v readonly value="{{ vless }}"><button class="btn gray" onclick="cp(\'v\',this)">Копировать</button></div><div class=linkbox><input id=su readonly value="{{ sub }}"><button class="btn gray" onclick="cp(\'su\',this)">Копировать</button></div></div>{% if c.http_port %}<div class=card><h2>🧩 Прокси для браузера</h2><p>Ключ: <code style="font-size:17px">{{ c.ext_key }}</code></p><p style="margin-top:14px"><a class=btn href="/extension.zip">⬇ Скачать расширение</a></p><p class=hint>chrome://extensions → режим разработчика → загрузить распакованное → ввести ключ.</p></div>{% endif %}{% else %}<div class=card style="text-align:center"><div style="font-size:42px">🔒</div><h2 style="margin-top:10px">Подключите тариф</h2><p class=hint>Ссылки, QR и ключ появятся после подключения тарифа.</p></div>{% endif %}<div class=card><h2>🔐 Кодовое слово</h2><p class=hint>Текущее: <code>{{ c.access_code or "защита отключена" }}</code></p><form method=post action="/client/{{ c.tg_id }}/setcode" style="display:flex;gap:8px;margin-top:10px"><input name=new placeholder="Новое слово" style="flex:1;text-transform:uppercase"><button class=btn>Сохранить</button></form></div></main><script>function cp(i,b){const e=document.getElementById(i);e.select();navigator.clipboard.writeText(e.value).then(()=>{const t=b.textContent;b.textContent="✓";setTimeout(()=>b.textContent=t,1200)})}</script>',' main{max-width:820px;margin:30px auto;padding:0 16px}.stat{background:rgba(255,255,255,.04);border:1px solid rgba(148,163,184,.16);border-radius:14px;padding:14px}.stat b{display:block;font-size:21px;margin-top:4px}.stat span{font-size:12px;color:#93a0b8}.linkbox{display:flex;gap:8px;margin-top:10px}.linkbox input{flex:1;font-family:ui-monospace,monospace;font-size:12px;color:#a5b4fc}.qrs{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:16px}.qr{background:#fff;border-radius:16px;padding:14px;text-align:center}.qr img{width:100%;max-width:180px}.qr span{display:block;color:#0f172a;font-size:12px;font-weight:600;margin-top:8px}.plan{display:flex;justify-content:space-between;align-items:center;gap:12px;padding:13px;border:1px solid rgba(148,163,184,.16);border-radius:14px;margin-bottom:10px}'))
(d/"landing.html").write_text(page("{{ s.panel_name }}",'<main><div class=hero><h1>Интернет <span class=grad>без границ</span></h1><p class=hint style="font-size:16px;max-width:560px;margin:0 auto">Защищённый доступ к любым сервисам. Один ключ — браузер, телефон и компьютер работают свободно.</p><div class=stats><div><b>{{ mstat("clients",n_clients) }}</b><span>{{ mstat("clients_label","пользователей") }}</span></div><div><b>{{ mstat("presets",n_presets) }}</b><span>{{ mstat("presets_label","сервисов") }}</span></div><div><b>{{ mstat("third","24/7") }}</b><span>{{ mstat("third_label","поддержка") }}</span></div></div></div>{% if msg %}<div class=msg id=login>{{ msg }}</div>{% else %}<div id=login></div>{% endif %}<div class=cards><div class="card ac" style="--ac:#22d3ee"><div class=ico>🔑</div><h2>Вход для клиентов</h2><p class=hint style="margin-bottom:14px">Введите ключ расширения или телефон</p><form method=post action=/login><input name=credential placeholder="Ключ или телефон" required style="margin-bottom:10px"><button class=btn style="width:100%">Войти в кабинет →</button></form></div><div class="card ac" style="--ac:#34d399"><div class=ico>✨</div><h2>Регистрация</h2><p class=hint style="margin-bottom:14px">Подайте заявку — администратор проверит и подключит</p><a class="btn green" style="width:100%;justify-content:center" href="/register">Подать заявку →</a></div><div class="card ac" style="--ac:#fbbf24"><div class=ico>🛡️</div><h2>Вход для админа</h2><p class=hint style="margin-bottom:14px">Клиенты, биллинг, тарифы, диагностика</p><a class=btn style="width:100%;justify-content:center;background:linear-gradient(90deg,#fbbf24,#f59e0b)" href="{{ admin_url }}">Открыть админку →</a></div></div><h2 style="text-align:center;margin:44px 0 20px;font-size:22px">Тарифы</h2><div class=fg>{% for p in get_plans() %}<div class=card><h3 style="font-size:17px">{{ p.name }}</h3><p style="font-size:26px;margin:8px 0">{{ "%g"|format(p.price) }} ₽ <span class=hint>/ {{ p.period_days }} дн.</span></p><p class=hint>{% if p.limit_gb %}{{ "%g"|format(p.limit_gb) }} ГБ{% else %}Безлимит{% endif %}{% if p.description %} · {{ p.description }}{% endif %}</p><a class="btn gray" style="margin-top:14px" href="/register">Подключить</a></div>{% endfor %}</div><div class=fg style="margin-top:24px"><div class=card><div style="font-size:26px">🛰️</div><h3 style="margin:8px 0">VLESS + Reality</h3><p class=hint>Устойчив к блокировкам</p></div><div class=card><div style="font-size:26px">🧩</div><h3 style="margin:8px 0">Расширение</h3><p class=hint>Один ключ для браузера</p></div><div class=card><div style="font-size:26px">🤖</div><h3 style="margin:8px 0">Telegram-бот</h3><p class=hint>Кабинет и уведомления</p></div><div class=card><div style="font-size:26px">🔒</div><h3 style="margin:8px 0">Шифрование</h3><p class=hint>HTTPS и TLS-прокси</p></div></div><p class=hint style="text-align:center;margin-top:36px">© 2026 {{ s.panel_name }}</p></main>',' main{max-width:1080px;margin:0 auto;padding:40px 18px}.hero{text-align:center;padding:30px 0 40px}.hero h1{font-size:clamp(30px,5vw,50px);line-height:1.1;margin-bottom:14px}.grad{background:linear-gradient(90deg,#22d3ee,#3b82f6,#8b5cf6);-webkit-background-clip:text;background-clip:text;color:transparent}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:20px}.ac{position:relative;overflow:hidden}.ac::before{content:"";position:absolute;top:0;left:0;right:0;height:3px;background:var(--ac)}.ac .ico{font-size:30px;margin-bottom:12px}.stats{display:flex;gap:34px;justify-content:center;flex-wrap:wrap;margin-top:26px}.stats b{display:block;font-size:28px;background:linear-gradient(90deg,#22d3ee,#8b5cf6);-webkit-background-clip:text;background-clip:text;color:transparent}.stats span{font-size:13px;color:#93a0b8}.fg{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}'))
print("шаблоны клиента готовы")
PY_TPL

python3 - <<'PY_ADMTPL'
import pathlib
css=pathlib.Path("templates/login.html").read_text().split("<style>")[1].split("</style>")[0].split(" body{display:flex")[0]
extra='header{background:rgba(20,26,46,.85);backdrop-filter:blur(14px);border-bottom:1px solid rgba(148,163,184,.16);padding:14px 22px;display:flex;align-items:center;gap:14px;flex-wrap:wrap;position:sticky;top:0;z-index:5}header h1{font-size:17px;flex:1}main{max-width:1240px;margin:0 auto;padding:22px}.tabs{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:18px}.tabs button{padding:10px 16px;border:1px solid rgba(148,163,184,.2);background:rgba(255,255,255,.04);color:#e7ecf5;border-radius:12px;cursor:pointer;font-size:14px;font-family:inherit}.tabs button.active{background:linear-gradient(90deg,#22d3ee,#3b82f6);color:#04121f;border-color:transparent;font-weight:600}.tab{display:none}.tab.active{display:block}.dot{width:10px;height:10px;border-radius:50%;display:inline-block;background:#64748b;margin-right:6px}.dot.ok{background:#34d399}.dot.bad{background:#f87171}#diagReport,#updOut,#prbOut,#netOut,#certOut{min-height:200px;white-space:pre}'
tabs=[("clients","👥 Клиенты"),("plans","💰 Тарифы"),("net","🌐 Домен и HTTPS"),("settings","⚙️ Настройки"),("market","📣 Маркетинг"),("ext","🧩 Расширение"),("tools","🧰 Сервис"),("security","🔒 Безопасность"),("diag","🩺 Диагностика")]
H=['<!doctype html><html lang=ru><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Админка</title><style>'+css+extra+'</style></head><body><header><h1>🛰️ {{ s.panel_name }}</h1><span id=xuiStatus style="font-size:13px;color:#93a0b8"><span class=dot id=xuiDot></span>3x-ui…</span><a href="/extension.zip">⬇ Расширение</a><a href="/logout">Выйти ({{ user }})</a></header><main>{% if msg %}<div class=msg>{{ msg }}</div>{% endif %}<div class=tabs>']
for i,(k,t) in enumerate(tabs): H.append('<button data-tab="%s"%s>%s</button>'%(k,' class=active' if i==0 else '',t))
H.append('</div>')
H.append('''<div class="tab active" id=tab-clients>
{% set regs=get_regs() %}<div class=card><h2>📝 Заявки ({{ regs|selectattr("status","equalto","pending")|list|length }} новых)</h2>
<form method=post action="/registrations/clear" onsubmit="return confirm('Удалить обработанные?')"><button class="btn sm gray">🧹 Очистить обработанные</button></form>
{% for r in regs %}<div style="border-bottom:1px solid rgba(148,163,184,.16);padding:10px 0"><b>{{ r.name }}</b> · 📞 {{ r.phone }}{% if r.email %} · ✉️ {{ r.email }}{% endif %}{% if r.tg_id %} · TG ✅{% endif %}
<div class=hint>{{ r.created_at }} · {{ r.code }} · {% if r.status=="pending" %}<span class="badge off">на проверке</span>{% elif r.status=="approved" %}<span class="badge on">одобрена</span>{% else %}<span class="badge off">отклонена</span>{% endif %}</div>
<div class=actions style="margin-top:6px"><form method=post action="/registrations/{{ r.id }}/delete" onsubmit="return confirm('Удалить?')"><button class="btn sm red">🗑</button></form>
{% if r.status=="pending" %}<form method=post action="/registrations/{{ r.id }}/approve"><select name=plan_id style="max-width:150px"><option value=0>без тарифа</option>{% for p in get_plans() %}<option value="{{ p.id }}">{{ p.name }}</option>{% endfor %}</select><input name=balance type=number step=0.01 value=0 title="Баланс"><label style="display:flex;gap:4px;align-items:center;font-size:12px"><input type=checkbox name=browser value=1 checked style="width:auto">браузер</label><button class="btn sm green">✔ Одобрить</button></form>
<form method=post action="/registrations/{{ r.id }}/reject"><button class="btn sm red">✕</button></form>{% endif %}</div></div>{% else %}<p class=hint>Заявок нет</p>{% endfor %}</div>
<div class=card><h2>Добавить клиента</h2><form method=post action="/clients/add"><div class=grid>
<div><label>Telegram ID (необязательно)</label><input name=tg_id placeholder="пусто = без Telegram"></div>
<div><label>Имя *</label><input name=name required></div><div><label>Email *</label><input name=email required></div>
<div><label>Баланс ₽</label><input name=balance type=number step=0.01 value=0></div>
<div><label>Лимит GB (0=∞)</label><input name=limit_gb type=number step=0.1 value=0></div>
<div><label>Подключение</label><select name=inbound_id id=addInbound><option value=0>по умолчанию (№{{ s.inbound_id }})</option></select></div>
<div><label>Браузер-прокси</label><select name=browser><option value=1 selected>создать + ключ</option><option value="">не нужен</option></select></div>
</div><p style="margin-top:12px"><button class=btn>➕ Добавить</button></p></form></div>
<div class=card><h2>📥 Импорт из 3x-ui</h2><form method=post action="/clients/import" class=actions><select name=inbound_id id=impInbound style="max-width:300px"><option value=0>текущий (№{{ s.inbound_id }})</option></select><button class=btn>Импортировать</button></form></div>
<div class=card><h2>Клиенты ({{ clients|length }})</h2><div class=tablewrap><table><tr><th>Клиент</th><th>Баланс</th><th>Трафик</th><th>До</th><th>Ключ/код</th><th>Статус</th><th>Действия</th></tr>
{% for c in clients %}<tr><td><b>{{ c.name }}</b><br><code>{{ c.email }}</code><br><span class=hint>{{ c.tg_id }}</span></td>
<td>{{ "%.2f"|format(c.balance) }} ₽</td><td>{{ c.used_gb }}/{% if c.limit_gb %}{{ "%g"|format(c.limit_gb) }}{% else %}∞{% endif %}{% if c.limit_gb %}<div class=bar><i style="width:{{ c.percent }}%"></i></div>{% endif %}</td>
<td>{{ c.paid_str }}</td><td><code>{{ c.ext_key }}</code><br><code>{{ c.access_code }}</code>{% if c.http_port %}<br><span class=hint>HTTP {{ c.http_port }}</span>{% endif %}</td>
<td>{% if c.enabled %}<span class="badge on">вкл</span>{% else %}<span class="badge off">выкл</span>{% endif %}</td>
<td><div class=actions>
<form method=post action="/clients/{{ c.id }}/topup"><input name=amount type=number step=0.01 placeholder="₽"><button class="btn sm green">＋₽</button></form>
<form method=post action="/clients/{{ c.id }}/reset"><button class="btn sm gray">Сброс</button></form>
<form method=post action="/clients/{{ c.id }}/toggle"><button class="btn sm {% if c.enabled %}red{% else %}green{% endif %}">{% if c.enabled %}Выкл{% else %}Вкл{% endif %}</button></form>
{% if not c.http_port %}<form method=post action="/clients/{{ c.id }}/browser"><button class="btn sm gray">＋HTTP</button></form>{% endif %}
<form method=post action="/clients/{{ c.id }}/sync"><button class="btn sm gray">Синк</button></form>
<a class="btn sm green" href="/enter/{{ c.tg_id }}/{{ c.access_code }}" target=_blank>🔗</a>
{% for p in get_plans() %}<form method=post action="/clients/{{ c.id }}/setplan/{{ p.id }}"><button class="btn sm gray">{{ p.name }}</button></form>{% endfor %}
<form method=post action="/clients/{{ c.id }}/code"><input name=code placeholder="код"><button class="btn sm gray">Код</button></form>
<form method=post action="/clients/{{ c.id }}/codeoff"><button class="btn sm gray">🔓</button></form>
<form method=post action="/clients/{{ c.id }}/delete" onsubmit="return confirm('Удалить {{ c.email }}?')"><button class="btn sm red">✕</button></form>
</div></td></tr>{% else %}<tr><td colspan=7>Клиентов нет</td></tr>{% endfor %}</table></div></div></div>''')
H.append('''<div class=tab id=tab-plans><div class=card><h2>Новый тариф</h2><form method=post action="/plans/add"><div class=grid>
<div><label>Название</label><input name=name required></div><div><label>Цена ₽</label><input name=price type=number step=0.01 value=200></div>
<div><label>Дней</label><input name=period_days type=number value=30></div><div><label>Лимит GB (0=∞)</label><input name=limit_gb type=number step=0.1 value=0></div>
<div><label>Описание</label><input name=description></div></div><p style="margin-top:12px"><button class=btn>➕ Добавить</button></p></form></div>
{% for p in get_plans(False) %}<div class=card><h2>{{ p.name }} <span class=hint>ID {{ p.id }} · {% if p.enabled %}вкл{% else %}выкл{% endif %}</span></h2>
<form method=post action="/plans/{{ p.id }}/save"><div class=grid>
<div><label>Название</label><input name=name value="{{ p.name }}"></div><div><label>Цена</label><input name=price type=number step=0.01 value="{{ p.price }}"></div>
<div><label>Дней</label><input name=period_days type=number value="{{ p.period_days }}"></div><div><label>Лимит GB</label><input name=limit_gb type=number step=0.1 value="{{ p.limit_gb }}"></div>
<div><label>Описание</label><input name=description value="{{ p.description }}"></div></div><p style="margin-top:12px"><button class="btn sm green">💾 Сохранить</button></p></form>
<div class=actions style="margin-top:8px"><form method=post action="/plans/{{ p.id }}/toggle"><button class="btn sm gray">{% if p.enabled %}Отключить{% else %}Включить{% endif %}</button></form>
<form method=post action="/plans/{{ p.id }}/delete" onsubmit="return confirm('Удалить?')"><button class="btn sm red">✕</button></form></div></div>{% endfor %}
<div class=card><h2>🎁 Промокоды</h2><p class=hint>balance — деньги; plan — бесплатный тариф (значение = ID тарифа); days — бонусные дни.</p>
<form method=post action="/promos/add" style="margin-top:12px"><div class=grid>
<div><label>Код</label><input name=code required style="text-transform:uppercase"></div>
<div><label>Тип</label><select name=kind><option value=balance>balance</option><option value=plan>plan</option><option value=days>days</option></select></div>
<div><label>Значение</label><input name=value type=number step=0.01 value=100></div>
<div><label>Лимит (0=∞)</label><input name=max_uses type=number value=0></div>
<div><label>Срок, дней (0=∞)</label><input name=valid_days type=number value=0></div></div>
<p style="margin-top:12px"><button class=btn>➕ Создать</button></p></form>
<div class=tablewrap style="margin-top:14px"><table><tr><th>Код</th><th>Тип</th><th>Знач</th><th>Исп</th><th>Статус</th><th></th></tr>
{% for p in get_promos() %}<tr><td><code>{{ p.code }}</code></td><td>{{ p.kind }}</td><td>{{ "%g"|format(p.value) }}</td><td>{{ p.used_count }}/{{ p.max_uses or "∞" }}</td>
<td>{% if p.enabled %}<span class="badge on">вкл</span>{% else %}<span class="badge off">выкл</span>{% endif %}</td>
<td><div class=actions><form method=post action="/promos/{{ p.id }}/toggle"><button class="btn sm gray">⇄</button></form><form method=post action="/promos/{{ p.id }}/delete"><button class="btn sm red">✕</button></form></div></td></tr>{% else %}<tr><td colspan=6>Нет промокодов</td></tr>{% endfor %}</table></div></div></div>''')
H.append('''<div class=tab id=tab-net>
<div class=card><h2>🌐 Домен и сертификат</h2>
<p class=hint>Сервер работает по IP: <b>{{ server_ip() }}</b>. Всё функционирует и без домена.
Когда появится домен: A-запись на этот IP → впиши ниже → «Применить» → «Запросить Let's Encrypt».</p>
<p class=hint>Сертификат: <code>{{ cert_path() }}</code><br>
Валидный (не самоподписанный): {% if cert_ok() %}<span class="badge on">да</span>{% else %}<span class="badge off">нет</span>{% endif %}<br>
Шифрованный браузер-прокси: {% if tls_on() %}<span class="badge on">активен</span>{% else %}<span class="badge off">выключен</span>{% endif %}</p>
<p class=hint>Chrome принимает HTTPS-прокси только с валидным сертификатом, поэтому шифрование прокси включится автоматически после получения Let's Encrypt.</p>
<form method=post action="/net/apply" style="margin-top:14px"><div class=grid>
<div><label>Домен (пусто = по IP)</label><input name=domain value="{{ s.domain }}" placeholder="example.com"></div>
<div><label>Email для Let's Encrypt</label><input name=le_email value="{{ s.le_email }}" placeholder="you@mail.ru"></div>
<div><label>Свой сертификат fullchain.pem</label><input name=tls_cert value="{{ s.tls_cert }}" placeholder="/root/cert/домен/fullchain.pem"></div>
<div><label>Свой ключ privkey.pem</label><input name=tls_key value="{{ s.tls_key }}" placeholder="/root/cert/домен/privkey.pem"></div>
</div><p style="margin-top:14px" class=actions><button class=btn>💾 Применить и перенастроить</button>
<button type=button class="btn gray" onclick=netSt()>Статус сети</button></p></form>
<div class=actions style="margin-top:10px">
<form method=post action="/net/cert"><button class="btn green">🔒 Запросить Let's Encrypt</button></form>
<button type=button class="btn gray" onclick=certSt()>Статус сертификата</button></div>
</div>
<div class=card><h2>📄 Статус сети</h2><textarea id=netOut readonly placeholder="Нажми «Статус сети»"></textarea></div>
<div class=card><h2>📄 Статус сертификата</h2><textarea id=certOut readonly placeholder="Нажми «Статус сертификата»"></textarea></div>
</div>''')
H.append('''<div class=tab id=tab-settings>
<div class=card><h2>🪄 Автонастройка из 3x-ui</h2><p class=hint>Прочитает inbound и подставит порт, SNI, Reality pbk/sid, шифрование.</p>
<form method=post action="/xui/autoconfig" class=actions style="margin-top:10px"><select name=inbound_id id=acInbound style="max-width:340px"><option value="">автовыбор</option></select><button class=btn>🔍 Подтянуть</button><button type=button class="btn gray" onclick=loadIb()>Обновить список</button></form></div>
<form method=post action="/settings">
<div class=card><h2>3x-ui</h2><div class=grid>
<div><label>URL панели (с base path)</label><input name=xui_url value="{{ s.xui_url }}"></div>
<div><label>Логин</label><input name=xui_user value="{{ s.xui_user }}"></div>
<div><label>Пароль</label><input name=xui_pass type=password value="{{ s.xui_pass }}"></div>
<div><label>API-токен</label><input name=xui_api_token value="{{ s.xui_api_token }}"></div>
<div><label>Inbound ID</label><input name=inbound_id value="{{ s.inbound_id }}"></div></div></div>
<div class=card><h2>Ссылки</h2><div class=grid>
<div><label>Публичный URL кабинета</label><input name=public_url value="{{ s.public_url }}"></div>
<div><label>URL админки</label><input name=admin_url value="{{ s.admin_url }}"></div>
<div><label>База подписки</label><input name=sub_url_base value="{{ s.sub_url_base }}"></div>
<div><label>SNI</label><input name=sni value="{{ s.sni }}"></div><div><label>Порт VLESS</label><input name=vless_port value="{{ s.vless_port }}"></div>
<div><label>Reality pbk</label><input name=reality_pbk value="{{ s.reality_pbk }}"></div><div><label>Reality sid</label><input name=reality_sid value="{{ s.reality_sid }}"></div>
<div><label>Fingerprint</label><input name=fp value="{{ s.fp }}"></div></div></div>
<div class=card><h2>Telegram</h2><div class=grid>
<div><label>Bot Token</label><input name=bot_token value="{{ s.bot_token }}"></div>
<div><label>Telegram ID админа</label><input name=admin_tg_id value="{{ s.admin_tg_id }}"></div>
<div><label>Название сервиса</label><input name=panel_name value="{{ s.panel_name }}"></div></div></div>
<div class=card><h2>Биллинг</h2><div class=grid>
<div><label>Режим</label><select name=billing_enabled><option value=0 {% if s.billing_enabled=="0" %}selected{% endif %}>выкл</option><option value=1 {% if s.billing_enabled=="1" %}selected{% endif %}>вкл</option></select></div>
<div><label>Цена по умолчанию</label><input name=price value="{{ s.price }}"></div>
<div><label>Период, дней</label><input name=period_days value="{{ s.period_days }}"></div>
<div><label>Секрет webhook</label><input name=billing_secret value="{{ s.billing_secret }}"></div></div></div>
<div class=card><h2>Браузер-прокси</h2><div class=grid>
<div><label>Порт от</label><input name=http_port_start value="{{ s.http_port_start }}"></div>
<div><label>Порт до</label><input name=http_port_end value="{{ s.http_port_end }}"></div>
<div><label>Шифрование TLS</label><select name=proxy_tls><option value=1 {% if s.proxy_tls!="0" %}selected{% endif %}>вкл (при валидном сертификате)</option><option value=0 {% if s.proxy_tls=="0" %}selected{% endif %}>выкл</option></select></div>
</div></div>
<button class=btn>💾 Сохранить</button></form></div>''')
H.append('''<div class=tab id=tab-market><form method=post action="/settings">
<div class=card><h2>📣 Цифры на главной</h2><p class=hint>Пусто = реальные данные.</p><div class=grid style="margin-top:12px">
<div><label>Число пользователей</label><input name=stat_clients value="{{ s.stat_clients }}"></div>
<div><label>Подпись</label><input name=stat_clients_label value="{{ s.stat_clients_label }}"></div>
<div><label>Число сервисов</label><input name=stat_presets value="{{ s.stat_presets }}"></div>
<div><label>Подпись</label><input name=stat_presets_label value="{{ s.stat_presets_label }}"></div>
<div><label>Третий показатель</label><input name=stat_third value="{{ s.stat_third }}"></div>
<div><label>Подпись</label><input name=stat_third_label value="{{ s.stat_third_label }}"></div></div></div>
<div class=card><h2>🔓 Показ ссылок</h2><select name=require_plan><option value=1 {% if s.require_plan!="0" %}selected{% endif %}>только после тарифа</option><option value=0 {% if s.require_plan=="0" %}selected{% endif %}>сразу всем</option></select></div>
<button class=btn>💾 Сохранить</button></form></div>''')
H.append('''<div class=tab id=tab-ext><div class=card><h2>Расширение</h2><p><a class=btn href="/extension.zip">⬇ Скачать zip</a></p>
<p class=hint>chrome://extensions → режим разработчика → загрузить распакованное → ввести ключ.</p></div>
<div class=card><h2>🧩 Пресеты</h2><form method=post action="/presets/add"><label>Название</label><input name=name required style="margin-bottom:10px"><label>Домены</label><textarea name=domains required placeholder="gosuslugi.ru"></textarea><p style="margin-top:10px"><button class=btn>➕ Добавить/обновить</button></p></form>
{% set pr=load_json(s.ext_presets or "{}") %}<div class=tablewrap style="margin-top:14px"><table><tr><th>Пресет</th><th>Домены</th><th></th></tr>
{% for n,ds in pr.items() %}<tr><td><b>{{ n }}</b></td><td class=hint>{{ ds|length }}: {{ ds[:4]|join(", ") }}{% if ds|length>4 %}…{% endif %}</td>
<td><form method=post action="/presets/delete"><input type=hidden name=name value="{{ n }}"><button class="btn sm red">✕</button></form></td></tr>{% endfor %}</table></div></div>
<form method=post action="/settings"><div class=card><h2>Внешние списки (JSON)</h2><textarea name=ext_lists>{{ s.ext_lists }}</textarea></div>
<div class=card><h2>Пресеты — JSON</h2><textarea name=ext_presets>{{ s.ext_presets }}</textarea></div><button class=btn>💾 Сохранить</button></form>
<div class=card><h2>Предложения ({{ suggestions|length }})</h2>{% for g in suggestions %}<p><b>{{ g.name }}</b> <code>{{ g.domains[:100] }}</code>
<span class=actions><form method=post action="/suggestions/{{ g.id }}/approve"><button class="btn sm green">Одобрить</button></form><form method=post action="/suggestions/{{ g.id }}/delete"><button class="btn sm red">✕</button></form></span></p>{% else %}<p class=hint>Нет</p>{% endfor %}</div></div>''')
H.append('''<div class=tab id=tab-tools>
<div class=card><h2>🔒 Шифрование браузер-прокси</h2>
<p class=hint>Статус: {% if tls_on() %}<span class="badge on">TLS активен</span>{% else %}<span class="badge off">обычный HTTP</span>{% endif %}</p>
<div class=actions style="margin-top:10px">
<form method=post action="/proxy/tls_all"><button class="btn green">🔒 Включить TLS на всех прокси</button></form>
<form method=post action="/proxy/tls_off"><button class="btn gray">🔓 Снять TLS</button></form></div>
<p class=hint>Нужен валидный сертификат (вкладка «Домен и HTTPS»). После включения клиенты нажимают в расширении «🔄 Обновить».</p></div>
<div class=card><h2>🛰️ Гостевой доступ (диагностика для помощника)</h2><p>Статус: {% if s.guest_enabled=="1" %}<span class="badge on">вкл</span>{% else %}<span class="badge off">выкл</span>{% endif %}</p>
<div class=actions style="margin-top:10px"><form method=post action="/guest/toggle"><button class="btn sm {% if s.guest_enabled=='1' %}red{% else %}green{% endif %}">{% if s.guest_enabled=="1" %}Выключить{% else %}Включить{% endif %}</button></form>
<form method=post action="/guest/rotate"><button class="btn sm gray">🔄 Новый токен</button></form></div>
<div style="display:flex;margin-top:12px"><input readonly value="{{ s.public_url }}/guest/{{ s.guest_token }}"></div></div>
<div class=card><h2>⬆️ Обновление файлом</h2><p class=hint>.zip с файлами проекта или .py/.html. Проверка → бэкап → применение → авто-откат.</p>
<form method=post action="/update/upload" enctype=multipart/form-data class=actions style="margin-top:10px"><input type=file name=file style="width:auto"><button class=btn>⬆️ Загрузить</button><button type=button class="btn gray" onclick=upd()>Статус</button></form>
<textarea id=updOut readonly style="margin-top:12px"></textarea></div>
<div class=card><h2>🧪 Маршруты API 3x-ui</h2><button class="btn gray" onclick=prb()>Проверить</button><textarea id=prbOut readonly style="margin-top:12px"></textarea></div></div>''')
H.append('''<div class=tab id=tab-security><div class=card><h2>Смена пароля</h2><form method=post action="/security"><div class=grid>
<div><label>Старый</label><input name=old type=password required></div><div><label>Новый (мин 6)</label><input name=new type=password required></div>
<div><label>Повтор</label><input name=new2 type=password required></div></div><p style="margin-top:12px"><button class=btn>🔒 Сменить</button></p></form></div></div>
<div class=tab id=tab-diag><div class=card><h2>🩺 Диагностика</h2><div class=actions><button class=btn onclick=dg()>🔄 Собрать</button><button class="btn green" onclick=cpt(this)">📋 Копировать отчёт</button></div>
<textarea id=diagReport readonly style="margin-top:14px" placeholder="Нажмите «Собрать»"></textarea></div></div>''')
H.append('''</main><script>
document.querySelectorAll('.tabs button').forEach(b=>b.onclick=()=>{document.querySelectorAll('.tabs button').forEach(x=>x.classList.remove('active'));document.querySelectorAll('.tab').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.getElementById('tab-'+b.dataset.tab).classList.add('active');localStorage.setItem('pm_tab',b.dataset.tab);if(b.dataset.tab==='diag')dg();if(b.dataset.tab==='net')netSt();});
const sv=localStorage.getItem('pm_tab');if(sv){const b=document.querySelector('.tabs button[data-tab="'+sv+'"]');if(b)b.click();}
async function poll(){const d=document.getElementById('xuiDot'),t=document.getElementById('xuiStatus');try{const j=await (await fetch('/api/xui_status')).json();d.className='dot '+(j.ok?'ok':'bad');t.innerHTML='';t.appendChild(d);t.append(j.ok?('3x-ui: '+j.xray+' CPU '+j.cpu+'%'):'3x-ui недоступен');}catch(e){d.className='dot bad';}}
poll();setInterval(poll,20000);
async function loadIb(){let d=[];try{const j=await (await fetch('/xui/inbounds')).json();if(j.ok)d=j.inbounds;}catch(e){}
const lb=i=>'№'+i.id+' · порт '+i.port+' · '+(i.clients||0)+' кл. · '+(i.remark||'');
const ac=document.getElementById('acInbound');if(ac){ac.innerHTML='<option value="">автовыбор</option>';d.forEach(i=>{const o=document.createElement('option');o.value=i.id;o.textContent=lb(i);ac.appendChild(o)});}
['addInbound','impInbound'].forEach(id=>{const s=document.getElementById(id);if(!s)return;const df=s.querySelector('option[value="0"]');s.innerHTML='';if(df)s.appendChild(df);d.forEach(i=>{const o=document.createElement('option');o.value=i.id;o.textContent=lb(i);s.appendChild(o)});});}
loadIb();
async function dg(){const t=document.getElementById('diagReport');t.value='Собираю…';try{const j=await (await fetch('/api/diagnostics')).json();t.value=j.report||j.error||'ошибка';}catch(e){t.value='Ошибка: '+e;}}
function cpt(b){const t=document.getElementById('diagReport');if(!t.value)return;t.select();navigator.clipboard.writeText(t.value).then(()=>{const x=b.textContent;b.textContent='✅';setTimeout(()=>b.textContent=x,1500)});}
async function upd(){document.getElementById('updOut').value=(await (await fetch('/update/status')).json()).text||'';}
async function prb(){document.getElementById('prbOut').value=JSON.stringify(await (await fetch('/api/probe')).json(),null,1);}
async function netSt(){const t=document.getElementById('netOut');if(!t)return;t.value=(await (await fetch('/net/status')).json()).text||'';}
async function certSt(){const t=document.getElementById('certOut');if(!t)return;t.value=(await (await fetch('/net/certstatus')).json()).text||'';}
</script></body></html>''')
pathlib.Path("templates/admin.html").write_text("".join(H))
print("admin.html готов")
PY_ADMTPL

echo "=========== 6. Расширение ==========="
cat > extension/manifest.json <<'EXT_M'
{"manifest_version":3,"name":"Proxy Manager Client","version":"5.0",
"description":"Прокси по ключу: пресеты, режимы, TLS-шифрование. Настройки выдаёт сервер.",
"permissions":["proxy","storage","webRequest","webRequestAuthProvider","alarms"],
"host_permissions":["<all_urls>"],"background":{"service_worker":"background.js"},
"action":{"default_popup":"popup.html","default_title":"Proxy Manager"}}
EXT_M

cat > extension/background.js <<'EXT_B'
const D={active:false,serverUrl:"",key:"",baseConfig:null,catalog:{presets:{},remote_lists:{}},userChoices:{mode:"whitelist",active_presets:[],custom_domains:[]}};
async function get(){const r=await chrome.storage.local.get("settings");const s=Object.assign({},D,r.settings||{});s.userChoices=Object.assign({},D.userChoices,s.userChoices||{});return s;}
async function put(s){await chrome.storage.local.set({settings:s});}
function dmap(ds){const m={};for(let d of ds){d=String(d||"").trim().toLowerCase().replace(/^\*\./,"").replace(/^\.+/,"").replace(/\.+$/,"");if(d&&/^[a-z0-9.-]+$/i.test(d))m[d]=1;}return m;}
function pac(cfg,mode,ds){
 const p=((cfg.scheme==="https")?"HTTPS ":"PROXY ")+cfg.host+":"+cfg.port;
 const head='function FindProxyForURL(u,h){h=h.toLowerCase();if(isPlainHostName(h)||h==="localhost"||shExpMatch(h,"*.local"))return "DIRECT";var ip=dnsResolve(h);if(ip&&(isInNet(ip,"127.0.0.0","255.0.0.0")||isInNet(ip,"10.0.0.0","255.0.0.0")||isInNet(ip,"172.16.0.0","255.240.0.0")||isInNet(ip,"192.168.0.0","255.255.0.0")))return "DIRECT";var M='+JSON.stringify(dmap(ds))+';function m(x){if(M[x])return true;var i=x.indexOf(".");while(i>0){x=x.slice(i+1);if(M[x])return true;i=x.indexOf(".");}return false;}var hit=m(h);';
 if(mode==="always")return head+'return "'+p+'";}';
 if(mode==="blacklist")return head+'return hit?"DIRECT":"'+p+'";}';
 return head+'return hit?"'+p+'":"DIRECT";}';}
function badge(on){chrome.action.setBadgeText({text:on?"ON":"OFF"});chrome.action.setBadgeBackgroundColor({color:on?"#16a34a":"#6b7280"});}
async function apply(s){
 if(!s.active||!s.baseConfig||s.userChoices.mode==="off"){await chrome.proxy.settings.clear({scope:"regular"});badge(false);return;}
 let ds=[...(s.userChoices.custom_domains||[])];const pr=(s.catalog&&s.catalog.presets)||{};
 for(const k of (s.userChoices.active_presets||[]))if(pr[k])ds=ds.concat(pr[k]);
 await chrome.proxy.settings.set({value:{mode:"pac_script",pacScript:{data:pac(s.baseConfig,s.userChoices.mode||"whitelist",ds)}},scope:"regular"});badge(true);}
async function ft(u,t=15000){const c=new AbortController();const x=setTimeout(()=>c.abort(),t);try{return await fetch(u,{signal:c.signal,cache:"no-store"});}finally{clearTimeout(x);}}
async function check(){const s=await get();if(!s.active||!s.key||!s.serverUrl)return;
 try{const r=await ft(s.serverUrl+"/api/ping?key="+encodeURIComponent(s.key));
  if(r.status===403){s.active=false;await put(s);await apply(s);return;}
  if(r.ok){const c=await ft(s.serverUrl+"/api/get_config?key="+encodeURIComponent(s.key));
   if(c.ok){const d=await c.json();s.baseConfig=d.base_config;s.catalog=d.catalog;await put(s);await apply(s);}}}catch(e){}}
chrome.runtime.onInstalled.addListener(async()=>{chrome.alarms.create("k",{periodInMinutes:15});await apply(await get());check();});
chrome.runtime.onStartup.addListener(async()=>{chrome.alarms.create("k",{periodInMinutes:15});await apply(await get());check();});
chrome.alarms.onAlarm.addListener(a=>{if(a.name==="k")check();});
chrome.runtime.onMessage.addListener((m,s,rep)=>{(async()=>{try{
 if(m.type==="GET_STATE")rep(await get());
 else if(m.type==="SAVE_STATE"){const x=Object.assign({},D,m.settings||{});x.userChoices=Object.assign({},D.userChoices,x.userChoices||{});await put(x);await apply(x);rep({ok:true});}
 else if(m.type==="CHECK_NOW"){await check();rep(await get());}
 else if(m.type==="LOAD_LIST"){const r=await ft(m.url,45000);if(!r.ok)throw new Error("HTTP "+r.status);
  const t=await r.text();const seen=new Set(),out=[];
  for(let l of t.split(/\r?\n/)){let d=l.trim().toLowerCase().replace(/^\|\|/,"").replace(/\^.*$/,"").replace(/^https?:\/\//,"").replace(/\/.*$/,"").replace(/^\.+/,"");
   if(d&&/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(d)&&!seen.has(d)){seen.add(d);out.push(d);if(out.length>=50000)break;}}
  rep({ok:true,domains:out});}
 else rep({ok:false,error:"unknown"});}catch(e){rep({ok:false,error:String((e&&e.message)||e)});}})();return true;});
chrome.webRequest.onAuthRequired.addListener((d,cb)=>{(async()=>{
 if(d.isProxy){const s=await get();const c=s.baseConfig;
  if(s.active&&c&&c.use_auth){cb({authCredentials:{username:c.username,password:c.password}});return;}}
 cb({});})();},{urls:["<all_urls>"]},["asyncBlocking"]);
EXT_B

cat > extension/popup.html <<'EXT_H'
<!doctype html><html lang=ru><head><meta charset=utf-8><style>
*{box-sizing:border-box}body{width:330px;margin:0;font-family:system-ui,sans-serif;background:#0f172a;color:#e2e8f0;padding:14px}
h1{font-size:15px;margin:0 0 10px}.hidden{display:none!important}
input,textarea{width:100%;padding:8px 10px;border:1px solid #334155;border-radius:8px;background:#1e293b;color:#e2e8f0;font-size:13px;margin-bottom:8px}
textarea{min-height:60px;font-family:monospace;font-size:11px}
button{padding:8px 12px;border:0;border-radius:8px;background:#3b82f6;color:#fff;font-size:13px;cursor:pointer}
button.wide{width:100%}button.ghost{background:#1e293b;border:1px solid #334155}button.danger{background:#7f1d1d}
.badge{display:block;text-align:center;padding:8px;border-radius:8px;font-size:13px;font-weight:600;margin-bottom:10px}
.badge.on{background:#14532d;color:#86efac}.badge.off{background:#334155;color:#94a3b8}
.modes{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-bottom:10px}
.mode-btn{background:#1e293b;border:1px solid #334155;text-align:left;padding:8px}.mode-btn.active{background:#3b82f6;border-color:#3b82f6}
.chips{display:flex;flex-wrap:wrap;gap:5px;margin-bottom:10px}
.chip{padding:5px 9px;border-radius:99px;background:#1e293b;border:1px solid #334155;font-size:12px;cursor:pointer}
.chip.active{background:#14532d;border-color:#166534;color:#86efac}
.st{font-size:12px;color:#94a3b8;min-height:16px;margin:6px 0}.st.error{color:#fca5a5}.st.ok{color:#86efac}
.sec{font-size:11px;color:#94a3b8;text-transform:uppercase;margin:10px 0 6px}.row{display:flex;gap:6px}.row button{flex:1}
hr{border:0;border-top:1px solid #334155;margin:12px 0}#srv{font-size:12px;color:#94a3b8;text-align:center;margin-bottom:8px}
</style></head><body><h1>🛰️ Proxy Manager</h1>
<div id=act><div id=srvBlock><div class=sec>Адрес сервера</div><input id=serverUrl value="__SERVER_URL__"></div>
<div class=sec>Ключ доступа</div><input id=key placeholder="A1B2C3D4" style="text-transform:uppercase">
<button id=go class=wide>🔑 Активировать</button><div id=actSt class=st></div></div>
<div id=ctl class=hidden><span id=badge class="badge off">⛔ Выключен</span><div id=srv></div>
<div class=modes><button class=mode-btn data-mode=whitelist>🎯 Только указанные</button><button class=mode-btn data-mode=blacklist>🚫 Все кроме</button><button class=mode-btn data-mode=always>🌍 Весь трафик</button><button class=mode-btn data-mode=off>⛔ Выключен</button></div>
<div class=sec>Пресеты</div><div id=chips class=chips></div>
<div class=sec>Свои домены</div><textarea id=custom placeholder="example.com"></textarea><button id=saveD class="ghost wide">💾 Сохранить домены</button>
<div class=sec>Списки</div><div class=row><button id=tg class=ghost>Telegram</button><button id=ru class=ghost>Заблокированные РФ</button></div>
<div class=row style="margin-top:6px"><button id=sync class=ghost>🔄 Обновить</button><button id=chk class=ghost>📡 Проверить ключ</button></div>
<div id=st class=st></div><hr><button id=sug class="ghost wide">💡 Предложить пресет</button>
<div id=sugF class=hidden style="margin-top:8px"><input id=sugN placeholder="Название"><textarea id=sugD placeholder="домены"></textarea>
<div class=row><button id=sugSend>Отправить</button><button id=sugCancel class=ghost>Отмена</button></div><div id=sugSt class=st></div></div>
<hr><button id=reset class="danger wide">🗑️ Сбросить ключ</button></div>
<script src=popup.js></script></body></html>
EXT_H

cat > extension/popup.js <<'EXT_J'
const $=i=>document.getElementById(i);let S={};
async function load(){S=await chrome.runtime.sendMessage({type:"GET_STATE"});
 const sb=$("srvBlock"),su=$("serverUrl");
 if(sb&&su&&/^https?:\/\/.+/.test(su.value)&&su.value.indexOf("__SERVER_URL__")===-1)sb.style.display="none";
 if(S.active&&S.baseConfig&&S.catalog){$("act").classList.add("hidden");$("ctl").classList.remove("hidden");render();}
 else{$("act").classList.remove("hidden");$("ctl").classList.add("hidden");if(S.serverUrl)$("serverUrl").value=S.serverUrl;}}
function render(){document.querySelectorAll(".mode-btn").forEach(b=>{b.classList.toggle("active",b.dataset.mode===S.userChoices.mode);b.onclick=()=>{S.userChoices.mode=b.dataset.mode;save();};});
 const c=$("chips");c.innerHTML="";const pr=(S.catalog&&S.catalog.presets)||{};
 for(const n of Object.keys(pr)){const e=document.createElement("div");const a=(S.userChoices.active_presets||[]).includes(n);
  e.className="chip"+(a?" active":"");e.textContent=(a?"✅ ":"⬜ ")+n;
  e.onclick=()=>{let l=S.userChoices.active_presets||[];S.userChoices.active_presets=l.includes(n)?l.filter(x=>x!==n):[...l,n];save();};c.appendChild(e);}
 $("custom").value=(S.userChoices.custom_domains||[]).join("\n");
 const sch=(S.baseConfig&&S.baseConfig.scheme==="https")?"🔒 TLS":"⚠️ HTTP";
 $("srv").textContent=sch+" · "+((S.baseConfig&&S.baseConfig.name)||"—")+" · "+S.key;badge();}
function badge(){const b=$("badge");if(S.userChoices.mode==="off"||!S.active){b.textContent="⛔ Выключен";b.className="badge off";}
 else{const l={whitelist:"🎯 Только указанные",blacklist:"🚫 Все кроме указанных",always:"🌍 Весь трафик"};b.textContent=l[S.userChoices.mode]||"✅ Работает";b.className="badge on";}}
async function save(){render();await chrome.runtime.sendMessage({type:"SAVE_STATE",settings:S});}
function fl(i,t,ok){const e=$(i);e.textContent=t;e.className="st"+(ok===true?" ok":ok===false?" error":"");if(ok===true)setTimeout(()=>{if(e.textContent===t)e.textContent="";},4000);}
$("go").onclick=async()=>{const u=$("serverUrl").value.trim().replace(/\/+$/,""),k=$("key").value.trim().toUpperCase();
 if(!u||!k){fl("actSt","❌ Заполните поля",false);return;}fl("actSt","⏳ Проверка…");
 try{const c=new AbortController();const t=setTimeout(()=>c.abort(),15000);
  const r=await fetch(u+"/api/get_config?key="+encodeURIComponent(k),{signal:c.signal});clearTimeout(t);
  if(!r.ok){let m="HTTP "+r.status;try{const j=await r.json();if(j.error)m=j.error;}catch(e){}throw new Error(m);}
  const d=await r.json();S={active:true,serverUrl:u,key:k,baseConfig:d.base_config,catalog:d.catalog,userChoices:{mode:"whitelist",active_presets:["Telegram"],custom_domains:[]}};
  await chrome.runtime.sendMessage({type:"SAVE_STATE",settings:S});fl("actSt","✅ Готово",true);setTimeout(load,600);}
 catch(e){fl("actSt","❌ "+(e.name==="AbortError"?"Сервер не отвечает":e.message),false);}};
$("saveD").onclick=()=>{S.userChoices.custom_domains=[...new Set($("custom").value.split(/\r?\n/).map(x=>x.trim().toLowerCase()).filter(Boolean))];save();fl("st","✅ Сохранено",true);};
$("sync").onclick=async()=>{fl("st","🔄 Обновление…");try{const r=await fetch(S.serverUrl+"/api/get_config?key="+encodeURIComponent(S.key));
 if(r.status===403){await chrome.runtime.sendMessage({type:"SAVE_STATE",settings:{active:false}});load();return;}
 if(!r.ok)throw new Error("HTTP "+r.status);const d=await r.json();S.catalog=d.catalog;S.baseConfig=d.base_config;await save();fl("st","✅ Обновлено",true);}catch(e){fl("st","❌ "+e.message,false);}};
$("chk").onclick=async()=>{fl("st","📡 Проверка…");S=await chrome.runtime.sendMessage({type:"CHECK_NOW"});if(!S.active){load();return;}render();fl("st","✅ Ключ активен",true);};
async function rl(t){fl("st","⏳ Загрузка…");const L=(S.catalog&&S.catalog.remote_lists)||{};const u=t==="tg"?L.telegram_actual:L.all_ru_blocked;
 if(!u){fl("st","❌ Ссылка не настроена",false);return;}
 const r=await chrome.runtime.sendMessage({type:"LOAD_LIST",url:u});
 if(r.ok){const s=new Set(S.userChoices.custom_domains||[]);let n=0;r.domains.forEach(d=>{if(!s.has(d)){s.add(d);n++;}});S.userChoices.custom_domains=[...s];await save();fl("st","✅ +"+n+" доменов",true);}
 else fl("st","❌ "+r.error,false);}
$("tg").onclick=()=>rl("tg");$("ru").onclick=()=>rl("ru");
$("sug").onclick=()=>{$("sugF").classList.remove("hidden");$("sug").classList.add("hidden");};
$("sugCancel").onclick=()=>{$("sugF").classList.add("hidden");$("sug").classList.remove("hidden");$("sugN").value="";$("sugD").value="";$("sugSt").textContent="";};
$("sugSend").onclick=async()=>{const n=$("sugN").value.trim(),d=$("sugD").value.trim();
 if(!n||!d){fl("sugSt","❌ Заполните поля",false);return;}
 try{const r=await fetch(S.serverUrl+"/api/suggest_preset",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({key:S.key,name:n,domains:d})});
  if(!r.ok){let m="HTTP "+r.status;try{const j=await r.json();if(j.error)m=j.error;}catch(e){}throw new Error(m);}
  fl("sugSt","✅ Отправлено",true);setTimeout(()=>$("sugCancel").click(),2000);}catch(e){fl("sugSt","❌ "+e.message,false);}};
$("reset").onclick=async()=>{if(confirm("Удалить ключ?")){await chrome.runtime.sendMessage({type:"SAVE_STATE",settings:{active:false}});load();}};
load();
EXT_J

echo "=========== 7. Резервный канал ==========="
cat > /opt/rescue-agent/agent.py <<'AGENT_PY'
#!/usr/bin/env python3
import http.server,ssl,subprocess,os,secrets,time,hmac,urllib.parse,glob,socketserver
B="/opt/rescue-agent"; TF=B+"/token"
if not os.path.exists(TF):
    open(TF,"w").write(secrets.token_urlsafe(24)); os.chmod(TF,0o600)
TOKEN=open(TF).read().strip()
SVC={"proxy-admin","proxy-web","proxy-bot","proxy-monitor","nginx","ssh","x-ui","web-term","web-files","rescue-agent"}
CMDS={"disk":["df","-h"],"mem":["free","-m"],"ports":["ss","-tulnp"],
 "ps":["ps","-eo","pid,user,%cpu,%mem,etime,cmd","--sort=-%cpu"],
 "net":["ss","-tnp","state","established"],"uptime":["uptime"],
 "nginxtest":["nginx","-t"],"sshtest":["sshd","-t"],
 "netsetup":["bash","/opt/proxy-manager/net-setup.sh"],
 "installerr":["bash","-c","cat /root/pm-install.err 2>/dev/null; tail -40 /root/pm-install.log"],
 "certs":["bash","-c","for f in /root/cert/*/fullchain.pem /etc/letsencrypt/live/*/fullchain.pem /etc/pm-web/self.crt; do [ -f \"$f\" ] && { echo \"$f\"; openssl x509 -in \"$f\" -noout -enddate -subject; }; done"]}
def run(a,t=30):
    try:
        r=subprocess.run(a,capture_output=True,text=True,timeout=t); return (r.stdout+r.stderr).strip() or "(пусто)"
    except Exception as e: return "(ошибка %s)"%e
def report():
    L=["=== RESCUE REPORT ===",time.strftime("%F %T"),""]
    for s in sorted(SVC): L.append("svc %-16s %s"%(s,run(["systemctl","is-active",s],6)))
    L+=["","--disk--",run(["df","-h","/"]),"--mem--",run(["free","-m"]),"--ports--",run(["ss","-tulnp"])]
    for s in ["proxy-admin","proxy-web","proxy-bot","nginx"]:
        L+=["","--log %s--"%s,run(["journalctl","-u",s,"-n","15","--no-pager"])]
    return "\n".join(L)
PAGE="""<!doctype html><meta charset=utf-8><title>Rescue</title><style>
body{font-family:system-ui;background:#0b1020;color:#e7ecf5;padding:24px;max-width:960px;margin:auto}
a{color:#22d3ee;display:inline-block;margin:4px 8px 4px 0;padding:9px 15px;border:1px solid #334155;border-radius:10px;text-decoration:none}
a:hover{background:#1e293b}h1{font-size:20px}</style><h1>🛟 Резервный канал</h1>
<p>Перезапуск:</p>__S__<p>Данные:</p>__C__<p><a href="/__T__/report">📄 Полный отчёт</a></p>"""
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def _s(self,c,b,ct="text/plain; charset=utf-8"):
        b=b.encode() if isinstance(b,str) else b
        self.send_response(c); self.send_header("Content-Type",ct)
        self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        u=urllib.parse.urlparse(self.path); p=[x for x in u.path.split("/") if x]
        if not p or not hmac.compare_digest(p[0],TOKEN):
            time.sleep(1.5); return self._s(403,"forbidden")
        r=p[1:]
        if not r:
            s="".join('<a href="/%s/restart/%s">↻ %s</a>'%(TOKEN,x,x) for x in sorted(SVC))
            c="".join('<a href="/%s/cmd/%s">%s</a>'%(TOKEN,k,k) for k in CMDS)
            return self._s(200,PAGE.replace("__T__",TOKEN).replace("__S__",s).replace("__C__",c),"text/html; charset=utf-8")
        if r[0]=="report": return self._s(200,report())
        if r[0]=="logs" and len(r)>1 and r[1] in SVC:
            n=min(int(urllib.parse.parse_qs(u.query).get("n",["150"])[0]),600)
            return self._s(200,run(["journalctl","-u",r[1],"-n",str(n),"--no-pager"],25))
        if r[0]=="restart" and len(r)>1 and r[1] in SVC:
            return self._s(200,"restart %s: %s"%(r[1],run(["systemctl","restart",r[1]],40) or "ok"))
        if r[0]=="cmd" and len(r)>1 and r[1] in CMDS: return self._s(200,run(CMDS[r[1]],90))
        return self._s(404,"not found")
class S(socketserver.ThreadingMixIn,http.server.HTTPServer): daemon_threads=True
if __name__=="__main__":
    cert=key=None
    for c in glob.glob("/etc/letsencrypt/live/*/fullchain.pem")+glob.glob("/root/cert/*/fullchain.pem"):
        k=c.replace("fullchain.pem","privkey.pem")
        if os.path.exists(k): cert,key=c,k; break
    if not cert and os.path.exists("/etc/pm-web/self.crt"): cert,key="/etc/pm-web/self.crt","/etc/pm-web/self.key"
    srv=S(("0.0.0.0",8444),H)
    if cert:
        ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert,key)
        srv.socket=ctx.wrap_socket(srv.socket,server_side=True)
    srv.serve_forever()
AGENT_PY
chmod 700 /opt/rescue-agent
cat > /etc/systemd/system/rescue-agent.service <<'U'
[Unit]
Description=Rescue Management Agent
After=network-online.target
[Service]
ExecStart=/usr/bin/python3 /opt/rescue-agent/agent.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
U
systemctl daemon-reload && systemctl enable --now rescue-agent

echo "=========== 8. Python-окружение ==========="
python3 -m venv venv || { echo "!!! venv не создался"; exit 1; }
./venv/bin/pip install -q --upgrade pip
./venv/bin/pip install -q "fastapi>=0.110" "uvicorn>=0.29" "aiogram>=3.7,<4" requests aiosqlite \
  "apscheduler>=3.10,<4" jinja2 python-multipart passlib "bcrypt==4.0.1" "pydantic>=2" qrcode pillow cryptography
./venv/bin/python -c "import common;common.init_db();print('БД ok')" || exit 1
./venv/bin/python -c "import common as cm; cm.setS({'domain':'$DOMAIN'})"
for m in common xui_api admin_app web_app bot monitor; do
  ./venv/bin/python -c "import $m" 2>/dev/null && echo "  OK $m" || echo "  FAIL $m"
done
./venv/bin/python - <<'CHK'
import admin_app,web_app,common as cm
s=cm.S()
admin_app.T.env.get_template("admin.html").render(s=s,clients=cm.clients(),suggestions=[],msg="",user="admin")
web_app.T.env.get_template("landing.html").render(s=s,msg="",admin_url="x",n_clients=0,n_presets=0)
print("шаблоны ok")
CHK

echo "=========== 9. Сервисы и сеть ==========="
for pair in admin:8003 web:8002; do n=${pair%%:*}; p=${pair##*:}
cat > /etc/systemd/system/proxy-$n.service <<U
[Unit]
Description=Proxy Manager $n
After=network-online.target
[Service]
WorkingDirectory=$APP
ExecStart=$APP/venv/bin/uvicorn ${n}_app:app --host 127.0.0.1 --port $p
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
U
done
for n in bot monitor; do
cat > /etc/systemd/system/proxy-$n.service <<U
[Unit]
Description=Proxy Manager $n
After=network-online.target
[Service]
WorkingDirectory=$APP
ExecStart=$APP/venv/bin/python $n.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
U
done
systemctl daemon-reload && systemctl enable proxy-admin proxy-web proxy-bot proxy-monitor >/dev/null 2>&1
systemctl restart proxy-admin proxy-web proxy-bot proxy-monitor
sleep 4
bash "$APP/net-setup.sh"
sleep 2

echo "--- ПРОВЕРКА ПОРТОВ ---"
for pp in 80 443 8443 2087 2083 2096 8444; do
  ss -tln | grep -q ":$pp " && echo "  $pp слушает" || echo "  $pp НЕ слушает!"
done
for u in http://127.0.0.1:7681 http://127.0.0.1:8080 http://127.0.0.1:8003/login http://127.0.0.1:8002/; do
  echo "  $u -> $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u" || echo 000)"
done
BASE=$([ -n "$DOMAIN" ] && echo "$DOMAIN" || echo "$SRV_IP")
GT=$(./venv/bin/python -c "import common;print(common.S()['guest_token'])")
RT=$(cat /opt/rescue-agent/token 2>/dev/null)
echo
echo "============================================================"
systemctl is-active proxy-admin proxy-web proxy-bot proxy-monitor nginx web-term web-files rescue-agent
cat <<SUM

 ✅ УСТАНОВЛЕНО — работа по ${BASE}
------------------------------------------------------------
 🖥  ВЕБ-КОНСОЛЬ   https://${BASE}:2087   ${WU} / ${WP}
 📁 ФАЙЛЫ         https://${BASE}:2083   ${WU} / ${WP}
 🌐 ГЛАВНАЯ       https://${BASE}/
 🛡  АДМИНКА       https://${BASE}:8443   admin / admin (СМЕНИ!)
 🔄 ПОДПИСКИ      https://${BASE}:2096/sub/<id>
 🛟 РЕЗЕРВ        https://${BASE}:8444/${RT}/
------------------------------------------------------------
 Сертификат самоподписанный -> браузер предупредит.
 «Дополнительно -> Перейти». Это нормально.
------------------------------------------------------------
 ДАЛЬШЕ (из админки):
 1) ⚙️ Настройки -> 3x-ui: URL/логин/пароль -> Сохранить -> 🪄 Подтянуть
 2) ⚙️ Настройки -> Telegram: токен бота + свой TG ID
 3) 🌐 Домен и HTTPS: впиши домен -> Применить -> Запросить Let's Encrypt
    (или укажи свои пути к сертификату)
 4) 🧰 Сервис -> 🔒 Включить TLS на всех прокси  <- шифрование браузера
    (включится только после валидного сертификата)
 5) 🧰 Сервис -> 🛰️ Гостевой доступ -> Включить, ссылка:
    https://${BASE}/guest/${GT}
------------------------------------------------------------
 Пароли: /etc/pm-web/cred
 Лог установки: /root/pm-install.log
 Ошибки (если были): /root/pm-install.err
 Перенастроить сеть: bash $APP/net-setup.sh
============================================================
SUM
[ -s "$ERRF" ] && { echo; echo "⚠️ Были ошибки на этапах (не критично, если всё выше активно):"; cat "$ERRF"; }
