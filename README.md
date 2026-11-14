# VPS Tools

轻量、极简、无冗余依赖的 Linux VPS 综合运维与代理管理工具箱。

---

## 🛠️ 工具列表

### 1. xray.sh — Xray 现代化轻量管理面板

> **快捷指令**：`xraym`

专为现代 Linux VPS 打造的极简 Xray 控制面板。单文件绿色运行，协议按注册表组织，配置走真事务。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh)
```

#### ✨ 核心亮点

- **直觉式极简交互**：
  - **添加节点两步走**：选协议（VLESS 再选传输方式）→ 敲回车确认推荐端口，密钥/UUID/ShortID/路径全部自动生成；
  - **修改节点**：以当前值为默认提示，直接回车保持不变，输入新值即刻热迁移；
  - **单线流程设计**：摒弃多层嵌套菜单，每个操作独立完成，一键回车返回。
- **现代化排版 & 显示宽度自适应**：
  - 全界面顶格左对齐，虚线与表格随终端宽度自适应（30–120 列）；
  - 表格按**显示宽度**补齐，中英混排不再错位（`dwidth` / `pad`）；
  - 统一状态标识：`[成功]`、`[失败]`、`[警告]`、`[提示]`。
- **配置事务引擎（`conf_mutate`）——六道闸门**：
  1. `flock` 全局锁，两个会话同时改配置不会互相覆盖；
  2. 临时文件落在**同目录同分区**且带 `.json` 后缀，`mv` 才是真原子；
  3. 同协议族端口冲突断言（TCP / UDP / both 相交才算冲突）；
  4. Xray 内核原生 `xray run -test` 预检；
  5. `sync` 后 rename 覆写，失败连同 owner/mode 一起回滚；
  6. 重启后要求 **PID 变化 + 存活 1.2 秒观察期**，抓"起来了又立刻崩"。
- **协议矩阵（3 种 / VLESS 含两种传输）**：
  - **VLESS · REALITY-Vision** — TCP + `xtls-rprx-vision`
  - **VLESS · REALITY-XHTTP** — XHTTP 传输，随机路径，`mode: auto`
  - **Hysteria 2** — UDP / QUIC / H3
  - **Shadowsocks 2022** — `2022-blake3-aes-128-gcm`

  字段写法对齐 [xtls.github.io](https://xtls.github.io) 当前版本：`settings.users`、`realitySettings.target`，
  默认伪装域名 **`www.apache.org`**（TLS 1.3 + ALPN h2，且不在 Xray 的"过度使用目标"警告名单里）。

  每个入站都补齐了文档定义的元数据：`users[].level` / `users[].email`（按用户统计与策略的基础）；
  Hysteria 2 额外带 `hysteriaSettings`（`udpIdleTimeout: 60`，并把 QUIC 端口伪装成 `www.apache.org` 的 HTTP/3 页面，
  被主动探测时不像一个代理）；Hysteria 与 Shadowsocks 均开启 `sniffing`。

> **UDP 入站注意**：官方文档指出，若网卡存在多个 IP 而客户端连接的是非首选地址，UDP 入站监听 `::`
> 会导致回包源地址错误、连接不通。多公网 IP 的机器请把 Hysteria 的 `listen` 改成具体网卡 IP。
- **多栈网络与分享链接**：
  - IPv4 / IPv6 独立探测，互不短路；
  - 每个节点单独生成分享链接，双栈分开输出；
  - 链接自动补齐 `fp=chrome`（REALITY 必需 uTLS 指纹），SS 遵循 SIP002。
- **配置模型收敛**：
  - `_meta` 只保留无法从 Xray 配置推导的字段（如 REALITY 公钥 `pbk`）；
  - 其余一律读真实字段，不存在"改了一处另一处没同步"的漂移；
  - 启动时幂等迁移老配置（`clients`→`users`、`dest`→`target`、清 `alterId`）。
- **服务后端自动收敛**：systemd / OpenRC / 裸进程三套一套接口；
  每次操作前 `systemctl reset-failed`，避免连续改配置撞上 systemd 的 5 次/10 秒启动限流。
- **智能快捷命令与免 API 限流更新**：
  - 支持 `bash <(curl -fsSL ...)` 管道运行，自动安装 `/usr/local/bin/xraym`；
  - 版本检查优先解析 Releases 302 重定向，避开 GitHub API 60 次/小时限流；
  - 核心包下载后校验 zip 完整性并试跑 `xray version`，架构不匹配直接拒绝；
  - 以普通用户 `xray:xray` 降权运行，用 `CAP_NET_BIND_SERVICE` 绑定低位端口。

> **注意**：Xray 26.x 已将 Shadowsocks 标记为弃用（配置仍有效，`-test` 通过），
> 并建议迁移到 VLESS Encryption。脚本已移除 VMess、Trojan 与 WebSocket 传输，
> 新部署建议优先 **VLESS + XHTTP**。

---

### 2. vps.sh — VPS 综合运维管理

> **快捷指令**：`vps`

涵盖 SSH 密钥与密码登录管理、端口修改、Fail2Ban 防爆破、BBR 拥塞控制、zRAM 动态内存压缩、Docker 运行环境管理与系统深度清理。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/vps.sh)
```

---

### 3. cliproxyapi.sh — CLIProxy API 管理器

> **快捷指令**：`cpapi`

CLIProxy API 服务全生命周期管理，本地安全回环绑定（`127.0.0.1:8317`），支持版本平滑升级回滚、配置备份与反代指引。

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/cliproxyapi.sh)
```

---

## 📄 运行环境要求

- **操作系统**：Debian 11+ / Ubuntu 20.04+ / Alpine Linux 等常见发行版
- **系统架构**：x86_64 (amd64) / aarch64 (arm64) / armv7l
- **核心依赖**：`curl`、`jq`、`unzip`、`openssl`、`ca-certificates`（脚本启动时自动检查并补齐）
  - 最小化系统常缺 `ca-certificates`，缺了 curl 会以 `error 77` 静默失败，脚本会一并装上
- **可选**：`qrencode`（装了才显示二维码）、`flock`（util-linux，装了才启用并发锁）

## ✅ 测试状态

`xray.sh` 在 Debian 13 (trixie) / x86_64 上跑过全量真机回归：**108 项断言全过**。

覆盖：依赖自举、环境初始化、核心安装、六种协议生成、事务写入、服务与端口监听、
五种链接格式、IPv6 方括号、表格、端口冲突拒绝、非法配置拒绝、节点编辑与删除、
配置迁移幂等、坏配置回滚、重启/停止/启动、彻底卸载。
