#!/usr/bin/env bash
# ==============================================================================
# Xray Management Script (xraym)
# Lightweight, Robust & Non-root Xray Server Manager for Linux VPS
# 单文件运行：bash <(curl -fsSL https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh)
# ==============================================================================
set -o pipefail
umask 077

if [ "${XRAY_TEST:-0}" != "1" ] && [ "$(id -u)" -ne 0 ]; then
    printf '%b[失败]%b 请使用 root 权限运行此脚本\n' "\033[31m" "\033[0m" >&2
    exit 1
fi

# 非交互兜底：脚本已落盘（bash <(curl ...) 或本地文件）且 stdin 不是终端时，
# 把 stdin 换成终端。curl | bash 不能在这里做——那时 stdin 正是脚本本身。
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ $# -eq 0 ] && [ ! -t 0 ]; then
    { exec < /dev/tty; } 2>/dev/null || true
fi

# ── 常量 ──────────────────────────────────────────────────────────────
CONF_DIR="${XRAY_CONF_DIR:-/usr/local/etc/xray}"
CONF="$CONF_DIR/config.json"
CERTS_DIR="$CONF_DIR/certs"
BIN="/usr/local/bin/xray"
SVC_NAME="xray"
VER_CACHE="$CONF_DIR/.latest_ver"
SHORTCUT="/usr/local/bin/xraym"
ASSET_DIR="/usr/local/share/xray"
META_VER=3

PUB_IPV4=""
PUB_IPV6=""
__IP_PROBED=""
SVC_BACKEND=""
__COLS=""

ARCH="64"
case "$(uname -m)" in
    aarch64|arm64)       ARCH="arm64-v8a" ;;
    armv7l|armv7*)       ARCH="arm32-v7a" ;;
    i386|i486|i586|i686) ARCH="32" ;;
    *)                   ARCH="64" ;;
esac

# ── 终端样式 ──────────────────────────────────────────────────────────
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_CYAN="\033[36m"; C_GREEN="\033[32m"; C_RED="\033[31m"; C_YELLOW="\033[33m"

cls() { clear 2>/dev/null || true; }

TMP_DIRS=()
cleanup_tmp() {
    local d
    for d in "${TMP_DIRS[@]}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done
    TMP_DIRS=()
}
trap cleanup_tmp EXIT
trap 'cleanup_tmp; exit 130' INT
trap 'cleanup_tmp; exit 143' TERM

# 临时目录：结果写入全局 MK_TMP_DIR（不能用 $(...) 取，否则 TMP_DIRS 记录会丢在子 shell 里）
MK_TMP_DIR=""
mk_tmp_dir() {
    local __d
    mkdir -p "$CONF_DIR" 2>/dev/null || true
    __d=$(mktemp -d "$CONF_DIR/.tmp.XXXXXX" 2>/dev/null) \
        || __d=$(mktemp -d "${TMPDIR:-/tmp}/xray.XXXXXX" 2>/dev/null) || return 1
    TMP_DIRS+=("$__d")
    MK_TMP_DIR="$__d"
    return 0
}

ok()   { printf '%b[成功]%b %b\n' "$C_GREEN" "$C_RESET" "$*"; }
err()  { printf '%b[失败]%b %b\n' "$C_RED" "$C_RESET" "$*" >&2; }
warn() { printf '%b[警告]%b %b\n' "$C_YELLOW" "$C_RESET" "$*"; }
info() { printf '%b[提示]%b %b\n' "$C_CYAN" "$C_RESET" "$*"; }

draw_line() {
    local char="${1:--}" color="${2:-}" cols line
    if [ -n "$__COLS" ]; then
        cols="$__COLS"
    else
        cols=$(tput cols 2>/dev/null || true)
        case "$cols" in ''|*[!0-9]*) cols="${COLUMNS:-}" ;; esac
        case "$cols" in ''|*[!0-9]*) cols=75 ;; esac
        [ "$cols" -lt 30 ] && cols=75
        [ "$cols" -gt 120 ] && cols=120
        __COLS="$cols"
    fi
    printf -v line '%*s' "$cols" ''
    line=${line// /"$char"}
    if [ -n "$color" ]; then printf '%b%s%b\n' "$color" "$line" "$C_RESET"
    else printf '%s\n' "$line"; fi
}

