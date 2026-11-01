#!/bin/bash
# Включает и снимает прокси туннеля для Claude Code и браузера — то же, что делает приложение
# (само включает, когда сервер настроен, и снимает при выходе). Нужен, если приложение закрыли аварийно.
#   mode.sh on   — прокси в ~/.claude/settings.json и PAC для сетевой службы
#   mode.sh off  — снять и то и другое
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
SVC=$(conf networkService Wi-Fi)
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
    networksetup -setautoproxyurl "$SVC" "$PAC_URL"
    networksetup -setautoproxystate "$SVC" on
    echo "Включено. Перезапустите Claude Code и приложение Claude, затем: bash $(cd "$(dirname "$0")" && pwd)/check.sh"
    ;;
  off)
    set_env off
    networksetup -setautoproxystate "$SVC" off
    echo "Снято. Claude Code и браузер ходят напрямую."
    ;;
  "")
    cc=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("env",{}).get("HTTPS_PROXY",""))' 2>/dev/null)
    pac=$(networksetup -getautoproxyurl "$SVC" | grep -c "Enabled: Yes" || true)
    echo "Claude Code: ${cc:-без прокси}; PAC для $SVC: $([ "$pac" = 1 ] && echo вкл || echo выкл)"
    ;;
  *)
    echo "mode.sh on | off"; exit 2 ;;
esac
