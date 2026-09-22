# WSS Relay — 经 Tokyo VPS 的 frp/WSS 通道（反向 SSH 端口池）

`register-ssh-tunnel.sh`（裸 ssh 反向隧道）在站点出口对"新建 TCP 长连接"做 DPI
杀伤的环境下不可用。本模块用 **frp over WebSocket-Secure(443, 域名 SNI)** 作为传输，
实测为现场出口唯一长期存活的形态（2026-09-22 全天验证）。

## 背景：站点出口行为（2026-09-22 实测结论）

| 现象 | 结论 |
| --- | --- |
| 同网关下不同主机命运不同（#1/jetson/ROS 通，#2 被杀） | DPI **按源主机**区别对待，非按出口 IP |
| 裸 TCP / 微量数据(<KB) 可过，KB 级持续传输 ~1s 内 RST | 按**流量大小/持续时间**杀伤 |
| 老连接豁免（jetson 7 天隧道），新连接必死 | 存在 grandfathering |
| 某源被标记后**过夜部分消退**（短请求恢复、长流仍死） | 标记有 TTL，但不完全 |

应对：受影响主机的长连接一律走 frp/WSS 到 Tokyo（若该主机自身出口也被杀，
则经同交换机内**出口干净的主机做 LAN 中继**，见端口表 21002）。

## 架构

```
现场设备 frpc (wss) ──443/TLS──> nginx(ssh-relay.dsh.onlyservice.io, Tokyo)
                                     └─ /~!frp ─> frps 容器(dsh-remote-host-control 网络, IP 172.22.0.9)
                                                    └─ 2100x 监听 ─宿主 socat-relay@2100x─> 对外
Mac/控制端: ssh -p 2100x root@43.167.173.46  (别名见 ~/.ssh/config: relay-*)
```

- frps 与既有 dsh-remote frps **完全独立**（独立容器 `ssh-relay-frps`、独立 token），
  不触碰生产 dsh-remote 体系。
- Tokyo 上 docker 端口发布有静默失败问题（PortBindings 写入但无 docker-proxy），
  故用宿主机 `socat-relay@.service` 逐端口中继到容器固定 IP `172.22.0.9`。

## 端口分配（SG 已开放 21001–21009，新主机从池内取号）

| 端口 | 主机 | frpc 运行于 | 说明 |
| --- | --- | --- | --- |
| 21001 | #1 (10.18.8.34) | #1 本机 | `relay-310p1` |
| 21002 | #2 (10.18.8.26) | **#1**（LAN 中继 10.18.8.26:22） | `relay-310p2`，**主力**（不依赖 #2 自身出口） |
| 21003 | jetson (10.18.8.42) | jetson 本机 | `relay-jetson` |
| 21004 | ROS (10.18.8.43) | jetson（LAN 中继 10.18.8.43:22） | `relay-ros2` |
| 21005 | #2 (10.18.8.26) | #2 本机（直连） | `relay-310p2w`，等 #2 出口窗口 |

## 部署

### 1) Tokyo 服务端（一次性）

```bash
# frps 配置与 token
sudo mkdir -p /opt/ssh-relay
sudo sh -c 'umask 077; openssl rand -base64 32 > /opt/ssh-relay/token'
sudo cp /opt/ssh-relay/frps.toml.template /opt/ssh-relay/frps.toml   # 按需改 token 引用
sudo docker run -d --name ssh-relay-frps --restart unless-stopped \
  --network dsh-remote-host-control --ip 172.22.0.9 \
  -v /opt/ssh-relay/frps.toml:/etc/frp/frps.toml:ro \
  fatedier/frps:v0.71.0        # 注意：不要 -p 发布端口，发布有静默失败问题

# 逐端口 socat 中继 + 防火墙
sudo cp socat-relay@.service /etc/systemd/system/
sudo systemctl daemon-reload
for p in 21001 21002 21003; do sudo systemctl enable --now socat-relay@$p; sudo ufw allow $p/tcp; done

# nginx vhost: ssh-relay.dsh.onlyservice.io -> 容器 7000
#   见 ~/docker/nginx 仓库 commit cbf7818（泛域名证书已覆盖）
#   nginx.conf 为单文件 bind mount，改后需 docker restart nginx-sub2api
```

### 2) 设备端（每台）

```bash
# token 放入 /root/.ssh-relay-token (600)，然后：
sudo ./deploy-device.sh --name p1 --remote-port 21001
# LAN 中继模式（在本机 frpc 里代理同网段其它主机）：
sudo ./deploy-device.sh --name p1 --remote-port 21001 \
     --lan-relay 21002:10.18.8.26:22
```

产物：`/opt/ssh-relay/frpc{,.toml}` + `ssh-relay.service`（enable，Restart=always，
frpc 端 `loginFailExit=false` 出口抖动时自愈重连）。

### 3) 控制端（Mac）

~/.ssh/config 别名（HostName 43.167.173.46，UserKnownHostsFile ~/.ssh/known_hosts.ssh-relay），
host key 用 `ssh-keyscan -p <port> -t ed25519 43.167.173.46` 采集；
LAN 中继端口（如 21002→21005 同主机）可直接复制 known_hosts 条目改端口。

## SNI 网关（模型/API 端点中继，配在 ROS 10.18.8.43）

出口被标记的主机（#2）访问 443 端点的**大请求体**（dsh 携带完整上下文的模型调用，
数十 KB）会被秒杀。方案：`/etc/hosts` 把域名指到同交换机的干净主机，由其 nginx
stream 按 SNI 透传（TLS 端到端不变）：

```bash
sudo apt install nginx libnginx-mod-stream
sudo cp sni-gateway.snippet.conf 的内容追加到 /etc/nginx/nginx.conf   # 顶层 stream{} 块
sudo nginx -t && sudo systemctl enable --now nginx
# 被救主机上：
echo "10.18.8.43    coding.onlyservice.io code.spottyx.xyz" >> /etc/hosts
```

非 443 端口（如 53288）不需要 SNI，直接 socat 透传（#1 上
`model-relay-haitian.service`）。openEuler 的 nginx **未编译 stream 模块**，
SNI 网关只能配在 Ubuntu 主机上（ROS）。

## 已知问题

- **#2 直连（21005）等窗口**：#2 出口标记未完全消退时 frpc 会话登录后 ~1s 即死；
  一切依赖 #2 自身出口的连接都不稳，用 21002（经 #1 LAN 中继）。
- **jetson↔#2 直连 SSH 被双向 RST**（仅此主机对，jetson→#1、#1→#2 均正常，
  两端 iptables/nft 全空）——未定案，绕行即可。
- frps 侧偶发**僵尸注册**占住端口（新代理 bind 成功但无数据），重启
  `ssh-relay-frps` 容器即清。
- **token 管理**：frps token 在 Tokyo `/opt/ssh-relay/token`（600）与各设备
  frpc.toml（600）内，控制端留档于 `~/.dsh/ssh-relay-token`。绝不入库。

## 相关

- dsh web 固定启动 token：见 shiliai/dsh-plugins PR#129
- 本模块 2026-09-22/23 夜间部署验证，审计日志：SSH_OPS/logs/ops-feishu-APP-Pvjp-000-20260922.md
