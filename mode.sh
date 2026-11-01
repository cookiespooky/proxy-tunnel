#!/bin/bash
# Включает и снимает прокси туннеля для Claude Code и браузера — то же, что делает приложение
# (само включает, когда сервер настроен, и снимает при выходе). Нужен, если приложение закрыли аварийно.
#   mode.sh on   — прокси в ~/.claude/settings.json и PAC на всех сетевых службах (VPN тоже; чужой PAC не трогается)
#   mode.sh off  — снять прокси и выключить PAC там, где стоит наш
#   mode.sh      — показать, включено ли
# Сервер, порты и службу берёт из настроек приложения.
set -e
S="$HOME/.claude/settings.json"
CONF="$HOME/Library/Application Support/Proxy Tunnel/config.json"
[ -f "$CONF" ] || { echo "Нет настроек приложения ($CONF) — сначала настройте Proxy Tunnel."; exit 2; }
conf() { python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(c.get(sys.argv[2],sys.argv[3]))' "$CONF" "$1" "$2"; }
HOST=$(conf host "")
LOCAL=$(conf localPort 8888)
PACP=$(conf pacPort 8889)
services() { networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*'; }
pac_of() { networksetup -getautoproxyurl "$1"; }
PROXY="http://127.0.0.1:$LOCAL"
PAC_URL="http://127.0.0.1:$PACP/proxy.pac"

set_env() {  # $1 = on | off
  python3 - "$S" "$1" "$PROXY" "$HOST" <<'PY'
import json, os, sys, shutil
p, mode, proxy, host = sys.argv[1:5]
d = json.load(open(p)) if os.path.exists(p) else {}
if os.path.exists(p):
    shutil.copy(p, p + ".bak")
env = d.get("env", {})
if mode == "on":
    env["HTTPS_PROXY"] = proxy
    env["NO_PROXY"] = "localhost,127.0.0.1,::1,.ru,.xn--p1ai," + host
else:
    env.pop("HTTPS_PROXY", None); env.pop("NO_PROXY", None)
if env: d["env"] = env
else: d.pop("env", None)
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, "w"), ensure_ascii=False, indent=2); open(p, "a").write("\n")
PY
}

case "$1" in
  on)
    [ -n "$HOST" ] || { echo "В настройках приложения не указан сервер."; exit 2; }
    set_env on
    services | while IFS= read -r s; do
      p=$(pac_of "$s")
      if echo "$p" | grep -q "Enabled: Yes" && ! echo "$p" | grep -qF "URL: $PAC_URL"; then echo "пропущена (чужой PAC): $s"; continue; fi
      networksetup -setautoproxyurl "$s" "$PAC_URL"; networksetup -setautoproxystate "$s" on
    done
    echo "Включено. Перезапустите Claude Code и приложение Claude, затем: bash $(cd "$(dirname "$0")" && pwd)/check.sh"
    ;;
  off)
    set_env off
    services | while IFS= read -r s; do
      pac_of "$s" | grep -qF "URL: $PAC_URL" && networksetup -setautoproxystate "$s" off
    done
    rm -f "$HOME/Library/Application Support/Proxy Tunnel/pac-services.json"
    echo "Снято. Claude Code и браузер ходят напрямую."
    ;;
  "")
    cc=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("env",{}).get("HTTPS_PROXY",""))' 2>/dev/null)
    n=0; services | { while IFS= read -r s; do p=$(pac_of "$s"); echo "$p" | grep -qF "URL: $PAC_URL" && echo "$p" | grep -q "Enabled: Yes" && n=$((n+1)); done; echo "Claude Code: ${cc:-без прокси}; PAC туннеля включён на службах: $n"; }
    scutil --proxy | grep -q "ProxyAutoConfigURLString : $PAC_URL" && echo "система применяет PAC туннеля" || echo "система PAC туннеля не применяет"
    ;;
  *)
    echo "mode.sh on | off"; exit 2 ;;
esac