# 显示宽度：ASCII 记 1，UTF-8 多字节按 2 记（CJK 正确，拉丁重音略宽）
dwidth() {
    local s="$1" b c
    b=$(LC_ALL=C; printf '%s' "$s" | wc -c)
    c=${#s}
    b=${b//[!0-9]/}; c=${c//[!0-9]/}
    [ -z "$b" ] && b=0
    [ -z "$c" ] && c=0
    printf '%s' $(( c + (b - c) / 2 ))
}

pad() {
    local s="$1" w="$2" d n
    d=$(dwidth "$s")
    n=$(( w - d ))
    [ "$n" -lt 0 ] && n=0
    printf '%s%*s' "$s" "$n" ''
}

# 长 IPv6 截断，避免顶栏折行
short_ip() {
    local s="$1"
    if [ "${#s}" -gt 22 ]; then printf '%s…%s' "${s:0:14}" "${s: -4}"
    else printf '%s' "$s"; fi
}

ask() {
    local p="$1" d="${2:-}" v="" rc=0
    if [ -n "$d" ]; then
        read -rp "$(printf '%b[提示]%b %s [%s]: ' "$C_CYAN" "$C_RESET" "$p" "$d")" v || rc=1
    else
        read -rp "$(printf '%b[提示]%b %s: ' "$C_CYAN" "$C_RESET" "$p")" v || rc=1
    fi
    printf '%s\n' "${v:-$d}"
    return "$rc"
}

pause_tip() { read -rp "$(printf '%b[提示]%b 按回车键继续...' "$C_CYAN" "$C_RESET")" _ || true; }

# ── 依赖 ──────────────────────────────────────────────────────────────
check_deps() {
    local need="" cmd miss=""
    for cmd in curl unzip openssl jq; do
        command -v "$cmd" >/dev/null 2>&1 || need+=" $cmd"
    done
    # 最小化系统常缺 CA 根证书，curl 会以 error 77 静默失败（表现为"网络不通"）
    if [ ! -s /etc/ssl/certs/ca-certificates.crt ] \
        && [ ! -s /etc/pki/tls/certs/ca-bundle.crt ] \
        && [ ! -s /etc/ssl/cert.pem ]; then
        need+=" ca-certificates"
    fi
    if ! command -v setcap >/dev/null 2>&1; then
        if command -v apt-get >/dev/null 2>&1; then need+=" libcap2-bin"
        elif command -v apk >/dev/null 2>&1; then need+=" libcap"; fi
    fi
    [ -z "$need" ] && return 0

    info "安装必要系统依赖:${need}"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $need >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk update -q >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        apk add -q $need >/dev/null 2>&1 || true
    else
        err "未找到包管理器，请手动安装:${need}"; return 1
    fi

    # 装完必须复验，不能"发完命令就当成功"
    for cmd in curl unzip openssl jq; do
        command -v "$cmd" >/dev/null 2>&1 || miss+=" $cmd"
    done
    if [ ! -s /etc/ssl/certs/ca-certificates.crt ] \
        && [ ! -s /etc/pki/tls/certs/ca-bundle.crt ] \
        && [ ! -s /etc/ssl/cert.pem ]; then
        miss+=" ca-certificates"
    fi
    if [ -n "$miss" ]; then err "依赖安装失败:$miss"; return 1; fi
    ok "依赖已就绪"
    return 0
}

gen_uuid() {
    if [ -x "$BIN" ]; then "$BIN" uuid 2>/dev/null
    else cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16; fi
}

cur_core_ver() {
    [ -x "$BIN" ] && "$BIN" version 2>/dev/null | head -n1 | awk '{print $2}' || printf ''
}

refresh_ips() {
    # 只探一次：IPv4-only 机器上 PUB_IPV6 永远为空，用值判断会导致每次调用都重试超时
    [ -n "$__IP_PROBED" ] && return 0
    __IP_PROBED=1
    if command -v ip >/dev/null 2>&1; then
        [ -z "$PUB_IPV4" ] && PUB_IPV4=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Ev '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)' | head -n1 || true)
        [ -z "$PUB_IPV6" ] && PUB_IPV6=$(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Ev '^(fe80|fd00|::1)' | head -n1 || true)
    fi
    if [ -z "$PUB_IPV4" ]; then
        PUB_IPV4=$(curl -fs4 -m 2 https://api.ipify.org 2>/dev/null || curl -fs4 -m 2 https://icanhazip.com 2>/dev/null || true)
    fi
    if [ -z "$PUB_IPV6" ]; then
        PUB_IPV6=$(curl -fs6 -m 2 https://api6.ipify.org 2>/dev/null || curl -fs6 -m 2 https://icanhazip.com 2>/dev/null || true)
    fi
    return 0
}
# ── 配置读写与事务引擎 ──────────────────────────────────────────────────
# 读只走真实字段，_meta 只保留「无法从 Xray 配置推导」的数据（Reality 公钥 pbk /
# hysteria 的 SNI），这样 edit 时不存在双写漂移。

conf_exists() { [ -s "$CONF" ]; }

conf_count() { jq -r '.inbounds | length' "$CONF" 2>/dev/null || printf '0'; }

conf_node() { jq -c --argjson i "${1:-0}" '.inbounds[$i] // empty' "$CONF" 2>/dev/null; }


# 端口冲突断言：同端口 + 同协议族（tcp/udp/both 相交）才算冲突
conf_assert_ports() {
    local f="$1" pmap="$2" dup
    [ -n "$pmap" ] || { err "端口映射为空，无法校验端口冲突"; return 1; }
    dup=$(jq -r --argjson m "$pmap" '
        [ .inbounds | to_entries[] | { i: .key, p: .value.port, t: ($m[.value.protocol] // "tcp") } ] as $x |
        $x[] as $a | $x[] as $b |
        select($a.i < $b.i and $a.p == $b.p and ($a.t == "both" or $b.t == "both" or $a.t == $b.t)) |
        $a.p
    ' "$f" 2>/dev/null | head -n1)
    if [ -n "$dup" ]; then
        err "端口 ${dup} 在同协议族现有多个节点中重复绑定"
        return 1
    fi
    return 0
}

# Xray 内核原生语法校验（内核未安装时跳过）
conf_test() {
    local f="$1" msg=""
    [ -x "$BIN" ] || return 0
    if ! msg=$("$BIN" run -test -format=json -c "$f" 2>&1); then
        err "内核配置校验未通过:"
        printf '%b%s%b\n' "$C_DIM" "$msg" "$C_RESET"
        return 1
    fi
    return 0
}

lock_acquire() {
    command -v flock >/dev/null 2>&1 || return 0   # 无 flock 时退化为无锁
    [ -d "$CONF_DIR" ] || return 0
    # 先确认可写：exec 重定向失败会让非交互 shell 直接退出
    { : > "$CONF_DIR/.lock"; } 2>/dev/null || return 0
    # 注意：exec 不带命令时重定向会永久生效，这里绝不能加 2>/dev/null，否则全脚本 stderr 报废
    exec 9>"$CONF_DIR/.lock" || return 0
    flock -w 5 9 2>/dev/null && return 0
    flock -n 9 2>/dev/null && return 0              # busybox flock 不支持 -w
    exec 9>&-
    return 1
}
lock_release() { exec 9>&-; }

# ── 事务：锁 → jq 计算 → 端口断言 → 内核校验 → 同分区 rename → 重启校验 → 回滚 ───
conf_mutate() {
    local filter="$1"; shift

    mkdir -p "$CONF_DIR" 2>/dev/null || true
    [ -s "$CONF" ] || { err "配置文件不存在，请先在菜单 6 安装核心"; return 1; }
    if ! lock_acquire; then err "另一个会话正在修改配置，请稍后重试"; return 1; fi

    local new="$CONF_DIR/.config.new.$$.json"   # 必须带 .json 后缀：Xray 按扩展名判格式
    if ! jq "$@" "$filter" "$CONF" > "$new" 2>/dev/null; then
        rm -f "$new"; lock_release; err "配置计算失败"; return 1
    fi
    if ! conf_assert_ports "$new" "$(proto_portmap)"; then
        rm -f "$new"; lock_release; return 1
    fi
    if ! conf_test "$new"; then
        rm -f "$new"; lock_release; return 1
    fi

    local old_pid
    old_pid=$(svc_pid)
    [ -f "$CONF" ] && { cp -f "$CONF" "$CONF.bak" 2>/dev/null && chmod 600 "$CONF.bak" 2>/dev/null; }
    sync

    if ! mv -f "$new" "$CONF" 2>/dev/null; then
        rm -f "$new"; lock_release; err "配置写入失败"; return 1
    fi
    chown xray:xray "$CONF" 2>/dev/null || true
    chmod 600 "$CONF" 2>/dev/null || true

    if ! svc_restart_verify "$old_pid"; then
        err "服务拉起失败，正在回滚原配置..."
        if [ -f "$CONF.bak" ]; then
            mv -f "$CONF.bak" "$CONF" 2>/dev/null
            chown xray:xray "$CONF" 2>/dev/null || true
            chmod 600 "$CONF" 2>/dev/null || true
            svc_do restart >/dev/null 2>&1 || true
        fi
        if [ -n "$(svc_pid)" ]; then ok "已恢复原配置"
        else err "恢复后仍未运行，请到「服务管理 → 实时日志」查看原因"; fi
        lock_release
        return 1
    fi

    rm -f "$CONF.bak" 2>/dev/null || true
    lock_release
    ok "配置已校验并成功加载生效"
}

# 配置模型迁移：升版本戳并按版本改写字段，幂等
conf_migrate() {
    [ -s "$CONF" ] || return 0
    local v
    v=$(jq -r '._meta.v // 0' "$CONF" 2>/dev/null || printf '0')
    [ "$v" = "$META_VER" ] && return 0

    local new="$CONF_DIR/.config.mig.$$.json"
    # v2 → v3：clients 改 users（文档写法）、删 alterId、reality dest 改 target
    local filter
    filter='._meta = ((._meta // {}) + {v: $v}) |
      .inbounds |= map(
        (if .protocol == "vless" then
           (if .settings.clients? != null
            then ((.settings.users = (.settings.clients | map(del(.alterId)))) | del(.settings.clients))
            else . end)
           | (if .settings.users? != null then .settings.users |= map(del(.alterId)) else . end)
         else . end)
        | (if .streamSettings.realitySettings.dest? != null
           then ((.streamSettings.realitySettings.target = .streamSettings.realitySettings.dest) | del(.streamSettings.realitySettings.dest))
           else . end)
      )'
    if jq --argjson v "$META_VER" "$filter" "$CONF" > "$new" 2>/dev/null; then
        chmod 600 "$new" 2>/dev/null
        mv -f "$new" "$CONF" 2>/dev/null || rm -f "$new"
        chown xray:xray "$CONF" 2>/dev/null || true
    else
        rm -f "$new"
    fi
    return 0
}

# ── 初始环境 ──────────────────────────────────────────────────────────
ensure_xray_user() {
    if ! id -u xray >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin -M -d /nonexistent -U xray 2>/dev/null \
            || adduser -S -D -H xray 2>/dev/null || true
    fi
    if [ -f "$BIN" ] && command -v setcap >/dev/null 2>&1; then
        setcap 'cap_net_bind_service=+ep' "$BIN" 2>/dev/null || true
    fi
    mkdir -p "$CONF_DIR" "$CERTS_DIR" /var/log/xray 2>/dev/null || true
    chown -R xray:xray "$CONF_DIR" /var/log/xray 2>/dev/null || true
    chmod 700 "$CONF_DIR" "$CERTS_DIR" 2>/dev/null || true
    [ -f "$CONF" ] && chmod 600 "$CONF" 2>/dev/null || true
}

init_env() {
    ensure_xray_user
    if [ ! -s "$CONF" ]; then
        printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}],"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","ip":["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","fc00::/7","fe80::/10"],"outboundTag":"block"}]},"_meta":{"v":'"$META_VER"'}}' > "$CONF"
        chown -R xray:xray "$CONF_DIR" 2>/dev/null || true
        chmod 600 "$CONF" 2>/dev/null || true
    fi
}
# ── 服务后端：systemd / openrc / 裸进程，三套收敛成一套接口 ───

svc_detect() {
    [ -n "$SVC_BACKEND" ] && return 0
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        SVC_BACKEND="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        SVC_BACKEND="openrc"
    else
        SVC_BACKEND="bare"
    fi
    return 0
}

# 取主进程 PID。systemd 用 MainPID（比 pgrep 准，不会探到正在退出的旧进程）
svc_pid() {
    svc_detect
    if [ "$SVC_BACKEND" = "systemd" ]; then
        local p
        p=$(systemctl show -p MainPID --value "$SVC_NAME" 2>/dev/null | tr -d ' \r\n')
        [ -z "$p" ] && p=$(systemctl show -p MainPID "$SVC_NAME" 2>/dev/null | sed 's/^MainPID=//')
        [ "$p" = "0" ] && p=""
        printf '%s' "$p"
    else
        pgrep -x xray 2>/dev/null | head -n1
    fi
}

is_running() { [ -n "$(svc_pid)" ]; }

svc_do() {
    local act="$1"
    svc_detect
    case "$SVC_BACKEND" in
        systemd)
            # 连续改配置会撞上 systemd 默认的 5 次/10s 启动限流，先清计数再操作
            systemctl reset-failed "$SVC_NAME" >/dev/null 2>&1 || true
            systemctl "$act" "$SVC_NAME" >/dev/null 2>&1 || true
            ;;
        openrc)
            rc-service "$SVC_NAME" "$act" >/dev/null 2>&1 || true
            ;;
        bare)
            pkill -u xray -x xray >/dev/null 2>&1 || true
            pkill -x xray >/dev/null 2>&1 || true
            case "$act" in
                start|restart)
                    [ -x "$BIN" ] || return 0
                    if id -u xray >/dev/null 2>&1; then
                        su -s /bin/sh xray -c "nohup '$BIN' run -c '$CONF' >/dev/null 2>&1 &" >/dev/null 2>&1 || true
                    else
                        nohup "$BIN" run -c "$CONF" >/dev/null 2>&1 &
                    fi
                    ;;
            esac
            ;;
    esac
    return 0
}

