#!/usr/bin/env bash
# Sing-box 极简交互式面板（仅支持 Debian / Alpine）
# 协议：SOCKS / Shadowsocks / Hysteria2 / VLESS(Reality) / AnyTLS / Snell(v5/v6)

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

SB_BIN=/usr/local/bin/sing-box
SB_DIR=/etc/sing-box
CONF=$SB_DIR/config.json
NODES=$SB_DIR/nodes.json
CERT_DIR=$SB_DIR/cert
SB_LOG=/var/log/sing-box.log
MIN_VER=1.14.0
DEFAULT_SNI=www.apache.org

# ───────── UI ─────────
B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
info() { printf '%s[信息]%s %s\n' "$D" "$N" "$*"; }
note() { printf '%s[注意]%s %s\n' "$C" "$N" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$Y" "$N" "$*"; }
err() { printf '%s[错误]%s %s\n' "$R" "$N" "$*"; }
ok() { printf '%s[正确]%s %s\n' "$G" "$N" "$*"; }
pause() {
  read -rsp $'按回车返回…' _ || return 1
  echo
}
ask() {
  local v
  read -rp "$1${2:+ [$2]}: " v || return 1
  REPLY="${v:-${2:-}}"
}
confirm() {
  local v
  read -rp "$1 [y/N]: " v || return 1
  [[ $v =~ ^[Yy]$ ]]
}
title() {
  header
  printf '%s▸%s %s%s%s\n' "$C" "$N" "$B" "$1" "$N"
}
_pad_left() { # $1=text $2=display_width
  local s=$1 target=$2 chars bytes w
  chars=${#s}
  bytes=$(printf '%s' "$s" | wc -c)
  w=$((chars + (bytes - chars) / 2))
  printf '%s' "$s"
  ((w < target)) && printf '%*s' $((target - w)) ''
}

# ───────── 环境预检与锁 ─────────
[[ $EUID -ne 0 ]] && {
  echo "请使用 root 运行"
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
LOCK_DIR=""
cleanup() {
  if [[ -n $LOCK_DIR ]]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  [[ -n $RUN_TMP ]] && rm -rf "$RUN_TMP"
  rm -f "$SB_DIR"/.tmp.* 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; echo; exit 130' INT TERM HUP

acquire_lock() {
  mkdir -p "$SB_DIR" && chmod 700 "$SB_DIR"
  local ld="$SB_DIR/.panel.lock"
  if ! mkdir "$ld" 2>/dev/null; then
    local pid
    pid=$(cat "$ld/pid" 2>/dev/null || true)
    if [[ -n $pid ]] && kill -0 "$pid" 2>/dev/null; then
      err "已有另一个面板实例正在运行 (PID: $pid)"
      exit 1
    fi
    rm -rf "$ld"
    mkdir "$ld" 2>/dev/null || {
      err "获取运行锁失败"
      exit 1
    }
  fi
  LOCK_DIR="$ld"
  printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
}

init_dirs() {
  mkdir -p "$SB_DIR" "$CERT_DIR" && chmod 700 "$SB_DIR" "$CERT_DIR"
  if [[ ! -f $NODES ]]; then
    if [[ -s $CONF ]]; then
      local bak
      bak="$CONF.bak.$(date +%Y%m%d%H%M%S)"
      cp -a "$CONF" "$bak"
      warn "检测到已有非面板管理的 config.json，已备份至：$bak"
      confirm "是否初始化空节点列表并由面板接管配置？" || exit 0
    fi
    echo '[]' >"$NODES"
    chmod 600 "$NODES"
  fi
}

# ───────── 基础环境与服务 ─────────
ensure_deps() {
  local pk=() c
  for c in curl jq openssl tar ss; do
    command -v "$c" >/dev/null && continue
    [[ $c == ss ]] && pk+=(iproute2) || pk+=("$c")
  done
  [[ ${#pk[@]} -eq 0 ]] && return 0
  if [[ $OS == debian ]]; then
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq "${pk[@]}" ca-certificates >/dev/null 2>&1
  else
    apk add --no-cache "${pk[@]}" ca-certificates >/dev/null 2>&1
  fi || {
    err "依赖安装失败"
    exit 1
  }
}

svc_exists() {
  if [[ $OS == debian ]]; then
    [[ -f /etc/systemd/system/sing-box.service ]]
  else
    [[ -f /etc/init.d/sing-box ]]
  fi
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
command_background=true
pidfile="/run/sing-box.pid"
output_log="$SB_LOG"
error_log="$SB_LOG"

depend() {
  need net
  after firewall
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
    info "暂无日志"
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
  [[ $ip =~ ^[0-9a-fA-F:]+$ ]] || return 1
  [[ $ip == *:*:* ]] || [[ $ip == *::* ]] || return 1
  [[ $ip != *:::* ]] || return 1
  local dc=${ip//[^:]/}
  ((${#dc} >= 2 && ${#dc} <= 7))
}

_fetch_ip() { # $1=-4|-6
  local ip u
  for u in "https://api${1#-}.ipify.org" "https://ip.sb" "https://ifconfig.me"; do
    ip=$(curl -fsS "$1" -m 2 "$u" 2>/dev/null | tr -d '[:space:]') || continue
    if [[ $1 == -4 ]] && _valid_ipv4 "$ip"; then
      echo "$ip"
      return 0
    elif [[ $1 == -6 ]] && _valid_ipv6 "$ip"; then
      echo "$ip"
      return 0
    fi
  done
}

detect_ips() {
  [[ -n ${IP_DETECTED:-} ]] && return
  IP_DETECTED=1
  _fetch_ip -4 >"$RUN_TMP/ip4" &
  _fetch_ip -6 >"$RUN_TMP/ip6" &
  wait
  [[ -s $RUN_TMP/ip4 ]] && PUBIP4=$(<"$RUN_TMP/ip4") || PUBIP4=""
  [[ -s $RUN_TMP/ip6 ]] && PUBIP6=$(<"$RUN_TMP/ip6") || PUBIP6=""
}

listen_addr() {
  if [[ -f /proc/net/if_inet6 ]]; then
    echo "::"
  else
    echo "0.0.0.0"
  fi
}

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
  local i max=$(( ${#va[@]} > ${#vb[@]} ? ${#va[@]} : ${#vb[@]} ))
  for ((i = 0; i < max; i++)); do
    local x=${va[i]:-0} y=${vb[i]:-0}
    ((10#$x > 10#$y)) && return 0
    ((10#$x < 10#$y)) && return 1
  done
  ((a_pre <= b_pre))
}

core_ok() {
  local a
  a=$(sb_version)
  [[ -n $a ]] && ver_ge "$a" "$MIN_VER"
}

_latest_sb_ver() {
  local loc v
  loc=$(curl -fsSL -m 10 -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null || true)
  v=${loc##*/}
  v=${v#v}
  if [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
    echo "$v"
    return 0
  fi
  v=$(curl -fsSL -m 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
  [[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] && echo "$v"
}

_verify_sha256() { # $1=file $2=expected_hex
  local got=""
  if command -v sha256sum >/dev/null; then
    got=$(sha256sum "$1" 2>/dev/null | awk '{print $1}')
  elif command -v openssl >/dev/null; then
    got=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}')
  else
    return 0
  fi
  [[ -n $got && $got == "$2" ]]
}

install_singbox() {
  local arch ver tmp libc="-glibc" cur_v pkg_name url
  case $(uname -m) in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7l) arch=armv7 ;;
    i386 | i686) arch=386 ;;
    *)
      err "不支持的架构：$(uname -m)"
      return 1
      ;;
  esac
  [[ $OS == alpine ]] && libc="-musl"
  cur_v=$(sb_version || true)
  ver=$(_latest_sb_ver || true)
  if [[ -z $ver ]]; then
    err "获取最新版本失败"
    if [[ -n $cur_v ]] && core_ok; then
      info "保留当前版本 v$cur_v"
      return 1
    fi
    confirm "是否改用最低支持版本 $MIN_VER 安装？" || return 1
    ver=$MIN_VER
  elif sb_installed && [[ $cur_v == "$ver" ]]; then
    ok "当前已是最新版本 v$ver"
    confirm "是否强制重新安装？" || return 1
  fi
  pkg_name="sing-box-$ver-linux-$arch$libc.tar.gz"
  url="https://github.com/SagerNet/sing-box/releases/download/v$ver/$pkg_name"
  tmp=$(mktemp -d "$RUN_TMP"/dl.XXXXXX)
  info "正在下载 Sing-box v$ver ..."
  if ! curl -fsSL --connect-timeout 15 -m 120 -o "$tmp/sb.tgz" "$url" 2>/dev/null; then
    err "下载安装包失败"
    rm -rf "$tmp"
    return 1
  fi
  if curl -fsSL --connect-timeout 10 -m 15 -o "$tmp/checksums.txt" \
    "https://github.com/SagerNet/sing-box/releases/download/v$ver/checksums.txt" 2>/dev/null; then
    local expected
    expected=$(awk -v f="$pkg_name" '$2==f {print $1; exit}' "$tmp/checksums.txt")
    if [[ -n $expected ]] && ! _verify_sha256 "$tmp/sb.tgz" "$expected"; then
      err "安装包 SHA256 校验失败"
      rm -rf "$tmp"
      return 1
    fi
  fi
  if ! tar -xzf "$tmp/sb.tgz" -C "$tmp" 2>/dev/null || ! install -m755 "$tmp"/sing-box-*/sing-box "$SB_BIN" 2>/dev/null; then
    err "解压或安装二进制失败"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  init_dirs
  svc_install
  local v
  v=$(sb_version)
  if [[ -z $v ]]; then
    err "安装后无法执行，请检查系统库兼容性"
    return 1
  fi
  ok "Sing-box $v 已安装"
}

# ───────── 配置生成与生效 ─────────
gen_config() {
  local la out_file=$1
  la=$(listen_addr)
  jq --arg la "$la" '{
    log: {level: "warn", timestamp: true},
    dns: {
      servers: [{type: "local", tag: "local"}]
    },
    inbounds: [ .[] |
      if .type == "socks" then
        {type: "socks", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true, tcp_fast_open: true,
         users: [{username: .user, password: .pass}]}
      elif .type == "shadowsocks" then
        {type: "shadowsocks", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true, tcp_fast_open: true,
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
         reuse_addr: true, tcp_fast_open: true,
         users: [{name: .tag, uuid: .uuid, flow: "xtls-rprx-vision"}],
         tls: {enabled: true, server_name: .sni,
               reality: {enabled: true, handshake: {server: .sni, server_port: 443},
                         private_key: .priv, short_id: [.sid], max_time_difference: "1m"}}}
      elif .type == "anytls" then
        {type: "anytls", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true, tcp_fast_open: true,
         users: [{name: .tag, password: .password}],
         tls: {enabled: true, server_name: .sni, min_version: "1.2", certificate_path: .cert, key_path: .key}}
      elif .type == "snell" then
        {type: "snell", tag: .tag, listen: $la, listen_port: .port,
         reuse_addr: true, tcp_fast_open: true,
         version: .version, psk: .psk}
        + (if .version == 6 then {mode: (.mode // "default")} else {obfs_mode: (.obfs // "none")} end)
      else empty end
    ],
    outbounds: [{type: "direct", tag: "direct"}],
    route: {
      rules: [
        {ip_cidr: ["127.0.0.0/8", "::1/128", "169.254.0.0/16", "fe80::/10", "224.0.0.0/4", "ff00::/8"], action: "reject"}
      ],
      default_domain_resolver: "local",
      final: "direct"
    }
  }' "$NODES" >"$out_file"
}

apply() { # return 0=成功; 1=校验/生成失败($CONF未改); 2=写入或服务启动失败($CONF已改)
  local conf_tmp out
  conf_tmp=$(mktemp "$SB_DIR/.tmp.conf.XXXXXX") || {
    err "创建临时配置文件失败"
    return 1
  }
  if ! gen_config "$conf_tmp"; then
    err "生成配置失败"
    rm -f "$conf_tmp"
    return 1
  fi
  if ! out=$("$SB_BIN" check -c "$conf_tmp" 2>&1); then
    err "配置校验失败"
    printf '%s\n' "$out"
    core_ok || warn "Snell / gecko 需要 Sing-box >= $MIN_VER，请先更新内核"
    rm -f "$conf_tmp"
    return 1
  fi
  if ! { chmod 600 "$conf_tmp" && mv "$conf_tmp" "$CONF"; }; then
    err "写入配置失败"
    rm -f "$conf_tmp"
    return 2
  fi
  if [[ $(jq length "$NODES") -eq 0 ]]; then
    svc_ctl stop
    ok "节点已清空，服务已停止"
    return 0
  fi
  svc_ctl enable
  svc_ctl restart
  local i
  for i in 1 2 3 4 5 6; do
    sleep 0.5
    if svc_ctl is-active; then
      if [[ $i -ge 2 ]]; then
        ok "配置已生效"
        return 0
      fi
      # 等待一次额外确认避免启动瞬间崩溃误判
      sleep 0.6
      svc_ctl is-active && {
        ok "配置已生效"
        return 0
      }
    fi
  done
  err "服务启动失败，最近日志："
  svc_logs 12
  return 2
}

# ───────── 通用辅助 ─────────
rnd() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_sni() {
  [[ ${#1} -le 253 ]] && [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9-]{2,63}$ ]]
}
valid_host() {
  [[ -z $1 ]] || valid_sni "$1" || _valid_ipv4 "$1" || _valid_ipv6 "$1"
}
valid_ss2022_psk() {
  local need=16 raw
  [[ $1 == 2022-blake3-aes-256-gcm ]] && need=32
  printf %s "$2" | base64 -d >/dev/null 2>&1 || return 1
  raw=$(printf %s "$2" | base64 -d 2>/dev/null | wc -c)
  ((raw == need))
}
valid_snell_psk() {
  local len
  LC_ALL=C len=${#2}
  [[ -n $2 ]] && (($1 != 6 || (len >= 12 && len <= 255)))
}

proto_net() { # $1=type -> tcp|udp|both
  case $1 in
    hysteria2) echo udp ;;
    socks | shadowsocks) echo both ;;
    *) echo tcp ;;
  esac
}

port_free() { # $1=port $2=proto(tcp|udp|both, default both) $3=exclude_idx(optional)
  local p=$1 net=${2:-both} ex=${3:--1}
  if [[ $net == tcp || $net == both ]]; then
    ss -lnt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$p$" && return 1
  fi
  if [[ $net == udp || $net == both ]]; then
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

ask_port() { # $1=proto_type
  local net def
  net=$(proto_net "${1:-}")
  while :; do
    def=$((((RANDOM << 15 | RANDOM) % 40001) + 20000))
    port_free "$def" "$net" && break
  done
  while :; do
    ask "端口（0=取消）" "$def" || return 1
    [[ $REPLY == 0 ]] && return 1
    valid_port "$REPLY" || {
      err "端口无效 (1-65535)"
      continue
    }
    PORT=$((10#$REPLY))
    port_free "$PORT" "$net" || {
      err "端口已被占用"
      continue
    }
    break
  done
}

ask_sni() { # $1=提示 $2=变量名（默认 SNI）
  local var=${2:-SNI}
  while :; do
    ask "$1（0=取消）" "$DEFAULT_SNI" || return 1
    [[ $REPLY == 0 ]] && return 1
    valid_sni "$REPLY" && {
      printf -v "$var" '%s' "$REPLY"
      return 0
    }
    err "域名 / SNI 格式无效（须为合法域名，如 example.com）"
  done
}

_cert_valid() {
  [[ -s $1 && -s $2 ]] || return 1
  local cp kp
  cp=$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null) || return 1
  kp=$(openssl pkey -in "$2" -pubout 2>/dev/null) || return 1
  [[ -n $cp && $cp == "$kp" ]]
}

ask_cert() {
  ask_sni "域名 / SNI" SNI || return 1
  while :; do
    ask "证书路径（留空=自签，0=取消）" "" || return 1
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
    else
      ask "私钥路径（0=取消）" "" || return 1
      [[ $REPLY == 0 ]] && return 1
      KEY=$REPLY
      if ! _cert_valid "$CERT" "$KEY"; then
        err "证书或私钥不存在/无效（留空证书路径可改用自签）"
        continue
      fi
      while :; do
        ask "客户端连接地址（-=自动用服务器 IP）" "$SNI" || return 1
        [[ $REPLY == "-" ]] && REPLY=""
        valid_host "$REPLY" && {
          HOST=$REPLY
          break
        }
        err "连接地址格式无效"
      done
      INSECURE=0
      return 0
    fi
  done
}

jqw() {
  local t
  t=$(mktemp "$SB_DIR/.tmp.nodes.XXXXXX") || return 1
  if jq "$@" "$NODES" >"$t" && chmod 600 "$t" && mv "$t" "$NODES"; then
    return 0
  else
    rm -f "$t"
    return 1
  fi
}
snapshot() {
  BAK_NODES="$RUN_TMP/nodes.$$.$RANDOM.bak"
  cp "$NODES" "$BAK_NODES"
  BAK_CONF=""
  [[ -f $CONF ]] && {
    BAK_CONF="$RUN_TMP/conf.$$.$RANDOM.bak"
    cp "$CONF" "$BAK_CONF"
  }
}
rollback() { # $1=apply_rc $2=msg
  local rc=$1 msg=$2 ct=""
  cp "$BAK_NODES" "$NODES"
  chmod 600 "$NODES"
  if [[ $rc -eq 2 ]]; then
    if [[ -n $BAK_CONF && -f $BAK_CONF ]]; then
      cp "$BAK_CONF" "$CONF"
      chmod 600 "$CONF"
    elif ct=$(mktemp "$SB_DIR/.tmp.conf.XXXXXX" 2>/dev/null) && gen_config "$ct" 2>/dev/null; then
      chmod 600 "$ct" && mv "$ct" "$CONF"
    else
      rm -f "$ct" 2>/dev/null || true
    fi
    if [[ $(jq length "$NODES") -eq 0 ]]; then
      svc_ctl stop
    else
      svc_ctl restart
    fi
  fi
  err "$msg"
}
setf() { jqw --argjson i "$1" --arg k "$2" --arg v "$3" '.[$i][$k]=$v'; }
g() { jq -r --argjson i "$IDX" --arg k "$1" '.[$i][$k] // empty' "$NODES"; }

choose_node() { # 交互选择节点并设置 IDX；取消返回 1
  local n def=""
  n=$(jq length "$NODES")
  [[ $n -eq 1 ]] && def=1
  while :; do
    ask "编号（0=返回）" "$def" || return 1
    [[ $REPLY == 0 ]] && return 1
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      IDX=$((10#$REPLY - 1))
      return 0
    fi
    [[ -n $REPLY ]] && err "编号无效（1-$n）"
  done
}

ensure_core() {
  core_ok && return 0
  warn "$1 需要 Sing-box >= $MIN_VER（当前 $(sb_version)）"
  confirm "立即更新内核？" && install_singbox && core_ok
}

# ───────── 添加节点 ─────────
add_socks() {
  ask_port socks || return 1
  local u p
  while :; do
    ask "用户名（0=取消）" "$(rnd 6)" || return 1
    [[ $REPLY == 0 ]] && return 1
    [[ -n $REPLY && ! $REPLY =~ [[:space:]] ]] && {
      u=$REPLY
      break
    }
    err "用户名不能为空或包含空白字符"
  done
  ask "密码（0=取消）" "$(rnd 12)" || return 1
  [[ $REPLY == 0 ]] && return 1
  p=$REPLY
  jqw --argjson port "$PORT" --arg u "$u" --arg p "$p" \
    '. + [{type:"socks",tag:("socks-"+($port|tostring)),port:$port,user:$u,pass:$p}]'
}

pick_ss_method() {
  printf '%s1%s  2022-blake3-aes-128-gcm\n%s2%s  2022-blake3-aes-256-gcm\n' "$C" "$N" "$C" "$N"
  printf '%s3%s  aes-256-gcm\n%s4%s  chacha20-ietf-poly1305\n' "$C" "$N" "$C" "$N"
  ask "加密方式（0=取消）" "1" || return 1
  [[ $REPLY == 0 ]] && return 1
  case $REPLY in
    2)
      SS_M=2022-blake3-aes-256-gcm
      SS_P=$(openssl rand -base64 32)
      ;;
    3)
      SS_M=aes-256-gcm
      SS_P=$(rnd 20)
      ;;
    4)
      SS_M=chacha20-ietf-poly1305
      SS_P=$(rnd 20)
      ;;
    *)
      SS_M=2022-blake3-aes-128-gcm
      SS_P=$(openssl rand -base64 16)
      ;;
  esac
}

add_ss() {
  ask_port shadowsocks || return 1
  pick_ss_method || return 1
  jqw --argjson port "$PORT" --arg m "$SS_M" --arg p "$SS_P" \
    '. + [{type:"shadowsocks",tag:("ss-"+($port|tostring)),port:$port,method:$m,password:$p}]'
}

pick_hy2_obfs() { # 设置 OBFS_T
  printf '%s0%s  不启用\n%s1%s  salamander\n%s2%s  gecko  %s(需 Sing-box>=1.14)%s\n' "$C" "$N" "$C" "$N" "$C" "$N" "$D" "$N"
  ask "QUIC 混淆" "0" || return 1
  OBFS_T=""
  case $REPLY in
    1) OBFS_T=salamander ;;
    2)
      ensure_core "gecko" || return 1
      OBFS_T=gecko
      ;;
  esac
}

add_hy2() {
  ask_port hysteria2 || return 1
  ask_cert || return 1
  ask "密码（0=取消）" "$(rnd 16)" || return 1
  [[ $REPLY == 0 ]] && return 1
  local p=$REPLY o=""
  pick_hy2_obfs || return 1
  if [[ -n $OBFS_T ]]; then
    ask "混淆密码（0=取消）" "$(rnd 16)" || return 1
    [[ $REPLY == 0 ]] && return 1
    o=$REPLY
  fi
  jqw --argjson port "$PORT" --arg p "$p" --arg o "$o" --arg ot "$OBFS_T" --arg c "$CERT" --arg k "$KEY" \
    --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"hysteria2",tag:("hy2-"+($port|tostring)),port:$port,password:$p,obfs_type:$ot,obfs:$o,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
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
  if [[ -z $RPRIV || -z $RPUB || -z $RSID ]]; then
    err "解析 Reality 密钥对失败"
    return 1
  fi
}

gen_uuid() {
  "$SB_BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null
}

add_vless() {
  ask_port vless || return 1
  local sni uuid
  ask_sni "Reality 伪装域名" sni || return 1
  gen_reality || return 1
  uuid=$(gen_uuid)
  [[ -n $uuid ]] || {
    err "生成 UUID 失败"
    return 1
  }
  jqw --argjson port "$PORT" --arg sni "$sni" --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" \
    --arg uuid "$uuid" \
    '. + [{type:"vless",tag:("vless-"+($port|tostring)),port:$port,uuid:$uuid,sni:$sni,priv:$priv,pub:$pub,sid:$sid}]'
}

add_anytls() {
  ask_port anytls || return 1
  ask_cert || return 1
  ask "密码（0=取消）" "$(rnd 16)" || return 1
  [[ $REPLY == 0 ]] && return 1
  local p=$REPLY
  jqw --argjson port "$PORT" --arg p "$p" --arg c "$CERT" --arg k "$KEY" \
    --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"anytls",tag:("anytls-"+($port|tostring)),port:$port,password:$p,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

add_snell() {
  ensure_core "Snell" || return 1
  ask_port snell || return 1
  local v o=none psk oh=""
  while :; do
    ask "版本 5/6（0=取消）" "5" || return 1
    [[ $REPLY == 0 ]] && return 1
    [[ $REPLY == 5 || $REPLY == 6 ]] && {
      v=$REPLY
      break
    }
    err "仅支持版本 5 或 6"
  done
  while :; do
    ask "PSK（0=取消）" "$(rnd 20)" || return 1
    [[ $REPLY == 0 ]] && return 1
    psk=$REPLY
    valid_snell_psk "$v" "$psk" && break
    if [[ $v == 6 ]]; then
      err "v6 的 PSK 须为 12-255 字节"
    else
      err "PSK 不能为空"
    fi
  done
  if [[ $v == 5 ]]; then
    while :; do
      ask "HTTP 混淆 none/http（0=取消）" "none" || return 1
      [[ $REPLY == 0 ]] && return 1
      [[ $REPLY == none || $REPLY == http ]] && {
        o=$REPLY
        break
      }
      err "仅支持 none 或 http"
    done
    if [[ $o == http ]]; then
      ask_sni "混淆域名" oh || return 1
    fi
  fi
  jqw --argjson port "$PORT" --argjson v "$v" --arg p "$psk" --arg o "$o" --arg oh "$oh" \
    '. + [{type:"snell",tag:("snell-"+($port|tostring)),port:$port,version:$v,psk:$p}
     + (if $v==6 then {mode:"default"} elif $o=="http" then {obfs:$o,obfs_host:$oh} else {obfs:$o} end)]'
}

menu_add() {
  local c
  while :; do
    title "添加节点"
    printf '%s1%s  %s%s2%s  Hysteria2\n' "$C" "$N" "$(_pad_left "VLESS" 14)" "$C" "$N"
    printf '%s3%s  %s%s4%s  Snell\n' "$C" "$N" "$(_pad_left "AnyTLS" 14)" "$C" "$N"
    printf '%s5%s  %s%s6%s  SOCKS\n' "$C" "$N" "$(_pad_left "Shadowsocks" 14)" "$C" "$N"
    printf '%s0%s  返回\n' "$C" "$N"
    read -rp "> " c || return 0
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && return 0
    [[ $c =~ ^[1-6]$ ]] && break
    err "无效选项"
    sleep 0.6
  done
  echo
  local n rc
  n=$(jq length "$NODES")
  snapshot
  case $c in
    1) add_vless ;; 2) add_hy2 ;; 3) add_anytls ;; 4) add_snell ;; 5) add_ss ;; 6) add_socks ;;
  esac
  if [[ $(jq length "$NODES") -eq $n ]]; then
    return 0
  fi
  IDX=$n
  if apply; then
    echo
    show_link "$IDX"
    note "云服务器请在安全组放行端口 $(g port)"
  else
    rc=$?
    rollback "$rc" "已撤销本次添加"
  fi
  pause || true
}

# ───────── 列表 / 链接 ─────────
list_nodes() {
  if [[ $(jq length "$NODES") -eq 0 ]]; then
    info "暂无节点"
    return 1
  fi
  printf '%s%s%s%s%s\n' \
    "$D" "$(_pad_left "#" 4)" "$(_pad_left "协议" 13)" "$(_pad_left "端口" 7)" "摘要$N"
  jq -r 'to_entries[] | .key+1 as $i | .value |
    "\($i) \(.type) \(.port) " +
    (if .type=="shadowsocks" then .method
     elif .type=="snell" then "v\(.version)" + (if .version==6 then "/\(.mode)" else (if .obfs=="http" then "/http" else "" end) end)
     elif .type=="hysteria2" then .sni + (if (.obfs//"")!="" then "/\(if (.obfs_type//"")=="" then "salamander" else .obfs_type end)" else "" end)
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
    def b64: @base64 | gsub("\\+"; "-") | gsub("/"; "_") | sub("=+$"; "");
    (.[$i] // {}) as $n | ($ip | br) as $h
    | if $n.type == "socks" then
        "socks5://\($n.user | e):\($n.pass | e)@\($h):\($n.port)#\($n.tag | e)"
      elif $n.type == "shadowsocks" then
        "ss://\(($n.method // "") + ":" + ($n.password // "") | b64)@\($h):\($n.port)#\($n.tag | e)"
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
        + (if ($n.version == 5 and $n.obfs == "http") then
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
    printf '%sIPv4:%s\n%s%s%s\n' "$D" "$N" "$G" "$(build_link "$PUBIP4")" "$N"
    printf '%sIPv6:%s\n%s%s%s\n\n' "$D" "$N" "$G" "$(build_link "$PUBIP6")" "$N"
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
    sleep 1
    return 0
  }
  local n
  n=$(jq length "$NODES")
  echo
  local i
  while :; do
    ask "编号（a=全部，0=返回）" "a" || return 0
    [[ $REPLY == 0 ]] && return 0
    if [[ $REPLY == a ]]; then
      echo
      for ((i = 0; i < n; i++)); do show_link "$i"; done
      break
    fi
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      echo
      show_link "$((10#$REPLY - 1))"
      break
    fi
    err "编号无效（1-$n 或 a）"
  done
  pause || true
}

# ───────── 修改入站 ─────────
node_fields() {
  case $(g type) in
    socks) FIELDS=("port:端口" "user:用户名" "pass:密码" "tag:节点名称") ;;
    shadowsocks) FIELDS=("port:端口" "method:加密方式" "password:密码" "tag:节点名称") ;;
    hysteria2) FIELDS=("port:端口" "password:密码" "obfs_type:QUIC 混淆" "obfs:混淆密码" "_cert:证书 / SNI" "host:连接地址" "insecure:跳过证书验证" "tag:节点名称") ;;
    vless) FIELDS=("port:端口" "sni:伪装域名" "uuid:UUID" "sid:ShortID" "_reality:重置 Reality 密钥对" "tag:节点名称") ;;
    anytls) FIELDS=("port:端口" "password:密码" "_cert:证书 / SNI" "host:连接地址" "insecure:跳过证书验证" "tag:节点名称") ;;
    snell)
      FIELDS=("port:端口" "psk:PSK" "version:版本")
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

_ask_match() { # $1=提示 $2=默认 $3=原值 $4=正则 $5=错误提示
  while :; do
    ask "$1（0=取消）" "$2" || return 1
    [[ $REPLY == 0 || $REPLY == "$3" ]] && return 1
    [[ $REPLY =~ $4 ]] && return 0
    err "$5"
  done
}

edit_field() { # return 0=需重启生效; 2=仅影响分享链接(无需重启); 1=未修改/取消
  local k=$1 cur np psk net
  cur=$(g "$k")
  case $k in
    port)
      net=$(proto_net "$(g type)")
      while :; do
        ask "新端口（0=取消）" "$cur" || return 1
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        valid_port "$REPLY" || {
          err "端口无效 (1-65535)"
          continue
        }
        np=$((10#$REPLY))
        port_free "$np" "$net" "$IDX" && break
        err "端口已被占用"
      done
      local tag
      tag=$(g tag | sed "s/-$cur\$/-$np/")
      jqw --argjson i "$IDX" --arg t "$tag" --argjson p "$np" '.[$i].tag=$t | .[$i].port=$p'
      ;;
    method)
      pick_ss_method || return 1
      jqw --argjson i "$IDX" --arg m "$SS_M" --arg p "$SS_P" '.[$i].method=$m | .[$i].password=$p'
      note "已按新加密方式重新生成密码"
      sleep 0.8
      ;;
    password)
      while :; do
        ask "新密码（0=取消）" "$cur" || return 1
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        [[ -n $REPLY ]] || {
          err "不能为空"
          continue
        }
        if [[ $(g type) == shadowsocks && $(g method) == 2022-blake3-* ]]; then
          valid_ss2022_psk "$(g method)" "$REPLY" || {
            err "SS 2022 密码须为对应长度（16/32 字节）的 Base64"
            continue
          }
        fi
        break
      done
      setf "$IDX" password "$REPLY"
      ;;
    sni | obfs_host)
      local label="新伪装域名" def=$cur
      [[ $k == obfs_host ]] && {
        label="新混淆域名"
        def=${cur:-$DEFAULT_SNI}
      }
      while :; do
        ask "$label（0=取消）" "$def" || return 1
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        valid_sni "$REPLY" && break
        err "域名 / SNI 格式无效"
      done
      setf "$IDX" "$k" "$REPLY"
      [[ $k == obfs_host ]] && return 2
      ;;
    host)
      while :; do
        ask "新连接地址（-=留空自动IP，0=取消）" "${cur:--}" || return 1
        [[ $REPLY == 0 ]] && return 1
        [[ $REPLY == "-" ]] && REPLY=""
        [[ $REPLY == "$cur" ]] && return 1
        valid_host "$REPLY" && break
        err "连接地址格式无效"
      done
      setf "$IDX" host "$REPLY"
      return 2
      ;;
    insecure)
      while :; do
        ask "跳过证书验证 0/1（0=不跳过，1=跳过，回车=取消）" "" || return 1
        [[ -z $REPLY ]] && return 1
        if [[ $REPLY == 0 || $REPLY == 1 ]]; then
          [[ $REPLY == "$cur" ]] && return 1
          jqw --argjson i "$IDX" --argjson v "$REPLY" '.[$i].insecure=$v'
          return 2
        fi
        err "请输入 0 或 1（直接回车取消）"
      done
      ;;
    tag)
      while :; do
        ask "新节点名称（0=取消）" "$cur" || return 1
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        if [[ ! $REPLY =~ ^[A-Za-z0-9._-]+$ ]]; then
          err "名称仅支持字母、数字、点、下划线和连字符"
          continue
        fi
        if jq -e --arg t "$REPLY" --argjson ex "$IDX" 'to_entries | any(.[]; .key != $ex and .value.tag == $t)' "$NODES" >/dev/null 2>&1; then
          err "节点名称已存在"
          continue
        fi
        break
      done
      setf "$IDX" tag "$REPLY"
      ;;
    version)
      while :; do
        ask "版本 5/6（0=取消）" "$cur" || return 1
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        [[ $REPLY == 5 || $REPLY == 6 ]] && break
        err "仅支持 5 或 6"
      done
      if [[ $REPLY == 6 ]]; then
        psk=$(g psk)
        if valid_snell_psk 6 "$psk"; then
          jqw --argjson i "$IDX" '.[$i].version=6 | .[$i].mode="default" | del(.[$i].obfs, .[$i].obfs_host)'
        else
          jqw --argjson i "$IDX" --arg p "$(rnd 20)" \
            '.[$i].version=6 | .[$i].mode="default" | .[$i].psk=$p | del(.[$i].obfs, .[$i].obfs_host)'
          note "v6 要求 PSK 12-255 字节，已重新生成"
          sleep 0.8
        fi
      else
        jqw --argjson i "$IDX" '.[$i].version=5 | .[$i].obfs="none" | del(.[$i].mode)'
      fi
      ;;
    obfs)
      if [[ $(g type) == snell ]]; then
        while :; do
          ask "HTTP 混淆 none/http（0=取消）" "${cur:-none}" || return 1
          [[ $REPLY == 0 || $REPLY == "${cur:-none}" ]] && return 1
          [[ $REPLY == none || $REPLY == http ]] && break
          err "仅支持 none 或 http"
        done
        if [[ $REPLY == http ]]; then
          local oh
          oh=$(g obfs_host)
          [[ -n $oh ]] || oh=$DEFAULT_SNI
          jqw --argjson i "$IDX" --arg oh "$oh" '.[$i].obfs="http" | .[$i].obfs_host=$oh'
        else
          jqw --argjson i "$IDX" '.[$i].obfs="none" | del(.[$i].obfs_host)'
        fi
      else
        ask "新混淆密码（-=关闭，0=取消）" "$cur" || return 1
        [[ $REPLY == 0 ]] && return 1
        [[ $REPLY == "-" ]] && REPLY=""
        [[ $REPLY == "$cur" ]] && return 1
        if [[ -z $REPLY ]]; then
          jqw --argjson i "$IDX" '.[$i] += {obfs:"",obfs_type:""}'
        else
          local ot
          ot=$(g obfs_type)
          jqw --argjson i "$IDX" --arg op "$REPLY" --arg ot "${ot:-salamander}" \
            '.[$i] += {obfs:$op,obfs_type:$ot}'
        fi
      fi
      ;;
    obfs_type)
      pick_hy2_obfs || {
        sleep 0.8
        return 1
      }
      if [[ -n $OBFS_T ]]; then
        local op
        op=$(g obfs)
        [[ -n $op ]] || {
          op=$(rnd 16)
          note "已生成混淆密码"
          sleep 0.8
        }
        jqw --argjson i "$IDX" --arg ot "$OBFS_T" --arg op "$op" '.[$i] += {obfs_type:$ot,obfs:$op}'
      else
        jqw --argjson i "$IDX" '.[$i] += {obfs_type:"",obfs:""}'
      fi
      ;;
    mode)
      _ask_match "模式 default/unshaped/unsafe-raw" "${cur:-default}" "${cur:-default}" \
        '^(default|unshaped|unsafe-raw)$' "模式无效" || return 1
      setf "$IDX" mode "$REPLY"
      ;;
    psk)
      while :; do
        ask "新 PSK（0=取消）" "$cur" || return 1
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        valid_snell_psk "$(g version)" "$REPLY" && break
        err "PSK 无效（v6 须为 12-255 字节）"
      done
      setf "$IDX" psk "$REPLY"
      ;;
    uuid)
      _ask_match "新 UUID" "$cur" "$cur" \
        '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' "UUID 格式无效" || return 1
      setf "$IDX" uuid "$REPLY"
      ;;
    sid)
      _ask_match "新 ShortID（偶数位十六进制，最长 16 位）" "$cur" "$cur" \
        '^([0-9a-fA-F]{2}){1,8}$' "ShortID 格式无效" || return 1
      setf "$IDX" sid "$REPLY"
      ;;
    _cert)
      ask_cert || {
        sleep 0.8
        return 1
      }
      jqw --argjson i "$IDX" --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson in "$INSECURE" \
        '.[$i] += {cert:$c,key:$k,sni:$sni,host:$h,insecure:$in}'
      ;;
    _reality)
      gen_reality || return 1
      jqw --argjson i "$IDX" --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" \
        '.[$i] += {priv:$priv,pub:$pub,sid:$sid}'
      ok "已生成新的密钥对"
      sleep 0.8
      ;;
    *)
      _ask_match "新值" "$cur" "$cur" '.+' "不能为空" || return 1
      setf "$IDX" "$k" "$REPLY"
      ;;
  esac
  return 0
}

