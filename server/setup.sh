#!/bin/bash
# Настройка сервера для Proxy Tunnel (Ubuntu/Debian), под root. Повторный запуск безопасен.
# Ставит tinyproxy, слушающий только 127.0.0.1, и пользователя, которому разрешён один проброс — на этот порт.
# О Claude сервер ничего не знает: какие домены идут через туннель, решает приложение на компьютере.
#
# Входные данные — переменные окружения:
#   PUBKEY        публичный ключ туннеля (одна строка «ssh-ed25519 AAAA… комментарий»)
#   TUNNEL_USER   пользователь туннеля, по умолчанию tunnel
#   PROXY_PORT    порт прокси на сервере, по умолчанию 8888
# Последняя строка при успехе — «Proxy Tunnel: сервер готов»; ошибка — строка «PT-ERROR: …» и код не 0.
# Его запускают приложения (macOS — menubar/Setup.swift, вручную — команда из настроек), сами подставляя переменные.
set -e
TUNNEL_USER=${TUNNEL_USER:-tunnel}
PROXY_PORT=${PROXY_PORT:-8888}

die() { echo "PT-ERROR: $*"; exit 3; }
[ "$(id -u)" = 0 ] || die "нужен root"
echo "$TUNNEL_USER" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$' || die "недопустимое имя пользователя: $TUNNEL_USER"
echo "$PROXY_PORT" | grep -Eq '^[0-9]{1,5}$' || die "недопустимый порт: $PROXY_PORT"
echo "$PUBKEY" | grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) [A-Za-z0-9+/=]+( [^"]*)?$' || die "нет публичного ключа или он не похож на ключ"
command -v apt-get >/dev/null || die "нужен сервер на Ubuntu или Debian (нет apt-get)"

export DEBIAN_FRONTEND=noninteractive
echo "Ставлю tinyproxy…"
apt-get update -qq || die "apt-get update не прошёл — проверьте интернет на сервере"
apt-get install -y -qq tinyproxy >/dev/null || die "tinyproxy не установился"

cat > /etc/tinyproxy/tinyproxy.conf <<CONF
User tinyproxy
Group tinyproxy
Port $PROXY_PORT
Listen 127.0.0.1
Timeout 600
LogLevel Warning
Syslog On
MaxClients 200
Allow 127.0.0.1
ConnectPort 443
ConnectPort 80
DisableViaHeader Yes
CONF
systemctl enable -q tinyproxy
systemctl restart tinyproxy
sleep 1
systemctl is-active -q tinyproxy || die "tinyproxy не запустился: journalctl -u tinyproxy"

echo "Завожу пользователя $TUNNEL_USER…"
id "$TUNNEL_USER" >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin "$TUNNEL_USER"
H=$(getent passwd "$TUNNEL_USER" | cut -d: -f6)
install -d -m 700 -o "$TUNNEL_USER" -g "$TUNNEL_USER" "$H/.ssh"
touch "$H/.ssh/authorized_keys"
echo "restrict,port-forwarding,permitopen=\"127.0.0.1:$PROXY_PORT\" $PUBKEY" >> "$H/.ssh/authorized_keys"
sort -u -o "$H/.ssh/authorized_keys" "$H/.ssh/authorized_keys"
chown "$TUNNEL_USER:$TUNNEL_USER" "$H/.ssh/authorized_keys"
chmod 600 "$H/.ssh/authorized_keys"

mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-proxy-tunnel.conf <<CONF
Match User $TUNNEL_USER
  AllowTcpForwarding local
  PermitTTY no
  X11Forwarding no
  AllowAgentForwarding no
  PermitTunnel no
  GatewayPorts no
  ForceCommand /usr/sbin/nologin
CONF
sshd -t || die "конфигурация sshd не прошла проверку (sshd -t)"
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

echo "Proxy Tunnel: сервер готов"