# 重启并验证：PID 必须变化 + 存活观察期，才算真起来
svc_restart_verify() {
    local old_pid="${1:-}" i=0 np=""
    svc_do restart
    while [ "$i" -lt 25 ]; do
        np=$(svc_pid)
        [ -n "$np" ] && [ "$np" != "$old_pid" ] && break
        sleep 0.2; i=$((i+1))
    done
    [ -z "$np" ] && return 1
    [ "$np" = "$old_pid" ] && return 1
    sleep 1.2
    [ "$(svc_pid)" = "$np" ] || return 1
    return 0
}

svc_start() {
    [ -n "$(svc_pid)" ] && return 0
    local p="" i=0
    svc_do start
    while [ "$i" -lt 25 ]; do
        p=$(svc_pid)
        [ -n "$p" ] && break
        sleep 0.2; i=$((i+1))
    done
    [ -z "$p" ] && return 1
    sleep 1.0   # 观察期：systemd 会瞬时给出 MainPID，进程随后就崩
    [ "$(svc_pid)" = "$p" ] || return 1
    return 0
}

svc_stop() {
    [ -z "$(svc_pid)" ] && return 0
    svc_do stop
    local i=0
    while [ "$i" -lt 25 ]; do
        [ -z "$(svc_pid)" ] && return 0
        sleep 0.2; i=$((i+1))
    done
    return 1
}

# 端口是否在监听：直接读 /proc，不依赖 ss/netstat
port_listening() {
    local p="$1" proto="${2:-tcp}" hex f
    hex=$(printf '%04X' "$p" 2>/dev/null) || return 1
    [ -z "$hex" ] && return 1
    if [ "$proto" != "udp" ]; then
        for f in /proc/net/tcp /proc/net/tcp6; do
            [ -r "$f" ] && awk -v h=":$hex" '$4=="0A" && index($2,h){f=1;exit} END{exit !f}' "$f" && return 0
        done
    fi
    if [ "$proto" != "tcp" ]; then
        for f in /proc/net/udp /proc/net/udp6; do
            [ -r "$f" ] && awk -v h=":$hex" '$4=="07" && index($2,h){f=1;exit} END{exit !f}' "$f" && return 0
        done
    fi
    return 1
}

rand_port() {
    local proto="${1:-tcp}" p="" i=0
    while [ "$i" -lt 50 ]; do
        p=$((RANDOM % 55535 + 10000))
        port_listening "$p" "$proto" || { printf '%s' "$p"; return 0; }
        i=$((i+1))
    done
    printf '%s' "$p"
}

# 交互式取端口：非法/占用/EOF 都能干净退出
ask_port() {
    local prompt="$1" def="$2" ignore_idx="${3:-}" proto="${4:-tcp}" p=""
    while true; do
        p=$(ask "$prompt" "$def") || return 1
        if [[ ! "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            err "端口无效，请输入 1-65535 纯数字"; continue
        fi
        if port_listening "$p" "$proto"; then
            local own=""
            if [ -n "$ignore_idx" ]; then
                own=$(jq -r --argjson i "$ignore_idx" '.inbounds[$i].port // empty' "$CONF" 2>/dev/null)
            fi
            [ "$p" != "$own" ] && { err "端口 ${p} 已被系统占用，请更换"; continue; }
        fi
        printf '%s\n' "$p"
        return 0
    done
}

# ── 服务安装 ──────────────────────────────────────────────────────────
svc_install() {
    svc_detect
    if [ ! -x "$BIN" ]; then
        warn "核心尚未安装，跳过服务单元写入"
        return 1
    fi
    case "$SVC_BACKEND" in
        systemd)
            cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray Core Engine
After=network.target

[Service]
Type=simple
User=xray
Group=xray
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
Environment=XRAY_LOCATION_ASSET=${ASSET_DIR}
ExecStart=${BIN} run -c ${CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable "$SVC_NAME" >/dev/null 2>&1 || true
            ;;
        openrc)
            cat > /etc/init.d/xray << 'EOF'
#!/sbin/openrc-run
description="Xray Core Engine"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_user="xray:xray"
command_background=true
pidfile="/run/xray.pid"
export XRAY_LOCATION_ASSET="/usr/local/share/xray"
depend() { need net; }
EOF
            chmod +x /etc/init.d/xray
            rc-update add "$SVC_NAME" default >/dev/null 2>&1 || true
            ;;
        *)
            :   # 裸进程模式无需安装
            ;;
    esac
}
# ── 协议注册表 ──────────────────────────────────────────────────────────
# 一个协议 = 三个钩子 + 一行注册，加协议只改这一处。
#   p_gen_<t>  [无参]          交互采集 → stdout 输出完整 inbound JSON
#   p_edit_<t> <json> <idx>    交互修改 → stdout 输出新 inbound JSON
#   p_info_<t> <json> [host]   stdout 输出一行 5 字段（| 分隔）：
#                                label|trans|target|detail|link
#                              detail 内多条用 ; 分隔；host 为空时 link 为空

