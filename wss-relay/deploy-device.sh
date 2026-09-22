#!/bin/bash
# deploy-device.sh — 在站点设备上部署 ssh-relay frpc (WSS -> Tokyo)
# 用法:
#   sudo ./deploy-device.sh --name p1 --remote-port 21001
#   sudo ./deploy-device.sh --name p1 --remote-port 21001 --lan-relay 21002:10.18.8.26:22
# 依赖: frpc 二进制（默认复用本机 dsh-remote-agent 自带的 0.71.0），token 在
#       /root/.ssh-relay-token (600, 单行无换行)。
set -euo pipefail

NAME="" PORT="" TOKEN_FILE="/root/.ssh-relay-token" LAN_RELAYS=()
FRPC_SRC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --remote-port) PORT="$2"; shift 2 ;;
    --token-file) TOKEN_FILE="$2"; shift 2 ;;
    --frpc) FRPC_SRC="$2"; shift 2 ;;
    --lan-relay) LAN_RELAYS+=("$2"); shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done
[ -n "$NAME" ] && [ -n "$PORT" ] || { echo "need --name and --remote-port" >&2; exit 1; }
[ -r "$TOKEN_FILE" ] || { echo "token file $TOKEN_FILE missing" >&2; exit 1; }

# frpc 二进制来源：优先 --frpc，其次本机 dsh-remote-agent 自带
if [ -z "$FRPC_SRC" ]; then
  for c in /root/.local/libexec/dsh-remote-agent/current/frpc \
           /home/data/dsh/root-local/.local/libexec/dsh-remote-agent/current/frpc; do
    [ -x "$c" ] && FRPC_SRC="$c" && break
  done
fi
[ -x "$FRPC_SRC" ] || { echo "frpc binary not found (pass --frpc)"; exit 1; }
FRPC_SRC=$(readlink -f "$FRPC_SRC")

mkdir -p /opt/ssh-relay
cp "$FRPC_SRC" /opt/ssh-relay/frpc
chmod 700 /opt/ssh-relay/frpc

umask 077
TOKEN=$(cat "$TOKEN_FILE")
{
  cat <<EOF
serverAddr = "ssh-relay.dsh.onlyservice.io"
serverPort = 443
user = "$NAME"
auth.token = "$TOKEN"
transport.protocol = "wss"
transport.tls.serverName = "ssh-relay.dsh.onlyservice.io"
transport.poolCount = 4
loginFailExit = false

[[proxies]]
name = "$NAME-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $PORT
EOF
  i=0
  for lr in "${LAN_RELAYS[@]:-}"; do
    [ -z "$lr" ] && continue
    i=$((i+1))
    rport="${lr%%:*}"; rest="${lr#*:}"; rhost="${rest%%:*}"; rport2="${rest#*:}"
    cat <<EOF

[[proxies]]
name = "$NAME-lan-$i"
type = "tcp"
localIP = "$rhost"
localPort = ${rport2:-22}
remotePort = $rport
EOF
  done
} > /opt/ssh-relay/frpc.toml

install -m 644 "$(dirname "$0")/ssh-relay.service" /etc/systemd/system/ssh-relay.service
systemctl daemon-reload
systemctl enable --now ssh-relay
sleep 3
systemctl is-active ssh-relay
journalctl -u ssh-relay -n 5 --no-pager | grep -E "login to server success|start proxy (success|error)" | head -3
