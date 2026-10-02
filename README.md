# Xray VLESS + Reality 极简部署方案

一个面向低配置 VPS 的 Xray 部署方案。

本方案只部署：

- Xray Core
- VLESS
- TCP
- Reality
- XTLS Vision
- systemd 守护与自动重启

本方案不部署：

- Caddy
- Nginx
- Cloudflare Argo / cloudflared
- Web 面板
- Docker
- 数据库
- WebSocket
- gRPC
- XHTTP
- 订阅服务
- 二维码生成工具
- SSH 工具箱

适合以下场景：

- 64 MB 内存 VPS
- 1 GB 磁盘 VPS
- Debian / Ubuntu 最小化系统
- 单人或少量设备使用
- 希望长期稳定运行
- 希望降低系统资源占用
- 不希望依赖 Cloudflare 临时隧道
- 不希望运行多个后台服务

---

## 1. 架构说明

本方案使用以下结构：

```text
客户端
  │
  │ VLESS + TCP + Reality + XTLS Vision
  │
  ▼
VPS 公网 IP:端口
  │
  ▼
Xray Core
  │
  ▼
互联网
```

服务端只运行一个常驻进程：

```text
xray
```

默认监听：

```text
TCP 443
```

默认协议参数：

```text
协议：VLESS
传输：TCP
安全：Reality
流控：xtls-rprx-vision
指纹：chrome
```

Reality 使用一个真实 HTTPS 网站作为伪装目标，例如：

```text
www.microsoft.com
```

当有人直接访问你的 VPS IP 或端口，但没有正确的 Reality 参数时，流量会表现为访问伪装站点，而不是暴露 Xray 服务特征。

---

## 2. 为什么选择这个方案

相比 VLESS + WS + TLS、Argo、Caddy、Nginx、面板等方案，VLESS + TCP + Reality + Vision 更适合低内存 VPS。

| 对比项 | 本方案 | Xray + Argo + Caddy | 面板 / Docker 方案 |
|---|---:|---:|---:|
| 常驻进程数量 | 1 个 | 通常 3 个以上 | 通常 3 到 10 个以上 |
| 内存占用 | 低 | 中等 | 较高 |
| 磁盘占用 | 低 | 中等 | 较高 |
| 配置复杂度 | 低 | 较高 | 中等 |
| Cloudflare 依赖 | 无 | 有 | 视方案而定 |
| 临时域名问题 | 无 | 可能存在 | 视方案而定 |
| 适合 64 MB VPS | 推荐 | 不推荐 | 不推荐 |
| 适合长期运行 | 推荐 | 不建议依赖临时 Tunnel | 取决于资源配置 |

本方案的核心目标是：

1. 尽可能减少后台服务数量。
2. 尽可能减少内存和磁盘占用。
3. 不依赖 Cloudflare 临时 Tunnel。
4. 不清空 VPS 防火墙规则。
5. 不修改 SSH 配置。
6. 使用 systemd 自动守护和异常重启。
7. 保留简单、可维护、可备份的配置文件。

---

## 3. 系统要求

### 支持系统

当前安装脚本支持：

```text
Debian 11
Debian 12
Ubuntu 20.04
Ubuntu 22.04
Ubuntu 24.04
```

系统必须使用 systemd。

### 推荐最低配置

| 项目 | 最低建议 | 推荐 |
|---|---:|---:|
| 内存 | 64 MB | 128 MB 以上 |
| Swap | 128 MB | 256 MB |
| 磁盘 | 1 GB | 2 GB 以上 |
| CPU | 1 核 | 1 核以上 |
| IPv4 | 推荐 | 推荐 |
| IPv6 | 可选 | 可选 |

### 不推荐的环境

以下环境可能无法正常使用或不建议使用：

- OpenVZ 且不支持 systemd 的旧系统
- 没有公网 IP 的内网机器
- 端口无法开放的 NAT VPS
- 被运营商完全封锁 TCP 端口的网络
- 已经安装多个面板、Docker、数据库和网站服务的 64 MB VPS
- 同一端口已被 Nginx、Caddy、Apache、宝塔、X-ui、3x-ui 占用

---

## 4. 安装前检查

### 检查系统版本

```bash
cat /etc/os-release
```

### 检查内存

```bash
free -h
```

### 检查磁盘

```bash
df -h
```

### 检查 443 端口是否占用

```bash
ss -lntp | grep ':443'
