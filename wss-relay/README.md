# WSS Relay — 经 Tokyo VPS 的 frp/WSS 通道（反向 SSH 端口池）

`register-ssh-tunnel.sh`（裸 ssh 反向隧道）在站点出口对"新建 TCP 长连接"做 DPI
杀伤的环境下不可用。本模块用 **frp over WebSocket-Secure(443, 域名 SNI)** 作为传输，
实测为现场出口唯一长期存活的形态（2026-09-22 全天验证）。

## 背景：站点出口行为（2026-09-22/23 实测结论）

| 现象 | 结论 |
| --- | --- |
| 同网关下不同主机命运不同 | 中间盒**按源主机**区别对待，非按出口 IP |
| 裸 TCP / 微量数据(<KB) 可过，KB 级持续传输 ~1s 内 RST | 按**流量大小/持续时间**杀伤 |
| 老连接豁免（jetson 7 天隧道），新连接必死 | 存在 grandfathering |
| 某源被标记后**过夜部分消退**（短请求恢复、长流仍死） | 标记有 TTL，但不完全（09-23 整夜未消退） |
| #1 被标记后，jetson→#1 的**LAN 跨段** SSH 也被连带杀 | 中间盒串在站内骨干，跨段流量同样过它 |
| #1↔#2（有线同交换机）的流量**从未**被杀 | 同段有线流量不过中间盒 |
| `myip.ipip.net` 返回拦截页「WFilter：不允许该网页分类」 | 中间盒真身 = **WFilter 上网行为管理**（L7 分类过滤 + 行为杀流） |

**09-23 定型的杀伤模型**：被标记主机（#1、#2）**持续发送**的流必死——外网方向与
LAN 跨段方向都杀；小请求（<1s 完成）与纯接收不受影响。jetson 一直干净的原因：
其本机跑 xray + sing-box(tun0) 透明代理，出站走 176.122.158.208 根本不过 WFilter。

## 架构（2026-09-23 定型）

```
路径A · SSH relay（frp 控制面走 socks 代理链）:
  #1/#2 frpc ──socks5://10.18.8.43:10808──> ROS nginx stream 转发
                                             └─> jetson xray(10.18.8.42:10808)
                                                   └─> 176.122.158.208 出网 ──443/WSS──> Tokyo nginx
                                                                                          └─ /~!frp > frps 容器(172.22.0.9)
                                                                                                        └─ 2100x ─宿主 socat-relay@2100x─> 对外
路径B · dsh web/agent WSS + 模型 API（TLS 端到端, SNI 网关透传）:
  #2 web ──hosts→10.18.8.43:443──> ROS(干净身份) ──443──> Tokyo hq-310p-2-via-vps.dsh.onlyservice.io
  #2 node ──hosts→10.18.8.43:443──> ROS ──443──> coding.onlyservice.io 等模型端点

Mac/控制端: ssh -p 2100x root@43.167.173.46  (别名见 ~/.ssh/config: relay-*)
```

- frps 与既有 dsh-remote frps **完全独立**（独立容器 `ssh-relay-frps`、独立 token），
  不触碰生产 dsh-remote 体系。
- Tokyo 上 docker 端口发布有静默失败问题（PortBindings 写入但无 docker-proxy），
  故用宿主机 `socat-relay@.service` 逐端口中继到容器固定 IP `172.22.0.9`。
- 代理链要点：**#1/#2 → ROS 是有线同段（不过 WFilter），ROS → jetson 是未标记
  主机的跨段流**——两段都躲开"被标记主机持续发送必死"的杀伤条件。

## 端口分配（SG 已开放 21001–21009，新主机从池内取号）

| 端口 | 主机 | frpc 运行于 | 说明 |
| --- | --- | --- | --- |
| 21001 | #1 (10.18.8.34) | #1 本机 | `relay-310p1`，frpc 走代理链 |
| 21002 | #2 (10.18.8.26) | **#1**（LAN 中继 10.18.8.26:22） | `relay-310p2`，**主力**（dshweb 也走此路） |
| 21003 | jetson (10.18.8.42) | jetson 本机 | `relay-jetson` |
| 21004 | ROS (10.18.8.43) | jetson（LAN 中继 10.18.8.43:22） | `relay-ros2`（应急跳板，曾救全場） |
| 21005 | #2 (10.18.8.26) | #2 本机（frpc 走代理链） | `relay-310p2w`，**已恢复** |

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

### 2) ROS 网关（代理链 + SNI 透传，一次性）

ROS（Ubuntu，10.18.8.43）是站内唯一既有 nginx stream 又出口干净的有线主机：

```bash
sudo apt install nginx libnginx-mod-stream
sudo cp sni-gateway.snippet.conf 的内容并入 /etc/nginx/nginx.conf 顶层 stream{} 块
sudo nginx -t && sudo systemctl reload nginx
```

