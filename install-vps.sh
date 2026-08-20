#!/usr/bin/env bash

set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JUMP_HOST=${1:-feishu-APP-Pvjp-000}
SSH_OPTIONS=(-o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=yes -o ConnectTimeout=10)

command -v ssh >/dev/null 2>&1 || { echo 'error: ssh is required' >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo 'error: tar is required' >&2; exit 1; }

ssh -T "${SSH_OPTIONS[@]}" "$JUMP_HOST" 'command -v tar >/dev/null && command -v ss >/dev/null' || {
  echo 'error: VPS needs tar and ss' >&2
  exit 1
}

COPYFILE_DISABLE=1 tar --no-xattrs -C "$ROOT/vps" -cf - reverse-tunnel-session reverse-tunnel-status port-pool.conf | \
  ssh -T "${SSH_OPTIONS[@]}" "$JUMP_HOST" '
    set -Eeuo pipefail
    umask 077
    tmp=$(mktemp -d)
    trap '\''rm -rf "$tmp"'\'' EXIT
    tar -xf - -C "$tmp"
    mkdir -p "$HOME/.local/bin" "$HOME/.local/state/reverse-tunnels/registry" "$HOME/.local/state/reverse-tunnels/online" "$HOME/.config/reverse-tunnels"
    chmod 0700 "$HOME/.local/state/reverse-tunnels" "$HOME/.local/state/reverse-tunnels/registry" "$HOME/.local/state/reverse-tunnels/online"
    for name in reverse-tunnel-session reverse-tunnel-status; do
      destination=$HOME/.local/bin/$name
      if [[ -f $destination ]] && ! cmp -s "$destination" "$tmp/$name"; then
        cp -p "$destination" "$destination.backup-$(date +%Y%m%d-%H%M%S)"
      fi
      install -m 0755 "$tmp/$name" "$destination"
    done
    destination=$HOME/.config/reverse-tunnels/port-pool.conf
    if [[ -f $destination ]] && ! cmp -s "$destination" "$tmp/port-pool.conf"; then
      cp -p "$destination" "$destination.backup-$(date +%Y%m%d-%H%M%S)"
    fi
    install -m 0600 "$tmp/port-pool.conf" "$destination"
  '

printf 'Installed VPS tools on %s\n' "$JUMP_HOST"
ssh -T "${SSH_OPTIONS[@]}" "$JUMP_HOST" '~/.local/bin/reverse-tunnel-status'
