# VPS Tools

三个单文件脚本，`bash <(curl ...)` 直接跑，不落地也能用。

| 脚本 | 快捷命令 | 用途 |
|---|---|---|
| `xray.sh` | `xraym` | Xray 服务端管理 |
| `vps.sh` | `vps` | 系统运维：SSH / Fail2Ban / BBR / zRAM / Docker / 清理 |
| `cliproxyapi.sh` | `cpapi` | CLIProxy API 全生命周期管理 |

---

## xray.sh

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh)
```

菜单 8 项：节点列表、添加、修改、删除、服务管理、核心安装更新、BBR、卸载。

### 协议

| 协议 | 传输 | 说明 |
|---|---|---|
| VLESS | REALITY + Vision (TCP) | `flow: xtls-rprx-vision` |
| VLESS | REALITY + XHTTP | 随机路径，`mode: auto` |
| Hysteria 2 | QUIC / HTTP3 | 端口伪装成 HTTP/3 页面 |
| Shadowsocks | TCP + UDP | `2022-blake3-aes-128-gcm` |

默认伪装域名 `www.apache.org`（TLS 1.3 + ALPN h2，不在 Xray 的「过度使用目标」警告名单里）。
字段写法对齐 [xtls.github.io](https://xtls.github.io)：`settings.users`、`realitySettings.target`、
`users[].level` / `users[].email`。

### 配置写入是事务

```
flock 锁 → 同分区 .json 临时文件 → 端口冲突断言 → xray run -test
→ sync + rename → PID 变化 + 1.2s 观察期 → 失败回滚（含 owner/mode）
```

### 其他

- 服务后端 systemd / OpenRC / 裸进程，一套接口
- 以 `xray:xray` 降权运行，`CAP_NET_BIND_SERVICE` 绑低位端口
- 分享链接补 `fp=chrome`（REALITY 必需 uTLS 指纹），SS 走 SIP002
- 启动时幂等迁移老配置（`clients`→`users`、`dest`→`target`、清 `alterId`）
- 三种运行方式都支持：`bash xray.sh` / `bash <(curl ...)` / `curl ... | bash`
- 版本检查解析 Releases 302 重定向，避开 GitHub API 限流；核心包校验 zip 完整性并试跑

> Xray 26.x 已弃用 Shadowsocks（配置仍有效），建议迁移到 VLESS Encryption。
> VMess / Trojan / WebSocket 传输已从脚本移除。

---

## 运行环境

- Debian 11+ / Ubuntu 20.04+ / Alpine
- x86_64 / aarch64 / armv7l
- 依赖：`curl` `jq` `unzip` `openssl` `ca-certificates`（启动时自动检查安装）
- 可选：`qrencode`（二维码）、`flock`（并发锁）

## 测试

`xray.sh` 在 Debian 13 / x86_64 上全量回归：**125 项断言全过**。

覆盖依赖自举、核心安装、四种传输生成、事务写入与回滚、服务启停、端口监听、
链接格式、端口冲突拒绝、配置迁移、三种运行方式、彻底卸载。