PROTOS=(vless hysteria shadowsocks)

declare -A P_LABEL=( [vless]="VLESS" [hysteria]="Hysteria 2" \
                     [shadowsocks]="Shadowsocks" )
declare -A P_NET=(   [vless]="tcp" [hysteria]="udp" \
                     [shadowsocks]="both" )
declare -A P_DEFPORT=( [vless]=443 [hysteria]=8443 \
                       [shadowsocks]=8388 )

# 协议 → 监听协议族（tcp/udp/both），供端口冲突断言使用
proto_portmap() {
    local t sep="" out="{"
    for t in "${PROTOS[@]}"; do
        out+="${sep}\"${t}\":\"${P_NET[$t]:-tcp}\""
        sep=","
    done
    printf '%s}' "$out"
}

n_proto() { jq -r '.protocol // ""' <<< "$1" 2>/dev/null; }
n_port()  { jq -r '.port // 0' <<< "$1" 2>/dev/null; }
n_tag()   { jq -r '.tag // "node"' <<< "$1" 2>/dev/null; }

# 推荐端口：默认端口被占则随机换一个
def_port() {
    local t="$1"
    local d="${P_DEFPORT[$t]:-443}"
    local p="${P_NET[$t]:-tcp}"
    port_listening "$d" "$p" && d=$(rand_port "$p")
    printf '%s' "$d"
}

# 解析 p_info 输出：$1=整行 $2=字段号(1-5)
p_field() {
    local IFS='|' a b c d e
    read -r a b c d e <<< "$1"
    case "$2" in
        1) printf '%s' "$a" ;; 2) printf '%s' "$b" ;; 3) printf '%s' "$c" ;;
        4) printf '%s' "$d" ;; 5) printf '%s' "$e" ;;
    esac
}

