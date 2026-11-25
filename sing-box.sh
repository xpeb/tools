#!/usr/bin/env bash
# sing-box 极简交互式面板（支持 Debian / Alpine）
# 协议：VLESS (Reality) / Hysteria2 / AnyTLS / Snell (v5/v6) / Shadowsocks / SOCKS

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

_init_locale() {
  local t="中" l orig_all=${LC_ALL:-} orig_ctype=${LC_CTYPE:-}
  ((${#t} == 1)) && return 0
  unset LC_ALL
  for l in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    LC_CTYPE=$l
    ((${#t} == 1)) && {
      export LC_CTYPE
      return 0
    }
  done
  [[ -n $orig_all ]] && export LC_ALL=$orig_all
  [[ -n $orig_ctype ]] && export LC_CTYPE=$orig_ctype
}
_init_locale

SB_BIN=/usr/local/bin/sing-box
SB_DIR=/etc/sing-box
CONF=$SB_DIR/config.json
NODES=$SB_DIR/nodes.json
CERT_DIR=$SB_DIR/cert
SB_LOG=/var/log/sing-box.log
MIN_VER=1.14.0
DEFAULT_SNI=www.apache.org

# ───────── UI 与交互基础 ─────────
B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
HR='────────────────────────────────────────────'

hr() { printf '%s%s%s\n' "$D" "$HR" "$N"; }
ok() { printf '%s✓%s %s\n' "$G" "$N" "$*"; }
err() { printf '%s✗%s %s\n' "$R" "$N" "$*"; }
warn() { printf '%s!%s %s\n' "$Y" "$N" "$*"; }
note() { printf '%si%s %s\n' "$C" "$N" "$*"; }
info() { printf '%s·%s %s\n' "$D" "$N" "$*"; }

pause() {
  printf '%s按回车键返回…%s' "$D" "$N"
  read -rs _ || return 1
  echo
}

ask() { # $1=提示 $2=默认值(可选) -> REPLY
  local v
  read -rp "$1${2:+ [$2]}: " v || return 1
  REPLY=${v:-${2:-}}
}

confirm() { # $1=提示
  local v
  read -rp "$1 [y/N]: " v || return 1
  [[ $v =~ ^[Yy]$ ]]
}

title() { # $1=标题 $2=右侧状态后缀(可选)
  header
  printf '%s▸%s %s%s%s%s\n\n' "$C" "$N" "$B" "$1" "$N" "${2:+  $2}"
}

_pad_left() { # $1=text(ASCII/CJK) $2=display_width
  local s=$1 target=$2 chars bytes w
  chars=${#s}
  bytes=$(printf '%s' "$s" | wc -c)
  w=$((chars + (bytes - chars) / 2))
  printf '%s' "$s"
  ((w < target)) && printf '%*s' $((target - w)) ''
}

# ───────── 环境预检与运行锁 ─────────
[[ $EUID -ne 0 ]] && {
  echo "请使用 root 权限运行此脚本"
  exit 1
}
if command -v apt-get >/dev/null && command -v systemctl >/dev/null; then
  OS=debian
elif command -v apk >/dev/null && command -v rc-service >/dev/null; then
  OS=alpine
else
  echo "仅支持 Debian (systemd) 或 Alpine (OpenRC)"
  exit 1
fi
if [[ ! -t 0 ]]; then
  if [[ -r /dev/tty ]]; then
    exec </dev/tty
  else
    echo "请在交互式终端中运行此脚本"
    exit 1
  fi
fi

RUN_TMP=$(mktemp -d -t sb-panel.XXXXXX) || {
  echo "创建临时目录失败"
  exit 1
}
LOCK_OPEN=0
DEPS_DONE=0

release_lock() {
  if ((LOCK_OPEN == 1)); then
    exec 9>&- 2>/dev/null || true
    LOCK_OPEN=0
  fi
}

cleanup() {
  release_lock
  [[ -n $RUN_TMP ]] && rm -rf "$RUN_TMP"
  rm -f "$SB_DIR"/.tmp.* 2>/dev/null || true
}
trap cleanup EXIT
trap 'echo; exit 130' INT TERM HUP

acquire_lock() {
  command -v flock >/dev/null || ensure_deps
  mkdir -p "$SB_DIR" && chmod 700 "$SB_DIR"
  local lf="$SB_DIR/.panel.lock"
  if [[ -d $lf ]]; then
    local old_pid
    old_pid=$(cat "$lf/pid" 2>/dev/null || true)
    if [[ -n $old_pid ]] && kill -0 "$old_pid" 2>/dev/null; then
      err "已有另一个面板实例正在运行 (PID: $old_pid)"
      exit 1
    fi
    rm -rf "$lf" 2>/dev/null || true
  fi
  exec 9>>"$lf" || {
    err "无法打开运行锁文件"
    exit 1
  }
  if ! flock -n 9; then
    local pid
    pid=$(cat "$lf" 2>/dev/null || true)
    err "已有另一个面板实例正在运行${pid:+ (PID: $pid)}"
    exec 9>&- 2>/dev/null || true
    exit 1
  fi
  LOCK_OPEN=1
  chmod 600 "$lf" 2>/dev/null || true
  printf '%s\n' "$$" >"$lf" 2>/dev/null || true
}

nodes_count() {
  local n
  n=$(jq -er 'if type == "array" then length else error("not array") end' "$NODES" 2>/dev/null) || return 1
  [[ $n =~ ^[0-9]+$ ]] && printf '%s\n' "$n"
}

init_dirs() {
  mkdir -p "$SB_DIR" "$CERT_DIR" && chmod 700 "$SB_DIR" "$CERT_DIR"
  if [[ ! -f $NODES ]]; then
    if [[ -s $CONF ]]; then
      local bak="$CONF.bak.$(date +%Y%m%d%H%M%S)"
      cp -a "$CONF" "$bak"
      warn "检测到已有非面板管理的 config.json，已备份至：$bak"
      confirm "是否初始化空节点列表并由面板接管配置？" || exit 0
    fi
    echo '[]' >"$NODES"
    chmod 600 "$NODES"
  elif ! nodes_count >/dev/null; then
    err "节点数据文件 $NODES 格式已损坏，请检查修复后再运行"
    exit 1
  fi
}

# ───────── 依赖、系统服务与网络探测 ─────────
ensure_deps() {
  ((DEPS_DONE == 1)) && return 0
  local pk=() c
  for c in curl jq openssl tar ss flock; do
    command -v "$c" >/dev/null && continue
    case $c in
      ss) pk+=(iproute2) ;;
      flock) pk+=(util-linux) ;;
      *) pk+=("$c") ;;
    esac
  done
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || pk+=(ca-certificates)
  if ((${#pk[@]} > 0)); then
    info "正在安装缺少的依赖：${pk[*]} ..."
    if [[ $OS == debian ]]; then
      apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq "${pk[@]}" >/dev/null 2>&1
    else
      apk add --no-cache "${pk[@]}" >/dev/null 2>&1
    fi || {
      err "依赖安装失败，请检查软件源或网络连接"
      exit 1
    }
  fi
  DEPS_DONE=1
}

svc_exists() {
  [[ $OS == debian && -f /etc/systemd/system/sing-box.service ]] || [[ $OS == alpine && -f /etc/init.d/sing-box ]]
}

svc_install() {
  if [[ $OS == debian ]]; then
    cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box
After=network.target nss-lookup.target

[Service]
ExecStart=$SB_BIN run -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  else
    cat >/etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
command="$SB_BIN"
command_args="run -c $CONF"
supervisor="supervise-daemon"
pidfile="/run/sing-box.pid"
output_log="$SB_LOG"
error_log="$SB_LOG"
rc_ulimit="-n 1048576"

depend() {
  need net
  after firewall
}

start_pre() {
  touch "$SB_LOG" && chmod 600 "$SB_LOG"
}
EOF
    chmod +x /etc/init.d/sing-box
  fi
}

svc_ctl() { # start|restart|stop|enable|disable|is-active|is-enabled
  if [[ $OS == debian ]]; then
    case $1 in
      is-active) systemctl is-active --quiet sing-box ;;
      is-enabled) systemctl is-enabled --quiet sing-box ;;
      *) systemctl "$1" sing-box >/dev/null 2>&1 ;;
    esac
  else
    case $1 in
      start | restart | stop) rc-service sing-box "$1" >/dev/null 2>&1 ;;
      enable) rc-update add sing-box default >/dev/null 2>&1 ;;
      disable) rc-update del sing-box default >/dev/null 2>&1 ;;
      is-active) rc-service sing-box status >/dev/null 2>&1 ;;
      is-enabled) rc-update show default 2>/dev/null | grep -qw sing-box ;;
    esac
  fi
}