menu_edit() {
  title "编辑节点"
  list_nodes || {
    sleep 1
    return 0
  }
  choose_node || return 0
  local dirty=0 link_dirty=0 i f k v rc c
  snapshot
  while :; do
    title "$(g tag)"
    node_fields
    i=1
    for f in "${FIELDS[@]}"; do
      k=${f%%:*}
      if [[ $k == _* ]]; then v=""; else
        v=$(g "$k")
        [[ -z $v ]] && v="—"
      fi
      printf '%s%s%s%s%s%s%s\n' \
        "$C" "$(_pad_left "$i" 3)" "$N" "$(_pad_left "${f#*:}" 20)" "$D" "$v" "$N"
      ((i++))
    done
    printf '%s%s%s%s%s%s\n' \
      "$C" "$(_pad_left "0" 3)" "$N" "$(_pad_left "保存并返回" 20)" "${C}q${N}  " "放弃修改"
    read -rp "> " c || {
      cp "$BAK_NODES" "$NODES"
      chmod 600 "$NODES"
      return 0
    }
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && break
    if [[ $c == q || $c == Q ]]; then
      cp "$BAK_NODES" "$NODES"
      chmod 600 "$NODES"
      info "已放弃修改"
      sleep 0.6
      return 0
    fi
    if [[ $c =~ ^[0-9]{1,2}$ ]] && ((10#$c >= 1 && 10#$c <= ${#FIELDS[@]})); then
      echo
      edit_field "${FIELDS[$((10#$c - 1))]%%:*}"
      rc=$?
      case $rc in
        0) dirty=1 ;;
        2) link_dirty=1 ;;
      esac
    fi
  done
  if [[ $dirty == 1 ]]; then
    echo
    if apply; then
      echo
      show_link "$IDX"
    else
      rc=$?
      rollback "$rc" "配置无效，已回滚修改"
    fi
    pause || true
  elif [[ $link_dirty == 1 ]]; then
    echo
    ok "已更新链接参数（无需重启服务）"
    show_link "$IDX"
    pause || true
  fi
}

# ───────── 删除 / 服务 / 日志 / 卸载 ─────────
menu_del() {
  title "删除节点"
  list_nodes || {
    sleep 1
    return 0
  }
  choose_node || return 0
  local port rc
  port=$(g port)
  confirm "确认删除 $(g type):$port ?" || return 0
  snapshot
  jqw --argjson i "$IDX" 'del(.[$i])'
  if apply; then
    ok "已删除"
    sleep 0.8
  else
    rc=$?
    rollback "$rc" "配置应用失败，已撤销删除"
    pause || true
  fi
}

menu_service() {
  local c auto
  while :; do
    title "服务管理"
    auto="${D}[已关闭]${N}"
    svc_ctl is-enabled && auto="${G}[已开启]${N}"
    printf '%s1%s  启动 / 重启\n%s2%s  停止服务\n%s3%s  开机自启  %s\n%s0%s  返回\n' "$C" "$N" "$C" "$N" "$C" "$N" "$auto" "$C" "$N"
    read -rp "> " c || return 0
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && return 0
    case $c in
      1)
        if apply; then
          sleep 0.8
        else
          pause || true
        fi
        ;;
      2)
        svc_ctl stop
        ok "服务已停止"
        sleep 0.8
        ;;
      3)
        if svc_ctl is-enabled; then
          svc_ctl disable
          ok "已关闭开机自启"
        else
          svc_ctl enable
          ok "已开启开机自启"
        fi
        sleep 0.8
        ;;
      *)
        err "无效选项"
        sleep 0.8
        continue
        ;;
    esac
    return 0
  done
}

