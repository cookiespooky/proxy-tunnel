#!/bin/bash
# Выключает вход на сервер по паролю: остаются только ключи. Под root. Повторный запуск безопасен.
# Приложение запускает его, только когда вход по ключу несколько раз подряд прошёл, и после — проверяет,
# что вход по ключу работает, а пароль сервер больше не принимает.
# Последняя строка при успехе — «Proxy Tunnel: вход по паролю выключен»; ошибка — «PT-ERROR: …» и код не 0.
set -e
die() { echo "PT-ERROR: $*"; exit 3; }
[ "$(id -u)" = 0 ] || die "нужен root"

F=/etc/ssh/sshd_config.d/00-proxy-tunnel-no-password.conf
B=/root/proxy-tunnel-backup-$(date +%Y%m%d-%H%M%S)
mkdir -p "$B" /etc/ssh/sshd_config.d
cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.d "$B/"
restore() {
  cp -a "$B/sshd_config" /etc/ssh/sshd_config
  rm -rf /etc/ssh/sshd_config.d && cp -a "$B/sshd_config.d" /etc/ssh/sshd_config.d
}

# sshd берёт первое встреченное значение: «yes» в другом файле перебил бы наш. Такие строки — в комментарий.
for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
  [ -f "$f" ] && [ "$f" != "$F" ] || continue
  sed -i -E \
    -e 's/^([[:space:]]*)(PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication)[[:space:]]+yes/\1# \2 yes  # выключено Proxy Tunnel/I' \
    -e 's/^([[:space:]]*)PermitRootLogin[[:space:]]+yes/\1PermitRootLogin prohibit-password  # было yes, Proxy Tunnel/I' \
    "$f"
done
cat > "$F" <<'CONF'
# Proxy Tunnel: вход только по ключу
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
CONF

sshd -t || { restore; die "конфигурация sshd не прошла проверку — вернул как было"; }
sshd -T 2>/dev/null | grep -qi '^passwordauthentication no' || { restore; die "вход по паролю остался включён (sshd -T) — вернул как было"; }
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
echo "Копия прежних настроек: $B"
echo "Proxy Tunnel: вход по паролю выключен"