`stream{}` 三职责（见 snippet，均已在生产验证）：

1. **socks/http 代理转发** `10808/10809 → jetson xray 同端口`（frpc proxyURL 用）；
2. **443 SNI 透传**：`coding.onlyservice.io`/`code.spottyx.xyz`（模型端点）+
   `hq-310p-{1,2}-via-vps`/`remote-shili(-tunnel)`（dsh web/agent WSS）；
3. **29321 纯 TCP 转发** → 43.167.173.46:29321（dsh-remote 网关备用端口）。

### 3) 设备端（每台）

```bash
# token 放入 /root/.ssh-relay-token (600)，然后：
sudo ./deploy-device.sh --name p1 --remote-port 21001
# LAN 中继模式（在本机 frpc 里代理同网段其它主机）：
sudo ./deploy-device.sh --name p1 --remote-port 21001 \
     --lan-relay 21002:10.18.8.26:22
# 出口被标记的主机（#1/#2）必须再加一行代理链（见 frpc.toml.template）：
#   transport.proxyURL = "socks5://10.18.8.43:10808"
```

产物：`/opt/ssh-relay/frpc{,.toml}` + `ssh-relay.service`（enable，Restart=always，
frpc 端 `loginFailExit=false` 出口抖动时自愈重连）。

### 4) 被救主机的 /etc/hosts（dsh WSS + 模型端点走 ROS）

```bash
echo "10.18.8.43 hq-310p-2-via-vps.dsh.onlyservice.io remote-shili-tunnel.dsh.onlyservice.io remote-shili.dsh.onlyservice.io" >> /etc/hosts
echo "10.18.8.43 coding.onlyservice.io code.spottyx.xyz" >> /etc/hosts
systemctl restart dsh-remote-hq-310p-2-via-vps   # 或对应单元，令 WSS 经 ROS 重建
```

### 5) 控制端（Mac）

~/.ssh/config 别名（HostName 43.167.173.46，UserKnownHostsFile ~/.ssh/known_hosts.ssh-relay），
host key 用 `ssh-keyscan -p <port> -t ed25519 43.167.173.46` 采集；
LAN 中继端口（如 21002→21005 同主机）可直接复制 known_hosts 条目改端口。

## 验证清单（变更后逐项过）

```bash
# Mac: 5 条 relay 全通
for h in relay-310p1 relay-310p2 relay-310p2w relay-jetson relay-ros2; do ssh $h date -u; done
# Tokyo: 会话稳定 = 近 5 分钟 0 login 0 closing
docker logs --since 5m ssh-relay-frps 2>&1 | grep -cE 'client login|closing'
# #2: WSS 单连接稳定（两次查看源端口不变）
ss -tn state established | grep '10.18.8.43:443'
# Mac: dsh web
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:13280/
```

## 已知问题

- ~~#2 直连（21005）等窗口~~ → **已解决**：frpc 走代理链后 21005 稳定。
- ~~jetson↔#2 双向 RST 未定案~~ → **已定案**：WFilter 对被标记主机的跨段连带杀；
  jetson→#1 在 #1 被标记后同样出现。应急跳板用 `relay-ros2`（`ssh -J relay-ros2 root@10.18.8.x`）。
- **jetson 的 10808/10809 为无认证全接口监听**：目前仅站内可达，风险可控；
  建议后续在 ROS nginx stream 块加 `allow 10.18.8.0/24; deny all;` 收紧。
- **单点**：路径A 依赖 jetson（xray 挂 → frpc 全线退回 flap），路径B 依赖 ROS
  （挂 → dsh WSS + 模型流量断）。两路互为部分备份，但同时依赖两台中继机在线。
- frps 侧偶发**僵尸注册**占住端口（新代理 bind 成功但无数据），重启
  `ssh-relay-frps` 容器即清。
- **token 管理**：frps token 在 Tokyo `/opt/ssh-relay/token`（600）与各设备
  frpc.toml（600）内，控制端留档于 `~/.dsh/ssh-relay-token`。绝不入库。

## 回滚

```bash
# 设备端撤代理链: sed -i '/transport.proxyURL/d' /opt/ssh-relay/frpc.toml && systemctl restart ssh-relay
# 撤 hosts: 删除对应 10.18.8.43 行后重启 dsh 单元
# ROS: cp /etc/nginx/nginx.conf.backup-<stamp> /etc/nginx/nginx.conf && systemctl reload nginx
```

## 相关

- dsh web 固定启动 token：见 shiliai/dsh-plugins PR#129
- 本模块 2026-09-22/23 部署验证，审计日志：
  SSH_OPS/logs/ops-feishu-APP-Pvjp-000-20260922.md、SSH_OPS/logs/ops-vps-tencent-tokyo-20260923.md