# ── p_info：所有协议共用同一个 jq 输出契约 ──────────────────
p_info_vless() {
    jq -r --arg host "${2:-}" '
        . as $n |
        (.streamSettings.realitySettings.serverNames[0] // ._meta.sni // "-") as $sni |
        (.settings.users[0].id // .settings.clients[0].id // "-") as $uid |
        (.streamSettings.realitySettings.shortIds[0] // "-") as $sid |
        (._meta.pbk // "-") as $pbk |
        (.streamSettings.network // "tcp") as $net |
        (.settings.clients[0].flow // "xtls-rprx-vision") as $flow |
        (.streamSettings.xhttpSettings.path // "/xhttp") as $path |
        ($n.tag // "node") as $tag |
        (if $net == "xhttp" then "VLESS-XHTTP" else "VLESS-Vision" end) as $label |
        (if $net == "xhttp" then "XHTTP" else "TCP" end) as $trans |
        (if $host == "" then "" else
            "vless://" + $uid + "@" + $host + ":" + ($n.port | tostring) +
            "?security=reality&encryption=none&pbk=" + $pbk + "&headerType=none&fp=chrome&spx=%2F&type=" + $net +
            (if $net == "xhttp" then "&path=" + ($path | @uri) + "&mode=auto" else "&flow=" + $flow end) +
            "&sni=" + $sni + "&sid=" + $sid + "#" + ($tag | @uri)
        end) as $link |
        [ $label, $trans, $sni,
          ("伪装域名: \($sni) (ShortID: \($sid));用户标识: \($uid);公钥密钥: \($pbk)"),
          $link ] | join("|")
    ' <<< "$1" 2>/dev/null
}

p_info_hysteria() {
    jq -r --arg host "${2:-}" '
        . as $n |
        (.streamSettings.tlsSettings.serverName // ._meta.sni // "-") as $sni |
        (.settings.users[0].auth // "-") as $pass |
        ($n.tag // "node") as $tag |
        (if $host == "" then "" else
            "hysteria2://" + ($pass | @uri) + "@" + $host + ":" + ($n.port | tostring) +
            "/?insecure=1&sni=" + $sni + "#" + ($tag | @uri)
        end) as $link |
        [ "Hysteria 2", "UDP/H3", $sni,
          ("伪装域名: \($sni);认证密码: \($pass);传输协议: QUIC / H3"),
          $link ] | join("|")
    ' <<< "$1" 2>/dev/null
}


p_info_shadowsocks() {
    jq -r --arg host "${2:-}" '
        . as $n |
        (.settings.method // "-") as $method |
        (.settings.password // "-") as $pass |
        ($n.tag // "node") as $tag |
        (if $host == "" then "" else
            "ss://" + ((($method + ":" + $pass) | @base64) | gsub("\\+"; "-") | gsub("/"; "_") | sub("=+$"; "")) +
            "@" + $host + ":" + ($n.port | tostring) + "#" + ($tag | @uri)
        end) as $link |
        [ "Shadowsocks", "TCP,UDP", $method,
          ("加密方式: \($method);预共享钥: \($pass)"),
          $link ] | join("|")
    ' <<< "$1" 2>/dev/null
}

# ── 协议生成钩子：p_gen_<t> 交互采集 → 输出 inbound JSON ───

# VLESS 两种传输：REALITY + Vision(TCP) / REALITY + XHTTP
p_gen_vless() {
    {
        printf '\n%b选择传输方式%b\n' "$C_BOLD" "$C_RESET"
        draw_line "-"
        printf '%b1.%b REALITY + Vision (TCP)\n' "$C_CYAN" "$C_RESET"
        printf '%b2.%b REALITY + XHTTP\n' "$C_CYAN" "$C_RESET"
        printf '%b0.%b 返回菜单\n' "$C_DIM" "$C_RESET"
        draw_line "-"
    } >&2

    local c
    c=$(ask "请选择" "0") || return 1
    case "$c" in
        1|'') p_gen_vless_tcp ;;
        2)    p_gen_xhttp ;;
        0)    return 1 ;;
        *)    err "无效选择"; return 1 ;;
    esac
}

p_gen_vless_tcp() {
    local port keys priv pub sid uid
    port=$(ask_port "监听端口" "$(def_port vless)" "" tcp) || return 1
    keys=$("$BIN" x25519 2>/dev/null)
    priv=$(printf '%s\n' "$keys" | awk -F': *' '/[Pp]rivate[ ]?[Kk]ey/{print $2}' | tr -d ' \r\n')
    pub=$(printf '%s\n' "$keys" | awk -F': *' '/[Pp]ublic[ ]?[Kk]ey/{print $2}' | tr -d ' \r\n')
    [ -z "$priv" ] && { err "生成 Reality 密钥对失败"; return 1; }
    sid=$(openssl rand -hex 4)
    uid=$(gen_uuid)

    jq -n --arg port "$port" --arg uid "$uid" --arg priv "$priv" --arg pbk "$pub" \
          --arg sni "www.apache.org" --arg sid "$sid" --arg rmk "VLESS-${port}" '
        { listen: "::", port: ($port | tonumber), protocol: "vless", tag: $rmk,
          settings: { users: [ { id: $uid, flow: "xtls-rprx-vision", level: 0, email: ($rmk + "@xraym") } ],
                      decryption: "none" },
          streamSettings: { network: "tcp", security: "reality",
              realitySettings: { show: false, target: ($sni + ":443"), xver: 0,
                                 serverNames: [$sni], privateKey: $priv, shortIds: [$sid] } },
          sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
          _meta: { pbk: $pbk } }
    '
}

# XHTTP：VLESS + REALITY + XHTTP 传输，不需要 flow
p_gen_xhttp() {
    local port keys priv pub sid uid path
    port=$(ask_port "监听端口" "$(def_port xhttp)" "" tcp) || return 1
    keys=$("$BIN" x25519 2>/dev/null)
    priv=$(printf '%s\n' "$keys" | awk -F': *' '/[Pp]rivate[ ]?[Kk]ey/{print $2}' | tr -d ' \r\n')
    pub=$(printf '%s\n' "$keys" | awk -F': *' '/[Pp]ublic[ ]?[Kk]ey/{print $2}' | tr -d ' \r\n')
    [ -z "$priv" ] && { err "生成 Reality 密钥对失败"; return 1; }
    sid=$(openssl rand -hex 4)
    uid=$(gen_uuid)
    path="/xhttp-$(openssl rand -hex 3)"

    jq -n --arg port "$port" --arg uid "$uid" --arg priv "$priv" --arg pbk "$pub" \
          --arg sni "www.apache.org" --arg sid "$sid" --arg path "$path" --arg rmk "XHTTP-${port}" '
        { listen: "::", port: ($port | tonumber), protocol: "vless", tag: $rmk,
          settings: { users: [ { id: $uid, level: 0, email: ($rmk + "@xraym") } ], decryption: "none" },
          streamSettings: { network: "xhttp", security: "reality",
              xhttpSettings: { path: $path, mode: "auto" },
              realitySettings: { show: false, target: ($sni + ":443"), xver: 0,
                                 serverNames: [$sni], privateKey: $priv, shortIds: [$sid] } },
          sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
          _meta: { pbk: $pbk } }
    '
}

p_gen_hysteria() {
    local port pass sni="www.apache.org"
    port=$(ask_port "监听端口" "$(def_port hysteria)" "" udp) || return 1
    pass=$(openssl rand -hex 8)
    ensure_self_cert "$sni"

    jq -n --arg port "$port" --arg pass "$pass" --arg crt "$CERTS_DIR/cert.crt" \
          --arg key "$CERTS_DIR/priv.key" --arg sni "$sni" --arg rmk "Hy2-${port}" '
        { listen: "::", port: ($port | tonumber), protocol: "hysteria", tag: $rmk,
          settings: { version: 2,
                      users: [ { auth: $pass, level: 0, email: ($rmk + "@xraym") } ] },
          streamSettings: { network: "hysteria", security: "tls",
              hysteriaSettings: { version: 2, udpIdleTimeout: 60,
                  masquerade: { type: "proxy", url: "https://www.apache.org/", rewriteHost: true } },
              tlsSettings: { certificates: [ { certificateFile: $crt, keyFile: $key } ],
                             alpn: ["h3"], serverName: $sni } },
          sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] },
          _meta: { sni: $sni } }
    '
}


p_gen_shadowsocks() {
    local port pass method="2022-blake3-aes-128-gcm"
    port=$(ask_port "监听端口" "$(def_port shadowsocks)" "" both) || return 1
    pass=$(openssl rand -base64 16 | tr -d '\n')

    jq -n --arg port "$port" --arg pass "$pass" --arg method "$method" --arg rmk "SS-${port}" '
        { listen: "::", port: ($port | tonumber), protocol: "shadowsocks", tag: $rmk,
          settings: { method: $method, password: $pass, network: "tcp,udp" },
          streamSettings: { network: "tcp" },
          sniffing: { enabled: true, destOverride: ["http", "tls"] } }
    '
}


# ── 协议编辑钩子 ────────────────────────────────────────────────────────
# p_edit_<t> <json> <idx> → 输出新 inbound JSON；回车即保持不变。

p_edit_vless() {
    local j="$1" idx="$2" port sni net path
    port=$(ask_port "监听端口" "$(n_port "$j")" "$idx" tcp) || return 1
    sni=$(jq -r '.streamSettings.realitySettings.serverNames[0] // "www.apache.org"' <<< "$j")
    sni=$(ask "伪装域名（SNI）" "$sni") || return 1
    net=$(jq -r '.streamSettings.network // "tcp"' <<< "$j")

    # XHTTP 节点额外维护路径
    if [ "$net" = "xhttp" ]; then
        path=$(jq -r '.streamSettings.xhttpSettings.path // "/xhttp"' <<< "$j")
        path=$(ask "XHTTP 路径" "$path") || return 1
        jq --arg p "$port" --arg sni "$sni" --arg path "$path" '
            .port = ($p | tonumber) |
            .tag = (.tag | sub("-[0-9]+$"; "-" + $p)) |
            .streamSettings.realitySettings.serverNames = [$sni] |
            .streamSettings.realitySettings.target = ($sni + ":443") |
            .streamSettings.xhttpSettings.path = $path
        ' <<< "$j"
        return 0
    fi

    jq --arg p "$port" --arg sni "$sni" '
        .port = ($p | tonumber) |
        .tag = (.tag | sub("-[0-9]+$"; "-" + $p)) |
        .streamSettings.realitySettings.serverNames = [$sni] |
        .streamSettings.realitySettings.target = ($sni + ":443")
    ' <<< "$j"
}

p_edit_hysteria() {
    local j="$1" idx="$2" port sni pass cur_sni cur_pass
    port=$(ask_port "监听端口" "$(n_port "$j")" "$idx" udp) || return 1
    cur_sni=$(jq -r '.streamSettings.tlsSettings.serverName // ._meta.sni // "www.apache.org"' <<< "$j")
    cur_pass=$(jq -r '.settings.users[0].auth // ""' <<< "$j")
    sni=$(ask "伪装域名（SNI）" "$cur_sni") || return 1
    pass=$(ask "认证密码" "$cur_pass") || return 1
    [ "$sni" != "$cur_sni" ] && regen_self_cert "$sni"

    jq --arg p "$port" --arg sni "$sni" --arg pass "$pass" '
        .port = ($p | tonumber) |
        .tag = (.tag | sub("-[0-9]+$"; "-" + $p)) |
        .settings.users[0].auth = $pass |
        .streamSettings.tlsSettings.serverName = $sni |
        ._meta.sni = $sni
    ' <<< "$j"
}


p_edit_shadowsocks() {
    local j="$1" idx="$2" port pass cur_pass
    port=$(ask_port "监听端口" "$(n_port "$j")" "$idx" both) || return 1
    cur_pass=$(jq -r '.settings.password // ""' <<< "$j")
    pass=$(ask "密钥密码" "$cur_pass") || return 1

    jq --arg p "$port" --arg pass "$pass" '
        .port = ($p | tonumber) |
        .tag = (.tag | sub("-[0-9]+$"; "-" + $p)) |
        .settings.password = $pass
    ' <<< "$j"
}

# ── 链接、节点表格、订阅 ──────────────────────────────────────────────

build_link() {
    local j="$1" host="$2" t link
    t=$(n_proto "$j")
    declare -F "p_info_$t" >/dev/null 2>&1 || return 0
    link=$(p_field "$("p_info_$t" "$j" "$host")" 5)
    # 带换行输出：调用方可能连续取多条链接，缺换行会粘成一行
    [ -n "$link" ] && printf '%s\n' "$link"
    return 0
}

# 一次 jq 拿全部节点（含索引），避免每行 8 次 jq 的 N+1
node_stream() {
    jq -r '.inbounds | to_entries[] | "\(.key)\t\(.value | tojson)"' "$CONF" 2>/dev/null
}

render_node_table() {
    local n
    n=$(conf_count)
    if [ "$n" -eq 0 ]; then
        printf '%b(暂无任何配置的入站节点)%b\n' "$C_DIM" "$C_RESET"
        return 0
    fi

    printf '%b%s%b\n' "$C_DIM" \
        "$(pad 序号 5)$(pad 协议 15)$(pad 端口 7)$(pad 传输 8)$(pad 别名 14)伪装目标 / 路径" "$C_RESET"
    draw_line "-" "$C_DIM"

    local idx j t info
    node_stream | while IFS=$'\t' read -r idx j; do
        [ -z "$j" ] && continue
        t=$(n_proto "$j")
        if declare -F "p_info_$t" >/dev/null 2>&1; then
            info=$("p_info_$t" "$j")
        else
            info="${t}|-|-|-|"
        fi
        printf '%b%s%b%s%b%s%b%s%s%b%s%b\n' \
            "$C_CYAN" "$(pad "$(printf '%02d' "$idx")" 5)" "$C_RESET" \
            "$(pad "$(p_field "$info" 1)" 15)" \
            "$C_YELLOW" "$(pad "$(n_port "$j")" 7)" "$C_RESET" \
            "$(pad "$(p_field "$info" 2)" 8)" \
            "$(pad "$(n_tag "$j")" 14)" \
            "$C_DIM" "$(p_field "$info" 3)" "$C_RESET"
    done
    draw_line "-" "$C_DIM"
}

print_node_card() {
    local j="$1" title="${2:-节点详细信息}" t info link4="" link6=""
    refresh_ips
    t=$(n_proto "$j")
    info=$("p_info_$t" "$j")

    printf '\n'
    draw_line "-" "$C_CYAN"
    printf '%b[%s] %s%b\n' "$C_BOLD" "$title" "$(n_tag "$j")" "$C_RESET"
    printf '协议类型: %b%s%b | 传输层: %s | 监听端口: %s\n' \
        "$C_BOLD" "$t" "$C_RESET" "$(p_field "$info" 2)" "$(n_port "$j")"
    printf '%s\n' "$(p_field "$info" 4)" | tr ';' '\n'

    [ -n "$PUB_IPV4" ] && link4=$(build_link "$j" "$PUB_IPV4")
    [ -n "$PUB_IPV6" ] && link6=$(build_link "$j" "[${PUB_IPV6}]")

    if [ -n "$link4" ]; then
        printf '\n%bIPv4 分享链接:%b\n  %b%s%b\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$link4" "$C_RESET"
        if command -v qrencode >/dev/null 2>&1; then
            printf '\n%bIPv4 二维码 (客户端扫码):%b\n' "$C_DIM" "$C_RESET"
            qrencode -t ANSIUTF8 "$link4" 2>/dev/null || true
        fi
    fi
    if [ -n "$link6" ]; then
        printf '\n%bIPv6 分享链接:%b\n  %b%s%b\n' "$C_BOLD" "$C_RESET" "$C_GREEN" "$link6" "$C_RESET"
    fi
    if [ -z "$link4" ] && [ -z "$link6" ]; then
        printf '\n%b未检测到公网 IP，以下为占位链接（请手动替换主机）:%b\n%s\n' \
            "$C_YELLOW" "$C_RESET" "$(build_link "$j" "127.0.0.1")"
    fi
    draw_line "-" "$C_CYAN"
    printf '\n'
}


# ── 核心安装 / 版本 / 证书 / 系统加速 ────────────────────────

latest_ver() {
    local tag
    tag=$(curl -fsSI -m 6 https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null \
        | awk 'BEGIN{IGNORECASE=1} /^location:/{print $2}' | tr -d '\r' | sed -n 's|.*/tag/||p' | head -n1)
    [ -z "$tag" ] && tag=$(curl -fsSL -m 6 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null || true)
    [[ "$tag" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]] && printf '%s' "$tag"
    return 0
}

check_update_async() {
    [ -x "$BIN" ] || return 0
    (
        mkdir -p "$CONF_DIR" 2>/dev/null || true
        local tag
        tag=$(latest_ver)
        [ -n "$tag" ] && printf '%s' "${tag#v}" > "$VER_CACHE" 2>/dev/null
    ) >/dev/null 2>&1 &
}

install_core() {
    local ver cur answer
    info "查询 Xray 最新版本..."
    ver=$(latest_ver)
    cur=$(cur_core_ver)

    if [ -z "$ver" ]; then
        err "获取最新版本失败 (检查网络 / CA 根证书 / GitHub 限流)"
        if [ -n "$cur" ]; then
            answer=$(ask "是否重装当前版本 ${cur}？[y/N]" "n") || return 1
            [[ "$answer" =~ ^[Yy]$ ]] && ver="$cur" || return 1
        else
            return 1
        fi
    elif [ -n "$cur" ] && [ "${cur#v}" = "${ver#v}" ]; then
        ok "当前已是最新版本 (${cur})"
        answer=$(ask "是否强制重新下载覆盖？[y/N]" "n") || return 1
        [[ "$answer" =~ ^[Yy]$ ]] || return 0
    fi

    local name="Xray-linux-${ARCH}.zip"
    local base="${XRAY_DL_MIRROR:-https://github.com/XTLS/Xray-core/releases/download}"
    local url="${base}/${ver}/${name}"
    info "下载核心包: ${ver} (${ARCH})"

    local tmp
    mk_tmp_dir || { err "创建临时目录失败"; return 1; }
    tmp="$MK_TMP_DIR"
    if ! curl -fsSL --retry 2 -m 180 "$url" -o "$tmp/x.zip"; then
        err "核心下载失败: ${url}"; return 1
    fi
    if ! unzip -tq "$tmp/x.zip" >/dev/null 2>&1; then
        err "核心包损坏 (zip 完整性校验失败)"; return 1
    fi
    unzip -qo "$tmp/x.zip" -d "$tmp" 2>/dev/null || { err "解压失败"; return 1; }
    [ -f "$tmp/xray" ] || { err "核心包内未找到 xray 可执行文件"; return 1; }
    chmod +x "$tmp/xray" 2>/dev/null
    if ! "$tmp/xray" version >/dev/null 2>&1; then
        err "下载的核心无法在本机运行 (架构不匹配或文件损坏)"; return 1
    fi

    local was_running=false
    is_running && was_running=true
    svc_stop >/dev/null 2>&1 || true

    mkdir -p "$ASSET_DIR" 2>/dev/null || true
    install -m 755 "$tmp/xray" "$BIN" || { err "安装核心失败"; return 1; }
    [ -f "$tmp/geoip.dat" ]   && install -m 644 "$tmp/geoip.dat"   "$ASSET_DIR/" 2>/dev/null
    [ -f "$tmp/geosite.dat" ] && install -m 644 "$tmp/geosite.dat" "$ASSET_DIR/" 2>/dev/null

    init_env
    svc_install
    printf '%s' "${ver#v}" > "$VER_CACHE" 2>/dev/null || true
    [ "$was_running" = "true" ] && svc_start >/dev/null 2>&1
    ok "Xray 核心已就绪 (${ver})"
    return 0
}

# ── 自签证书 ──────────────────────────────────────────────────────────
ensure_self_cert() {
    local domain="${1:-www.apache.org}" crt="$CERTS_DIR/cert.crt" key="$CERTS_DIR/priv.key"
    mkdir -p "$CERTS_DIR" 2>/dev/null || true
    if [ ! -s "$crt" ] || [ ! -s "$key" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -sha256 -days 3650 \
            -keyout "$key" -out "$crt" -subj "/CN=${domain}" >/dev/null 2>&1
        chmod 600 "$key" "$crt" 2>/dev/null || true
        chown -R xray:xray "$CERTS_DIR" 2>/dev/null || true
    fi
}

# 改 SNI 时必须重签，否则证书 CN 与 SNI 不符
regen_self_cert() {
    local domain="${1:-www.apache.org}"
    mkdir -p "$CERTS_DIR" 2>/dev/null || true
    rm -f "$CERTS_DIR/cert.crt" "$CERTS_DIR/priv.key" 2>/dev/null || true
    ensure_self_cert "$domain"
}

cert_info() {
    local crt="$CERTS_DIR/cert.crt"
    [ -s "$crt" ] || { warn "未发现自签证书"; return 0; }
    printf '%b证书信息%b\n' "$C_BOLD" "$C_RESET"
    openssl x509 -in "$crt" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
}

# ── BBR ────────────────────────────────────────────────────────────
enable_bbr() {
    if ! sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -qw "bbr"; then
        printf '%s\n' "net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr" \
            > /etc/sysctl.d/99-bbr.conf 2>/dev/null || true
        sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true
    fi
    local cur
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '关闭')
    if [[ "$cur" == *"bbr"* ]]; then ok "BBR 拥塞控制: ${C_GREEN}开启${C_RESET}"
    else warn "BBR: 未开启或内核未加载模块"; fi
}

# ── 快捷命令 ──────────────────────────────────────────────────────────
setup_shortcut() {
    local src="${BASH_SOURCE[0]}" real_src="" target="$SHORTCUT"
    mkdir -p /usr/local/bin 2>/dev/null || true
    [ -n "$src" ] && real_src=$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")

    if [ "$real_src" = "$target" ]; then
        chmod +x "$target" 2>/dev/null || true
        return 0
    fi

    case "$real_src" in
        /dev/fd/*|/proc/*) ;;
        *)
            if [ -n "$real_src" ] && [ -f "$real_src" ]; then
                cp -f "$real_src" "${target}.tmp" 2>/dev/null \
                    && mv -f "${target}.tmp" "$target" 2>/dev/null \
                    && chmod +x "$target" 2>/dev/null
                return 0
            fi
            ;;
    esac

    # 管道运行且本地尚无快捷命令：只从显式来源拉取，不再从 bash_history 猜 URL
    if [ ! -s "$target" ]; then
        local u
        for u in "${XRAY_SOURCE_URL:-https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh}" \
                 "https://raw.gitmirror.com/xpeb/vps-tools/main/xray.sh"; do
            if curl -fsSL -m 8 "$u" -o "${target}.tmp" 2>/dev/null && bash -n "${target}.tmp" 2>/dev/null; then
                mv -f "${target}.tmp" "$target" 2>/dev/null
                chmod +x "$target" 2>/dev/null || true
                ok "已自动配置快捷命令: ${C_BOLD}xraym${C_RESET}"
                return 0
            fi
            rm -f "${target}.tmp" 2>/dev/null
        done
    fi
    return 0
}
# ── 节点增删改查：菜单只是入口，真正的逻辑都在协议钩子里 ──────────────

pick_proto() {
    # 展示内容必须走 stderr：本函数的 stdout 会被 $(...) 捕获
    {
        printf '\n%b添加节点 - 选择协议%b\n' "$C_BOLD" "$C_RESET"
        draw_line "-"
        local i=1 t
        for t in "${PROTOS[@]}"; do
            printf '%b%d.%b %s\n' "$C_CYAN" "$i" "$C_RESET" "${P_LABEL[$t]}"
            i=$((i + 1))
        done
        printf '%b0. 返回菜单%b\n' "$C_DIM" "$C_RESET"
        draw_line "-"
    } >&2

    local c
    c=$(ask "请选择" "0") || return 1
    case "$c" in 0|'') return 1 ;; esac
    if [[ ! "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt "${#PROTOS[@]}" ]; then
        err "无效选择"; sleep 1; return 1
    fi
    printf '%s' "${PROTOS[$((c - 1))]}"
}

add_node() {
    [ -x "$BIN" ] || { err "请先安装 Xray 核心（菜单 6）"; sleep 1.2; return 1; }
    init_env

    local t inb
    t=$(pick_proto) || return 0
    inb=$("p_gen_$t") || { info "已取消"; return 1; }
    [ -z "$inb" ] && { err "生成节点配置失败"; return 1; }

    conf_mutate '.inbounds += [$inb]' --argjson inb "$inb" || return 1
    print_node_card "$inb" "节点添加成功"
    pause_tip
}

edit_node() {
    conf_exists || { err "配置文件不存在"; sleep 1; return 1; }
    local n
    n=$(conf_count)
    [ "$n" -eq 0 ] && { info "当前暂无配置节点可修改"; sleep 1; return 0; }

    printf '\n%b修改节点%b\n' "$C_BOLD" "$C_RESET"
    render_node_table
    printf '\n'

    local sel
    sel=$(ask "输入节点序号（回车返回）" "") || return 0
    [ -z "$sel" ] && return 0
    [[ "$sel" =~ ^[0-9]+$ ]] || { err "序号须为纯数字"; sleep 1; return 1; }

    local j
    j=$(conf_node "$sel")
    [ -z "$j" ] && { err "序号不存在"; sleep 1; return 1; }

    local t
    t=$(n_proto "$j")
    if ! declare -F "p_edit_$t" >/dev/null 2>&1; then
        err "协议 ${t} 暂不支持在线修改"; sleep 1; return 1
    fi

    info "修改节点 [${sel}] ${P_LABEL[$t]:-$t} (直接回车保持不变)"
    local new
    new=$("p_edit_$t" "$j" "$sel") || { info "已取消"; return 1; }
    [ -z "$new" ] && { err "生成新配置失败"; return 1; }

    if conf_mutate '.inbounds[$i] = $inb' --argjson i "$sel" --argjson inb "$new"; then
        ok "节点 [${sel}] 配置已更新生效"
        sleep 1
    fi
}

delete_node() {
    conf_exists || { err "配置文件不存在"; sleep 1; return 1; }
    local n
    n=$(conf_count)
    [ "$n" -eq 0 ] && { info "当前暂无配置节点可删除"; sleep 1; return 0; }

    printf '\n%b删除节点%b\n' "$C_BOLD" "$C_RESET"
    render_node_table
    printf '\n'

    local sel
    sel=$(ask "输入节点序号（回车返回）" "") || return 0
    [ -z "$sel" ] && return 0
    [[ "$sel" =~ ^[0-9]+$ ]] || { err "序号须为纯数字"; sleep 1; return 1; }

    local tag
    tag=$(jq -r --argjson i "$sel" '.inbounds[$i].tag // empty' "$CONF" 2>/dev/null)
    [ -z "$tag" ] && { err "序号不存在"; sleep 1; return 1; }

    local answer
    answer=$(ask "确认删除节点 ${sel}（${tag}）？[y/N]" "n") || return 0
    [[ "$answer" =~ ^[Yy]$ ]] || { info "已取消删除"; sleep 0.8; return 0; }

    if conf_mutate 'del(.inbounds[$i])' --argjson i "$sel"; then
        ok "节点 [${sel}] (${tag}) 已删除"
        sleep 1
    fi
}

show_nodes() {
    conf_exists || { err "配置文件不存在"; sleep 1; return 1; }
    local n
    n=$(conf_count)
    [ "$n" -eq 0 ] && { info "当前暂无配置节点"; sleep 1; return 0; }

    printf '\n%b[节点列表] 共 %s 个节点%b\n' "$C_BOLD" "$n" "$C_RESET"
    render_node_table
    printf '\n'

    local opt
    opt=$(ask "输入序号查看链接（回车返回）" "") || return 0
    [ -z "$opt" ] && return 0

    if [[ "$opt" =~ ^[0-9]+$ ]] && [ "$opt" -lt "$n" ]; then
        local j
        j=$(conf_node "$opt")
        if [ -n "$j" ]; then
            print_node_card "$j" "节点详细信息"
            pause_tip
        fi
    else
        err "无效序号: ${opt}"
        sleep 1
    fi
}
# ── 服务菜单 / 卸载 ──────────────────────────────────────

svc_log() {
    trap ':' INT
    if [ -f /var/log/xray/error.log ]; then
        info "Ctrl+C 退出日志监控"
        tail -n 40 -f /var/log/xray/error.log
    elif command -v journalctl >/dev/null 2>&1; then
        info "Ctrl+C 退出日志监控"
        journalctl -u "$SVC_NAME" -f -n 40
    else
        warn "未发现日志文件"; sleep 1
    fi
    trap 'cleanup_tmp; exit 130' INT
}

manage_service() {
    cls
    local st
    if is_running; then st="${C_GREEN}[运行中]${C_RESET}"; else st="${C_RED}[已停止]${C_RESET}"; fi

    printf '%b服务管理%b  %b\n' "$C_BOLD" "$C_RESET" "$st"
    draw_line "-"
    printf '%b1.%b 重启服务\n' "$C_CYAN" "$C_RESET"
    printf '%b2.%b 停止服务\n' "$C_CYAN" "$C_RESET"
    printf '%b3.%b 启动服务\n' "$C_CYAN" "$C_RESET"
    printf '%b4.%b 实时日志\n' "$C_CYAN" "$C_RESET"
    printf '%b5.%b 证书信息\n' "$C_CYAN" "$C_RESET"
    printf '%b0. 返回菜单%b\n' "$C_DIM" "$C_RESET"
    draw_line "-"

    local c
    c=$(ask "请选择操作" "0") || return 0
    case "$c" in
        1) if svc_restart_verify "$(svc_pid)"; then ok "服务已重启"; else err "重启失败，请查看日志"; fi; sleep 0.8 ;;
        2) if svc_stop; then ok "服务已停止"; else err "停止失败"; fi; sleep 0.8 ;;
        3) if svc_start; then ok "服务已启动"; else err "启动失败，请检查端口与日志"; fi; sleep 0.8 ;;
        4) svc_log ;;
        5) cls; cert_info; printf '\n'; pause_tip ;;
        *) return 0 ;;
    esac
}

uninstall_xray() {
    local answer
    answer=$(ask "确定彻底卸载？将删除 Xray、证书与全部配置，不可恢复 [y/N]" "n") || return 0
    [[ "$answer" =~ ^[Yy]$ ]] || { info "已取消卸载"; return 0; }

    info "停止服务并清理进程..."
    svc_stop >/dev/null 2>&1 || true
    pkill -9 -u xray >/dev/null 2>&1 || true
    pkill -9 -x xray >/dev/null 2>&1 || true

    info "注销系统服务守护..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable "$SVC_NAME" >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/xray.service
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed >/dev/null 2>&1 || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
        rc-update del "$SVC_NAME" default >/dev/null 2>&1 || true
        rm -f /etc/init.d/xray
    fi

    info "清理文件目录..."
    rm -rf "$BIN" "$SHORTCUT" "$CONF_DIR" "$ASSET_DIR" /var/log/xray /run/xray.pid
    userdel -r xray >/dev/null 2>&1 || deluser xray >/dev/null 2>&1 || true

    ok "Xray 环境已彻底卸载清除"
    exit 0
}

# ── 看板 ──────────────────────────────────────────────────────────────
menu_header() {
    local ver st upd="" node_cnt bbr bbr_badge ip_summary
    ver=$(cur_core_ver)
    [ -z "$ver" ] && ver="未安装"
    __VER="$ver"

    if is_running; then st="${C_GREEN}[运行中]${C_RESET}"; else st="${C_RED}[已停止]${C_RESET}"; fi

    if [ "$ver" != "未安装" ] && [ -f "$VER_CACHE" ]; then
        local lv
        lv=$(tr -d ' \r\n' < "$VER_CACHE" 2>/dev/null || true)
        if [ -n "$lv" ] && [ "${ver#v}" != "${lv#v}" ]; then
            upd=" ${C_YELLOW}(可更新: v${lv#v})${C_RESET}"
        fi
    fi

    node_cnt=$(conf_count)
    __NODE_CNT="$node_cnt"
    bbr=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf '关闭')
    if [[ "$bbr" == *"bbr"* ]]; then bbr_badge="${C_GREEN}开启${C_RESET}"
    else bbr_badge="${C_DIM}${bbr}${C_RESET}"; fi

    if [ -n "$PUB_IPV4" ] && [ -n "$PUB_IPV6" ]; then
        ip_summary="IPv4: ${PUB_IPV4} | IPv6: $(short_ip "$PUB_IPV6")"
    elif [ -n "$PUB_IPV4" ]; then
        ip_summary="IPv4: ${PUB_IPV4}"
    elif [ -n "$PUB_IPV6" ]; then
        ip_summary="IPv6: $(short_ip "$PUB_IPV6")"
    else
        ip_summary="${C_DIM}离线/局域网${C_RESET}"
    fi

    printf '%bXray Core%b %b%s%b' "$C_BOLD" "$C_RESET" "$C_CYAN" "$ver" "$C_RESET"
    printf '%b' "$upd"
    printf ' %b | BBR: %b\n' "$st" "$bbr_badge"
    printf '节点: %s 个 | 网络: %b\n' "$node_cnt" "$ip_summary"
}

menu_body() {
    local ver="${__VER:-}"
    [ -z "$ver" ] && { ver=$(cur_core_ver); [ -z "$ver" ] && ver="未安装"; }

    printf '%b[节点配置]%b\n' "$C_BOLD" "$C_RESET"
    printf '%b1.%b 节点列表 %b(%s)%b\n' "$C_CYAN" "$C_RESET" "$C_DIM" "${__NODE_CNT:-0}" "$C_RESET"
    printf '%b2.%b 添加节点\n' "$C_CYAN" "$C_RESET"
    printf '%b3.%b 修改节点\n' "$C_CYAN" "$C_RESET"
    printf '%b4.%b 删除节点\n' "$C_CYAN" "$C_RESET"
    printf '\n%b[服务与系统]%b\n' "$C_BOLD" "$C_RESET"
    printf '%b5.%b 服务管理\n' "$C_CYAN" "$C_RESET"
    printf '%b6.%b 安装 / 更新核心\n' "$C_CYAN" "$C_RESET"
    printf '%b7.%b BBR 加速\n' "$C_CYAN" "$C_RESET"
    printf '%b8.%b 彻底卸载\n' "$C_RED" "$C_RESET"
    printf '\n%b0. 退出%b\n' "$C_DIM" "$C_RESET"
}

main_menu() {
    # curl | bash：脚本已从 stdin 读完，此刻可把 stdin 换成终端接管键盘
    if [ -z "${BASH_SOURCE[0]}" ] && [ ! -t 0 ]; then
        { exec < /dev/tty; } 2>/dev/null || true
    fi
    check_deps || { err "环境依赖缺失，终止"; exit 1; }
    setup_shortcut
    refresh_ips
    check_update_async
    conf_migrate

    local c
    while true; do
        cls
        menu_header
        draw_line "-"
        menu_body
        draw_line "-"

        if ! c=$(ask "请选择操作" "0"); then
            cls
            printf '\n%b[提示]%b 已退出 Xray 管理面板\n\n' "$C_CYAN" "$C_RESET"
            exit 0
        fi

        case "$c" in
            1) show_nodes ;;
            2) add_node ;;
            3) edit_node ;;
            4) delete_node ;;
            5) manage_service ;;
            6) install_core ;;
            7) enable_bbr; sleep 1 ;;
            8) uninstall_xray ;;
            0|q|quit)
                cls
                printf '\n%b[提示]%b 已退出 Xray 管理面板\n\n' "$C_CYAN" "$C_RESET"
                exit 0 ;;
            *) err "请输入有效选项 [0-8]"; sleep 0.6 ;;
        esac
    done
}
# ── 入口：仅在被直接执行时启动；被 source 时不动作（方便测试） ───
# 直接执行时 BASH_SOURCE[0] 等于 $0；curl | bash 时 BASH_SOURCE[0] 为空。
# 被 source 时两者不同且 BASH_SOURCE[0] 非空 —— 那种情况不启动菜单。
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${BASH_SOURCE[0]}" ]; then
    main_menu "$@"
fi