svc_logs() {
  local lines=${1:-40} out=""
  if [[ $OS == debian ]]; then
    out=$(journalctl -u sing-box -n "$lines" --no-pager -o cat 2>/dev/null)
  elif [[ -f $SB_LOG ]]; then
    out=$(tail -n "$lines" "$SB_LOG" 2>/dev/null)
  fi
  if [[ -n $out ]]; then
    printf '%s\n' "$out"
  else
    info "暂无运行日志"
  fi
}

_valid_ipv4() {
  local ip=$1 o1 o2 o3 o4
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  o1=${BASH_REMATCH[1]} o2=${BASH_REMATCH[2]} o3=${BASH_REMATCH[3]} o4=${BASH_REMATCH[4]}
  ((10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255))
}

_valid_ipv6() {
  local ip=$1
  [[ -n $ip && $ip =~ ^[0-9a-fA-F:.]+$ && $ip == *:* ]] || return 1
  [[ $ip =~ ^[:0]+$ || $ip == *:::* ]] && return 1
  local tmp=${ip#*::}
  [[ $tmp == "$ip" || $tmp != *::* ]] || return 1
  [[ ($ip == :* && $ip != ::*) || ($ip == *: && $ip != *::) ]] && return 1

  local has_dc=0 left=$ip right=""
  if [[ $ip == *::* ]]; then
    has_dc=1
    left=${ip%%::*}
    right=${ip#*::}
  fi

  local -a parts=() lp=() rp=()
  local IFS=:
  [[ -n $left ]] && { read -ra lp <<<"$left"; parts+=("${lp[@]}"); }
  [[ -n $right ]] && { read -ra rp <<<"$right"; parts+=("${rp[@]}"); }

  local count=0 i n=${#parts[@]} seg
  for ((i = 0; i < n; i++)); do
    seg=${parts[i]}
    if [[ $seg == *.* ]]; then
      ((i == n - 1)) || return 1
      ((has_dc == 1)) && [[ -z $right ]] && return 1
      _valid_ipv4 "$seg" || return 1
      ((count += 2))
    else
      [[ $seg =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
      ((count += 1))
    fi
  done
  ((has_dc == 1 ? count < 8 : count == 8))
}

_fetch_ip() { # $1=-4|-6
  local ip u
  for u in "https://api${1#-}.ipify.org" "https://ip.sb" "https://ifconfig.me"; do
    ip=$(curl -fsS "$1" -m 3 "$u" 2>/dev/null | tr -d '[:space:]') || continue
    if [[ ($1 == -4 && $(_valid_ipv4 "$ip" && echo 1)) || ($1 == -6 && $(_valid_ipv6 "$ip" && echo 1)) ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
}

detect_ips() {
  [[ -n ${IP_DETECTED:-} ]] && return
  _fetch_ip -4 >"$RUN_TMP/ip4" &
  _fetch_ip -6 >"$RUN_TMP/ip6" &
  wait
  [[ -s $RUN_TMP/ip4 ]] && PUBIP4=$(<"$RUN_TMP/ip4") || PUBIP4=""
  [[ -s $RUN_TMP/ip6 ]] && PUBIP6=$(<"$RUN_TMP/ip6") || PUBIP6=""
  [[ -n $PUBIP4 || -n $PUBIP6 ]] && IP_DETECTED=1
}

listen_addr() { grep -q . /proc/net/if_inet6 2>/dev/null && echo "::" || echo "0.0.0.0"; }

tfo_enabled() {
  local v
  v=$(cat /proc/sys/net/ipv4/tcp_fastopen 2>/dev/null || echo 0)
  [[ $v =~ ^[0-9]+$ ]] && (((10#$v & 2) != 0)) && echo true || echo false
}

# ───────── 内核管理 ─────────
sb_installed() { [[ -x $SB_BIN ]]; }
sb_version() { sb_installed && "$SB_BIN" version 2>/dev/null | awk 'NR==1{print $3}'; }

ver_ge() { # $1 >= $2 (strict numeric semver, prerelease < release)
  local a=$1 b=$2 a_pre=0 b_pre=0
  [[ $a == *-* ]] && { a_pre=1; a=${a%%-*}; }
  [[ $b == *-* ]] && { b_pre=1; b=${b%%-*}; }
  [[ $a =~ ^[0-9]+(\.[0-9]+)*$ && $b =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 1
  local IFS=.
  local -a va vb
  read -ra va <<<"$a"
  read -ra vb <<<"$b"
  local i max=$((${#va[@]} > ${#vb[@]} ? ${#va[@]} : ${#vb[@]}))
  for ((i = 0; i < max; i++)); do
    local x=${va[i]:-0} y=${vb[i]:-0}
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  ((a_pre <= b_pre))
}

core_ok() {
  local v
  v=$(sb_version)
  [[ -n $v ]] && ver_ge "$v" "$MIN_VER"
}

_latest_sb_ver() {
  local loc v
  loc=$(curl -fsSL -m 10 -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)
  v=${loc##*/}
  v=${v#v}
  if [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
    printf '%s\n' "$v"
    return 0
  fi
  v=$(curl -fsSL -m 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] && printf '%s\n' "$v"
}

_verify_sha256() { # $1=file $2=expected_hex
  local got=""
  if command -v sha256sum >/dev/null; then
    got=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
  elif command -v openssl >/dev/null; then
    got=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}')
  else
    return 1
  fi
  [[ -n $got && ${got,,} == "${2,,}" ]]
}

install_singbox() {
  local arch ver tmp cur_v pkg_name url prev_bin=""
  case $(uname -m) in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7l) arch=armv7 ;;
    i386 | i686) arch=386 ;;
    *)
      err "不支持的 CPU 架构：$(uname -m)"
      return 1
      ;;
  esac
  cur_v=$(sb_version || true)
  info "正在查询最新版本..."
  ver=$(_latest_sb_ver || true)
  if [[ -z $ver ]]; then
    err "获取最新版本失败，请检查网络"
    if [[ -n $cur_v ]] && core_ok; then
      info "保留当前版本 v$cur_v"
      return 1
    fi
    confirm "是否改用最低支持版本 v$MIN_VER 安装？" || return 1
    ver=$MIN_VER
  elif sb_installed && [[ $cur_v == "$ver" ]]; then
    ok "当前已是最新版本 v$ver"
    confirm "是否强制重新安装？" || return 1
  fi

  pkg_name="sing-box-$ver-linux-$arch.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v$ver/$pkg_name"
  tmp=$(mktemp -d "$RUN_TMP"/dl.XXXXXX)
  info "正在下载 sing-box v$ver ($arch) ..."
  if ! curl -fsSL --connect-timeout 15 -m 120 -o "$tmp/sb.tgz" "$url" 2>/dev/null; then
    err "下载安装包失败"
    rm -rf "$tmp"
    return 1
  fi

  local expected=""
  if curl -fsSL --connect-timeout 10 -m 15 -o "$tmp/checksums.txt" \
    "https://github.com/SagerNet/sing-box/releases/download/v$ver/checksums.txt" 2>/dev/null; then
    expected=$(awk -v f="$pkg_name" '{sub(/^(\*|\.\/)/, "", $2); if ($2==f) {print $1; exit}}' "$tmp/checksums.txt")
  fi
  if [[ -n $expected ]]; then
    if ! _verify_sha256 "$tmp/sb.tgz" "$expected"; then
      err "安装包 SHA256 校验未通过，已中止安装"
      rm -rf "$tmp"
      return 1
    fi
  else
    warn "未获取到官方 SHA256 校验值，无法验证安装包完整性"
    if ! confirm "是否仍继续安装？"; then
      rm -rf "$tmp"
      return 1
    fi
  fi

  if sb_installed; then
    prev_bin="$tmp/sing-box.prev"
    cp -a "$SB_BIN" "$prev_bin" 2>/dev/null || prev_bin=""
  fi
  if ! tar -xzf "$tmp/sb.tgz" -C "$tmp" 2>/dev/null || ! install -m755 "$tmp"/sing-box-*/sing-box "$SB_BIN" 2>/dev/null; then
    err "解压或安装二进制文件失败"
    [[ -n $prev_bin && -x $prev_bin ]] && cp -a "$prev_bin" "$SB_BIN" 2>/dev/null || true
    rm -rf "$tmp"
    return 1
  fi
  local v
  v=$(sb_version)
  if [[ -z $v ]]; then
    err "安装后无法正常运行，请检查系统兼容性"
    if [[ -n $prev_bin && -x $prev_bin ]]; then
      cp -a "$prev_bin" "$SB_BIN" 2>/dev/null || true
      warn "已自动回滚至原有内核"
    fi
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  svc_install
  ok "sing-box v$v 已就绪"
}

update_core() {
  title "更新内核"
  local prev_bin="$RUN_TMP/sing-box.prev"
  rm -f "$prev_bin"
  sb_installed && cp -a "$SB_BIN" "$prev_bin" 2>/dev/null || true
  if install_singbox; then
    if apply; then
      rm -f "$prev_bin"
      sleep 0.6
      return 0
    fi
    if [[ -x $prev_bin ]]; then
      cp -a "$prev_bin" "$SB_BIN" 2>/dev/null || true
      warn "新内核与当前配置不兼容，已回滚至旧版本"
      apply >/dev/null 2>&1 || true
    fi
  fi
  echo
  pause || true
}

# ───────── 配置生成与生效 ─────────
gen_config() {
  local la tfo out_file=$1
  la=$(listen_addr)
  tfo=$(tfo_enabled)
  jq --arg la "$la" --argjson tfo "$tfo" '{
    log: {level: "warn", timestamp: true},
    dns: {
      servers: [{type: "local", tag: "local"}]
    },
    inbounds: [ .[] |
      if .type == "socks" then
        {type: "socks", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true, tcp_fast_open: $tfo,
         users: [{username: .user, password: .pass}]}
      elif .type == "shadowsocks" then
        {type: "shadowsocks", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true, tcp_fast_open: $tfo,
         method: .method, password: .password}
      elif .type == "hysteria2" then
        {type: "hysteria2", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true,
         users: [{name: .tag, password: .password}],
         tls: {enabled: true, server_name: .sni, alpn: ["h3"], certificate_path: .cert, key_path: .key}}
        + (if (.obfs // "") != "" then
            {obfs: {type: (if (.obfs_type // "") == "" then "salamander" else .obfs_type end), password: .obfs}}
           else {} end)
      elif .type == "vless" then
        {type: "vless", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true, tcp_fast_open: $tfo,
         users: [{name: .tag, uuid: .uuid, flow: "xtls-rprx-vision"}],
         tls: {enabled: true, server_name: .sni,
               reality: {enabled: true, handshake: {server: .sni, server_port: 443},
                         private_key: .priv, short_id: [.sid], max_time_difference: "1m"}}}
      elif .type == "anytls" then
        {type: "anytls", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true, tcp_fast_open: $tfo,
         users: [{name: .tag, password: .password}],
         tls: {enabled: true, server_name: .sni, min_version: "1.2", certificate_path: .cert, key_path: .key}}
      elif .type == "snell" then
        {type: "snell", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true, tcp_fast_open: $tfo,
         version: .version, psk: .psk}
        + (if .version == 6 then {mode: (.mode // "default")} else {obfs_mode: (.obfs // "none")} end)
      else empty end
    ],
    outbounds: [{type: "direct", tag: "direct"}],
    route: {
      rules: [
        {action: "resolve"},
        {ip_cidr: ["0.0.0.0/8", "127.0.0.0/8", "::/128", "::1/128", "169.254.0.0/16", "fe80::/10", "224.0.0.0/4", "ff00::/8"], action: "reject"}
      ],
      default_domain_resolver: "local",
      final: "direct"
    }
  }' "$NODES" >"$out_file"
}

apply() { # return 0=成功; 1=校验/生成失败($CONF未改); 2=写入或服务启动失败($CONF已改)
  local conf_tmp out cnt
  cnt=$(nodes_count) || {
    err "节点数据文件格式异常"
    return 1
  }
  conf_tmp=$(mktemp "$SB_DIR/.tmp.conf.XXXXXX") || {
    err "创建临时配置文件失败"
    return 1
  }
  if ! gen_config "$conf_tmp"; then
    err "生成配置文件失败"
    rm -f "$conf_tmp"
    return 1
  fi
  if ! out=$("$SB_BIN" check -c "$conf_tmp" 2>&1); then
    err "配置校验失败："
    printf '%s\n' "$out"
    core_ok || warn "Snell / gecko 混淆需要 sing-box >= v$MIN_VER，请先更新内核"
    rm -f "$conf_tmp"
    return 1
  fi
  if ! { chmod 600 "$conf_tmp" && mv "$conf_tmp" "$CONF"; }; then
    err "写入配置文件失败"
    rm -f "$conf_tmp"
    return 2
  fi
  if [[ $cnt -eq 0 ]]; then
    svc_ctl stop
    svc_ctl disable
    ok "节点已清空，服务已停止"
    return 0
  fi
  svc_ctl enable
  svc_ctl restart
  local i active=0
  for i in 1 2 3 4 5 6; do
    sleep 0.5
    if svc_ctl is-active; then
      active=1
      break
    fi
  done
  if ((active == 1)); then
    sleep 0.6
    if svc_ctl is-active; then
      ok "配置已生效"
      return 0
    fi
  fi
  err "服务启动失败，最近日志："
  svc_logs 12
  return 2
}

# ───────── 校验、状态与共享输入辅助 ─────────
rnd() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_sni() {
  [[ ${#1} -le 253 ]] && [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+([A-Za-z]{2,63}|xn--[A-Za-z0-9-]{1,59}[A-Za-z0-9])$ ]]
}
valid_host() { [[ -z $1 ]] || valid_sni "$1" || _valid_ipv4 "$1" || _valid_ipv6 "$1"; }

valid_ss2022_psk() {
  local need=16 raw
  [[ $1 == 2022-blake3-aes-256-gcm ]] && need=32
  [[ $2 =~ ^[A-Za-z0-9+/]+={0,2}$ ]] && ((${#2} % 4 == 0)) || return 1
  printf %s "$2" | base64 -d >/dev/null 2>&1 || return 1
  raw=$(printf %s "$2" | base64 -d 2>/dev/null | wc -c)
  ((raw == need))
}

valid_snell_psk() {
  local len
  LC_ALL=C len=${#2}
  [[ -n $2 && ! $2 =~ [[:space:],=] ]] && (($1 != 6 || (len >= 12 && len <= 255)))
}

proto_net() { # $1=type -> tcp|udp|both
  case $1 in
    hysteria2) echo udp ;;
    socks | shadowsocks) echo both ;;
    *) echo tcp ;;
  esac
}

proto_net_label() {
  case $(proto_net "$1") in
    udp) echo "UDP" ;;
    both) echo "TCP / UDP" ;;
    *) echo "TCP" ;;
  esac
}

tag_exists() { # $1=tag $2=exclude_idx(optional)
  jq -e --arg t "$1" --argjson ex "${2:--1}" \
    'to_entries | any(.[]; .key != $ex and .value.tag == $t)' "$NODES" >/dev/null 2>&1
}

unique_tag() { # $1=base_tag $2=exclude_idx(optional)
  local base=$1 ex=${2:--1} t=$1 n=2
  while tag_exists "$t" "$ex"; do
    t="${base}-${n}"
    ((n++))
  done
  printf '%s\n' "$t"
}

port_free() { # $1=port $2=proto(tcp|udp|both) $3=exclude_idx(optional)
  local p=$1 net=${2:-both} ex=${3:--1} skip_tcp=0 skip_udp=0
  if ((ex >= 0)) && [[ -n ${EDIT_ORIG_PORT:-} && $p == "$EDIT_ORIG_PORT" ]]; then
    [[ ${EDIT_ORIG_NET:-} == tcp || ${EDIT_ORIG_NET:-} == both ]] && skip_tcp=1
    [[ ${EDIT_ORIG_NET:-} == udp || ${EDIT_ORIG_NET:-} == both ]] && skip_udp=1
  fi
  if ((skip_tcp == 0)) && [[ $net == tcp || $net == both ]]; then
    ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$p$" && return 1
  fi
  if ((skip_udp == 0)) && [[ $net == udp || $net == both ]]; then
    ss -lnu 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$p$" && return 1
  fi
  jq -e --argjson p "$p" --arg net "$net" --argjson ex "$ex" '
    to_entries | any(.[]; .key != $ex and .value.port == $p and (
      ($net == "both") or
      (.value.type == "socks" or .value.type == "shadowsocks") or
      ($net == "udp" and .value.type == "hysteria2") or
      ($net == "tcp" and .value.type != "hysteria2")
    ))
  ' "$NODES" >/dev/null 2>&1 && return 1
  return 0
}

_ask_match() { # $1=提示 $2=默认 $3=原值(可选,相同则取消) $4=正则 $5=错误提示
  while :; do
    ask "$1 (0 取消)" "$2" || return 1
    [[ $REPLY == 0 || (-n $3 && $REPLY == "$3") ]] && return 1
    [[ $REPLY =~ $4 ]] && return 0
    err "$5"
  done
}

ask_port() { # $1=proto_type
  local net def="" i cand
  net=$(proto_net "${1:-}")
  for ((i = 0; i < 50; i++)); do
    cand=$((((RANDOM << 15 | RANDOM) % 40001) + 20000))
    if port_free "$cand" "$net"; then
      def=$cand
      break
    fi
  done
  while :; do
    ask "监听端口 (0 取消)" "$def" || return 1
    [[ $REPLY == 0 ]] && return 1
    valid_port "$REPLY" || {
      err "端口须在 1-65535 之间"
      continue
    }
    PORT=$((10#$REPLY))
    port_free "$PORT" "$net" && return 0
    err "端口 $PORT 已被占用，请更换"
  done
}

ask_sni() { # $1=提示 $2=目标变量名(默认 SNI) $3=默认值 $4=原值(可选)
  local var=${2:-SNI} def=${3:-$DEFAULT_SNI} orig=${4:-}
  while :; do
    ask "$1 (0 取消)" "$def" || return 1
    [[ $REPLY == 0 || (-n $orig && $REPLY == "$orig") ]] && return 1
    valid_sni "$REPLY" && {
      printf -v "$var" '%s' "$REPLY"
      return 0
    }
    err "域名格式无效（示例：www.apache.org）"
  done
}

ask_user() { # $1=提示 $2=默认值 $3=原值(可选)
  while :; do
    ask "$1 (0 取消)" "$2" || return 1
    [[ $REPLY == 0 || (-n ${3:-} && $REPLY == "$3") ]] && return 1
    [[ -n $REPLY && ! $REPLY =~ [[:space:]] ]] && return 0
    err "用户名不能为空或包含空白字符"
  done
}

ask_snell_psk() { # $1=提示 $2=version $3=默认值 $4=原值(可选)
  while :; do
    ask "$1 (0 取消)" "$3" || return 1
    [[ $REPLY == 0 || (-n ${4:-} && $REPLY == "$4") ]] && return 1
    valid_snell_psk "$2" "$REPLY" && return 0
    if [[ $2 == 6 ]]; then
      err "Snell v6 的 PSK 须为 12-255 字节，且不能包含空白、逗号或等号"
    else
      err "PSK 不能为空，且不能包含空白、逗号或等号"
    fi
  done
}

_cert_valid() {
  [[ -s $1 && -s $2 ]] || return 1
  openssl x509 -in "$1" -noout -checkend 0 >/dev/null 2>&1 || return 1
  local cp kp
  cp=$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null) || return 1
  kp=$(openssl pkey -in "$2" -pubout 2>/dev/null) || return 1
  [[ -n $cp && $cp == "$kp" ]]
}

ask_cert() {
  ask_sni "域名 / SNI" SNI || return 1
  while :; do
    ask "证书路径 (留空自签，0 取消)" "" || return 1
    [[ $REPLY == 0 ]] && return 1
    CERT=$REPLY
    if [[ -z $CERT ]]; then
      CERT=$CERT_DIR/$SNI.crt
      KEY=$CERT_DIR/$SNI.key
      if ! _cert_valid "$CERT" "$KEY"; then
        rm -f "$CERT" "$KEY"
        local ossl=(req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1
          -keyout "$KEY" -out "$CERT" -days 3650 -subj "/CN=$SNI")
        openssl "${ossl[@]}" -addext "subjectAltName=DNS:$SNI" >/dev/null 2>&1 \
          || openssl "${ossl[@]}" >/dev/null 2>&1 \
          || {
            err "自签证书生成失败"
            rm -f "$CERT" "$KEY"
            return 1
          }
        chmod 600 "$KEY"
        chmod 644 "$CERT"
      fi
      INSECURE=1
      HOST=""
      return 0
    fi
    ask "私钥路径 (0 取消)" "" || return 1
    [[ $REPLY == 0 ]] && return 1
    KEY=$REPLY
    if ! _cert_valid "$CERT" "$KEY"; then
      err "证书或私钥不存在、不匹配或已过期（证书路径留空可改用自签）"
      continue
    fi
    while :; do
      ask "客户端连接地址 (- 自动用公网 IP)" "$SNI" || return 1
      [[ $REPLY == "-" ]] && REPLY=""
      valid_host "$REPLY" && {
        HOST=$REPLY
        break
      }
      err "连接地址格式无效"
    done
    INSECURE=0
    return 0
  done
}

jqw() {
  local t
  t=$(mktemp "$SB_DIR/.tmp.nodes.XXXXXX") || return 1
  if jq "$@" "$NODES" >"$t" && chmod 600 "$t" && mv "$t" "$NODES"; then
    return 0
  fi
  rm -f "$t"
  return 1
}

_write() {
  "$@" || {
    err "保存节点数据失败"
    return 1
  }
}

restore_nodes() {
  cp "$BAK_NODES" "$NODES"
  chmod 600 "$NODES"
}

snapshot() {
  BAK_NODES="$RUN_TMP/nodes.$$.$RANDOM.bak"
  cp "$NODES" "$BAK_NODES"
  BAK_CONF=""
  [[ -f $CONF ]] && {
    BAK_CONF="$RUN_TMP/conf.$$.$RANDOM.bak"
    cp "$CONF" "$BAK_CONF"
  }
  BAK_ENABLED=0
  svc_ctl is-enabled && BAK_ENABLED=1
}

rollback() { # $1=apply_rc $2=msg
  local rc=$1 msg=$2 ct="" cnt=0
  restore_nodes
  cnt=$(nodes_count 2>/dev/null || echo 0)
  if [[ $rc -eq 2 ]]; then
    if [[ -n $BAK_CONF && -f $BAK_CONF ]]; then
      cp "$BAK_CONF" "$CONF"
      chmod 600 "$CONF"
    elif ct=$(mktemp "$SB_DIR/.tmp.conf.XXXXXX" 2>/dev/null) && gen_config "$ct" 2>/dev/null; then
      chmod 600 "$ct" && mv "$ct" "$CONF"
    else
      rm -f "$ct" 2>/dev/null || true
    fi
    [[ $cnt -eq 0 ]] && svc_ctl stop || svc_ctl restart
    ((${BAK_ENABLED:-0} == 1)) && svc_ctl enable || svc_ctl disable
  fi
  err "$msg"
}

setf() { jqw --argjson i "$1" --arg k "$2" --arg v "$3" '.[$i][$k]=$v'; }
g() { jq -r --argjson i "$IDX" --arg k "$1" '.[$i][$k] // empty' "$NODES"; }

choose_node() { # 交互选择节点 -> IDX；取消返回 1
  local n def=""
  n=$(nodes_count) || {
    err "读取节点列表失败"
    return 1
  }
  [[ $n -eq 1 ]] && def=1
  echo
  while :; do
    ask "节点编号 (0 返回)" "$def" || return 1
    [[ $REPLY == 0 ]] && return 1
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      IDX=$((10#$REPLY - 1))
      return 0
    fi
    [[ -n $REPLY ]] && err "请输入 1-$n 之间的编号"
  done
}

ensure_core() {
  core_ok && return 0
  warn "$1 需要 sing-box >= v$MIN_VER（当前 v$(sb_version)）"
  confirm "是否立即更新内核？" && install_singbox && core_ok
}

# ───────── 添加节点 ─────────
add_socks() {
  ask_port socks || return 1
  local u p tag
  ask_user "用户名" "$(rnd 6)" || return 1
  u=$REPLY
  ask "密码 (0 取消)" "$(rnd 12)" || return 1
  [[ $REPLY == 0 ]] && return 1
  p=$REPLY
  tag=$(unique_tag "socks-$PORT")
  _write jqw --arg tag "$tag" --argjson port "$PORT" --arg u "$u" --arg p "$p" \
    '. + [{type:"socks",tag:$tag,port:$port,user:$u,pass:$p}]'
}

pick_ss_method() {
  printf '%s1%s  2022-blake3-aes-128-gcm  %s(推荐)%s\n' "$C" "$N" "$D" "$N"
  printf '%s2%s  2022-blake3-aes-256-gcm\n' "$C" "$N"
  printf '%s3%s  aes-256-gcm\n' "$C" "$N"
  printf '%s4%s  chacha20-ietf-poly1305\n' "$C" "$N"
  while :; do
    ask "加密方式 (0 取消)" "1" || return 1
    [[ $REPLY == 0 ]] && return 1
    case $REPLY in
      1) SS_M=2022-blake3-aes-128-gcm; SS_P=$(openssl rand -base64 16); return 0 ;;
      2) SS_M=2022-blake3-aes-256-gcm; SS_P=$(openssl rand -base64 32); return 0 ;;
      3) SS_M=aes-256-gcm; SS_P=$(rnd 20); return 0 ;;
      4) SS_M=chacha20-ietf-poly1305; SS_P=$(rnd 20); return 0 ;;
      *) err "请输入 1-4" ;;
    esac
  done
}

add_ss() {
  ask_port shadowsocks || return 1
  pick_ss_method || return 1
  local tag
  tag=$(unique_tag "ss-$PORT")
  _write jqw --arg tag "$tag" --argjson port "$PORT" --arg m "$SS_M" --arg p "$SS_P" \
    '. + [{type:"shadowsocks",tag:$tag,port:$port,method:$m,password:$p}]'
}

pick_hy2_obfs() { # -> OBFS_T ("" / salamander / gecko)
  printf '%s0%s  关闭\n%s1%s  salamander\n%s2%s  gecko  %s(需 v1.14+)%s\n' "$C" "$N" "$C" "$N" "$C" "$N" "$D" "$N"
  while :; do
    ask "QUIC 混淆" "0" || return 1
    case $REPLY in
      0) OBFS_T=""; return 0 ;;
      1) OBFS_T=salamander; return 0 ;;
      2) ensure_core "gecko 混淆" || return 1; OBFS_T=gecko; return 0 ;;
      *) err "请输入 0-2" ;;
    esac
  done
}

add_hy2() {
  ask_port hysteria2 || return 1
  ask_cert || return 1
  ask "密码 (0 取消)" "$(rnd 16)" || return 1
  [[ $REPLY == 0 ]] && return 1
  local p=$REPLY o="" tag
  pick_hy2_obfs || return 1
  if [[ -n $OBFS_T ]]; then
    ask "混淆密码 (0 取消)" "$(rnd 16)" || return 1
    [[ $REPLY == 0 ]] && return 1
    o=$REPLY
  fi
  tag=$(unique_tag "hy2-$PORT")
  _write jqw --arg tag "$tag" --argjson port "$PORT" --arg p "$p" --arg o "$o" --arg ot "$OBFS_T" \
    --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"hysteria2",tag:$tag,port:$port,password:$p,obfs_type:$ot,obfs:$o,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

gen_reality() {
  local out
  out=$("$SB_BIN" generate reality-keypair 2>/dev/null) || {
    err "生成 Reality 密钥对失败"
    return 1
  }
  RPRIV=$(awk '/PrivateKey/{print $2}' <<<"$out")
  RPUB=$(awk '/PublicKey/{print $2}' <<<"$out")
  RSID=$(openssl rand -hex 4)
  [[ -n $RPRIV && -n $RPUB && -n $RSID ]] || {
    err "解析 Reality 密钥对失败"
    return 1
  }
}

add_vless() {
  ask_port vless || return 1
  local sni uuid tag
  ask_sni "Reality 伪装域名" sni || return 1
  gen_reality || return 1
  uuid=$("$SB_BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
  [[ -n $uuid ]] || {
    err "生成 UUID 失败"
    return 1
  }
  tag=$(unique_tag "vless-$PORT")
  _write jqw --arg tag "$tag" --argjson port "$PORT" --arg sni "$sni" --arg priv "$RPRIV" \
    --arg pub "$RPUB" --arg sid "$RSID" --arg uuid "$uuid" \
    '. + [{type:"vless",tag:$tag,port:$port,uuid:$uuid,sni:$sni,priv:$priv,pub:$pub,sid:$sid}]'
}

add_anytls() {
  ask_port anytls || return 1
  ask_cert || return 1
  ask "密码 (0 取消)" "$(rnd 16)" || return 1
  [[ $REPLY == 0 ]] && return 1
  local p=$REPLY tag
  tag=$(unique_tag "anytls-$PORT")
  _write jqw --arg tag "$tag" --argjson port "$PORT" --arg p "$p" --arg c "$CERT" --arg k "$KEY" \
    --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"anytls",tag:$tag,port:$port,password:$p,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

add_snell() {
  ensure_core "Snell" || return 1
  ask_port snell || return 1
  local v o=none psk oh="" tag
  _ask_match "协议版本 (5 / 6)" "5" "" '^(5|6)$' "仅支持版本 5 或 6" || return 1
  v=$REPLY
  [[ $v == 5 ]] && note "sing-box 的 Snell v5 入站不支持 QUIC 代理模式"
  ask_snell_psk "预共享密钥 PSK" "$v" "$(rnd 20)" || return 1
  psk=$REPLY
  if [[ $v == 5 ]]; then
    _ask_match "HTTP 混淆 (none / http)" "none" "" '^(none|http)$' "仅支持 none 或 http" || return 1
    o=$REPLY
    if [[ $o == http ]]; then
      ask_sni "混淆域名" oh || return 1
    fi
  fi
  tag=$(unique_tag "snell-$PORT")
  _write jqw --arg tag "$tag" --argjson port "$PORT" --argjson v "$v" --arg p "$psk" --arg o "$o" --arg oh "$oh" \
    '. + [{type:"snell",tag:$tag,port:$port,version:$v,psk:$p}
     + (if $v==6 then {mode:"default"} elif $o=="http" then {obfs:$o,obfs_host:$oh} else {obfs:$o} end)]'
}

menu_add() {
  local c label
  while :; do
    title "添加节点"
    printf '%s1%s  %s%s2%s  Hysteria2\n' "$C" "$N" "$(_pad_left "VLESS (Reality)" 18)" "$C" "$N"
    printf '%s3%s  %s%s4%s  Snell (v5/v6)\n' "$C" "$N" "$(_pad_left "AnyTLS" 18)" "$C" "$N"
    printf '%s5%s  %s%s6%s  SOCKS5\n' "$C" "$N" "$(_pad_left "Shadowsocks" 18)" "$C" "$N"
    hr
    printf '%s0%s  返回\n\n' "$C" "$N"
    read -rp "› " c || return 0
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && return 0
    [[ $c =~ ^[1-6]$ ]] && break
    err "无效选项，请输入 0-6"
    sleep 0.5
  done

  local n rc
  n=$(nodes_count) || {
    err "读取节点列表失败"
    pause || true
    return 0
  }
  case $c in
    1) label="VLESS (Reality)" ;; 2) label="Hysteria2" ;; 3) label="AnyTLS" ;;
    4) label="Snell" ;; 5) label="Shadowsocks" ;; 6) label="SOCKS5" ;;
  esac
  title "添加节点 · $label"
  snapshot
  case $c in
    1) add_vless ;; 2) add_hy2 ;; 3) add_anytls ;; 4) add_snell ;; 5) add_ss ;; 6) add_socks ;;
  esac || {
    restore_nodes
    return 0
  }

  IDX=$n
  echo
  if apply; then
    echo
    show_link "$IDX"
    note "请在防火墙 / 安全组放行 $(proto_net_label "$(g type)") 端口 $(g port)"
  else
    rc=$?
    rollback "$rc" "配置未能生效，已撤销本次添加"
  fi
  echo
  pause || true
}

# ───────── 节点列表与分享链接 ─────────
list_nodes() {
  local n
  n=$(nodes_count) || {
    err "节点数据文件格式异常"
    return 1
  }
  if [[ $n -eq 0 ]]; then
    info "暂无节点，可从主菜单选择「添加节点」"
    return 1
  fi
  printf '%s%s%s%s%s\n' \
    "$D" "$(_pad_left "#" 4)" "$(_pad_left "协议" 13)" "$(_pad_left "端口" 7)" "详情$N"
  hr
  jq -r 'to_entries[] | .key+1 as $i | .value |
    "\($i) \(.type) \(.port) " +
    (if .type=="shadowsocks" then .method
     elif .type=="snell" then "v\(.version)" + (if .version==6 then " · \(.mode // "default")" elif .obfs=="http" then " · http" else "" end)
     elif .type=="hysteria2" then .sni + (if (.obfs//"")!="" then " · \(if (.obfs_type//"")=="" then "salamander" else .obfs_type end)" else "" end)
     elif .sni then .sni
     else .user end)' "$NODES" \
    | while read -r i t p m; do
      printf '%s%s%s%s%s%s%s%s\n' \
        "$C" "$(_pad_left "$i" 4)" "$N" "$(_pad_left "$t" 13)" "$(_pad_left "$p" 7)" "$D" "$m" "$N"
    done
}

build_link() { # $1=raw_ip；单次 jq 完成编码与拼接
  jq -r --argjson i "$IDX" --arg ip "$1" --arg dsn "$DEFAULT_SNI" '
    def br: if test(":") then "[" + . + "]" else . end;
    def e: (. // "") | @uri;
    (.[$i] // {}) as $n | ($ip | br) as $h
    | if $n.type == "socks" then
        "socks5://\($n.user | e):\($n.pass | e)@\($h):\($n.port)#\($n.tag | e)"
      elif $n.type == "shadowsocks" then
        if (($n.method // "") | startswith("2022-")) then
          "ss://\($n.method | e):\($n.password | e)@\($h):\($n.port)#\($n.tag | e)"
        else
          "ss://\(($n.method // "") + ":" + ($n.password // "") | @base64)@\($h):\($n.port)#\($n.tag | e)"
        end
      elif $n.type == "hysteria2" then
        "hysteria2://\($n.password | e)@\($h):\($n.port)/?sni=\($n.sni | e)&insecure=\($n.insecure // 0)"
        + (if ($n.obfs // "") != "" then
            "&obfs=\((if ($n.obfs_type // "") == "" then "salamander" else $n.obfs_type end) | e)&obfs-password=\($n.obfs | e)"
           else "" end)
        + "#\($n.tag | e)"
      elif $n.type == "vless" then
        "vless://\($n.uuid | e)@\($h):\($n.port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\($n.sni | e)&fp=chrome&pbk=\($n.pub | e)&sid=\($n.sid | e)&type=tcp#\($n.tag | e)"
      elif $n.type == "anytls" then
        "anytls://\($n.password | e)@\($h):\($n.port)/?sni=\($n.sni | e)&insecure=\($n.insecure // 0)#\($n.tag | e)"
      elif $n.type == "snell" then
        "\($n.tag) = snell, \($ip), \($n.port), psk=\($n.psk // ""), version=\($n.version // ""), reuse=true, tfo=true"
        + (if ($n.version == 6 and (($n.mode // "default") != "default")) then
            ", mode=\($n.mode)"
           elif ($n.version == 5 and $n.obfs == "http") then
            ", obfs=http, obfs-host=\(if ($n.obfs_host // "") == "" then $dsn else $n.obfs_host end)"
           else "" end)
      else "" end
  ' "$NODES"
}

show_link() {
  IDX=$1
  local name t port host meta badge
  meta=$(jq -r --argjson i "$IDX" '(.[$i] // {}) | [(.tag // ""), (.type // ""), ((.port // "")|tostring), (.host // "")] | join("\u001f")' "$NODES")
  IFS=$'\x1f' read -r name t port host <<<"$meta"
  badge="$t · $port"
  [[ $t == snell ]] && badge="$badge · Surge"
  printf '%s▸%s %s%s%s  %s(%s)%s\n' "$C" "$N" "$B" "$name" "$N" "$D" "$badge" "$N"
  if [[ -n $host ]]; then
    printf '%s%s%s\n\n' "$G" "$(build_link "$host")" "$N"
    return
  fi
  detect_ips
  if [[ -n $PUBIP4 && -n $PUBIP6 ]]; then
    printf '%sIPv4%s  %s%s%s\n' "$D" "$N" "$G" "$(build_link "$PUBIP4")" "$N"
    printf '%sIPv6%s  %s%s%s\n\n' "$D" "$N" "$G" "$(build_link "$PUBIP6")" "$N"
  elif [[ -n $PUBIP4 ]]; then
    printf '%s%s%s\n\n' "$G" "$(build_link "$PUBIP4")" "$N"
  elif [[ -n $PUBIP6 ]]; then
    printf '%s%s%s\n\n' "$G" "$(build_link "$PUBIP6")" "$N"
  else
    printf '%s%s%s\n\n' "$G" "$(build_link "YOUR_IP")" "$N"
  fi
}

menu_links() {
  title "分享链接"
  list_nodes || {
    echo
    pause || true
    return 0
  }
  local n i
  n=$(nodes_count) || return 0
  if [[ $n -eq 1 ]]; then
    echo
    show_link 0
    pause || true
    return 0
  fi
  echo
  while :; do
    ask "节点编号 (a 全部，0 返回)" "a" || return 0
    [[ $REPLY == 0 ]] && return 0
    if [[ $REPLY == a || $REPLY == A ]]; then
      echo
      for ((i = 0; i < n; i++)); do show_link "$i"; done
      break
    fi
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      echo
      show_link "$((10#$REPLY - 1))"
      break
    fi
    err "请输入 1-$n 或 a"
  done
  pause || true
}

# ───────── 编辑节点 ─────────
node_fields() {
  case $(g type) in
    socks) FIELDS=("port:监听端口" "user:用户名" "pass:密码" "tag:节点名称") ;;
    shadowsocks) FIELDS=("port:监听端口" "method:加密方式" "password:密码" "tag:节点名称") ;;
    hysteria2)
      FIELDS=("port:监听端口" "password:密码" "obfs_type:QUIC 混淆")
      [[ -n $(g obfs) ]] && FIELDS+=("obfs:混淆密码")
      FIELDS+=("_cert:证书 / SNI" "host:连接地址" "insecure:跳过证书验证" "tag:节点名称")
      ;;
    vless) FIELDS=("port:监听端口" "sni:伪装域名" "uuid:UUID" "sid:ShortID" "_reality:Reality 密钥对" "tag:节点名称") ;;
    anytls) FIELDS=("port:监听端口" "password:密码" "_cert:证书 / SNI" "host:连接地址" "insecure:跳过证书验证" "tag:节点名称") ;;
    snell)
      FIELDS=("port:监听端口" "psk:预共享密钥" "version:协议版本")
      if [[ $(g version) == 6 ]]; then
        FIELDS+=("mode:流量整形")
      else
        FIELDS+=("obfs:HTTP 混淆")
        [[ $(g obfs) == http ]] && FIELDS+=("obfs_host:混淆域名")
      fi
      FIELDS+=("tag:节点名称")
      ;;
  esac
}

field_display() { # $1=key -> 人类可读展示文本
  local k=$1 v
  case $k in
    _cert)
      local sni cert mode="自定义"
      sni=$(g sni)
      cert=$(g cert)
      [[ $cert == "$CERT_DIR/"* ]] && mode="自签"
      printf '%s（%s）' "$sni" "$mode"
      ;;
    _reality) printf '重新生成' ;;
    insecure) [[ $(g insecure) == 1 ]] && printf '开启' || printf '关闭' ;;
    host) v=$(g host); printf '%s' "${v:-自动（公网 IP）}" ;;
    obfs_type) v=$(g obfs_type); printf '%s' "${v:-未启用}" ;;
    obfs)
      v=$(g obfs)
      if [[ $(g type) == snell ]]; then
        [[ $v == http ]] && printf 'HTTP' || printf '关闭'
      else
        printf '%s' "${v:-—}"
      fi
      ;;
    *) v=$(g "$k"); printf '%s' "${v:-—}" ;;
  esac
}

edit_field() { # return 0=需重启生效; 2=仅影响分享链接(无需重启); 1=未修改/取消
  local k=$1 cur np psk net
  cur=$(g "$k")
  case $k in
    port)
      net=$(proto_net "$(g type)")
      while :; do
        ask "新端口 (0 取消)" "$cur" || return 1
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        valid_port "$REPLY" || {
          err "端口须在 1-65535 之间"
          continue
        }
        np=$((10#$REPLY))
        port_free "$np" "$net" "$IDX" && break
        err "端口 $np 已被占用"
      done
      local tag
      tag=$(unique_tag "$(g tag | sed "s/-$cur\$/-$np/")" "$IDX")
      _write jqw --argjson i "$IDX" --arg t "$tag" --argjson p "$np" '.[$i].tag=$t | .[$i].port=$p' || return 1
      ;;
    user)
      ask_user "新用户名" "$cur" "$cur" || return 1
      _write setf "$IDX" user "$REPLY" || return 1
      ;;
    method)
      pick_ss_method || return 1
      _write jqw --argjson i "$IDX" --arg m "$SS_M" --arg p "$SS_P" '.[$i].method=$m | .[$i].password=$p' || return 1
      note "已按新加密方式重新生成密码"
      sleep 0.6
      ;;
    password | pass)
      while :; do
        ask "新密码 (0 取消)" "$cur" || return 1
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        [[ -n $REPLY ]] || {
          err "密码不能为空"
          continue
        }
        if [[ $(g type) == shadowsocks && $(g method) == 2022-blake3-* ]]; then
          valid_ss2022_psk "$(g method)" "$REPLY" || {
            err "SS 2022 密码须为对应长度（16 / 32 字节）的标准 Base64"
            continue
          }
        fi
        break
      done
      _write setf "$IDX" "$k" "$REPLY" || return 1
      ;;
    sni | obfs_host)
      local label="新伪装域名" def=$cur
      [[ $k == obfs_host ]] && { label="新混淆域名"; def=${cur:-$DEFAULT_SNI}; }
      ask_sni "$label" REPLY "$def" "$cur" || return 1
      _write setf "$IDX" "$k" "$REPLY" || return 1
      [[ $k == obfs_host ]] && return 2
      ;;
    host)
      while :; do
        ask "新连接地址 (- 自动用公网 IP，0 取消)" "${cur:--}" || return 1
        [[ $REPLY == 0 ]] && return 1
        [[ $REPLY == "-" ]] && REPLY=""
        [[ $REPLY == "$cur" ]] && return 1
        valid_host "$REPLY" && break
        err "连接地址格式无效"
      done
      _write setf "$IDX" host "$REPLY" || return 1
      return 2
      ;;
    insecure)
      local nv=$((cur == 1 ? 0 : 1))
      _write jqw --argjson i "$IDX" --argjson v "$nv" '.[$i].insecure=$v' || return 1
      return 2
      ;;
    tag)
      while :; do
        ask "新节点名称 (0 取消)" "$cur" || return 1
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        if [[ ! $REPLY =~ ^[A-Za-z0-9._-]+$ ]]; then
          err "仅支持字母、数字、点、下划线和连字符"
          continue
        fi
        if tag_exists "$REPLY" "$IDX"; then
          err "节点名称已存在"
          continue
        fi
        break
      done
      _write setf "$IDX" tag "$REPLY" || return 1
      ;;
    version)
      _ask_match "协议版本 (5 / 6)" "$cur" "$cur" '^(5|6)$' "仅支持版本 5 或 6" || return 1
      if [[ $REPLY == 6 ]]; then
        psk=$(g psk)
        if valid_snell_psk 6 "$psk"; then
          _write jqw --argjson i "$IDX" '.[$i].version=6 | .[$i].mode="default" | del(.[$i].obfs, .[$i].obfs_host)' || return 1
        else
          _write jqw --argjson i "$IDX" --arg p "$(rnd 20)" \
            '.[$i].version=6 | .[$i].mode="default" | .[$i].psk=$p | del(.[$i].obfs, .[$i].obfs_host)' || return 1
          note "v6 要求 PSK 12-255 字节，已自动重新生成"
          sleep 0.6
        fi
      else
        _write jqw --argjson i "$IDX" '.[$i].version=5 | .[$i].obfs="none" | del(.[$i].mode)' || return 1
      fi
      ;;
    obfs)
      if [[ $(g type) == snell ]]; then
        _ask_match "HTTP 混淆 (none / http)" "${cur:-none}" "${cur:-none}" '^(none|http)$' "仅支持 none 或 http" || return 1
        if [[ $REPLY == http ]]; then
          local oh
          oh=$(g obfs_host)
          _write jqw --argjson i "$IDX" --arg oh "${oh:-$DEFAULT_SNI}" '.[$i].obfs="http" | .[$i].obfs_host=$oh' || return 1
        else
          _write jqw --argjson i "$IDX" '.[$i].obfs="none" | del(.[$i].obfs_host)' || return 1
        fi
      else
        ask "新混淆密码 (- 关闭混淆，0 取消)" "$cur" || return 1
        [[ $REPLY == 0 ]] && return 1
        [[ $REPLY == "-" ]] && REPLY=""
        [[ $REPLY == "$cur" ]] && return 1
        if [[ -z $REPLY ]]; then
          _write jqw --argjson i "$IDX" '.[$i] += {obfs:"",obfs_type:""}' || return 1
        else
          local ot
          ot=$(g obfs_type)
          _write jqw --argjson i "$IDX" --arg op "$REPLY" --arg ot "${ot:-salamander}" \
            '.[$i] += {obfs:$op,obfs_type:$ot}' || return 1
        fi
      fi
      ;;
    obfs_type)
      pick_hy2_obfs || { sleep 0.6; return 1; }
      if [[ -n $OBFS_T ]]; then
        local op
        op=$(g obfs)
        [[ -n $op ]] || {
          op=$(rnd 16)
          note "已自动生成混淆密码"
          sleep 0.5
        }
        _write jqw --argjson i "$IDX" --arg ot "$OBFS_T" --arg op "$op" '.[$i] += {obfs_type:$ot,obfs:$op}' || return 1
      else
        _write jqw --argjson i "$IDX" '.[$i] += {obfs_type:"",obfs:""}' || return 1
      fi
      ;;
    mode)
      _ask_match "流量整形 (default / unshaped / unsafe-raw)" "${cur:-default}" "${cur:-default}" \
        '^(default|unshaped|unsafe-raw)$' "仅支持 default、unshaped 或 unsafe-raw" || return 1
      _write setf "$IDX" mode "$REPLY" || return 1
      ;;
    psk)
      ask_snell_psk "新 PSK" "$(g version)" "$cur" "$cur" || return 1
      _write setf "$IDX" psk "$REPLY" || return 1
      ;;
    uuid)
      _ask_match "新 UUID" "$cur" "$cur" \
        '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' "UUID 格式无效" || return 1
      _write setf "$IDX" uuid "$REPLY" || return 1
      ;;
    sid)
      _ask_match "新 ShortID (偶数位十六进制，最长 16 位)" "$cur" "$cur" \
        '^([0-9a-fA-F]{2}){1,8}$' "ShortID 格式无效" || return 1
      _write setf "$IDX" sid "$REPLY" || return 1
      ;;
    _cert)
      ask_cert || { sleep 0.6; return 1; }
      _write jqw --argjson i "$IDX" --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson in "$INSECURE" \
        '.[$i] += {cert:$c,key:$k,sni:$sni,host:$h,insecure:$in}' || return 1
      ;;
    _reality)
      gen_reality || return 1
      _write jqw --argjson i "$IDX" --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" \
        '.[$i] += {priv:$priv,pub:$pub,sid:$sid}' || return 1
      ok "已重新生成 Reality 密钥对与 ShortID"
      sleep 0.6
      ;;
  esac
  return 0
}

