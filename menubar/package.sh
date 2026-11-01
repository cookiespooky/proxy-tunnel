#!/bin/bash
# Собирает приложение и упаковывает его для пользователей: dist/ProxyTunnel-mac.dmg
# с ярлыком «Applications» — открыть образ и перетащить значок.
# Подпись — ad hoc, без нотаризации Apple: на чужом Маке первый запуск — через «Открыть» в контекстном меню
# или «Всё равно открыть» в «Конфиденциальность и безопасность» (README, «Установка»).
set -e
cd "$(dirname "$0")"
./build.sh
APP="build/Proxy Tunnel.app"
OUT="../dist/ProxyTunnel-mac.dmg"   # без версии: на него ведёт ссылка «последний релиз» в README
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Proxy Tunnel.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p ../dist
rm -f "$OUT"
hdiutil create -quiet -volname "Proxy Tunnel" -srcfolder "$STAGE" -format UDZO -ov "$OUT"
echo "Образ: $(cd ../dist && pwd)/$(basename "$OUT")"
