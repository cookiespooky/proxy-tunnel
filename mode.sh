#!/bin/bash
# Переключает, как Claude выходит в интернет, — то же, что переключатель в окошке Proxy Tunnel.
#   mode.sh tunnel — через свой SSH-туннель (VPN не нужен)
#   mode.sh vpn    — без туннеля: через любой включённый VPN; старое имя happ тоже работает
#   mode.sh        — показать текущий режим
# Трогает только env.HTTPS_PROXY и env.NO_PROXY в ~/.claude/settings.json и PAC сетевой службы.
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
  python3 - "$S" "$1" "$PROXY" "$HOST" <<'EOF'
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
EOF
}

current() {
  cc=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("env",{}).get("HTTPS_PROXY",""))' 2>/dev/null)
  pac=$(networksetup -getautoproxyurl "$SVC" | grep -c "Enabled: Yes" || true)
  if [ -n "$cc" ] && [ "$pac" = 1 ]; then echo "tunnel"
  elif [ -z "$cc" ] && [ "$pac" = 0 ]; then echo "vpn"
  else echo "смешанный (Claude Code: ${cc:-без прокси}, PAC: $([ "$pac" = 1 ] && echo вкл || echo выкл)) — выполните mode.sh tunnel или mode.sh vpn"; fi
}

case "$1" in
  tunnel)
    [ -n "$HOST" ] || { echo "В настройках приложения не указан сервер."; exit 2; }
    set_env on
    networksetup -setautoproxyurl "$SVC" "$PAC_URL"
    networksetup -setautoproxystate "$SVC" on
    echo "Режим: туннель. Перезапустите Claude Code и приложение Claude, затем:"
    echo "  bash $(cd "$(dirname "$0")" && pwd)/check.sh"
    ;;
  happ|vpn)
    set_env off
    networksetup -setautoproxystate "$SVC" off
    echo "Режим: VPN. Включите VPN-клиент, перезапустите Claude Code и приложение Claude."
    echo "Выход сейчас: $(curl -s --noproxy '*' --max-time 8 https://claude.ai/cdn-cgi/trace | sed -n 's/^loc=//p' | sed 's/^$/нет ответа/') (пусто или RU — VPN выключен, Claude не откроется)"
    ;;
  "")
    echo "Режим: $(current)"
    ;;
  *)
    echo "mode.sh tunnel | vpn"; exit 2 ;;
esac
