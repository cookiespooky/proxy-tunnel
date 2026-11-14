#!/bin/bash
# Проверка туннеля перед работой с подпиской Claude — то же, что «Проверить» в окошке Proxy Tunnel.
# Итог — отдельной строкой для каждого: Claude Code, codex и gemini в терминале, VS Code, браузер с приложением Claude
# (каждое — если включено в настройках программы). ✓ — через туннель, ! — работает, но с оговоркой (браузер идёт через
# VPN), ✗ — не работает. Последняя строка начинается с «МОЖНО» или «НЕЛЬЗЯ».
# Код выхода: 0 — можно (оговорки «!» не мешают); 2 — Claude Code можно, остальное — не всё; 1 — нельзя ничего.
# Сервер, порты и галочки берёт из настроек приложения.
CONF="$HOME/Library/Application Support/Proxy Tunnel/config.json"
STATE="$HOME/Library/Application Support/Proxy Tunnel/cli-proxy"
conf() { python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(c.get(sys.argv[2],sys.argv[3]))' "$CONF" "$1" "$2" 2>/dev/null || echo "$2"; }
EXPECT_IP=$(conf host "")
LOCAL=$(conf localPort 8888)
PACP=$(conf pacPort 8889)
PROXY="http://127.0.0.1:$LOCAL"
# До разделения была одна галочка cliProxy на codex и gemini.
LEGACY=$(conf cliProxy True)
CLAUDE=$(conf claudeCode True)
CODEX=$(conf codexCLI "$LEGACY")
GEMINI=$(conf geminiCLI "$LEGACY")
VS_CODEX=$(conf vscodeCodex False)
VS_ALL=$(conf vscodeAll False)

bad_tunnel=0; bad_browser=0; bad_cc=0; bad_cli=0; bad_vs=0; warn_browser=0; warn_vs=0; sec=tunnel
ok()   { printf "  ✓ %s\n" "$1"; }
warn() { printf "  ! %s\n" "$1"; eval "warn_$sec=1"; }
fail() { printf "  ✗ %s\n" "$1"; eval "bad_$sec=1"; }

echo "Туннель:"
if pgrep -f "ssh -N -F none .*-L 127.0.0.1:$LOCAL:" >/dev/null; then
  ok "туннель (ssh) запущен"
else
  fail "туннель не запущен — запустите Proxy Tunnel"
fi
if lsof -nP -iTCP:"$LOCAL" -sTCP:LISTEN 2>/dev/null | grep -q ssh; then
  ok "порт 127.0.0.1:$LOCAL открыт туннелем"
else
  fail "порт $LOCAL не слушает ssh"
fi
trace=$(curl -s -x "$PROXY" --max-time 10 https://claude.ai/cdn-cgi/trace)
ip=$(echo "$trace" | sed -n 's/^ip=//p'); loc=$(echo "$trace" | sed -n 's/^loc=//p')
if [ -n "$ip" ] && [ "$ip" = "$EXPECT_IP" ] && [ "$loc" != "RU" ]; then
  ok "claude.ai через туннель видит $ip, $loc"
else
  fail "claude.ai через туннель видит «${ip:-нет ответа}» «${loc}» — ожидалось ${EXPECT_IP:-адрес из настроек}, не RU"
fi

if [ "$CLAUDE" = "True" ]; then
  sec=cc
  echo "Claude Code:"
  cc=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("env",{}).get("HTTPS_PROXY",""))' 2>/dev/null)
  if [ "$cc" = "$PROXY" ]; then
    ok "HTTPS_PROXY в ~/.claude/settings.json — в терминале и в VS Code, целиком"
  else
    fail "HTTPS_PROXY в ~/.claude/settings.json не задан — Claude Code пойдёт напрямую"
  fi
fi

# codex и gemini в терминале: блок программы в ~/.zshrc и адрес прокси для него (menubar/Terminal.swift).
names=""
[ "$CODEX" = "True" ] && command -v codex >/dev/null && names="codex"
if [ "$GEMINI" = "True" ] && { command -v gemini >/dev/null || [ -f "$HOME/.gemini/settings.json" ] || [ -f "$HOME/.gemini/oauth_creds.json" ]; }; then
  names="${names:+$names и }gemini"
fi
if [ -n "$names" ]; then
  sec=cli
  echo "$names в терминале:"
  if ! grep -qF "# >>> Proxy Tunnel >>>" "$HOME/.zshrc" 2>/dev/null; then
    fail "блока Proxy Tunnel нет в ~/.zshrc — $names идут напрямую"
  elif [ "$(cat "$STATE" 2>/dev/null)" != "$PROXY" ]; then
    fail "адрес прокси для терминала не записан — $names идут напрямую"
  else
    ok "$names — через туннель, целиком (в окнах терминала, открытых после включения)"
  fi
  if [ "$CODEX" = "True" ] && grep -Eq '^[[:space:]]*(features\.)?respect_system_proxy[[:space:]]*=[[:space:]]*true' "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null; then
    fail "в ~/.codex/config.toml включён respect_system_proxy — с ним Codex идёт мимо туннеля; уберите эту строку"
  fi
fi

# VS Code: окружение запущенных процессов — так они ходят на самом деле.
uses_proxy() {  # $1 — часть команды процесса; 0 — все с нашим прокси, 1 — нет, 2 — таких процессов нет
  local l
  l=$(ps -axww -E -o command= | grep -F "$1" | grep -v -e "grep" -e "/bin/ps ")
  [ -z "$l" ] && return 2
  echo "$l" | grep -vqF "HTTPS_PROXY=$PROXY" && return 1
  return 0
}
if [ "$VS_CODEX" = "True" ] || [ "$VS_ALL" = "True" ]; then
  sec=vs
  echo "VS Code:"
  if [ "$VS_CODEX" = "True" ]; then
    if ! grep -qF "\"chatgpt.cliExecutable\": \"$HOME/Library/Application Support/Proxy Tunnel/codex-vscode\"" "$HOME/Library/Application Support/Code/User/settings.json" 2>/dev/null; then
      fail "Codex: строки Proxy Tunnel нет в настройках VS Code"
    else
      uses_proxy "openai.chatgpt-"; r=$?
      case $r in 0) ok "Codex — через туннель";; 1) warn "Codex — пока напрямую: перезапустите VS Code";; *) ok "Codex — через туннель с запуска VS Code";; esac
    fi
  fi
  if [ "$VS_ALL" = "True" ]; then
    if ! grep -qF "VSCODE_RESOLVING_ENVIRONMENT" "$HOME/.zshrc" 2>/dev/null; then
      fail "весь VS Code: блока Proxy Tunnel нет в ~/.zshrc"
    else
      uses_proxy "Code Helper (Plugin)"; r=$?
      case $r in 0) ok "весь VS Code — через туннель";; 1) warn "весь VS Code — пока напрямую: закройте VS Code и откройте из Dock";; *) ok "весь VS Code — через туннель с запуска из Dock";; esac
    fi
  fi