uninstall() {
  local svc_file="/etc/init.d/sing-box"
  [[ $OS == debian ]] && svc_file="/etc/systemd/system/sing-box.service"
  title "${R}彻底卸载${N}"
  echo
  warn "将停止服务并删除以下全部数据（不可恢复）："
  printf '%s-%s %s%s\n' "$R" "$N" "$(_pad_left "内核程序" 10)" "$SB_BIN"
  printf '%s-%s %s%s\n' "$R" "$N" "$(_pad_left "快捷命令" 10)" "/usr/local/bin/sb"
  printf '%s-%s %s%s\n' "$R" "$N" "$(_pad_left "配置目录" 10)" "$SB_DIR（节点、证书、config.json）"
  printf '%s-%s %s%s\n' "$R" "$N" "$(_pad_left "服务文件" 10)" "$svc_file"
  printf '%s-%s %s%s\n' "$R" "$N" "$(_pad_left "运行日志" 10)" "$SB_LOG"
  echo
  if ! confirm "确认彻底卸载？"; then
    info "已取消卸载"
    sleep 0.6
    return 0
  fi
  echo
  info "正在停止服务并清理文件..."
  svc_ctl stop
  svc_ctl disable
  rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box \
    "$SB_BIN" /usr/local/bin/sb "$SB_LOG" /run/sing-box.pid
  rm -rf "$SB_DIR"
  LOCK_DIR=""
  [[ $OS == debian ]] && systemctl daemon-reload
  ok "已彻底卸载并清理全部数据"
  exit 0
}

