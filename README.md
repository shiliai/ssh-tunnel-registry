# SSH Tunnel Registration

`register-ssh-tunnel.sh` registers a Linux host behind NAT as a persistent
reverse SSH tunnel through `feishu-APP-Pvjp-000`.

The script runs on the controller (the machine that already has SSH aliases for
the new host and the VPS). It performs four operations:

1. Generates a dedicated tunnel key on the new Linux host.
2. Registers a restricted key and host metadata on the VPS.
3. Installs a persistent systemd service on the new host.
4. Adds a `ProxyJump` alias to the controller's SSH config.

The tunnel requests a `127.0.0.1` listener and restricts its key to that request.
The installer verifies the resulting socket and warns if the VPS has an sshd
`GatewayPorts` policy that overrides it with a wildcard/public listener.

## Register a host

Prerequisites:

- The controller can already run `ssh <target>` and
  `ssh feishu-APP-Pvjp-000` with key authentication.
- The target is Linux with systemd and OpenSSH.
- The target login can run non-interactive `sudo` (`sudo -n true`).
- New registrations use the managed `20000-20999` port pool.

The VPS allocates the lowest free port atomically while holding a registry lock.
It skips registered ports and real listeners, so parallel registrations cannot
claim the same port. Use `--remote-port` only when a specific pool port is
required; existing names outside the pool retain their legacy port.

```bash
./register-ssh-tunnel.sh \
  --target 'HQ-310p-#1' \
  --name 'HQ-310p-#1-via-vps'
```

After registration:

```bash
ssh 'HQ-310p-#1-via-vps'
```

Run `./register-ssh-tunnel.sh --help` for optional arguments such as a custom
jump host, local SSH port, target user, or identity file.

## View registered and online hosts

Install or update the status tooling without registering a host:

```bash
./install-vps.sh feishu-APP-Pvjp-000
```

From the controller:

```bash
./register-ssh-tunnel.sh --status
```

Or directly on `feishu-APP-Pvjp-000`:

```bash
~/.local/bin/reverse-tunnel-status
```

Example output:

```text
HOST                           PORT    STATUS   ONLINE-SINCE         DURATION     TARGET-USER
HQ-310p-#1-via-vps            5555    ONLINE   2026-08-20 14:31:08  2h 17m       root
lab-node-via-vps               5556    OFFLINE  -                    -            ubuntu
```

`ONLINE` requires both an active registration session and an actual listening
socket on the assigned VPS port. `ONLINE-SINCE` and `DURATION` refer to the
current uninterrupted tunnel connection.

Existing tunnels can be entered as `legacy` registry records. For those,
online state comes from the listening socket and duration is calculated from
the owning sshd process when passwordless read-only sudo is available.

## Files installed

On each target:

- `/etc/ssh/reverse-tunnel/id_ed25519`
- `/etc/ssh/reverse-tunnel/known_hosts`
- `/etc/systemd/system/reverse-ssh-tunnel.service`

On the VPS, under the jump user's home directory:

- `~/.local/bin/reverse-tunnel-session`
- `~/.local/bin/reverse-tunnel-status`
- `~/.local/state/reverse-tunnels/registry/`
- `~/.local/state/reverse-tunnels/online/`
- `~/.config/reverse-tunnels/port-pool.conf`
- A restricted entry in `~/.ssh/authorized_keys`

On the controller:

- `~/.ssh/config.d/reverse-tunnels`
- `~/.ssh/known_hosts.reverse-tunnels`
- One `Include ~/.ssh/config.d/reverse-tunnels` line in `~/.ssh/config`

Changed files are backed up with a `.backup-YYYYMMDD-HHMMSS` suffix.
Both VPS and target host keys are copied over existing trusted SSH connections;
the generated tunnel never disables host-key checking.

## Troubleshooting

```bash
ssh '<target>' sudo systemctl status reverse-ssh-tunnel --no-pager
ssh '<target>' sudo journalctl -u reverse-ssh-tunnel -n 100 --no-pager
ssh feishu-APP-Pvjp-000 '~/.local/bin/reverse-tunnel-status'
```

The service uses SSH keepalives and systemd restart policy, so it reconnects
automatically after network interruption or reboot.

### SELinux Enforcing hosts (RHEL-family / openEuler)

On hosts with **SELinux enforcing**, the tunnel service (run by systemd in the
`init_t` domain) fails immediately with `status=203/EXEC`, e.g.:

```
Process: 12345 ExecStart=/usr/bin/ssh ... (code=exited, status=203/EXEC)
journalctl: reverse-ssh-tunnel.service: Failed with result 'exit-code'
```

Cause: `init_t` is denied several operations by SELinux. Confirm with
`ausearch -m AVC -ts recent` or the raw AVCs in `/var/log/audit/audit.log`
(`avc:  denied  { ... } ... scontext=...:init_t:s0 ...`). The denials that block
the tunnel are:

1. Executing `/usr/bin/ssh` (`ssh_exec_t`) — needs `execute open read
   execute_no_trans map` on the file.
2. Connecting out to the jump host port (`unreserved_port_t`) — needs
   `name_connect`.
3. **Reverse forward loopback** — needs `name_connect` to `ssh_port_t`.
   Without this, the VPS shows the listener `127.0.0.1:PORT` and the session is
   ONLINE, but clients connecting to it get `connection reset` /
   `kex_exchange_identification: Connection closed` because the target's ssh
   (root, `init_t`) cannot connect back to its own `127.0.0.1:22`.

Fix by installing a minimal local policy module (on the target, as root):

```bash
cat > /tmp/reverse-ssh-tunnel.te <<'EOF'
module reverse-ssh-tunnel 1.0;

require {
  type init_t;
  type ssh_exec_t;
  type unreserved_port_t;
  type ssh_port_t;
  class file { execute open read execute_no_trans map };
  class tcp_socket name_connect;
}

allow init_t ssh_exec_t:file { execute open read execute_no_trans map };
allow init_t unreserved_port_t:tcp_socket name_connect;
allow init_t ssh_port_t:tcp_socket name_connect;
EOF
cd /tmp && checkmodule -M -m -o reverse-ssh-tunnel.mod reverse-ssh-tunnel.te \
  && semodule_package -o reverse-ssh-tunnel.pp -m reverse-ssh-tunnel.mod \
  && semodule -i reverse-ssh-tunnel.pp && systemctl restart reverse-ssh-tunnel
```

(`checkmodule`/`semodule_package` come from `checkpolicy` and
`policycoreutils-python-utils`. If a previous settings left the service in a
half-tunneled state, `systemctl restart reverse-ssh-tunnel` after loading the
module. Removing it later: `semodule -r reverse-ssh-tunnel`.)
