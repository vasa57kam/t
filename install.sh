#!/usr/bin/env bash
# =====================================================================
#  Нейтральный лендинг + шифрованное (TLS) браузерное расширение
#  Ставится поверх работающего Proxy Manager. Идемпотентно.
#  Запуск: bash neutral.sh
# =====================================================================
set -uo pipefail
APP=/opt/proxy-manager
[ -d "$APP" ] || { echo "Нет $APP — сначала основной установщик"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Нужен root"; exit 1; }
cd "$APP"
B="backups/neutral-$(date +%Y%m%d_%H%M%S)"; mkdir -p "$B"
cp -a *.py "$B"/ 2>/dev/null; cp -a templates extension "$B"/ 2>/dev/null
echo "Бэкап: $APP/$B"

python3 - <<'PY_PATCH'
import pathlib,re,sys
def rd(p): return pathlib.Path(p).read_text()
def wr(p,s): pathlib.Path(p).write_text(s)

# ---------- 1. common.py: TLS-хелперы (работают и со старой, и с новой версией) ----------
s=rd("common.py")
if "def tlson(" not in s:
    s+='''

# ================= PM TLS HELPERS =================
import os as _os

def pm_settings():
    return S() if "S" in globals() else get_settings()

def pm_tls_paths(s=None):
    s=s or pm_settings()
    c=(s.get("tls_cert") or "").strip(); k=(s.get("tls_key") or "").strip()
    if c and k and _os.path.exists(c) and _os.path.exists(k): return c,k
    d=s.get("domain") or ""
    if d:
        for c,k in ((f"/etc/letsencrypt/live/{d}/fullchain.pem",f"/etc/letsencrypt/live/{d}/privkey.pem"),
                    (f"/root/cert/{d}/fullchain.pem",f"/root/cert/{d}/privkey.pem")):
            if _os.path.exists(c) and _os.path.exists(k): return c,k
    if _os.path.exists("/etc/pm-web/self.crt"): return "/etc/pm-web/self.crt","/etc/pm-web/self.key"
    return "",""

def cert_trusted(s=None):
    c,_=pm_tls_paths(s)
    return bool(c) and not c.endswith("self.crt")

def tlson(s=None):
    s=s or pm_settings()
    if str(s.get("proxy_tls","1"))!="1": return False
    return cert_trusted(s)

def pm_clients():
    return clients() if "clients" in globals() else get_clients()

def pm_xui(s,t=15):
    return xui(s,t) if "xui" in globals() else make_xui(s,timeout=t)

def pm_host(s):
    return host(s) if "host" in globals() else server_host(s)
'''
    wr("common.py",s); print("✓ common.py: TLS-хелперы")

# ---------- 2. web_app.py: лендинг, вход в кабинет, заявка, privacy, scheme ----------
s=rd("web_app.py")
NEWIDX='''@app.get("/")
def index(request: Request, msg: str = ""):
    s = cm.pm_settings(); cs = cm.pm_clients()
    au = s.get("admin_url") or ("https://%s:8443" % cm.pm_host(s))
    return _TPL.TemplateResponse(request, "landing.html",
        {"s": s, "msg": msg, "admin_url": au, "n_clients": len(cs)})
'''
if "landing.html" not in s:
    m=re.search(r'@app\.get\("/"\)\ndef \w+\([^)]*\):.*?(?=\n@app\.|\Z)', s, re.S)
    if not m: print("❌ не найден index в web_app.py"); sys.exit(1)
    s=s[:m.start()]+NEWIDX+s[m.end():]
    print("✓ web_app.py: index → лендинг")

NEWLOGIN='''@app.get("/login")
def cabinet_login_page(request: Request, msg: str = ""):
    return _TPL.TemplateResponse(request, "cabinet_login.html", {"s": cm.pm_settings(), "msg": msg})
'''
m=re.search(r'@app\.get\("/login"\)\ndef \w+\([^)]*\):.*?(?=\n@app\.|\Z)', s, re.S)
if m: s=s[:m.start()]+NEWLOGIN+s[m.end():]
else: s+="\n"+NEWLOGIN
print("✓ web_app.py: страница входа в кабинет")

if '"scheme"' not in s:
    a='"use_auth": True,'
    if a in s:
        s=s.replace(a,'"use_auth": True, "scheme": ("https" if cm.tlson(s) else "http"),',1)
        print("✓ web_app.py: scheme в конфиге расширения")

if "/callback" not in s:
    s+='''

# ================= Нейтральный сайт: заявка и privacy =================
import re as _re, secrets as _sec
_TPL = globals().get("T") or globals().get("templates")

_CB_SCHEMA = """
CREATE TABLE IF NOT EXISTS registrations(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT,phone TEXT,
 email TEXT DEFAULT '',tg_id TEXT DEFAULT '',comment TEXT DEFAULT '',code TEXT UNIQUE,
 status TEXT DEFAULT 'pending',client_id INTEGER DEFAULT 0,
 created_at TEXT DEFAULT (datetime('now')),decided_at TEXT DEFAULT '');
"""

@app.post("/callback")
async def callback(request: Request):
    f = await request.form()
    nm = str(f.get("name","")).strip()[:60]
    ph = _re.sub(r"\\D","",str(f.get("phone","")))
    em = str(f.get("email","")).strip()[:100]
    cm_ = str(f.get("comment","")).strip()[:400]
    if not nm or len(ph) < 10:
        return RedirectResponse("/?msg="+quote("Укажите имя и телефон")+"#contact", status_code=303)
    with cm.db() as con:
        con.executescript(_CB_SCHEMA)
        code = "".join(_sec.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(10))
        con.execute("INSERT INTO registrations(name,phone,email,comment,code) VALUES(?,?,?,?,?)",(nm,ph,em,cm_,code))
    s = cm.pm_settings()
    _tg = getattr(cm,"tg",None) or getattr(cm,"tg_send")
    _tg(s, s.get("admin_tg_id"), f"📩 Заявка с сайта: {nm}, {ph}"+(f", {em}" if em else "")+(f"\\n{cm_}" if cm_ else ""))
    return RedirectResponse("/?msg="+quote("Заявка принята. Мы свяжемся с вами в рабочее время.")+"#contact", status_code=303)

@app.get("/privacy")
def privacy(request: Request):
    return _TPL.TemplateResponse(request, "privacy.html", {"s": cm.pm_settings()})
'''
    wr("web_app.py",s); print("✓ web_app.py: /callback + /privacy")
else:
    wr("web_app.py",s)

# ---------- 3. admin_app.py: TLS-переключатели + редактор сайта ----------
s=rd("admin_app.py")
if "/proxy/tls_all" not in s:
    s+='''

# ================= TLS прокси + редактор нейтрального сайта =================
_A = auth
_R = globals().get("rd") or globals().get("redirect")
_T = globals().get("T") or globals().get("templates")

@app.post("/proxy/tls_all")
def pm_tls_all(request: Request):
    if not _A(request): return RedirectResponse("/login", status_code=303)
    s = cm.pm_settings()
    cert, key = cm.pm_tls_paths(s)
    if not cert: return _R("Сертификат не найден")
    if not cm.cert_trusted(s):
        return _R("Сертификат самоподписанный — Chrome не примет его для HTTPS-прокси. Сначала получите Let's Encrypt.")
    x = cm.pm_xui(s); ok = 0; er = []
    for c in cm.pm_clients():
        if not c.get("http_inbound_id"): continue
        try:
            b = x.get_inbound(c["http_inbound_id"]); ss = b.get("streamSettings")
            if isinstance(ss, str): ss = json.loads(ss or "{}")
            ss = dict(ss or {}); ss["security"] = "tls"
            ss.pop("realitySettings", None)
            ss["tlsSettings"] = {"certificates":[{"certificateFile":cert,"keyFile":key}],
                                 "alpn":["http/1.1"],"minVersion":"1.2"}
            b["streamSettings"] = ss; x.update_inbound(b); ok += 1
        except Exception as e: er.append(str(e)[:60])
    return _R(f"TLS включён на {ok} прокси. " + "; ".join(er))

@app.post("/proxy/tls_off")
def pm_tls_off(request: Request):
    if not _A(request): return RedirectResponse("/login", status_code=303)
    s = cm.pm_settings(); x = cm.pm_xui(s); ok = 0
    for c in cm.pm_clients():
        if not c.get("http_inbound_id"): continue
        try:
            b = x.get_inbound(c["http_inbound_id"]); ss = b.get("streamSettings")
            if isinstance(ss, str): ss = json.loads(ss or "{}")
            ss = dict(ss or {}); ss["security"] = "none"
            ss.pop("tlsSettings", None); ss.pop("realitySettings", None)
            b["streamSettings"] = ss; x.update_inbound(b); ok += 1
        except Exception: pass
    return _R(f"TLS снят с {ok} прокси")

@app.get("/site")
def site_edit(request: Request, msg: str = ""):
    if not _A(request): return RedirectResponse("/login", status_code=303)
    return _T.TemplateResponse(request, "site_admin.html", {"s": cm.pm_settings(), "msg": msg})

@app.post("/site")
async def site_save(request: Request):
    if not _A(request): return RedirectResponse("/login", status_code=303)
    f = await request.form(); up = {}
    for k in ("site_name","site_tagline","site_about","site_phone","site_email","site_inn",
              "site_years","site_projects","site_uptime","site_addr","proxy_tls"):
        if k in f: up[k] = str(f[k]).strip()
    cm.setS(up)
    return RedirectResponse("/site?msg="+quote("Сохранено"), status_code=303)
'''
    wr("admin_app.py",s); print("✓ admin_app.py: TLS + /site")
print("=== код пропатчен ===")
PY_PATCH

mkdir -p templates extension
cat > templates/landing.html <<'TPL_LAND'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{{ s.site_name or "Инфоструктура" }} — {{ s.site_tagline or "IT-инфраструктура и сопровождение веб-проектов" }}</title>
<meta name="description" content="Проектирование, размещение и техническое сопровождение серверов и веб-сервисов для малого и среднего бизнеса.">
<style>
:root{--bg:#fff;--soft:#f6f8fb;--txt:#101828;--mut:#5b6b82;--brd:#e4e9f0;--acc:#0f62fe;--acc2:#00867d;--dark:#0b1524}
*{box-sizing:border-box;margin:0}
html{scroll-behavior:smooth}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;color:var(--txt);background:var(--bg);line-height:1.6;-webkit-font-smoothing:antialiased}
a{color:inherit;text-decoration:none}
.wrap{max-width:1140px;margin:0 auto;padding:0 22px}
header{position:sticky;top:0;z-index:50;background:rgba(255,255,255,.92);backdrop-filter:blur(10px);border-bottom:1px solid var(--brd)}
.nav{display:flex;align-items:center;gap:26px;height:68px}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:18px;letter-spacing:-.01em}
.mark{width:30px;height:30px;border-radius:8px;background:linear-gradient(135deg,var(--acc),var(--acc2));display:grid;place-items:center;color:#fff;font-size:15px;font-weight:700}
.nav nav{display:flex;gap:24px;margin-left:auto}
.nav nav a{font-size:14.5px;color:var(--mut)}
.nav nav a:hover{color:var(--txt)}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;padding:11px 20px;border-radius:9px;border:1px solid transparent;font-size:14.5px;font-weight:600;cursor:pointer;font-family:inherit;transition:.18s}
.btn-p{background:var(--acc);color:#fff}.btn-p:hover{background:#0b52d6}
.btn-o{border-color:var(--brd);background:#fff;color:var(--txt)}.btn-o:hover{border-color:#c9d4e2}
.btn-l{background:rgba(255,255,255,.12);color:#fff;border-color:rgba(255,255,255,.25)}
.hero{padding:76px 0 64px;background:linear-gradient(180deg,#f8fafc,#fff)}
.hero-grid{display:grid;grid-template-columns:1.1fr .9fr;gap:52px;align-items:center}
h1{font-size:clamp(30px,4.4vw,46px);line-height:1.14;letter-spacing:-.025em;font-weight:700;margin-bottom:18px}
.lead{font-size:17.5px;color:var(--mut);max-width:540px;margin-bottom:28px}
.hero-cta{display:flex;gap:12px;flex-wrap:wrap}
.panel{background:var(--dark);border-radius:16px;padding:24px;color:#dbe6f5;font-size:13px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;box-shadow:0 24px 60px rgba(11,21,36,.22)}
.panel .row{display:flex;justify-content:space-between;padding:7px 0;border-bottom:1px solid rgba(255,255,255,.07)}
.panel .row:last-child{border:0}
.ok{color:#4ade80}.warn{color:#fbbf24}
.panel h4{font-family:inherit;font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#7d93b0;margin-bottom:12px;font-weight:600}
.trust{border-top:1px solid var(--brd);border-bottom:1px solid var(--brd);background:var(--soft)}
.trust-in{display:grid;grid-template-columns:repeat(4,1fr);gap:20px;padding:30px 0;text-align:center}
.trust b{display:block;font-size:29px;font-weight:700;letter-spacing:-.02em}
.trust span{font-size:13.5px;color:var(--mut)}
section{padding:74px 0}
.eyebrow{font-size:12.5px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:var(--acc);margin-bottom:12px}
h2{font-size:clamp(24px,3vw,33px);letter-spacing:-.02em;font-weight:700;margin-bottom:14px}
.sub{color:var(--mut);font-size:16.5px;max-width:640px;margin-bottom:40px}
.grid3{display:grid;grid-template-columns:repeat(3,1fr);gap:20px}
.grid2{display:grid;grid-template-columns:repeat(2,1fr);gap:20px}
.card{border:1px solid var(--brd);border-radius:14px;padding:26px;background:#fff;transition:.2s}
.card:hover{border-color:#cfd9e6;box-shadow:0 10px 30px rgba(16,24,40,.06)}
.ico{width:42px;height:42px;border-radius:10px;background:var(--soft);display:grid;place-items:center;font-size:20px;margin-bottom:16px}
.card h3{font-size:17px;margin-bottom:9px;letter-spacing:-.01em}
.card p{color:var(--mut);font-size:14.5px}
.soft{background:var(--soft)}
.price{display:flex;flex-direction:column;border:1px solid var(--brd);border-radius:14px;padding:28px;background:#fff}
.price.hi{border-color:var(--acc);box-shadow:0 12px 34px rgba(15,98,254,.1)}
.price .tag{font-size:12px;font-weight:700;color:var(--acc);text-transform:uppercase;letter-spacing:.06em;margin-bottom:10px}
.price .num{font-size:30px;font-weight:700;letter-spacing:-.02em;margin:6px 0 4px}
.price .per{color:var(--mut);font-size:13.5px;margin-bottom:18px}
.price ul{list-style:none;margin-bottom:22px;flex:1}
.price li{font-size:14.5px;color:var(--mut);padding:7px 0 7px 24px;position:relative}
.price li::before{content:"✓";position:absolute;left:0;color:var(--acc2);font-weight:700}
.steps{display:grid;grid-template-columns:repeat(4,1fr);gap:20px;counter-reset:s}
.step{padding:24px;border-radius:14px;background:#fff;border:1px solid var(--brd)}
.step::before{counter-increment:s;content:"0" counter(s);display:block;font-size:26px;font-weight:700;color:var(--acc);margin-bottom:10px}
.step h4{font-size:16px;margin-bottom:7px}.step p{font-size:14px;color:var(--mut)}
.about{display:grid;grid-template-columns:1fr 1fr;gap:48px;align-items:start}
.about ul{list-style:none;margin-top:18px}
.about li{padding:9px 0 9px 26px;position:relative;color:var(--mut);font-size:15px}
.about li::before{content:"—";position:absolute;left:0;color:var(--acc)}
.contact{background:var(--dark);color:#e8eff8;border-radius:18px;padding:44px;display:grid;grid-template-columns:1fr 1fr;gap:44px}
.contact h2{color:#fff}.contact p{color:#9db1cb;font-size:15.5px}
.form label{display:block;font-size:12.5px;color:#9db1cb;margin:14px 0 6px}
.form input,.form textarea{width:100%;padding:12px 14px;border-radius:9px;border:1px solid rgba(255,255,255,.16);background:rgba(255,255,255,.06);color:#fff;font-size:15px;font-family:inherit}
.form input:focus,.form textarea:focus{outline:none;border-color:#4d90ff}
.form textarea{min-height:88px;resize:vertical}
.form .btn{width:100%;margin-top:20px}
.meta{margin-top:26px;font-size:14px;color:#9db1cb}
.meta div{padding:5px 0}
.msg{max-width:1140px;margin:18px auto 0;padding:13px 18px;border-radius:10px;background:#e7f3ff;border:1px solid #b9dbff;color:#0b4ea2;font-size:14.5px}
footer{border-top:1px solid var(--brd);padding:38px 0;background:var(--soft)}
.foot{display:flex;justify-content:space-between;gap:26px;flex-wrap:wrap;font-size:14px;color:var(--mut)}
.foot a:hover{color:var(--txt)}
.foot .col{display:flex;flex-direction:column;gap:7px}
@media(max-width:940px){.hero-grid,.about,.contact{grid-template-columns:1fr}.grid3,.grid2,.steps,.trust-in{grid-template-columns:1fr 1fr}.nav nav{display:none}.contact{padding:28px}}
@media(max-width:560px){.grid3,.grid2,.steps,.trust-in{grid-template-columns:1fr}}
</style></head><body>

<header><div class="wrap nav">
  <a class="brand" href="/"><span class="mark">И</span>{{ s.site_name or "Инфоструктура" }}</a>
  <nav>
    <a href="#services">Услуги</a>
    <a href="#pricing">Тарифы</a>
    <a href="#process">Как работаем</a>
    <a href="#about">О компании</a>
    <a href="#contact">Контакты</a>
  </nav>
  <a class="btn btn-o" href="/login">Личный кабинет</a>
</div></header>

{% if msg %}<div class="wrap"><div class="msg">{{ msg }}</div></div>{% endif %}

<div class="hero"><div class="wrap hero-grid">
  <div>
    <h1>IT-инфраструктура,<br>которая просто работает</h1>
    <p class="lead">{{ s.site_tagline or "Проектируем, размещаем и сопровождаем серверы и веб-сервисы для малого и среднего бизнеса. Берём на себя техническую часть — вы занимаетесь делом." }}</p>
    <div class="hero-cta">
      <a class="btn btn-p" href="#contact">Обсудить проект</a>
      <a class="btn btn-o" href="#services">Наши услуги</a>
    </div>
  </div>
  <div class="panel">
    <h4>Мониторинг узлов · сводка</h4>
    <div class="row"><span>web-01 · nginx</span><span class="ok">healthy</span></div>
    <div class="row"><span>db-01 · postgres</span><span class="ok">healthy</span></div>
    <div class="row"><span>backup · daily</span><span class="ok">02:15 ok</span></div>
    <div class="row"><span>app-02 · worker</span><span class="warn">load 71%</span></div>
    <div class="row"><span>uptime 30d</span><span>{{ s.site_uptime or "99.94" }}%</span></div>
    <div class="row"><span>reaction SLA</span><span>&lt; 15 min</span></div>
  </div>
</div></div>

<div class="trust"><div class="wrap trust-in">
  <div><b>{{ s.site_years or "12" }}</b><span>лет на рынке</span></div>
  <div><b>{{ s.site_projects or "240" }}+</b><span>проектов</span></div>
  <div><b>{{ s.site_uptime or "99.9" }}%</b><span>доступность</span></div>
  <div><b>24/7</b><span>дежурная смена</span></div>
</div></div>

<section id="services"><div class="wrap">
  <div class="eyebrow">Услуги</div>
  <h2>Что мы делаем</h2>
  <p class="sub">Полный цикл: от проектирования архитектуры до ежедневной эксплуатации и развития.</p>
  <div class="grid3">
    <div class="card"><div class="ico">🖥️</div><h3>Размещение и серверы</h3><p>Подбор конфигурации, настройка окружения, миграция проектов, резервное копирование и восстановление.</p></div>
    <div class="card"><div class="ico">🧩</div><h3>Разработка веб-сервисов</h3><p>Корпоративные сайты, внутренние порталы, личные кабинеты, интеграции с CRM и учётными системами.</p></div>
    <div class="card"><div class="ico">🛠️</div><h3>Техническая поддержка</h3><p>Дежурная смена, реакция по SLA, обновления, устранение инцидентов, ежемесячная отчётность.</p></div>
    <div class="card"><div class="ico">📊</div><h3>Мониторинг и отчётность</h3><p>Метрики доступности и нагрузки, оповещения, понятные дашборды для руководителя и техспециалиста.</p></div>
    <div class="card"><div class="ico">🔐</div><h3>Аудит и безопасность</h3><p>Проверка конфигураций, разграничение доступа, обновления, резервные копии, план восстановления.</p></div>
    <div class="card"><div class="ico">⚙️</div><h3>Автоматизация</h3><p>Скрипты обслуживания, CI/CD, автоматические бэкапы, синхронизация данных между системами.</p></div>
  </div>
</div></section>

<section id="pricing" class="soft"><div class="wrap">
  <div class="eyebrow">Тарифы</div>
  <h2>Сопровождение</h2>
  <p class="sub">Фиксированная monthly-стоимость, без скрытых платежей. Разработка и миграция оцениваются отдельно.</p>
  <div class="grid3">
    <div class="price"><div class="tag">Базовый</div><div class="num">4 900 ₽</div><div class="per">в месяц</div>
      <ul><li>Мониторинг доступности</li><li>Обновления раз в месяц</li><li>Резервные копии</li><li>Реакция до 8 часов</li></ul>
      <a class="btn btn-o" href="#contact">Оставить заявку</a></div>
    <div class="price hi"><div class="tag">Бизнес</div><div class="num">12 400 ₽</div><div class="per">в месяц</div>
      <ul><li>Всё из «Базового»</li><li>Дежурная смена 24/7</li><li>Реакция до 30 минут</li><li>До 4 часов работ в месяц</li><li>Ежемесячный отчёт</li></ul>
      <a class="btn btn-p" href="#contact">Оставить заявку</a></div>
    <div class="price"><div class="tag">Проектный</div><div class="num">по смете</div><div class="per">разовые работы</div>
      <ul><li>Аудит инфраструктуры</li><li>Миграция и перенос данных</li><li>Разработка и интеграции</li><li>Обучение сотрудников</li></ul>
      <a class="btn btn-o" href="#contact">Обсудить задачу</a></div>
  </div>
</div></section>

<section id="process"><div class="wrap">
  <div class="eyebrow">Процесс</div>
  <h2>Как мы работаем</h2>
  <p class="sub">Прозрачные этапы и понятная зона ответственности.</p>
  <div class="steps">
    <div class="step"><h4>Заявка</h4><p>Вы описываете задачу. Мы связываемся в рабочее время и уточняем детали.</p></div>
    <div class="step"><h4>Аудит</h4><p>Смотрим текущее состояние, фиксируем риски и составляем план работ.</p></div>
    <div class="step"><h4>Внедрение</h4><p>Выполняем работы по согласованной смете, передаём документацию.</p></div>
    <div class="step"><h4>Поддержка</h4><p>Берём на эксплуатацию по SLA, ведём отчётность в личном кабинете.</p></div>
  </div>
</div></section>

<section id="about" class="soft"><div class="wrap about">
  <div>
    <div class="eyebrow">О компании</div>
    <h2>Небольшая инженерная команда</h2>
    <p class="sub" style="margin-bottom:0">{{ s.site_about or "Мы занимаемся серверной инфраструктурой и веб-проектами с 2014 года. Работаем без менеджеров-посредников: задачу обсуждает и решает инженер, который будет её сопровождать. Не берём больше проектов, чем можем качественно вести." }}</p>
    <ul>
      <li>Прямой контакт с инженером, а не с колл-центром</li>
      <li>Документация и доступы передаются заказчику</li>
      <li>Работаем по договору, закрывающие документы</li>
      <li>Отчёт о работах и состоянии систем каждый месяц</li>
    </ul>
  </div>
  <div class="card">
    <h3>Частые задачи</h3>
    <p style="margin-bottom:14px">С чем к нам приходят чаще всего:</p>
    <ul style="list-style:none">
      <li style="padding:8px 0;border-bottom:1px solid var(--brd)">Сайт падает под нагрузкой</li>
      <li style="padding:8px 0;border-bottom:1px solid var(--brd)">Нужен перенос на другой сервер</li>
      <li style="padding:8px 0;border-bottom:1px solid var(--brd)">Нет резервных копий</li>
      <li style="padding:8px 0;border-bottom:1px solid var(--brd)">Ушёл прежний подрядчик</li>
      <li style="padding:8px 0">Нужен личный кабинет для клиентов</li>
    </ul>
  </div>
</div></section>

<section id="contact"><div class="wrap">
  <div class="contact">
    <div>
      <div class="eyebrow" style="color:#6ea8ff">Контакты</div>
      <h2>Расскажите о задаче</h2>
      <p>Опишите, что нужно сделать или что сейчас не работает. Ответим в рабочее время и предложим варианты.</p>
      <div class="meta">
        {% if s.site_phone %}<div>Телефон: {{ s.site_phone }}</div>{% endif %}
        {% if s.site_email %}<div>Почта: {{ s.site_email }}</div>{% endif %}
        {% if s.site_addr %}<div>{{ s.site_addr }}</div>{% endif %}
        <div>Пн–Пт, 10:00–19:00 (МСК)</div>
        <div>Дежурная смена для клиентов на поддержке — круглосуточно</div>
      </div>
    </div>
    <form class="form" method="post" action="/callback">
      <label>Имя *</label><input name="name" required placeholder="Как к вам обращаться">
      <label>Телефон *</label><input name="phone" required placeholder="+7 900 000-00-00">
      <label>Почта</label><input name="email" type="email" placeholder="you@company.ru">
      <label>Задача</label><textarea name="comment" placeholder="Коротко о проекте или проблеме"></textarea>
      <button class="btn btn-p">Отправить заявку</button>
      <div style="font-size:12px;color:#7d93b0;margin-top:12px">Отправляя форму, вы соглашаетесь с <a href="/privacy" style="color:#9db1cb;text-decoration:underline">обработкой данных</a>.</div>
    </form>
  </div>
</div></section>

<footer><div class="wrap foot">
  <div class="col">
    <a class="brand" href="/" style="font-size:16px"><span class="mark" style="width:24px;height:24px;font-size:12px">И</span>{{ s.site_name or "Инфоструктура" }}</a>
    <span>© 2026. Все права защищены.</span>
    {% if s.site_inn %}<span>ИНН {{ s.site_inn }}</span>{% endif %}
  </div>
  <div class="col"><a href="#services">Услуги</a><a href="#pricing">Тарифы</a><a href="#process">Как работаем</a></div>
  <div class="col"><a href="#about">О компании</a><a href="#contact">Контакты</a><a href="/privacy">Обработка данных</a></div>
  <div class="col"><a href="/login">Личный кабинет</a>{% if s.site_email %}<a href="mailto:{{ s.site_email }}">{{ s.site_email }}</a>{% endif %}</div>
</div></footer>
</body></html>
TPL_LAND

cat > templates/cabinet_login.html <<'TPL_CLOG'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Личный кабинет — {{ s.site_name or "Инфоструктура" }}</title>
<style>
*{box-sizing:border-box;margin:0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;background:#f6f8fb;color:#101828;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:22px;line-height:1.6}
.card{background:#fff;border:1px solid #e4e9f0;border-radius:16px;padding:34px;width:min(400px,94vw);box-shadow:0 12px 34px rgba(16,24,40,.06)}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:17px;margin-bottom:22px}
.mark{width:28px;height:28px;border-radius:8px;background:linear-gradient(135deg,#0f62fe,#00867d);display:grid;place-items:center;color:#fff;font-size:14px}
h1{font-size:20px;letter-spacing:-.01em;margin-bottom:6px}
p{color:#5b6b82;font-size:14px;margin-bottom:20px}
label{display:block;font-size:12.5px;color:#5b6b82;margin-bottom:6px}
input{width:100%;padding:12px 14px;border:1px solid #e4e9f0;border-radius:9px;font-size:15px;font-family:inherit;margin-bottom:16px}
input:focus{outline:none;border-color:#0f62fe}
button{width:100%;padding:12px;border:0;border-radius:9px;background:#0f62fe;color:#fff;font-size:15px;font-weight:600;cursor:pointer;font-family:inherit}
button:hover{background:#0b52d6}
.msg{background:#fdecec;border:1px solid #f6c9c9;color:#a12626;border-radius:9px;padding:10px 13px;font-size:13.5px;margin-bottom:16px}
.back{display:block;text-align:center;margin-top:18px;font-size:13.5px;color:#5b6b82;text-decoration:none}
</style></head><body>
<form class="card" method="post" action="/login">
<div class="brand"><span class="mark">И</span>{{ s.site_name or "Инфоструктура" }}</div>
<h1>Личный кабинет</h1>
<p>Вход для действующих клиентов. Код доступа выдаётся при подключении обслуживания.</p>
{% if msg %}<div class="msg">{{ msg }}</div>{% endif %}
<label>Код доступа или телефон</label>
<input name="credential" required autocomplete="username" placeholder="Например: A1B2C3D4">
<button>Войти</button>
<a class="back" href="/">← На главную</a>
</form></body></html>
TPL_CLOG

cat > templates/privacy.html <<'TPL_PRIV'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Обработка данных — {{ s.site_name or "Инфоструктура" }}</title>
<style>
*{box-sizing:border-box;margin:0}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Arial,sans-serif;background:#fff;color:#101828;line-height:1.7}
.wrap{max-width:760px;margin:0 auto;padding:48px 22px}
h1{font-size:28px;letter-spacing:-.02em;margin-bottom:8px}h2{font-size:18px;margin:28px 0 10px}
p,li{color:#3f4f66;font-size:15.5px}ul{padding-left:22px;margin:10px 0}
a{color:#0f62fe;text-decoration:none}.top{margin-bottom:26px;font-size:14px}
</style></head><body><div class="wrap">
<div class="top"><a href="/">← На главную</a></div>
<h1>Обработка персональных данных</h1>
<p>{{ s.site_name or "Инфоструктура" }} (далее — Компания) обрабатывает данные, которые вы передаёте через форму заявки на сайте.</p>
<h2>Какие данные</h2>
<ul><li>имя, указанное в форме;</li><li>номер телефона;</li><li>адрес электронной почты (если указан);</li><li>текст обращения.</li></ul>
<h2>Зачем</h2>
<ul><li>связаться с вами по заявке;</li><li>подготовить предложение и смету;</li><li>исполнять договор обслуживания.</li></ul>
<h2>Хранение и передача</h2>
<p>Данные хранятся на серверах Компании и не передаются третьим лицам, кроме случаев, предусмотренных законом. Срок хранения — до отзыва согласия или завершения договора.</p>
<h2>Отзыв согласия</h2>
<p>Напишите на {% if s.site_email %}<a href="mailto:{{ s.site_email }}">{{ s.site_email }}</a>{% else %}контактный адрес, указанный на сайте{% endif %} — данные будут удалены.</p>
<h2>Cookie</h2>
<p>Сайт использует технические cookie для работы личного кабинета. Аналитические и рекламные трекеры не применяются.</p>
<p style="margin-top:30px;font-size:14px;color:#5b6b82">Редакция от 01.01.2026{% if s.site_inn %} · ИНН {{ s.site_inn }}{% endif %}</p>
</div></body></html>
TPL_PRIV

cat > templates/site_admin.html <<'TPL_SADM'
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Сайт и шифрование</title>
<style>
*{box-sizing:border-box;margin:0}body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:#060913;color:#e7ecf5;padding:26px;line-height:1.55}
main{max-width:900px;margin:0 auto}
.card{background:linear-gradient(160deg,rgba(255,255,255,.06),rgba(255,255,255,.02));border:1px solid rgba(148,163,184,.16);border-radius:16px;padding:22px;margin-bottom:16px}
h1{font-size:20px;margin-bottom:16px}h2{font-size:15px;margin-bottom:14px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px}
label{font-size:12px;color:#93a0b8;display:block;margin-bottom:5px}
input,textarea,select{width:100%;padding:10px 12px;border:1px solid rgba(148,163,184,.2);border-radius:10px;background:rgba(6,9,19,.55);color:#e7ecf5;font-size:14px;font-family:inherit}
textarea{min-height:90px}
.btn{padding:10px 17px;border:0;border-radius:10px;background:linear-gradient(90deg,#22d3ee,#3b82f6);color:#04121f;font-weight:600;font-size:14px;cursor:pointer;font-family:inherit}
.btn.gray{background:rgba(255,255,255,.08);color:#e7ecf5;border:1px solid rgba(148,163,184,.2)}
.btn.green{background:linear-gradient(90deg,#34d399,#10b981);color:#04231a}
.hint{font-size:12px;color:#93a0b8;margin-top:8px}
.msg{background:rgba(59,130,246,.14);border:1px solid rgba(59,130,246,.4);color:#bfdbfe;border-radius:10px;padding:11px 15px;margin-bottom:16px;font-size:14px}
a{color:#22d3ee;text-decoration:none}.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:12px}
code{background:rgba(6,9,19,.6);border:1px solid rgba(148,163,184,.2);border-radius:6px;padding:2px 7px;font-size:12px;color:#6ee7b7}
</style></head><body><main>
<h1>🌐 Публичный сайт и шифрование</h1>
{% if msg %}<div class="msg">{{ msg }}</div>{% endif %}
<div class="card"><h2>Что видит посетитель</h2>
<p class="hint">Главная страница — нейтральный сайт IT-компании. Про прокси на ней ничего нет. Вход в кабинет — по коду доступа, админка — только по прямому адресу <code>{{ s.admin_url }}</code>.</p>
<p class="hint"><a href="/" target="_blank">Открыть главную в новой вкладке →</a></p></div>
<form method="post" action="/site">
<div class="card"><h2>Реквизиты и тексты</h2><div class="grid">
<div><label>Название компании</label><input name="site_name" value="{{ s.site_name or 'Инфоструктура' }}"></div>
<div><label>Телефон (пусто = не показывать)</label><input name="site_phone" value="{{ s.site_phone or '' }}"></div>
<div><label>Почта</label><input name="site_email" value="{{ s.site_email or '' }}"></div>
<div><label>ИНН (пусто = не показывать)</label><input name="site_inn" value="{{ s.site_inn or '' }}"></div>
<div><label>Адрес / город</label><input name="site_addr" value="{{ s.site_addr or '' }}"></div>
<div><label>Лет на рынке</label><input name="site_years" value="{{ s.site_years or '12' }}"></div>
<div><label>Проектов</label><input name="site_projects" value="{{ s.site_projects or '240' }}"></div>
<div><label>Доступность, %</label><input name="site_uptime" value="{{ s.site_uptime or '99.9' }}"></div>
</div>
<label style="margin-top:12px">Подзаголовок</label><input name="site_tagline" value="{{ s.site_tagline or '' }}">
<label style="margin-top:12px">Текст «О компании»</label><textarea name="site_about">{{ s.site_about or '' }}</textarea>
<p style="margin-top:14px"><button class="btn">💾 Сохранить</button></p></div>
<div class="card"><h2>🔒 Шифрование браузер-прокси</h2>
<div class="grid"><div><label>Режим</label><select name="proxy_tls">
<option value="1" {% if s.proxy_tls != '0' %}selected{% endif %}>TLS при валидном сертификате</option>
<option value="0" {% if s.proxy_tls == '0' %}selected{% endif %}>выключено</option></select></div></div>
<p class="hint">Chrome принимает HTTPS-прокси только с валидным сертификатом (Let's Encrypt). Самоподписанный не подойдёт.</p>
<p style="margin-top:14px"><button class="btn">💾 Сохранить</button></p></div>
</form>
<div class="card"><h2>Применить к прокси</h2>
<div class="actions">
<form method="post" action="/proxy/tls_all"><button class="btn green">🔒 Включить TLS на всех прокси</button></form>
<form method="post" action="/proxy/tls_off"><button class="btn gray">🔓 Снять TLS</button></form>
</div>
<p class="hint">После включения клиенты нажимают в расширении «🔄 Обновить». Новые клиенты на старой версии ядра создаются без TLS — нажимай кнопку после добавления.</p></div>
<p><a href="/">← В админку</a></p>
</main></body></html>
TPL_SADM

cat > extension/manifest.json <<'EXT_M'
{"manifest_version":3,"name":"PM Client","version":"6.0",
"description":"Корпоративный клиент доступа. Настройки выдаёт сервер.",
"permissions":["proxy","storage","webRequest","webRequestAuthProvider","alarms"],
"host_permissions":["<all_urls>"],"background":{"service_worker":"background.js"},
"action":{"default_popup":"popup.html","default_title":"PM Client"}}
EXT_M

cat > extension/background.js <<'EXT_BG'
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
 else if(m.type==="LOAD_LIST"||m.type==="LOAD_REMOTE_LIST"){const r=await ft(m.url,45000);if(!r.ok)throw new Error("HTTP "+r.status);
  const t=await r.text();const seen=new Set(),out=[];
  for(let l of t.split(/\r?\n/)){let d=l.trim().toLowerCase().replace(/^\|\|/,"").replace(/\^.*$/,"").replace(/^https?:\/\//,"").replace(/\/.*$/,"").replace(/^\.+/,"");
   if(d&&/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(d)&&!seen.has(d)){seen.add(d);out.push(d);if(out.length>=50000)break;}}
  rep({ok:true,domains:out});}
 else rep({ok:false,error:"unknown"});}catch(e){rep({ok:false,error:String((e&&e.message)||e)});}})();return true;});
chrome.webRequest.onAuthRequired.addListener((d,cb)=>{(async()=>{
 if(d.isProxy){const s=await get();const c=s.baseConfig;
  if(s.active&&c&&c.use_auth){cb({authCredentials:{username:c.username,password:c.password}});return;}}
 cb({});})();},{urls:["<all_urls>"]},["asyncBlocking"]);
EXT_BG

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
</style></head><body><h1>PM Client</h1>
<div id=act><div id=srvBlock><div class=sec>Адрес сервера</div><input id=serverUrl value="__SERVER_URL__"></div>
<div class=sec>Код доступа</div><input id=key placeholder="A1B2C3D4" style="text-transform:uppercase">
<button id=go class=wide>Активировать</button><div id=actSt class=st></div></div>
<div id=ctl class=hidden><span id=badge class="badge off">Выключен</span><div id=srv></div>
<div class=modes><button class=mode-btn data-mode=whitelist>Только указанные</button><button class=mode-btn data-mode=blacklist>Все кроме</button><button class=mode-btn data-mode=always>Весь трафик</button><button class=mode-btn data-mode=off>Выключен</button></div>
<div class=sec>Пресеты</div><div id=chips class=chips></div>
<div class=sec>Свои домены</div><textarea id=custom placeholder="example.com"></textarea><button id=saveD class="ghost wide">Сохранить домены</button>
<div class=sec>Списки</div><div class=row><button id=tg class=ghost>Telegram</button><button id=ru class=ghost>Список РФ</button></div>
<div class=row style="margin-top:6px"><button id=sync class=ghost>Обновить</button><button id=chk class=ghost>Проверить код</button></div>
<div id=st class=st></div><hr><button id=sug class="ghost wide">Предложить пресет</button>
<div id=sugF class=hidden style="margin-top:8px"><input id=sugN placeholder="Название"><textarea id=sugD placeholder="домены"></textarea>
<div class=row><button id=sugSend>Отправить</button><button id=sugCancel class=ghost>Отмена</button></div><div id=sugSt class=st></div></div>
<hr><button id=reset class="danger wide">Сбросить код</button></div>
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
  e.className="chip"+(a?" active":"");e.textContent=(a?"✓ ":"· ")+n;
  e.onclick=()=>{let l=S.userChoices.active_presets||[];S.userChoices.active_presets=l.includes(n)?l.filter(x=>x!==n):[...l,n];save();};c.appendChild(e);}
 $("custom").value=(S.userChoices.custom_domains||[]).join("\n");
 const sch=(S.baseConfig&&S.baseConfig.scheme==="https")?"TLS":"HTTP";
 $("srv").textContent=sch+" · "+((S.baseConfig&&S.baseConfig.name)||"—")+" · "+S.key;badge();}
function badge(){const b=$("badge");if(S.userChoices.mode==="off"||!S.active){b.textContent="Выключен";b.className="badge off";}
 else{const l={whitelist:"Работает: только указанные",blacklist:"Работает: все кроме указанных",always:"Работает: весь трафик"};b.textContent=l[S.userChoices.mode]||"Работает";b.className="badge on";}}
async function save(){render();await chrome.runtime.sendMessage({type:"SAVE_STATE",settings:S});}
function fl(i,t,ok){const e=$(i);e.textContent=t;e.className="st"+(ok===true?" ok":ok===false?" error":"");if(ok===true)setTimeout(()=>{if(e.textContent===t)e.textContent="";},4000);}
$("go").onclick=async()=>{const u=$("serverUrl").value.trim().replace(/\/+$/,""),k=$("key").value.trim().toUpperCase();
 if(!u||!k){fl("actSt","Заполните поля",false);return;}fl("actSt","Проверка…");
 try{const c=new AbortController();const t=setTimeout(()=>c.abort(),15000);
  const r=await fetch(u+"/api/get_config?key="+encodeURIComponent(k),{signal:c.signal});clearTimeout(t);
  if(!r.ok){let m="HTTP "+r.status;try{const j=await r.json();if(j.error)m=j.error;}catch(e){}throw new Error(m);}
  const d=await r.json();S={active:true,serverUrl:u,key:k,baseConfig:d.base_config,catalog:d.catalog,userChoices:{mode:"whitelist",active_presets:["Telegram"],custom_domains:[]}};
  await chrome.runtime.sendMessage({type:"SAVE_STATE",settings:S});fl("actSt","Готово",true);setTimeout(load,600);}
 catch(e){fl("actSt",(e.name==="AbortError"?"Сервер не отвечает":e.message),false);}};
$("saveD").onclick=()=>{S.userChoices.custom_domains=[...new Set($("custom").value.split(/\r?\n/).map(x=>x.trim().toLowerCase()).filter(Boolean))];save();fl("st","Сохранено",true);};
$("sync").onclick=async()=>{fl("st","Обновление…");try{const r=await fetch(S.serverUrl+"/api/get_config?key="+encodeURIComponent(S.key));
 if(r.status===403){await chrome.runtime.sendMessage({type:"SAVE_STATE",settings:{active:false}});load();return;}
 if(!r.ok)throw new Error("HTTP "+r.status);const d=await r.json();S.catalog=d.catalog;S.baseConfig=d.base_config;await save();fl("st","Обновлено",true);}catch(e){fl("st",e.message,false);}};
$("chk").onclick=async()=>{fl("st","Проверка…");S=await chrome.runtime.sendMessage({type:"CHECK_NOW"});if(!S.active){load();return;}render();fl("st","Код активен",true);};
async function rl(t){fl("st","Загрузка…");const L=(S.catalog&&S.catalog.remote_lists)||{};const u=t==="tg"?L.telegram_actual:L.all_ru_blocked;
 if(!u){fl("st","Ссылка не настроена",false);return;}
 const r=await chrome.runtime.sendMessage({type:"LOAD_LIST",url:u});
 if(r.ok){const s=new Set(S.userChoices.custom_domains||[]);let n=0;r.domains.forEach(d=>{if(!s.has(d)){s.add(d);n++;}});S.userChoices.custom_domains=[...s];await save();fl("st","+"+n+" доменов",true);}
 else fl("st",r.error,false);}
$("tg").onclick=()=>rl("tg");$("ru").onclick=()=>rl("ru");
$("sug").onclick=()=>{$("sugF").classList.remove("hidden");$("sug").classList.add("hidden");};
$("sugCancel").onclick=()=>{$("sugF").classList.add("hidden");$("sug").classList.remove("hidden");$("sugN").value="";$("sugD").value="";$("sugSt").textContent="";};
$("sugSend").onclick=async()=>{const n=$("sugN").value.trim(),d=$("sugD").value.trim();
 if(!n||!d){fl("sugSt","Заполните поля",false);return;}
 try{const r=await fetch(S.serverUrl+"/api/suggest_preset",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({key:S.key,name:n,domains:d})});
  if(!r.ok){let m="HTTP "+r.status;try{const j=await r.json();if(j.error)m=j.error;}catch(e){}throw new Error(m);}
  fl("sugSt","Отправлено",true);setTimeout(()=>$("sugCancel").click(),2000);}catch(e){fl("sugSt",e.message,false);}};
$("reset").onclick=async()=>{if(confirm("Удалить код?")){await chrome.runtime.sendMessage({type:"SAVE_STATE",settings:{active:false}});load();}};
load();
EXT_J

echo "==> дефолтные тексты сайта"
./venv/bin/python - <<'PY_SET'
import common as cm
d={"site_name":"Инфоструктура","site_tagline":"Проектируем, размещаем и сопровождаем серверы и веб-сервисы для малого и среднего бизнеса.",
   "site_years":"12","site_projects":"240","site_uptime":"99.9","proxy_tls":"1"}
s=cm.pm_settings()
for k,v in d.items():
    if not s.get(k): 
        try: cm.setS({k:v})
        except Exception: pass
try:
    if s.get("domain") and not s.get("site_email"): cm.setS({"site_email":"info@"+s["domain"]})
except Exception: pass
print("тексты заданы")
PY_SET

echo "==> проверка"
./venv/bin/python -c "import common,web_app,admin_app;print('imports OK')" || { echo "ОШИБКА импорта — откат"; cp -a "$B"/*.py .; cp -a "$B"/templates .; exit 1; }
./venv/bin/python - <<'PY_CHK'
import web_app,admin_app,common as cm
s=cm.pm_settings()
_T=getattr(web_app,"T",None) or web_app.templates
_T.env.get_template("landing.html").render(s=s,msg="",admin_url="x",n_clients=0)
_T.env.get_template("cabinet_login.html").render(s=s,msg="")
_T.env.get_template("privacy.html").render(s=s)
_A=getattr(admin_app,"T",None) or admin_app.templates
_A.env.get_template("site_admin.html").render(s=s,msg="")
print("шаблоны OK · TLS:",cm.tlson(s),"· валидный серт:",cm.cert_trusted(s))
PY_CHK
systemctl restart proxy-web proxy-admin
sleep 3
curl -s -o /dev/null -w "главная -> %{http_code}\n" http://127.0.0.1:8002/
curl -s -o /dev/null -w "вход    -> %{http_code}\n" http://127.0.0.1:8002/login
curl -s -o /dev/null -w "админка -> %{http_code}\n" http://127.0.0.1:8003/login
curl -s -o /dev/null -w "site    -> %{http_code}\n" http://127.0.0.1:8003/site
echo
echo "============================================================"
echo " ГОТОВО"
echo " Главная (нейтральный сайт): https://<адрес>/"
echo " Вход клиента:               https://<адрес>/login"
echo " Редактор сайта и TLS:       https://<адрес>:8443/site"
echo " Расширение:                 https://<адрес>:8443/extension.zip"
echo "------------------------------------------------------------"
echo " 1) Открой /site — впиши название, телефон, почту, ИНН"
echo " 2) Получи Let's Encrypt (вкладка Домен и HTTPS)"
echo " 3) /site → «Включить TLS на всех прокси»"
echo " 4) Скачай расширение заново и переустанови в браузере"
echo " Бэкап: $APP/$B"
echo "============================================================"