# ───────── 主界面 ─────────
header() {
  clear
  if sb_installed; then
    local st n=0 v
    [[ -f $NODES ]] && n=$(jq length "$NODES" 2>/dev/null || echo 0)
    if svc_ctl is-active; then
      st="${G}● 运行中${N}"
    else
      st="${D}○ 已停止${N}"
    fi
    v=$(sb_version)
    printf '%sSing-box%s  %s  %sv%s · %s 节点%s\n' "$B" "$N" "$st" "$D" "${v:-?}" "$n" "$N"
  else
    printf '%sSing-box%s\n' "$B" "$N"
  fi
}

main_menu() {
  local c
  while :; do
    header
    printf '%s1%s  %s%s6%s  服务管理\n' "$C" "$N" "$(_pad_left "节点列表" 14)" "$C" "$N"
    printf '%s2%s  %s%s7%s  运行日志\n' "$C" "$N" "$(_pad_left "添加节点" 14)" "$C" "$N"
    printf '%s3%s  %s%s8%s  更新内核\n' "$C" "$N" "$(_pad_left "编辑节点" 14)" "$C" "$N"
    printf '%s4%s  %s%s9%s  彻底卸载\n' "$C" "$N" "$(_pad_left "删除节点" 14)" "$C" "$N"
    printf '%s5%s  %s%s0%s  退出\n' "$C" "$N" "$(_pad_left "分享链接" 14)" "$C" "$N"
    read -rp "> " c || exit 0
    case $c in
      1)
        title "节点列表"
        list_nodes || true
        pause || true
        ;;
      2) menu_add ;;
      3) menu_edit ;;
      4) menu_del ;;
      5) menu_links ;;
      6) menu_service ;;
      7)
        title "运行日志"
        svc_logs
        pause || true
        ;;
      8)
        title "更新内核"
        if install_singbox && apply; then
          sleep 1
        else
          pause || true
        fi
        ;;
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
if ! sb_installed; then
  header
  info "未检测到 Sing-box"
  confirm "是否安装？" || exit 0
  install_singbox || exit 1
  sleep 0.8
elif ! svc_exists; then
  svc_install
fi
init_dirs
if [[ -f $0 && $(readlink -f "$0") != /usr/local/bin/sb ]]; then
  install -m755 "$0" /usr/local/bin/sb 2>/dev/null || true
fi
main_menu
