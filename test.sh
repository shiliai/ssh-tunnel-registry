#!/usr/bin/env bash

set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT=$ROOT/register-ssh-tunnel.sh
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

extract_heredoc() {
  local marker=$1 output=$2
  awk -v marker="$marker" '
    index($0, "<<\047" marker "\047") { inside=1; next }
    inside && $0 == marker { exit }
    inside { print }
  ' "$SCRIPT" > "$output"
  [[ -s $output ]]
}

bash -n "$SCRIPT"
for marker in TARGET_PREPARE VPS_REGISTER SESSION_SCRIPT STATUS_SCRIPT TARGET_INSTALL; do
  extract_heredoc "$marker" "$TMP_DIR/$marker.sh"
  bash -n "$TMP_DIR/$marker.sh"
done
cmp "$TMP_DIR/STATUS_SCRIPT.sh" "$ROOT/vps/reverse-tunnel-status"
bash -n "$ROOT/install-vps.sh" "$ROOT/vps/reverse-tunnel-session" "$ROOT/vps/reverse-tunnel-status"
session_help=$(bash "$ROOT/vps/reverse-tunnel-session" help)
grep -Fq 'health HOST' <<<"$session_help"
grep -Fq 'reset HOST' <<<"$session_help"
grep -Fq 'serve HOST PORT' <<<"$session_help"

RESET_HOME=$TMP_DIR/reset-home
RESET_BIN=$TMP_DIR/reset-bin
RESET_MARKER=$TMP_DIR/reset-requested
mkdir -p "$RESET_HOME/.local/state/reverse-tunnels/registry" \
  "$RESET_HOME/.local/state/reverse-tunnels/online" "$RESET_BIN"
printf 'stale-host\t20010\tuser\t1\tfingerprint\tmanaged\n' > \
  "$RESET_HOME/.local/state/reverse-tunnels/registry/stale-host.tsv"
printf '1\t99999999\t192.0.2.1\t20010\n' > \
  "$RESET_HOME/.local/state/reverse-tunnels/online/stale-host.tsv"
cat > "$RESET_BIN/ss" <<'EOF'
#!/usr/bin/env bash
if [[ $* == *-ltnp* ]]; then
  if [[ -f $RESET_MARKER ]]; then pid=424243; else pid=424242; fi
  printf 'LISTEN 0 128 127.0.0.1:20010 0.0.0.0:* users:(("sshd",pid=%s,fd=7))\n' "$pid"
else
  printf 'LISTEN 0 128 127.0.0.1:20010 0.0.0.0:*\n'
fi
EOF
cat > "$RESET_BIN/ps" <<'EOF'
#!/usr/bin/env bash
[[ $* == *comm=* ]] && printf 'sshd\n'
exit 0
EOF
cat > "$RESET_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -n ]] && shift
if [[ $1 == kill ]]; then
  : > "$RESET_MARKER"
  exit 0
fi
exec "$@"
EOF
cat > "$RESET_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'SSH-2.0-test-server'
EOF
chmod +x "$RESET_BIN/ss" "$RESET_BIN/ps" "$RESET_BIN/sudo" "$RESET_BIN/timeout"
reset_output=$(HOME="$RESET_HOME" PATH="$RESET_BIN:$PATH" RESET_MARKER="$RESET_MARKER" \
  REVERSE_TUNNEL_RESET_WAIT_SECONDS=2 bash "$ROOT/vps/reverse-tunnel-session" reset stale-host)
grep -Fq 'State PID 99999999 is stale' <<<"$reset_output"
grep -Fq 'stale-host reconnected successfully: SSH-2.0-test-server' <<<"$reset_output"
[[ -f $RESET_MARKER ]]
grep -Fqx 'PORT_POOL_START=20000' "$ROOT/vps/port-pool.conf"
grep -Fqx 'PORT_POOL_END=20999' "$ROOT/vps/port-pool.conf"

ALLOCATOR_HOME=$TMP_DIR/allocator-home
ALLOCATOR_BIN=$TMP_DIR/allocator-bin
mkdir -p "$ALLOCATOR_HOME" "$ALLOCATOR_BIN"
cat > "$ALLOCATOR_BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$ALLOCATOR_BIN/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ALLOCATOR_BIN/ss" "$ALLOCATOR_BIN/flock"
ssh-keygen -q -t ed25519 -N '' -f "$TMP_DIR/allocator-key"
allocator_key_b64=$(base64 < "$TMP_DIR/allocator-key.pub" | tr -d '\n')
session_script_b64=$(base64 < "$ROOT/vps/reverse-tunnel-session" | tr -d '\n')
allocator_one=$(HOME="$ALLOCATOR_HOME" PATH="$ALLOCATOR_BIN:$PATH" \
  bash "$TMP_DIR/VPS_REGISTER.sh" host-one auto user-one "$allocator_key_b64" 20000 20002 "$session_script_b64")