fi

sec=browser
echo "Браузер и приложение Claude:"
# Не настройка Wi-Fi, а то, что система применяет на самом деле: VPN в режиме TUN её перекрывает. Это не поломка —
# браузер просто идёт через VPN: «!», а не «✗».
eff=$(scutil --proxy)
if echo "$eff" | grep -q "ProxyAutoConfigEnable : 1" && echo "$eff" | grep -q "ProxyAutoConfigURLString : http://127.0.0.1:$PACP/proxy.pac"; then
  ok "система применяет список сайтов туннеля"
else
  iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  case "$iface" in utun*|ppp*|ipsec*) warn "включён VPN ($iface): браузер и приложение Claude идут через VPN, а не через туннель";;
    *) fail "система не применяет список сайтов туннеля";; esac
fi
if echo "$eff" | grep -Eq "(HTTP|HTTPS|SOCKS)Enable : 1"; then fail "в системе включён ещё и обычный прокси — браузер может пойти через него"; fi
if curl -s --noproxy '*' --max-time 3 "http://127.0.0.1:$PACP/proxy.pac" | grep -q "PROXY 127.0.0.1:$LOCAL"; then
  ok "список сайтов раздаётся"
else
  fail "список сайтов не раздаётся — эти сайты не откроются"
fi

# Без туннеля нельзя ничего.
[ $bad_tunnel = 1 ] && { bad_browser=1; bad_cc=1; bad_cli=1; bad_vs=1; }
line() {  # $1 — что, $2 — bad, $3 — warn, $4 — текст оговорки
  if [ "$2" = 1 ]; then echo "  $1: НЕЛЬЗЯ — пойдёт не через туннель (причина — ✗ выше)."
  elif [ "$3" = 1 ]; then echo "  $1: МОЖНО, с оговоркой — $4."
  else echo "  $1: МОЖНО — через туннель."; fi
}
echo
[ "$CLAUDE" = "True" ] && line "Claude Code" $bad_cc 0 ""
[ -n "$names" ] && line "$names в терминале" $bad_cli 0 ""
[ "$VS_CODEX" = "True" ] || [ "$VS_ALL" = "True" ] && line "VS Code" $bad_vs $warn_vs "см. «!» выше"
line "Браузер и приложение Claude" $bad_browser $warn_browser "идут через VPN, а не через туннель"
echo
other=$((bad_browser + bad_cli + bad_vs))
if [ $bad_tunnel = 0 ] && [ $bad_cc = 0 ] && [ $other = 0 ]; then
  if [ $warn_browser = 1 ] || [ $warn_vs = 1 ]; then echo "МОЖНО, с оговорками «!» выше ($EXPECT_IP)."; else echo "МОЖНО: всё через туннель ($EXPECT_IP)."; fi
  exit 0
elif [ $bad_tunnel = 0 ] && [ $bad_cc = 0 ]; then
  no=""; [ $bad_browser = 1 ] && no="claude.ai и приложение Claude"
  [ $bad_cli = 1 ] && no="${no:+$no, }$names в терминале"
  [ $bad_vs = 1 ] && no="${no:+$no, }VS Code"
  echo "НЕЛЬЗЯ: $no. Claude Code — можно."; exit 2
else
  echo "НЕЛЬЗЯ: не открывайте Claude, пока не исправлено отмеченное ✗."; exit 1
fi
