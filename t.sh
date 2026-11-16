#!/usr/bin/env bash
# =====================================================================
#  PROXY MANAGER v7 — единый установщик
#  Веб-консоль + файлы + шифрованный браузер-прокси + биллинг + бот
#  Автоподхват сертификатов, режимы: авто / свой / self-signed / LE
#  Запуск: bash t.sh        DOMAIN=example.com bash t.sh
# =====================================================================
set -uo pipefail
APP=/opt/proxy-manager
WU="${WU:-admin}"
WP="${WP:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)}"
LOG=/root/pm-install.log; ERRF=/root/pm-install.err
[ "$(id -u)" = 0 ] || { echo "Нужен root"; exit 1; }
exec > >(tee -a "$LOG") 2>&1
trap 'echo "строка $LINENO: ошибка команды" >> "$ERRF"' ERR
rm -f "$ERRF"

echo "=========== 1. Пакеты, IP ==========="
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv python3-pip \
  nginx certbot curl git zip tar openssl ufw ca-certificates openssh-client dnsutils
mkdir -p "$APP/templates" "$APP/extension" /etc/pm-web /var/www/certbot /opt/rescue-agent
SRV_IP=$(curl -4 -s --max-time 8 https://api.ipify.org || true)
[ -z "$SRV_IP" ] && SRV_IP=$(curl -4 -s --max-time 8 https://ifconfig.me || true)
[ -z "$SRV_IP" ] && SRV_IP=$(hostname -I | awk '{print $1}')
DOMAIN="${DOMAIN:-}"
echo "IP: $SRV_IP"; [ -n "$DOMAIN" ] && echo "Домен: $DOMAIN" || echo "Домен определится из сертификата"

echo "=========== 2. ВЕБ-ДОСТУП (первым делом) ==========="
printf '%s\n' "$WU" "$WP" > /etc/pm-web/cred; chmod 600 /etc/pm-web/cred
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout /etc/pm-web/self.key -out /etc/pm-web/self.crt \
  -subj "/CN=${DOMAIN:-$SRV_IP}" -addext "subjectAltName=DNS:${DOMAIN:-$SRV_IP},IP:$SRV_IP,IP:127.0.0.1" 2>/dev/null
chmod 600 /etc/pm-web/self.key
command -v ttyd >/dev/null 2>&1 || { curl -fsSL -o /usr/local/bin/ttyd \
  https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.x86_64 && chmod +x /usr/local/bin/ttyd; }
command -v filebrowser >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/filebrowser/get/master/get.sh | bash || true
command -v filebrowser >/dev/null 2>&1 || { curl -fsSL -o /tmp/fb.tgz \
  https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz \
  && tar -xzf /tmp/fb.tgz -C /usr/local/bin filebrowser && chmod +x /usr/local/bin/filebrowser; } || true
cat > /etc/systemd/system/web-term.service <<U
[Unit]
Description=Web Terminal
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
Description=Web Files
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
  location / { return 200 "installing..."; } }
server { listen 2087 ssl default_server; server_name _;
  ssl_certificate /etc/pm-web/self.crt; ssl_certificate_key /etc/pm-web/self.key;
  location / { proxy_pass http://127.0.0.1:7681; proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade";
    proxy_set_header Host \$host; proxy_read_timeout 86400; } }
server { listen 2083 ssl default_server; server_name _;
  ssl_certificate /etc/pm-web/self.crt; ssl_certificate_key /etc/pm-web/self.key;
  client_max_body_size 4096m;
  location / { proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$host; } }
NG
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/proxy-manager /etc/nginx/sites-enabled/proxy-manager
nginx -t && systemctl enable --now nginx && systemctl restart nginx
systemctl daemon-reload && systemctl enable --now web-term web-files
command -v ufw >/dev/null && { for p in 22 2222 80 443 2087 2083 8443 8444 2096; do ufw allow $p/tcp; done; ufw allow 20000:21000/tcp; } || true
sleep 2
echo "############################################################"
echo "#  КОНСОЛЬ: https://${SRV_IP}:2087   ${WU} / ${WP}"
echo "#  ФАЙЛЫ:   https://${SRV_IP}:2083"
echo "#  Сертификат пока самоподписанный -> Дополнительно/Перейти"
echo "############################################################"

echo "=========== 3. net-setup.sh (применить сертификат везде) ==========="
cat > "$APP/net-setup.sh" <<'NETSETUP'
#!/usr/bin/env bash
# Выбирает лучший сертификат и применяет его ВЕЗДЕ: nginx, прокси xray, rescue.
set -uo pipefail
APP=/opt/proxy-manager; cd "$APP" || exit 1
read -r DOMAIN CERT KEY TRUSTED <<<"$(./venv/bin/python - <<'PY'
import common as cm
s=cm.S(); c,k=cm.tlspaths(s)
print((s.get("domain") or "-"),(c or "-"),(k or "-"),("1" if cm.cert_trusted(s) else "0"))
PY
)"
[ "$DOMAIN" = "-" ] && DOMAIN=""
[ "$CERT" = "-" ] && CERT=""
[ "$KEY" = "-" ] && KEY=""
IP=$(curl -4 -s --max-time 6 https://api.ipify.org || true); [ -z "$IP" ] && IP=$(hostname -I|awk '{print $1}')
SN="${DOMAIN:-$IP}"
if [ -z "$CERT" ] || [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
  echo "Валидного сертификата нет — самоподписанный для $SN"
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout /etc/pm-web/self.key \
    -out /etc/pm-web/self.crt -subj "/CN=$SN" \
    -addext "subjectAltName=DNS:$SN,IP:$IP,IP:127.0.0.1" 2>/dev/null
  chmod 600 /etc/pm-web/self.key; CERT=/etc/pm-web/self.crt; KEY=/etc/pm-web/self.key
fi
echo "Сертификат: $CERT (валидный/доверенный: $TRUSTED)"
cat > /etc/nginx/sites-available/proxy-manager <<NG
server { listen 80 default_server; server_name ${DOMAIN:-_};
  location /.well-known/acme-challenge/ { root /var/www/certbot; }
  location / { return 301 https://\$host\$request_uri; } }
server { listen 443 ssl default_server; server_name ${DOMAIN:-_};
  ssl_certificate ${CERT}; ssl_certificate_key ${KEY}; ssl_protocols TLSv1.2 TLSv1.3;
  client_max_body_size 4096m;
  location / { proxy_pass http://127.0.0.1:8002; proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https; } }
server { listen 8443 ssl; server_name ${DOMAIN:-_};
  ssl_certificate ${CERT}; ssl_certificate_key ${KEY}; ssl_protocols TLSv1.2 TLSv1.3;
  client_max_body_size 4096m;
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
  ssl_certificate ${CERT}; ssl_certificate_key ${KEY}; ssl_protocols TLSv1.2 TLSv1.3;
  client_max_body_size 4096m;
  location / { proxy_pass http://127.0.0.1:8080; proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-Proto https; proxy_read_timeout 3600; } }
NG
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/acme
ln -sf /etc/nginx/sites-available/proxy-manager /etc/nginx/sites-enabled/proxy-manager
nginx -t && systemctl reload nginx || { echo "ОШИБКА NGINX"; nginx -t; exit 1; }
./venv/bin/python - <<PY
import common as cm
d="${DOMAIN}"; ip="${IP}"; base=d or ip
cm.setS({"public_url":"https://"+base,"admin_url":"https://"+base+":8443","sub_url_base":"https://"+base+":2096"})
print("URL: https://"+base)
try:
    ok,msg=cm.apply_proxy_tls()
    print("Прокси xray:",msg)
except Exception as e:
    print("Прокси xray пропущены:",e)
PY
systemctl restart rescue-agent 2>/dev/null || true
echo "Готово: $SN"
NETSETUP
chmod +x "$APP/net-setup.sh"

echo "=========== 4. Модули ==========="
cd "$APP"
cat > common.py <<'PY_COMMON'
import json,sqlite3,time,secrets,hmac,hashlib,base64,io,zipfile,os,re,string,subprocess,socket,calendar
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
"public_url":"","admin_url":"","sub_url_base":"","proxy_tls":"1","cert_mode":"auto",
"tls_cert":"","tls_key":"","le_email":"",
"site_name":"Инфоструктура","site_tagline":"Проектируем, размещаем и сопровождаем серверы и веб-сервисы для малого и среднего бизнеса.",
"site_about":"","site_phone":"","site_email":"","site_inn":"","site_addr":"",
"site_years":"12","site_projects":"240","site_uptime":"99.9",
"guest_enabled":"0","guest_token":secrets.token_urlsafe(24),
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
    finally: c.close()
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
    w=hmac.new(str(sec).encode(),f"{tg_id}:{amt}".encode(),hashlib.sha256).hexdigest()
    return hmac.compare_digest(w,str(sg or ""))
def extzip(s,h):
    url=pbase(s); b=io.BytesIO()
    with zipfile.ZipFile(b,"w",zipfile.ZIP_DEFLATED) as z:
        for p in sorted((BASE/"extension").rglob("*")):
            if p.is_file(): z.writestr("pm-client/"+str(p.relative_to(BASE/"extension")),p.read_bytes().replace(b"__SERVER_URL__",url.encode()))
    return b.getvalue()
def _run(cmd,t=8):
    try:
        r=subprocess.run(cmd,shell=True,capture_output=True,text=True,timeout=t); return (r.stdout+r.stderr).strip()
    except Exception as e: return f"(err {e})"

# ================= СЕРТИФИКАТЫ: поиск, выбор, применение =================
def _cinfo(cert):
    out=_run(f"openssl x509 -in '{cert}' -noout -subject -issuer -enddate -ext subjectAltName 2>/dev/null",8)
    cn=""; iss=""; sub=""; end=""; sans=[]
    for ln in out.splitlines():
        ln=ln.strip()
        if ln.startswith("subject="): sub=ln.split("=",1)[1].strip(); m=re.search(r"CN\s*=\s*([^,/]+)",sub); cn=m.group(1).strip() if m else ""
        elif ln.startswith("issuer="): iss=ln.split("=",1)[1].strip()
        elif ln.startswith("notAfter="): end=ln.split("=",1)[1].strip()
        elif "DNS:" in ln or "IP Address:" in ln:
            for part in ln.split(","):
                if ":" in part: sans.append(part.split(":",1)[1].strip())
    days=None
    if end:
        try: days=int((calendar.timegm(time.strptime(end,"%b %d %H:%M:%S %Y %Z"))-time.time())/86400)
        except Exception: days=None
    return {"cn":cn,"sans":sans,"end":end,"days":days,"selfsigned":bool(sub) and sub==iss}
def cert_list(s=None):
    s=s or S(); out=[]; seen=set(); paths=[]
    c=(s.get("tls_cert") or "").strip(); k=(s.get("tls_key") or "").strip()
    if c and k and os.path.isfile(c) and os.path.isfile(k): paths.append((c,k,"вручную"))
    for base in ("/root/cert","/etc/letsencrypt/live","/etc/x-ui/cert","/opt/cert","/etc/ssl/pm"):
        if os.path.isdir(base):
            try: dirs=sorted(os.listdir(base))
            except Exception: dirs=[]
            for d in dirs:
                p=os.path.join(base,d)
                if not os.path.isdir(p): continue
                for cn,kn in (("fullchain.pem","privkey.pem"),("cert.pem","key.pem"),("server.crt","server.key")):
                    cc,kk=os.path.join(p,cn),os.path.join(p,kn)
                    if os.path.isfile(cc) and os.path.isfile(kk): paths.append((cc,kk,base))
    if os.path.isfile("/etc/pm-web/self.crt"): paths.append(("/etc/pm-web/self.crt","/etc/pm-web/self.key","self-signed"))
    dom=(s.get("domain") or "").strip(); ip=server_ip()
    for cc,kk,src in paths:
        if cc in seen: continue
        seen.add(cc); i=_cinfo(cc)
        names=[i["cn"]]+i["sans"]
        valid=(i["days"] is None or i["days"]>0)
        out.append({"cert":cc,"key":kk,"src":src,"cn":i["cn"],"sans":i["sans"],"end":i["end"],
          "days":i["days"],"selfsigned":i["selfsigned"],"valid":valid,
          "trusted":(not i["selfsigned"]) and valid,
          "match":bool((dom and dom in names) or (ip and ip in names))})
    return out
def best_cert(s=None):
    s=s or S(); mode=(s.get("cert_mode") or "auto").lower()
    lst=cert_list(s)
    if mode=="manual":
        c=(s.get("tls_cert") or "").strip(); k=(s.get("tls_key") or "").strip()
        if c and k and os.path.isfile(c) and os.path.isfile(k): return c,k
    if mode=="self":
        for x in lst:
            if x["cert"].endswith("self.crt"): return x["cert"],x["key"]
    good=[x for x in lst if x["trusted"]]
    good.sort(key=lambda x:(not x["match"], -(x["days"] or 0)))
    if good: return good[0]["cert"],good[0]["key"]
    for x in lst:
        if x["cert"].endswith("self.crt"): return x["cert"],x["key"]
    return "",""
def tlspaths(s=None): return best_cert(s)
def cert_trusted(s=None):
    s=s or S(); c,_=best_cert(s)
    if not c: return False
    for x in cert_list(s):
        if x["cert"]==c: return x["trusted"]
    return False
def tlson(s=None):
    s=s or S()
    if str(s.get("proxy_tls","1"))!="1": return False
    return cert_trusted(s)
def apply_proxy_tls(s=None):
    """Ставит TLS на все браузерные http-inbound'ы (или снимает)."""
    s=s or S(); on=tlson(s); cert,key=tlspaths(s)
    try: x=xui(s,15)
    except Exception as e: return False,f"3x-ui недоступен: {e}"
    n=0; errs=[]
    for c in clients():
        if not c.get("http_inbound_id"): continue
        try:
            b=x.get_inbound(c["http_inbound_id"]); ss=b.get("streamSettings")
            if isinstance(ss,str): ss=json.loads(ss or "{}")
            ss=dict(ss or {}); ss.pop("realitySettings",None)
            if on:
                ss["security"]="tls"
                ss["tlsSettings"]={"certificates":[{"certificateFile":cert,"keyFile":key}],"alpn":["http/1.1"],"minVersion":"1.2"}
            else:
                ss["security"]="none"; ss.pop("tlsSettings",None)
            b["streamSettings"]=ss; x.update_inbound(b); n+=1
        except Exception as e: errs.append(str(e)[:60])
    return True,f"{'TLS включён' if on else 'TLS снят'} на {n} прокси"+(("; "+"; ".join(errs)) if errs else "")
def report():
    s=S(); c,_=tlspaths(s)
    L=["=== PROXY MANAGER REPORT ===",time.strftime("%F %T"),
       f"domain={s.get('domain') or '(по IP)'} ip={server_ip()}",
       f"cert={c or 'нет'} trusted={cert_trusted(s)} tls_proxy={tlson(s)} mode={s.get('cert_mode')}"]
    try:
        for x in cert_list(s):
            L.append("  cert %s CN=%s days=%s trusted=%s match=%s"%(x["cert"],x["cn"],x["days"],x["trusted"],x["match"]))
    except Exception as e: L.append("cert err %s"%e)
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
        with db() as con:
            L.append("DB clients=%s regs=%s plans=%s promos=%s"%(con.execute("SELECT COUNT(*) FROM clients").fetchone()[0],
              con.execute("SELECT COUNT(*) FROM registrations").fetchone()[0],con.execute("SELECT COUNT(*) FROM plans").fetchone()[0],
              con.execute("SELECT COUNT(*) FROM promos").fetchone()[0]))
            for r in con.execute("SELECT id,name,email,plan_id,paid_until,enabled,balance,http_port,inbound_id FROM clients LIMIT 25"):
                L.append("  #%s %s %s plan=%s paid=%s on=%s bal=%s http=%s ib=%s"%tuple(r))
    except Exception as e: L.append("db err %s"%e)
    for v in ["proxy-admin","proxy-web","proxy-bot","proxy-monitor"]:
        L.append("--- %s ---"%v); L.append(_run(f"journalctl -u {v} -n 12 --no-pager 2>&1|tail -12",6))
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
T.env.globals.update(get_plans=cm.plans,get_plan=cm.plan,get_promos=cm.promos,get_regs=_regs,
  get_clients_full=cm.clients,load_json=json.loads,server_ip=cm.server_ip,
  cert_path=lambda: cm.tlspaths()[0] or "нет",cert_ok=cm.cert_trusted,tls_on=cm.tlson)
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
    try: bal=float(f.get("balance",0) or 0); lim=float(f.get("limit_gb",0) or 0); ibid=int(f.get("inbound_id",0) or 0)
    except ValueError: return rd("Числа неверны")
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
    try:
        ca=cm.ibcache(cm.S(),True)
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
    p=cm.ibcache(s).get(str(ch["id"])) or {}
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
@app.post("/guest/toggle")
def gt(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    s=cm.S(); cm.setS({"guest_enabled":"0" if s.get("guest_enabled")=="1" else "1"}); return rd("Гостевой доступ переключён")
@app.post("/guest/rotate")
def gr(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    cm.setS({"guest_token":secrets.token_urlsafe(24),"guest_enabled":"0"}); return rd("Токен обновлён")
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
        return rd("Применено, перезапуск. «Статус» через 10 сек")
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
      headers={"Content-Disposition":"attachment; filename=pm-client.zip"})

# ================= СЕРТИФИКАТЫ =================
NETLOG="/opt/proxy-manager/net_result.txt"; CERTLOG="/opt/proxy-manager/cert_result.txt"
@app.get("/certs")
def certs_page(r:Request,msg:str=""):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    s=cm.S()
    return T.TemplateResponse(r,"certs.html",{"s":s,"msg":msg,"certs":cm.cert_list(s),
      "chosen":cm.tlspaths(s)[0],"trusted":cm.cert_trusted(s),"tlson":cm.tlson(s),"ip":cm.server_ip()})
@app.post("/certs/apply")
async def certs_apply(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form()
    dom=re.sub(r"^https?://","",str(f.get("domain","")).strip().lower()).split("/")[0]
    cm.setS({"cert_mode":str(f.get("cert_mode","auto")),"domain":dom,
      "tls_cert":str(f.get("tls_cert","")).strip(),"tls_key":str(f.get("tls_key","")).strip(),
      "le_email":str(f.get("le_email","")).strip(),"proxy_tls":str(f.get("proxy_tls","1"))})
    open(NETLOG,"w").write("ПРИМЕНЯЕТСЯ…")
    subprocess.Popen(["bash","-c",f"bash {cm.BASE}/net-setup.sh > {NETLOG} 2>&1"],
      stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return RedirectResponse("/certs?msg="+quote("Применяю везде (nginx + прокси + резерв). Обнови страницу через 10 сек."),status_code=303)
@app.post("/certs/le")
async def certs_le(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    s=cm.S(); d=(s.get("domain") or "").strip()
    if not d: return RedirectResponse("/certs?msg="+quote("Сначала укажи домен и нажми «Применить везде»"),status_code=303)
    ip=cm.server_ip()
    try: dip=socket.gethostbyname(d)
    except Exception: dip=None
    warn="" if dip==ip else f"\nВНИМАНИЕ: {d} -> {dip}, IP сервера {ip}\n"
    em=(s.get("le_email") or "").strip(); mail=f"-m {em}" if em else "--register-unsafely-without-email"
    open(CERTLOG,"w").write("ЗАПРОС…"+warn)
    sc=(f"{{ echo 'certbot для {d}'; certbot certonly --webroot -w /var/www/certbot -d {d} "
        f"--non-interactive --agree-tos {mail} --deploy-hook 'systemctl reload nginx' 2>&1; "
        f"if [ -f /etc/letsencrypt/live/{d}/fullchain.pem ]; then echo 'ПОЛУЧЕН'; bash {cm.BASE}/net-setup.sh 2>&1; "
        f"else echo 'НЕ УДАЛОСЬ: домен должен указывать на {ip}, порт 80 открыт'; fi; }} > {CERTLOG} 2>&1")
    subprocess.Popen(["bash","-c",sc],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    return RedirectResponse("/certs?msg="+quote("Запрос запущен, обнови через 20-30 сек."+warn),status_code=303)
@app.post("/certs/proxy")
def certs_proxy(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    ok,m=cm.apply_proxy_tls()
    return RedirectResponse("/certs?msg="+quote(m),status_code=303)
@app.get("/certs/status")
def certs_status(r:Request):
    if not auth(r): return JSONResponse({"ok":False},status_code=401)
    t=""
    for p in (NETLOG,CERTLOG):
        try: t+="\n--- "+p+" ---\n"+open(p).read()
        except Exception: pass
    return {"ok":True,"text":t or "Пока ничего не запускали"}
@app.get("/site")
def site_edit(r:Request,msg:str=""):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    return T.TemplateResponse(r,"site.html",{"s":cm.S(),"msg":msg})
@app.post("/site")
async def site_save(r:Request):
    if not auth(r): return RedirectResponse("/login",status_code=303)
    f=await r.form(); up={}
    for k in ("site_name","site_tagline","site_about","site_phone","site_email","site_inn","site_addr",
              "site_years","site_projects","site_uptime"):
        if k in f: up[k]=str(f[k]).strip()
    cm.setS(up); return RedirectResponse("/site?msg="+quote("Сохранено"),status_code=303)
PY_ADMIN

cat > web_app.py <<'PY_WEB'
import base64,json,re,time,secrets
from pathlib import Path
from urllib.parse import quote
from fastapi import FastAPI,Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse,JSONResponse,Response,PlainTextResponse,HTMLResponse
from fastapi.templating import Jinja2Templates
import common as cm
app=FastAPI(docs_url=None,redoc_url=None)
app.add_middleware(CORSMiddleware,allow_origins=["*"],allow_methods=["*"],allow_headers=["*"])
T=Jinja2Templates(directory=str(Path(__file__).parent/"templates"))
@app.on_event("startup")
def _s(): cm.init_db()
T.env.globals.update(qr=cm.qr,has_plan=cm.hasplan,get_plans=cm.plans,get_plan=cm.plan)
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
def index(r:Request,msg:str=""):
    s=cm.S()
    return T.TemplateResponse(r,"landing.html",{"s":s,"msg":msg})
@app.get("/login")
def login_page(r:Request,msg:str=""):
    return T.TemplateResponse(r,"cabinet_login.html",{"s":cm.S(),"msg":msg})
@app.post("/login")
async def login_do(r:Request):
    f=await r.form(); v=str(f.get("credential","")).strip()
    if not v: return RedirectResponse("/login?msg="+quote("Введите код доступа или телефон"),status_code=303)
    c=cm.client(ext_key=v.upper()) or cm.client(tg_id=v)
    if not c:
        d=re.sub(r"\D","",v)
        if d:
            with cm.db() as con:
                row=con.execute("SELECT client_id FROM registrations WHERE phone=? AND status='approved' AND client_id>0 ORDER BY id DESC LIMIT 1",(d,)).fetchone()
            if row: c=cm.client(id=row["client_id"])
    if not c: return RedirectResponse("/login?msg="+quote("Клиент не найден. Проверьте код доступа."),status_code=303)
    return RedirectResponse("/client/"+c["tg_id"],status_code=303)
@app.post("/callback")
async def callback(r:Request):
    f=await r.form(); nm=str(f.get("name","")).strip()[:60]
    ph=re.sub(r"\D","",str(f.get("phone",""))); em=str(f.get("email","")).strip()[:100]
    cmt=str(f.get("comment","")).strip()[:400]
    if not nm or len(ph)<10: return RedirectResponse("/?msg="+quote("Укажите имя и телефон")+"#contact",status_code=303)
    code=cm.rnd(10,True)
    with cm.db() as con:
        con.execute("INSERT INTO registrations(name,phone,email,comment,code) VALUES(?,?,?,?,?)",(nm,ph,em,cmt,code))
    s=cm.S(); cm.tg(s,s.get("admin_tg_id"),f"📩 Заявка: {nm}, {ph}"+(f", {em}" if em else "")+(f"\n{cmt}" if cmt else ""))
    return RedirectResponse("/?msg="+quote(f"Заявка принята. Номер обращения {code}. Мы свяжемся в рабочее время.")+"#contact",status_code=303)
@app.get("/privacy")
def privacy(r:Request): return T.TemplateResponse(r,"privacy.html",{"s":cm.S()})
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
def cabinet(r:Request,tg:str,msg:str=""):
    c=cm.client(tg_id=tg)
    if not c: return PlainTextResponse("Клиент не найден",status_code=404)
    s=cm.S(); u=used(c,s); l=float(c["limit_gb"] or 0)
    return T.TemplateResponse(r,"client.html",{"c":c,"s":s,"msg":msg,"used_gb":cm.gb(u),
      "percent":min(100,round(u/(l*2**30)*100)) if l>0 else 0,
      "paid_str":time.strftime("%d.%m.%Y",time.localtime(c["paid_until"])) if c["paid_until"] else "—",
      "vless":cm.vless(c,s),"sub":cm.sub(c,s),"tls":cm.tlson(s)})
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
    return RedirectResponse(f"/client/{tg}?msg="+quote("Заявка на пополнение отправлена"),status_code=303)
@app.get("/sub/{sid}")
def sb(sid:str):
    c=cm.client(sub_id=sid) or cm.client(tg_id=sid)
    if not c: return PlainTextResponse("",status_code=404)
    s=cm.S(); ok,_=cm.allowed(c,s)
    if not ok: return PlainTextResponse("",status_code=403)
    return PlainTextResponse(base64.b64encode(cm.vless(c,s).encode()).decode(),
      headers={"Profile-Title":base64.b64encode(s["panel_name"].encode()).decode(),
        "Subscription-Userinfo":f"upload=0; download={c['used_bytes']}; total={int(float(c['limit_gb'] or 0)*2**30)}; expire={c['paid_until']}"})
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
      "scheme":"https" if cm.tlson(s) else "http","username":c["http_user"],"password":c["http_pass"],"name":s["site_name"]},
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
      headers={"Content-Disposition":"attachment; filename=pm-client.zip"})
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
    for t,c in (("📊 Кабинет","me"),("💰 Тарифы","plans"),("🎁 Промокод","promo"),("🔑 Ключ и ссылки","key")): b.button(text=t,callback_data=c)
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
            f"Тариф: {p['name'] if p else 'не выбран'}\nТрафик: {cm.gb(c['used_bytes'])} / {l}\nОплачено до: {u}\n"
            f"Шифрование прокси: {'🔒 TLS' if cm.tlson(s) else '⚠️ HTTP'}\n\n🌐 {cm.cab(c,s)}\n🔐 Код: {c['access_code']}")
def ktext(c,s): return f"🔑 Ключ:\n{c['ext_key']}\n\n📱 VLESS:\n{cm.vless(c,s)}\n\n🔄 Подписка:\n{cm.sub(c,s)}"
@R.message(CommandStart())
async def start(m:Message):
    s=S()
    if adm(m.from_user.id):
        await m.answer("👋 Админ\n\n/status /stats /clients /regs\n/approve <id> [тариф] /reject <id>\n/topup <email|tg> <сумма>\n/on /off /reset <email>\n/plans /promos\n/newpromo <код> <balance|plan|days> <знач> [лимит] [дней]\n/certs /settings"); return
    c=me(m.from_user.id)
    if c: await m.answer(mtext(c,s),reply_markup=kb())
    else: await m.answer(f"Вы не зарегистрированы.\nID: {m.from_user.id}\n\nЗаявка: {cm.pbase(s)}")
@R.message(Command("me"))
async def mme(m:Message):
    c=me(m.from_user.id)
    if c: await m.answer(mtext(c,S()),reply_markup=kb())
    else: await m.answer("Вы не зарегистрированы")
@R.message(Command("key"))
async def mkey(m:Message):
    c=me(m.from_user.id)
    if c: await m.answer(ktext(c,S()))
@R.message(Command("plans"))
async def mpl(m:Message):
    ps=cm.plans()
    if not ps: await m.answer("Тарифы не настроены"); return
    t="💰 Тарифы:\n\n"+"".join(f"• {p['name']} — {p['price']:g} ₽ / {p['period_days']} дн.\n" for p in ps)
    c=me(m.from_user.id)
    if c: await m.answer(t+f"\nБаланс: {c['balance']:.2f} ₽",reply_markup=pkb())
    else: await m.answer(t)
@R.message(Command("promo"))
async def mpr(m:Message):
    c=me(m.from_user.id)
    if not c: await m.answer("Сначала зарегистрируйтесь"); return
    p=(m.text or "").split(maxsplit=1)
    if len(p)<2: await m.answer("/promo КОД"); return
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
    try: await q.message.edit_text("💰 Тарифы\nБаланс: %.2f ₽"%(c["balance"] if c else 0),reply_markup=pkb())
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
    try: await q.message.edit_text(f"«{p['name']}»\n{p['price']:g} ₽ / {p['period_days']} дн.\nБаланс: {c['balance']:.2f} ₽",reply_markup=b.as_markup())
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
    t=f"📊 Клиенты: {a}/{n}\n📝 Заявок: {p}\n🔒 TLS-прокси: {'вкл' if cm.tlson(s) else 'выкл'}\n"
    try:
        r=await asyncio.to_thread(cm.xui(s,8).status); x=(r or {}).get("xray",{})
        t+=f"🟢 xray {x.get('state','?')} {x.get('version','')}"
    except Exception as e: t+=f"🔴 3x-ui: {e}"
    await m.answer(t)
@R.message(Command("certs"))
async def acerts(m:Message):
    if not adm(m.from_user.id): return
    s=S(); c,_=cm.tlspaths(s)
    t=f"🔐 Сертификат: {c or 'нет'}\nДоверенный: {cm.cert_trusted(s)}\nРежим: {s.get('cert_mode')}\nTLS-прокси: {cm.tlson(s)}\n\nНайденные:\n"
    for x in cm.cert_list(s):
        t+=f"• {x['cert']}\n  CN={x['cn']} дней={x['days']} доверенный={x['trusted']} совпадает={x['match']}\n"
    await m.answer(t[:3900])
@R.message(Command("stats"))
async def astats(m:Message):
    if not adm(m.from_user.id): return
    with cm.db() as c:
        f=lambda q:c.execute(q).fetchone()[0]
        await m.answer("📈 Клиентов %d (активных %d)\nБалансы %.2f ₽\nПополнений %.2f ₽\nСписаний %.2f ₽\nЗаявок %d\nТарифов %d\nПромокодов %d"%(
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
    await m.answer("📝 Заявки:\n\n"+"".join(f"#{r['id']} {r['name']} · {r['phone']}\n" for r in rows)+"\n/approve <id> [тариф] · /reject <id>")
@R.message(Command("approve"))
async def aap(m:Message):
    if not adm(m.from_user.id): return
    p=(m.text or "").split()
    if len(p)<2: await m.answer("/approve <id> [id тарифа]"); return
    import uuid as U
    with cm.db() as con: row=con.execute("SELECT * FROM registrations WHERE id=?",(int(p[1]),)).fetchone()
    if not row or row["status"]!="pending": await m.answer("Не найдена/обработана"); return
    g=dict(row); s=S(); pl=cm.plan(int(p[2])) if len(p)>2 else None
    em="u"+"".join(ch for ch in g["phone"] if ch.isdigit())
    while cm.client(email=em): em="u"+cm.rnd(6)
    tg=g["tg_id"] or "u_"+cm.rnd(8)
    c={"tg_id":tg,"name":g["name"],"email":em,"uuid":str(U.uuid4()),"balance":0,
       "limit_gb":float(pl["limit_gb"]) if pl else 0,"ext_key":cm.rnd(8,True),"inbound_id":0,
       "http_port":0,"http_user":"","http_pass":"","http_inbound_id":0}
    x=cm.xui(s)
    try: x.add_client(cm.ib(c,s),em,client_uuid=c["uuid"],total_gb=c["limit_gb"])
    except Exception as e: await m.answer("⚠️ VLESS: %s"%e)
    cert,key=cm.tlspaths(s) if cm.tlson(s) else ("","")
    used={y["http_port"] for y in cm.clients()}
    port=next((q for q in range(int(s["http_port_start"]),int(s["http_port_end"])+1) if q not in used),None)
    if port:
        c["http_port"]=port; c["http_user"]="u"+cm.rnd(6); c["http_pass"]=cm.rnd(16)
        try: c["http_inbound_id"]=x.add_http_inbound(port,c["http_user"],c["http_pass"],"browser-"+em,tls_cert=cert,tls_key=key)
        except Exception: c["http_port"]=0
    with cm.db() as con:
        cur=con.execute("INSERT INTO clients(tg_id,name,email,uuid,balance,limit_gb,used_bytes,enabled,notified,paid_until,ext_key,http_port,http_user,http_pass,http_inbound_id,inbound_id,plan_id,sub_id,access_code) VALUES(?,?,?,?,0,?,0,1,0,0,?,?,?,?,?,0,?,?)",
          (tg,g["name"],em,c["uuid"],c["limit_gb"],c["ext_key"],c["http_port"],c["http_user"],c["http_pass"],c["http_inbound_id"],cm.rnd(16),cm.rnd(6,True)))
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
    await m.answer("Отклонена")
@R.message(Command("newpromo"))
async def anp(m:Message):
    if not adm(m.from_user.id): return
    p=(m.text or "").split()
    if len(p)<4: await m.answer("/newpromo <код> <balance|plan|days> <знач> [лимит] [дней]"); return
    try: v=float(p[3].replace(",",".")); mx=int(p[4]) if len(p)>4 else 0; vd=int(p[5]) if len(p)>5 else 0
    except ValueError: await m.answer("Числа неверны"); return
    ok,msg=cm.mkpromo(p[1],p[2],v,mx,cm.now()+vd*86400 if vd>0 else 0,"bot")
    await m.answer(("✅ " if ok else "❌ ")+msg)
@R.message(Command("promos"))
async def apr(m:Message):
    if not adm(m.from_user.id): return
    ps=cm.promos()
    if not ps: await m.answer("Промокодов нет"); return
    await m.answer("🎁\n"+"".join(f"{'🟢' if p['enabled'] else '🔴'} {p['code']} {p['kind']} {p['value']:g} {p['used_count']}/{p['max_uses'] or '∞'}\n" for p in ps))
@R.message(Command("settings"))
async def ast2(m:Message):
    if not adm(m.from_user.id): return
    s=S()
    await m.answer(f"⚙️ 3x-ui: {s['xui_url']} (inbound {s['inbound_id']})\nАдрес: {cm.host(s)}\nБиллинг: {'вкл' if s['billing_enabled']=='1' else 'выкл'}\nTLS: {cm.tlson(s)}\nТарифов: {len(cm.plans())}")
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
def certwatch():
    s=cm.S(); c,_=cm.tlspaths(s)
    prev=s.get("_last_cert","")
    if c and c!=prev:
        cm.setS({"_last_cert":c}); log.info("сертификат изменился: %s — применяю",c)
        import subprocess
        subprocess.Popen(["bash",str(cm.BASE/"net-setup.sh")],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
if __name__=="__main__":
    cm.init_db(); sc=BlockingScheduler()
    sc.add_job(traffic,"interval",minutes=30,next_run_time=datetime.now(),id="t",max_instances=1,coalesce=True)
    sc.add_job(billing,"interval",minutes=5,next_run_time=datetime.now(),id="b",max_instances=1,coalesce=True)
    sc.add_job(certwatch,"interval",minutes=10,id="c",max_instances=1,coalesce=True)
    log.info("монитор запущен")
    try: sc.start()
    except KeyboardInterrupt: pass
PY_MON
echo "модули записаны"