allocator_two=$(HOME="$ALLOCATOR_HOME" PATH="$ALLOCATOR_BIN:$PATH" \
  bash "$TMP_DIR/VPS_REGISTER.sh" host-two auto user-two "$allocator_key_b64" 20000 20002 "$session_script_b64")
grep -Fq $'ASSIGNED_PORT\t20000' <<<"$allocator_one"
grep -Fq $'ASSIGNED_PORT\t20001' <<<"$allocator_two"
set +e
allocator_outside=$(HOME="$ALLOCATOR_HOME" PATH="$ALLOCATOR_BIN:$PATH" \
  bash "$TMP_DIR/VPS_REGISTER.sh" host-three 21000 user-three "$allocator_key_b64" 20000 20002 "$session_script_b64" 2>&1)
allocator_outside_status=$?
set -e
[[ $allocator_outside_status -ne 0 ]]
grep -Fq 'new explicit ports must be in 20000-20002' <<<"$allocator_outside"

STATUS_HOME=$TMP_DIR/status-home
MOCK_BIN=$TMP_DIR/mock-bin
mkdir -p "$STATUS_HOME/.local/state/reverse-tunnels/registry" \
  "$STATUS_HOME/.local/state/reverse-tunnels/online" "$MOCK_BIN"
cat > "$MOCK_BIN/ss" <<'EOF'
#!/usr/bin/env bash
[[ $* == *':5555'* ]] && printf 'LISTEN 0 128 127.0.0.1:5555 0.0.0.0:*\n'
[[ $* == *':5557'* ]] && printf 'LISTEN 0 128 127.0.0.1:5557 0.0.0.0:* users:(("sshd",pid=9876,fd=7))\n'
exit 0
EOF
cat > "$MOCK_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
[[ $1 == -n ]] && shift
exec "$@"
EOF
cat > "$MOCK_BIN/ps" <<'EOF'
#!/usr/bin/env bash
printf ' 90061\n'
EOF
chmod +x "$MOCK_BIN/ss"
chmod +x "$MOCK_BIN/sudo" "$MOCK_BIN/ps"
now=$(date +%s)
printf 'online-host\t5555\troot\t%s\tSHA256:test\n' "$((now - 7200))" > \
  "$STATUS_HOME/.local/state/reverse-tunnels/registry/online-host.tsv"
printf 'offline-host\t5556\tubuntu\t%s\tSHA256:test\n' "$((now - 7200))" > \
  "$STATUS_HOME/.local/state/reverse-tunnels/registry/offline-host.tsv"
printf 'legacy-host\t5557\tlegacy-user\t%s\tlegacy\tlegacy\n' "$((now - 7200))" > \
  "$STATUS_HOME/.local/state/reverse-tunnels/registry/legacy-host.tsv"
printf '%s\t1234\t192.0.2.1\t5555\n' "$((now - 3660))" > \
  "$STATUS_HOME/.local/state/reverse-tunnels/online/online-host.tsv"
status_output=$(HOME="$STATUS_HOME" PATH="$MOCK_BIN:$PATH" bash "$TMP_DIR/STATUS_SCRIPT.sh")
grep -Eq 'online-host +5555 +ONLINE .+1h 01m +root' <<<"$status_output"
grep -Eq 'offline-host +5556 +OFFLINE +- +- +ubuntu' <<<"$status_output"
grep -Eq 'legacy-host +5557 +ONLINE .+1d 01h 01m +legacy-user' <<<"$status_output"

help_output=$("$SCRIPT" --help)
grep -Fq -- '--status' <<<"$help_output"
grep -Fq -- '--remote-port PORT' <<<"$help_output"

set +e
invalid_output=$("$SCRIPT" --target host --name 'bad name' --remote-port 5555 2>&1)
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]
grep -Fq 'name must contain only' <<<"$invalid_output"

set +e
port_output=$("$SCRIPT" --target host --name valid --remote-port 22 2>&1)
port_status=$?
set -e
[[ $port_status -ne 0 ]]
grep -Fq 'remote port must be at least 1024' <<<"$port_output"

printf 'All local tests passed.\n'
