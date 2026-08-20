#!/usr/bin/env bash

set -Eeuo pipefail

PROGRAM=${0##*/}
DEFAULT_JUMP_HOST=feishu-APP-Pvjp-000
DEFAULT_LOCAL_SSH_PORT=22
PORT_POOL_START=20000
PORT_POOL_END=20999

usage() {
  cat <<EOF
Register a persistent reverse SSH tunnel through a jump host.

Usage:
  $PROGRAM --target HOST --name NAME [options]
  $PROGRAM --status [--jump-host HOST]

Required for registration:
  --target HOST          SSH host/alias of the new Linux machine
  --name NAME            New local SSH alias (for example: server-via-vps)
Options:
  --jump-host HOST       VPS SSH alias (default: $DEFAULT_JUMP_HOST)
  --remote-port PORT     Explicit port in $PORT_POOL_START-$PORT_POOL_END
                         (default: allocate the lowest free port automatically)
  --target-user USER     Login user exposed by the tunnel (default: ssh -G target)
  --local-ssh-port PORT  SSH port on the new machine (default: $DEFAULT_LOCAL_SSH_PORT)
  --identity-file PATH   Local key used to log in through the alias
                         (default: first identity from ssh -G target)
  --status               Show registered hosts, online state, and online duration
  -h, --help             Show this help

Prerequisites:
  - The controller can SSH to both --target and --jump-host.
  - The target runs Linux with systemd, OpenSSH client, ssh-keygen, and sudo.
  - The target login has passwordless sudo for non-interactive installation.

Example:
  ./$PROGRAM \\
    --target 'HQ-310p-#1' \\
    --name 'HQ-310p-#1-via-vps'

  ./$PROGRAM --status
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

ssh_value() {
  local host=$1 key=$2
  ssh -G "$host" 2>/dev/null | awk -v wanted="$key" '$1 == wanted { print $2; exit }'
}

validate_name() {
  [[ $1 =~ ^[A-Za-z0-9._#-]+$ ]] ||
    die "$2 must contain only letters, digits, dot, underscore, #, or hyphen"
}

validate_port() {
  [[ $1 =~ ^[0-9]+$ ]] || die "$2 must be an integer"
  (( 1 <= 10#$1 && 10#$1 <= 65535 )) || die "$2 must be between 1 and 65535"
}

expand_home() {
  case $1 in
    '~/'*) printf '%s/%s\n' "$HOME" "${1#~/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

TARGET=
NAME=
REMOTE_PORT=
JUMP_HOST=$DEFAULT_JUMP_HOST
TARGET_USER=
LOCAL_SSH_PORT=$DEFAULT_LOCAL_SSH_PORT
IDENTITY_FILE=
STATUS_ONLY=0

while (($#)); do
  case $1 in
    --target) [[ $# -ge 2 ]] || die "--target requires a value"; TARGET=$2; shift 2 ;;
    --name) [[ $# -ge 2 ]] || die "--name requires a value"; NAME=$2; shift 2 ;;
    --remote-port) [[ $# -ge 2 ]] || die "--remote-port requires a value"; REMOTE_PORT=$2; shift 2 ;;
    --jump-host) [[ $# -ge 2 ]] || die "--jump-host requires a value"; JUMP_HOST=$2; shift 2 ;;
    --target-user) [[ $# -ge 2 ]] || die "--target-user requires a value"; TARGET_USER=$2; shift 2 ;;
    --local-ssh-port) [[ $# -ge 2 ]] || die "--local-ssh-port requires a value"; LOCAL_SSH_PORT=$2; shift 2 ;;
    --identity-file) [[ $# -ge 2 ]] || die "--identity-file requires a value"; IDENTITY_FILE=$2; shift 2 ;;
    --status) STATUS_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require_command ssh
validate_name "$JUMP_HOST" "jump host"

SSH_BASE=(-o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=yes -o ConnectTimeout=10)

if ((STATUS_ONLY)); then
  info "Reverse tunnel registry on $JUMP_HOST"
  ssh -T "${SSH_BASE[@]}" "$JUMP_HOST" '~/.local/bin/reverse-tunnel-status'
  exit $?
fi

[[ -n $TARGET ]] || die "--target is required"
[[ -n $NAME ]] || die "--name is required"
validate_name "$NAME" "name"
validate_port "$LOCAL_SSH_PORT" "local SSH port"
if [[ -n $REMOTE_PORT ]]; then
  validate_port "$REMOTE_PORT" "remote port"
  (( 10#$REMOTE_PORT >= 1024 )) || die "remote port must be at least 1024"
fi

require_command awk
require_command base64
require_command ssh-keygen

if [[ -z $TARGET_USER ]]; then
  TARGET_USER=$(ssh_value "$TARGET" user)
fi
[[ -n $TARGET_USER ]] || die "could not determine target user; pass --target-user"
validate_name "$TARGET_USER" "target user"

if [[ -z $IDENTITY_FILE ]]; then
  IDENTITY_FILE=$(ssh_value "$TARGET" identityfile)
fi
[[ -n $IDENTITY_FILE ]] || die "could not determine identity file; pass --identity-file"
IDENTITY_FILE=$(expand_home "$IDENTITY_FILE")
[[ -f $IDENTITY_FILE ]] || die "identity file does not exist: $IDENTITY_FILE"

JUMP_HOSTNAME=$(ssh_value "$JUMP_HOST" hostname)
JUMP_USER=$(ssh_value "$JUMP_HOST" user)
JUMP_PORT=$(ssh_value "$JUMP_HOST" port)
[[ -n $JUMP_HOSTNAME && -n $JUMP_USER && -n $JUMP_PORT ]] ||
  die "could not resolve hostname, user, and port for $JUMP_HOST"
validate_port "$JUMP_PORT" "jump host port"

info "Checking SSH access"
ssh -T "${SSH_BASE[@]}" "$JUMP_HOST" 'command -v ss >/dev/null && command -v ssh-keygen >/dev/null && command -v base64 >/dev/null && command -v flock >/dev/null' ||
  die "jump host needs ss, ssh-keygen, base64, and flock"
ssh -T "${SSH_BASE[@]}" "$TARGET" 'command -v systemctl >/dev/null && command -v ssh >/dev/null && command -v ssh-keygen >/dev/null && sudo -n true' ||
  die "target needs systemd, OpenSSH, ssh-keygen, and passwordless sudo"

info "Reading trusted VPS host keys over the existing SSH connection"
VPS_HOST_KEYS=$(ssh -T "${SSH_BASE[@]}" "$JUMP_HOST" \
  'for key in /etc/ssh/ssh_host_*_key.pub; do [ -r "$key" ] && cat "$key"; done')
[[ -n $VPS_HOST_KEYS ]] || die "could not read VPS public host keys"

KNOWN_HOST_LABEL=$JUMP_HOSTNAME
if [[ $JUMP_PORT != 22 ]]; then
  KNOWN_HOST_LABEL="[$JUMP_HOSTNAME]:$JUMP_PORT"
fi
KNOWN_HOSTS_CONTENT=$(awk -v label="$KNOWN_HOST_LABEL" 'NF >= 2 { print label, $1, $2 }' <<<"$VPS_HOST_KEYS")
KNOWN_HOSTS_B64=$(printf '%s\n' "$KNOWN_HOSTS_CONTENT" | base64 | tr -d '\n')

info "Preparing the dedicated tunnel key on $TARGET"
TARGET_OUTPUT=$(ssh -T "${SSH_BASE[@]}" "$TARGET" sudo -n bash -s -- "$KNOWN_HOSTS_B64" <<'TARGET_PREPARE'
set -Eeuo pipefail
install -d -m 0700 -o root -g root /etc/ssh/reverse-tunnel
if [[ ! -f /etc/ssh/reverse-tunnel/id_ed25519 ]]; then
  ssh-keygen -q -t ed25519 -N '' -C reverse-ssh-tunnel -f /etc/ssh/reverse-tunnel/id_ed25519
fi
printf '%s' "$1" | base64 -d > /etc/ssh/reverse-tunnel/known_hosts.new
chmod 0600 /etc/ssh/reverse-tunnel/known_hosts.new
if [[ ! -f /etc/ssh/reverse-tunnel/known_hosts ]] ||
   ! cmp -s /etc/ssh/reverse-tunnel/known_hosts.new /etc/ssh/reverse-tunnel/known_hosts; then
  if [[ -f /etc/ssh/reverse-tunnel/known_hosts ]]; then
    cp -p /etc/ssh/reverse-tunnel/known_hosts "/etc/ssh/reverse-tunnel/known_hosts.backup-$(date +%Y%m%d-%H%M%S)"
  fi
  mv /etc/ssh/reverse-tunnel/known_hosts.new /etc/ssh/reverse-tunnel/known_hosts
else
  rm -f /etc/ssh/reverse-tunnel/known_hosts.new
fi
printf 'TUNNEL_KEY\t'
cat /etc/ssh/reverse-tunnel/id_ed25519.pub
for key in /etc/ssh/ssh_host_*_key.pub; do
  [[ -r $key ]] || continue
  printf 'TARGET_HOST_KEY\t'
  cat "$key"
done
TARGET_PREPARE
)
TUNNEL_PUBLIC_KEY=$(awk -F '\t' '$1 == "TUNNEL_KEY" { print $2; exit }' <<<"$TARGET_OUTPUT")
TARGET_HOST_KEYS=$(awk -F '\t' '$1 == "TARGET_HOST_KEY" { print $2 }' <<<"$TARGET_OUTPUT")
[[ -n $TUNNEL_PUBLIC_KEY ]] || die "target did not return a tunnel public key"
[[ -n $TARGET_HOST_KEYS ]] || die "target did not return SSH host keys"
TUNNEL_PUBLIC_KEY_B64=$(printf '%s\n' "$TUNNEL_PUBLIC_KEY" | base64 | tr -d '\n')

REQUESTED_PORT=${REMOTE_PORT:-auto}
info "Registering $NAME on $JUMP_HOST (port: $REQUESTED_PORT)"
VPS_OUTPUT=$(ssh -T "${SSH_BASE[@]}" "$JUMP_HOST" bash -s -- \
  "$NAME" "$REQUESTED_PORT" "$TARGET_USER" "$TUNNEL_PUBLIC_KEY_B64" "$PORT_POOL_START" "$PORT_POOL_END" <<'VPS_REGISTER'
set -Eeuo pipefail
name=$1
requested_port=$2
target_user=$3
public_key=$(printf '%s' "$4" | base64 -d)
pool_start=$5
pool_end=$6
bin_dir=$HOME/.local/bin
state_dir=$HOME/.local/state/reverse-tunnels
registry_dir=$state_dir/registry
online_dir=$state_dir/online
pool_config=$HOME/.config/reverse-tunnels/port-pool.conf
if [[ -f $pool_config ]]; then
  configured_start=$(awk -F= '$1 == "PORT_POOL_START" { print $2; exit }' "$pool_config")
  configured_end=$(awk -F= '$1 == "PORT_POOL_END" { print $2; exit }' "$pool_config")
  if [[ $configured_start =~ ^[0-9]+$ && $configured_end =~ ^[0-9]+$ && configured_start -le configured_end ]]; then
    pool_start=$configured_start
    pool_end=$configured_end
  else
    printf 'invalid port pool config: %s\n' "$pool_config" >&2
    exit 1
  fi
fi
mkdir -p "$bin_dir" "$registry_dir" "$online_dir" "$HOME/.ssh"
chmod 0700 "$HOME/.ssh" "$state_dir" "$registry_dir" "$online_dir"

exec 9>"$state_dir/registry.lock"
flock -x 9

existing_registered_port=
for record in "$registry_dir"/*.tsv; do
  [[ -e $record ]] || continue
  IFS=$'\t' read -r existing_name existing_port rest < "$record"
  [[ $existing_name == "$name" ]] && existing_registered_port=$existing_port
done

port_owner() {
  local candidate=$1 record owner record_port rest
  for record in "$registry_dir"/*.tsv; do
    [[ -e $record ]] || continue
    IFS=$'\t' read -r owner record_port rest < "$record"
    if [[ $record_port == "$candidate" ]]; then
      printf '%s\n' "$owner"
      return
    fi
  done
}

if [[ $requested_port == auto ]]; then
  if [[ -n $existing_registered_port ]]; then
    port=$existing_registered_port
  else
    port=
    for ((candidate=pool_start; candidate<=pool_end; candidate++)); do
      [[ -z $(port_owner "$candidate") ]] || continue
      ss -H -ltn "sport = :$candidate" 2>/dev/null | grep -q . && continue
      port=$candidate
      break
    done
    [[ -n $port ]] || {
      printf 'no free port remains in %s-%s\n' "$pool_start" "$pool_end" >&2
      exit 1
    }
  fi
else
  port=$requested_port
  owner=$(port_owner "$port")
  [[ -z $owner || $owner == "$name" ]] || {
    printf 'port %s is already registered to %s\n' "$port" "$owner" >&2
    exit 1
  }
  if ((port < pool_start || port > pool_end)) && [[ $existing_registered_port != "$port" ]]; then
    printf 'new explicit ports must be in %s-%s\n' "$pool_start" "$pool_end" >&2
    exit 1
  fi
fi

owner=$(port_owner "$port")
if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then
  [[ $owner == "$name" ]] || {
    printf 'port %s already has an unmanaged listener on this VPS\n' "$port" >&2
    exit 1
  }
fi

backup_if_changed() {
  local source=$1 replacement=$2
  if [[ -f $source ]] && ! cmp -s "$source" "$replacement"; then
    cp -p "$source" "$source.backup-$(date +%Y%m%d-%H%M%S)"
  fi
}

cat > "$bin_dir/reverse-tunnel-session.new" <<'SESSION_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
name=$1
port=$2
online_dir=$HOME/.local/state/reverse-tunnels/online
mkdir -p "$online_dir"
state_file=$online_dir/$name.tsv
connected_at=$(date +%s)
remote_ip=${SSH_CONNECTION%% *}
printf '%s\t%s\t%s\t%s\n' "$connected_at" "$$" "$remote_ip" "$port" > "$state_file.tmp.$$"
mv "$state_file.tmp.$$" "$state_file"
cleanup() {
  if [[ -f $state_file ]]; then
    state_pid=$(awk -F '\t' 'NR == 1 { print $2 }' "$state_file")
    [[ $state_pid == $$ ]] && rm -f "$state_file"
  fi
}
trap cleanup EXIT HUP INT TERM
while :; do sleep 3600 & wait $!; done
SESSION_SCRIPT
chmod 0755 "$bin_dir/reverse-tunnel-session.new"
backup_if_changed "$bin_dir/reverse-tunnel-session" "$bin_dir/reverse-tunnel-session.new"
mv "$bin_dir/reverse-tunnel-session.new" "$bin_dir/reverse-tunnel-session"

cat > "$bin_dir/reverse-tunnel-status.new" <<'STATUS_SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
base=$HOME/.local/state/reverse-tunnels
registry_dir=$base/registry
online_dir=$base/online

duration() {
  local seconds=$1 days hours minutes
  days=$((seconds / 86400))
  hours=$(((seconds % 86400) / 3600))
  minutes=$(((seconds % 3600) / 60))
  if ((days)); then printf '%dd %02dh %02dm' "$days" "$hours" "$minutes"
  elif ((hours)); then printf '%dh %02dm' "$hours" "$minutes"
  else printf '%dm' "$minutes"
  fi
}

printf '%-30s %-7s %-8s %-20s %-12s %s\n' HOST PORT STATUS ONLINE-SINCE DURATION TARGET-USER
found=0
for record in "$registry_dir"/*.tsv; do
  [[ -e $record ]] || continue
  found=1
  IFS=$'\t' read -r name port target_user registered_at fingerprint mode < "$record"
  status=OFFLINE
  since=-
  elapsed=-
  state=$online_dir/$name.tsv
  listening=0
  if ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then listening=1; fi
  if ((listening)) && [[ -f $state ]]; then
    IFS=$'\t' read -r connected_at session_pid remote_ip state_port < "$state"
    if [[ $state_port == "$port" && $connected_at =~ ^[0-9]+$ ]]; then
      status=ONLINE
      since=$(date -d "@$connected_at" '+%F %T' 2>/dev/null || date -r "$connected_at" '+%F %T')
      elapsed=$(duration "$(($(date +%s) - connected_at))")
    fi
  elif ((listening)) && [[ $mode == legacy ]]; then
    status=ONLINE
    socket_line=$(sudo -n ss -H -ltnp "sport = :$port" 2>/dev/null | head -n 1 || true)
    socket_pid=$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' <<<"$socket_line")
    if [[ -n $socket_pid ]]; then
      process_age=$(sudo -n ps -o etimes= -p "$socket_pid" 2>/dev/null | awk 'NR == 1 { print $1 }')
      if [[ $process_age =~ ^[0-9]+$ ]]; then
        connected_at=$(($(date +%s) - process_age))
        since=$(date -d "@$connected_at" '+%F %T' 2>/dev/null || date -r "$connected_at" '+%F %T')
        elapsed=$(duration "$process_age")
      fi
    fi
  fi
  printf '%-30s %-7s %-8s %-20s %-12s %s\n' "$name" "$port" "$status" "$since" "$elapsed" "$target_user"
done
((found)) || printf '%s\n' '(no registered hosts)'
STATUS_SCRIPT
chmod 0755 "$bin_dir/reverse-tunnel-status.new"
backup_if_changed "$bin_dir/reverse-tunnel-status" "$bin_dir/reverse-tunnel-status.new"
mv "$bin_dir/reverse-tunnel-status.new" "$bin_dir/reverse-tunnel-status"

fingerprint_file=$(mktemp "$state_dir/.fingerprint-key.XXXXXX")
trap 'rm -f "$fingerprint_file"' EXIT
printf '%s\n' "$public_key" > "$fingerprint_file"
fingerprint=$(ssh-keygen -lf "$fingerprint_file" | awk '{print $2}')
rm -f "$fingerprint_file"
trap - EXIT
registered_at=$(date +%s)
if [[ -f $registry_dir/$name.tsv ]]; then
  IFS=$'\t' read -r _ _ _ old_registered_at _ < "$registry_dir/$name.tsv"
  [[ $old_registered_at =~ ^[0-9]+$ ]] && registered_at=$old_registered_at
fi
printf '%s\t%s\t%s\t%s\t%s\tmanaged\n' "$name" "$port" "$target_user" "$registered_at" "$fingerprint" > "$registry_dir/$name.tsv.new"
backup_if_changed "$registry_dir/$name.tsv" "$registry_dir/$name.tsv.new"
mv "$registry_dir/$name.tsv.new" "$registry_dir/$name.tsv"

authorized_keys=$HOME/.ssh/authorized_keys
touch "$authorized_keys"
chmod 0600 "$authorized_keys"
marker="reverse-tunnel:$name"
awk -v marker="$marker" 'index($0, marker) == 0' "$authorized_keys" > "$authorized_keys.new"
session_command=$bin_dir/reverse-tunnel-session
printf 'restrict,port-forwarding,permitlisten="127.0.0.1:%s",command="%s %s %s" %s %s\n' \
  "$port" "$session_command" "$name" "$port" "$public_key" "$marker" >> "$authorized_keys.new"
backup_if_changed "$authorized_keys" "$authorized_keys.new"
mv "$authorized_keys.new" "$authorized_keys"
chmod 0600 "$authorized_keys"
printf 'ASSIGNED_PORT\t%s\n' "$port"
VPS_REGISTER
)
ASSIGNED_PORT=$(awk -F '\t' '$1 == "ASSIGNED_PORT" { print $2; exit }' <<<"$VPS_OUTPUT")
[[ $ASSIGNED_PORT =~ ^[0-9]+$ ]] || die "VPS did not return an assigned port"
REMOTE_PORT=$ASSIGNED_PORT
info "Assigned VPS port: $REMOTE_PORT"

info "Installing and starting the systemd tunnel service on $TARGET"
ssh -T "${SSH_BASE[@]}" "$TARGET" sudo -n bash -s -- \
  "$NAME" "$REMOTE_PORT" "$LOCAL_SSH_PORT" "$JUMP_USER" "$JUMP_HOSTNAME" "$JUMP_PORT" <<'TARGET_INSTALL'
set -Eeuo pipefail
name=$1
remote_port=$2
local_ssh_port=$3
jump_user=$4
jump_hostname=$5
jump_port=$6
unit=/etc/systemd/system/reverse-ssh-tunnel.service
cat > "$unit.new" <<EOF
[Unit]
Description=Reverse SSH tunnel for $name
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/bin/ssh -T -i /etc/ssh/reverse-tunnel/id_ed25519 -o IdentitiesOnly=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/reverse-tunnel/known_hosts -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -p $jump_port -R 127.0.0.1:$remote_port:127.0.0.1:$local_ssh_port $jump_user@$jump_hostname
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
chmod 0644 "$unit.new"
if [[ -f $unit ]] && ! cmp -s "$unit" "$unit.new"; then
  cp -p "$unit" "$unit.backup-$(date +%Y%m%d-%H%M%S)"
fi
mv "$unit.new" "$unit"
systemctl daemon-reload
systemctl enable --now reverse-ssh-tunnel.service
systemctl restart reverse-ssh-tunnel.service
TARGET_INSTALL

info "Updating the controller SSH configuration"
SSH_DIR=$HOME/.ssh
CONFIG_DIR=$SSH_DIR/config.d
TUNNEL_CONFIG=$CONFIG_DIR/reverse-tunnels
TUNNEL_KNOWN_HOSTS=$SSH_DIR/known_hosts.reverse-tunnels
MAIN_CONFIG=$SSH_DIR/config
mkdir -p "$CONFIG_DIR"
chmod 0700 "$SSH_DIR" "$CONFIG_DIR"
touch "$MAIN_CONFIG" "$TUNNEL_CONFIG" "$TUNNEL_KNOWN_HOSTS"
chmod 0600 "$MAIN_CONFIG" "$TUNNEL_CONFIG" "$TUNNEL_KNOWN_HOSTS"
STAMP=$(date +%Y%m%d-%H%M%S)

INCLUDE_LINE='Include ~/.ssh/config.d/reverse-tunnels'
if ! grep -Fqx "$INCLUDE_LINE" "$MAIN_CONFIG"; then
  cp -p "$MAIN_CONFIG" "$MAIN_CONFIG.backup-$STAMP"
  awk -v include="$INCLUDE_LINE" '
    !inserted && /^[[:space:]]*Host[[:space:]]/ { print include; print ""; inserted=1 }
    { print }
    END { if (!inserted) { print ""; print include } }
  ' "$MAIN_CONFIG" > "$MAIN_CONFIG.new"
  mv "$MAIN_CONFIG.new" "$MAIN_CONFIG"
  chmod 0600 "$MAIN_CONFIG"
fi

BEGIN_MARKER="# BEGIN reverse-tunnel:$NAME"
END_MARKER="# END reverse-tunnel:$NAME"
KNOWN_HOST_LABEL="[127.0.0.1]:$REMOTE_PORT"
awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
  $0 == begin { skipping=1; next }
  skipping && $0 == end { skipping=0; next }
  !skipping { print }
' "$TUNNEL_CONFIG" > "$TUNNEL_CONFIG.new"
{
  cat "$TUNNEL_CONFIG.new"
  cat <<EOF
$BEGIN_MARKER
Host $NAME
    HostName 127.0.0.1
    User $TARGET_USER
    Port $REMOTE_PORT
    ProxyJump $JUMP_HOST
    IdentityFile $IDENTITY_FILE
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    UserKnownHostsFile $TUNNEL_KNOWN_HOSTS
$END_MARKER
EOF
} > "$TUNNEL_CONFIG.next"
if ! cmp -s "$TUNNEL_CONFIG" "$TUNNEL_CONFIG.next"; then
  [[ ! -s $TUNNEL_CONFIG ]] || cp -p "$TUNNEL_CONFIG" "$TUNNEL_CONFIG.backup-$STAMP"
  mv "$TUNNEL_CONFIG.next" "$TUNNEL_CONFIG"
else
  rm -f "$TUNNEL_CONFIG.next"
fi
rm -f "$TUNNEL_CONFIG.new"
chmod 0600 "$TUNNEL_CONFIG"

awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
  $0 == begin { skipping=1; next }
  skipping && $0 == end { skipping=0; next }
  !skipping { print }
' "$TUNNEL_KNOWN_HOSTS" > "$TUNNEL_KNOWN_HOSTS.new"
{
  cat "$TUNNEL_KNOWN_HOSTS.new"
  printf '%s\n' "$BEGIN_MARKER"
  awk -v label="$KNOWN_HOST_LABEL" 'NF >= 2 { print label, $1, $2 }' <<<"$TARGET_HOST_KEYS"
  printf '%s\n' "$END_MARKER"
} > "$TUNNEL_KNOWN_HOSTS.next"
if ! cmp -s "$TUNNEL_KNOWN_HOSTS" "$TUNNEL_KNOWN_HOSTS.next"; then
  [[ ! -s $TUNNEL_KNOWN_HOSTS ]] || cp -p "$TUNNEL_KNOWN_HOSTS" "$TUNNEL_KNOWN_HOSTS.backup-$STAMP"
  mv "$TUNNEL_KNOWN_HOSTS.next" "$TUNNEL_KNOWN_HOSTS"
else
  rm -f "$TUNNEL_KNOWN_HOSTS.next"
fi
rm -f "$TUNNEL_KNOWN_HOSTS.new"
chmod 0600 "$TUNNEL_KNOWN_HOSTS"

info "Waiting for the reverse listener"
for attempt in {1..10}; do
  if ssh -T "${SSH_BASE[@]}" "$JUMP_HOST" "ss -H -ltn 'sport = :$REMOTE_PORT' | grep -q ."; then
    break
  fi
  ((attempt < 10)) || die "tunnel did not become online; inspect: ssh $TARGET sudo systemctl status reverse-ssh-tunnel"
  sleep 2
done

if ssh -T "${SSH_BASE[@]}" "$JUMP_HOST" \
  "ss -H -ltn 'sport = :$REMOTE_PORT' | awk '\$4 ~ /^0\\.0\\.0\\.0:/ || \$4 ~ /^\\[::\\]:/' | grep -q ."; then
  warn "VPS sshd exposed port $REMOTE_PORT on wildcard addresses despite the requested 127.0.0.1 bind"
  warn "review GatewayPorts on $JUMP_HOST; the tunnel is currently reachable outside ProxyJump unless blocked by a firewall"
fi

ssh -G "$NAME" >/dev/null 2>&1 || die "generated SSH alias is invalid"
info "Registration complete. Connect with: ssh $NAME"
printf '\n'
ssh -T "${SSH_BASE[@]}" "$JUMP_HOST" '~/.local/bin/reverse-tunnel-status'