menu_edit() {
  title "编辑节点"
  list_nodes || {
    echo
    pause || true
    return 0
  }
  choose_node || return 0

  local dirty=0 link_dirty=0 i f k rc c tag_flag=""
  local EDIT_ORIG_PORT EDIT_ORIG_NET
  EDIT_ORIG_PORT=$(g port)
  EDIT_ORIG_NET=$(proto_net "$(g type)")
  snapshot

  while :; do
    tag_flag=""
    ((dirty == 1 || link_dirty == 1)) && tag_flag="${Y}● 未保存${N}"
    title "编辑 · $(g tag)" "$tag_flag"
    node_fields
    i=1
    for f in "${FIELDS[@]}"; do
      k=${f%%:*}
      printf '%s%s%s%s%s%s%s\n' \
        "$C" "$(_pad_left "$i" 3)" "$N" "$(_pad_left "${f#*:}" 18)" "$D" "$(field_display "$k")" "$N"
      ((i++))
    done
    hr
    if ((dirty == 1 || link_dirty == 1)); then
      printf '%s0%s  %s%sq%s  放弃修改\n\n' "$C" "$N" "$(_pad_left "保存并应用" 16)" "$C" "$N"
    else
      printf '%s0%s  返回\n\n' "$C" "$N"
    fi
    read -rp "› " c || {
      restore_nodes
      return 0
    }
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && break
    if [[ $c == q || $c == Q ]]; then
      restore_nodes
      info "已放弃修改"
      sleep 0.5
      return 0
    fi
    if [[ $c =~ ^[0-9]{1,2}$ ]] && ((10#$c >= 1 && 10#$c <= ${#FIELDS[@]})); then
      k=${FIELDS[$((10#$c - 1))]%%:*}
      [[ $k != insecure ]] && echo
      edit_field "$k"
      rc=$?
      case $rc in
        0) dirty=1 ;;
        2) link_dirty=1 ;;
      esac
    fi
  done

  if ((dirty == 1)); then
    echo
    if apply; then
      echo
      show_link "$IDX"
      [[ $(g port) != "$EDIT_ORIG_PORT" ]] && note "端口已变更，请放行 $(proto_net_label "$(g type)") 端口 $(g port)"
    else
      rc=$?
      rollback "$rc" "配置校验或启动失败，已回滚全部修改"
    fi
    echo
    pause || true
  elif ((link_dirty == 1)); then
    echo
    ok "分享链接参数已更新（无需重启服务）"
    echo
    show_link "$IDX"
    pause || true
  fi
}

# ───────── 删除、服务管理与卸载 ─────────
menu_del() {
  title "删除节点"
  list_nodes || {
    echo
    pause || true
    return 0
  }
  choose_node || return 0
  local tag port rc
  tag=$(g tag)
  port=$(g port)
  echo
  confirm "确认删除节点 $tag ($(g type):$port)？" || return 0
  snapshot
  if ! _write jqw --argjson i "$IDX" 'del(.[$i])'; then
    pause || true
    return 0
  fi
  if apply; then
    ok "节点 $tag 已删除"
    sleep 0.6
  else
    rc=$?
    rollback "$rc" "应用配置失败，已撤销删除"
    echo
    pause || true
  fi
}

menu_service() {
  local c auto start_lbl
  while :; do
    title "服务管理"
    auto="${D}已关闭${N}"
    svc_ctl is-enabled && auto="${G}已开启${N}"
    svc_ctl is-active && start_lbl="重启服务" || start_lbl="启动服务"
    printf '%s1%s  %s\n' "$C" "$N" "$start_lbl"
    printf '%s2%s  停止服务\n' "$C" "$N"
    printf '%s3%s  %s[%s]\n' "$C" "$N" "$(_pad_left "开机自启" 12)" "$auto"
    hr
    printf '%s0%s  返回\n\n' "$C" "$N"
    read -rp "› " c || return 0
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && return 0
    echo
    case $c in
      1)
        if apply; then
          sleep 0.6
        else
          echo
          pause || true
        fi
        ;;
      2)
        svc_ctl stop
        ok "服务已停止"
        sleep 0.6
        ;;
      3)
        if svc_ctl is-enabled; then
          svc_ctl disable
          ok "已关闭开机自启"
        else
          svc_ctl enable
          ok "已开启开机自启"
        fi
        sleep 0.6
        ;;
      *)
        err "无效选项，请输入 0-3"
        sleep 0.5
        ;;
    esac
  done
}

uninstall() {
  local svc_file="/etc/init.d/sing-box"
  [[ $OS == debian ]] && svc_file="/etc/systemd/system/sing-box.service"
  title "${R}彻底卸载${N}"
  warn "此操作将停止服务并永久清除以下内容："
  echo
  printf '  %s·%s %s%s\n' "$R" "$N" "$(_pad_left "内核程序" 10)" "$SB_BIN"
  [[ -e /usr/local/bin/sb ]] && printf '  %s·%s %s%s\n' "$R" "$N" "$(_pad_left "快捷命令" 10)" "/usr/local/bin/sb"
  printf '  %s·%s %s%s\n' "$R" "$N" "$(_pad_left "配置目录" 10)" "$SB_DIR（节点、证书、config.json）"
  printf '  %s·%s %s%s\n' "$R" "$N" "$(_pad_left "服务文件" 10)" "$svc_file"
  printf '  %s·%s %s%s\n' "$R" "$N" "$(_pad_left "运行日志" 10)" "$SB_LOG"
  echo
  if ! confirm "确认彻底卸载？"; then
    info "已取消"
    sleep 0.5
    return 0
  fi
  echo
  info "正在停止服务并清理文件..."
  svc_ctl stop
  svc_ctl disable
  release_lock
  rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box \
    "$SB_BIN" /usr/local/bin/sb "$SB_LOG" /run/sing-box.pid
  rm -rf "$SB_DIR"
  [[ $OS == debian ]] && systemctl daemon-reload
  ok "已彻底卸载并清理全部数据"
  exit 0
}

# ───────── 主界面 ─────────
header() {
  clear
  if sb_installed; then
    local st n=0 v
    [[ -f $NODES ]] && n=$(nodes_count 2>/dev/null || echo "?")
    svc_ctl is-active && st="${G}● 运行中${N}" || st="${D}○ 已停止${N}"
    v=$(sb_version)
    printf '%ssing-box%s  %s  %sv%s · %s 节点%s\n' "$B" "$N" "$st" "$D" "${v:-?}" "$n" "$N"
  else
    printf '%ssing-box%s\n' "$B" "$N"
  fi
  hr
}

main_menu() {
  local c
  while :; do
    header
    echo
    printf '%s1%s  %s%s6%s  服务管理\n' "$C" "$N" "$(_pad_left "节点列表" 16)" "$C" "$N"
    printf '%s2%s  %s%s7%s  查看日志\n' "$C" "$N" "$(_pad_left "添加节点" 16)" "$C" "$N"
    printf '%s3%s  %s%s8%s  更新内核\n' "$C" "$N" "$(_pad_left "编辑节点" 16)" "$C" "$N"
    printf '%s4%s  %s%s9%s  彻底卸载\n' "$C" "$N" "$(_pad_left "删除节点" 16)" "$C" "$N"
    printf '%s5%s  %s%s0%s  退出面板\n\n' "$C" "$N" "$(_pad_left "分享链接" 16)" "$C" "$N"
    read -rp "› " c || exit 0
    case $c in
      1)
        title "节点列表"
        list_nodes || true
        echo
        pause || true
        ;;
      2) menu_add ;;
      3) menu_edit ;;
      4) menu_del ;;
      5) menu_links ;;
      6) menu_service ;;
      7)
        title "运行日志" "${D}最近 40 行${N}"
        svc_logs 40
        echo
        pause || true
        ;;
      8) update_core ;;
      9) uninstall ;;
      0)
        clear
        exit 0
        ;;
    esac
  done
}

# ───────── 入口 ─────────
acquire_lock
ensure_deps
init_dirs
if ! sb_installed; then
  header
  echo
  info "未检测到 sing-box 内核"
  confirm "是否立即下载安装？" || exit 0
  echo
  install_singbox || exit 1
  sleep 0.6
elif ! svc_exists; then
  svc_install
fi
if [[ -f $0 && $(readlink -f "$0") != /usr/local/bin/sb ]]; then
  install -m755 "$0" /usr/local/bin/sb 2>/dev/null || true
fi
main_menu
