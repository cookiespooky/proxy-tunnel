#!/bin/bash
# Проверка туннеля перед работой с подпиской Claude — то же, что «Проверить» в окошке Proxy Tunnel.
# Последняя строка: «МОЖНО» или «НЕЛЬЗЯ». Код выхода 0 — можно.
# Сервер, порты и сетевую службу берёт из настроек приложения.
CONF="$HOME/Library/Application Support/Proxy Tunnel/config.json"
conf() { python3 -c 'import json,sys;c=json.load(open(sys.argv[1]));print(c.get(sys.argv[2],sys.argv[3]))' "$CONF" "$1" "$2" 2>/dev/null || echo "$2"; }
EXPECT_IP=$(conf host "")
LOCAL=$(conf localPort 8888)
PACP=$(conf pacPort 8889)
bad=0
ok()   { printf "  ✓ %s\n" "$1"; }
fail() { printf "  ✗ %s\n" "$1"; bad=1; }

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
trace=$(curl -s -x "http://127.0.0.1:$LOCAL" --max-time 10 https://claude.ai/cdn-cgi/trace)
ip=$(echo "$trace" | sed -n 's/^ip=//p'); loc=$(echo "$trace" | sed -n 's/^loc=//p')
if [ -n "$ip" ] && [ "$ip" = "$EXPECT_IP" ] && [ "$loc" != "RU" ]; then
  ok "claude.ai через туннель видит $ip, $loc"
else
  fail "claude.ai через туннель видит «${ip:-нет ответа}» «${loc}» — ожидалось ${EXPECT_IP:-адрес из настроек}, не RU"
fi

echo "Браузер и приложение Claude:"
# Не настройка Wi-Fi, а то, что система применяет на самом деле: VPN в режиме TUN её перекрывает.
eff=$(scutil --proxy)
if echo "$eff" | grep -q "ProxyAutoConfigEnable : 1" && echo "$eff" | grep -q "ProxyAutoConfigURLString : http://127.0.0.1:$PACP/proxy.pac"; then
  ok "система применяет PAC туннеля"
else
  iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  case "$iface" in utun*|ppp*|ipsec*) fail "включён VPN ($iface), система не применяет PAC — браузер и приложение Claude идут через VPN";;
    *) fail "система не применяет PAC туннеля";; esac
fi
if echo "$eff" | grep -Eq "(HTTP|HTTPS|SOCKS)Enable : 1"; then fail "в системе включён ещё и обычный прокси — браузер может пойти через него"; fi
if curl -s --noproxy '*' --max-time 3 "http://127.0.0.1:$PACP/proxy.pac" | grep -q "PROXY 127.0.0.1:$LOCAL"; then
  ok "PAC-файл раздаётся"
else
  fail "PAC-файл не раздаётся — эти сайты не откроются"
fi

echo "Claude Code:"
cc=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser("~/.claude/settings.json"))).get("env",{}).get("HTTPS_PROXY",""))' 2>/dev/null)
if [ "$cc" = "http://127.0.0.1:$LOCAL" ]; then
  ok "HTTPS_PROXY в ~/.claude/settings.json"
else
  fail "HTTPS_PROXY в ~/.claude/settings.json не задан — Claude Code пойдёт напрямую"
fi

echo
if [ $bad = 0 ]; then echo "МОЖНО: подписка пойдёт через туннель ($EXPECT_IP)."; exit 0
else echo "НЕЛЬЗЯ: не открывайте Claude, пока не исправлено отмеченное ✗."; exit 1; fi
