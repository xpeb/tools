#!/usr/bin/env bash
# Xray-core 现代交互式面板（支持 Debian systemd / Alpine OpenRC，Alpine 需预装 bash）
# 支持协议：VLESS (Reality: RAW/XHTTP) / Hysteria2 / Trojan (TLS) / VMess (WS+TLS) / Shadowsocks / SOCKS5

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

XR_BIN=/usr/local/bin/xray
XR_DIR=/etc/xray
CERT_DIR=/etc/xray/cert
NODES=/etc/xray/nodes.json
CONF=/etc/xray/config.json
XR_LOG=/var/log/xray.log
SCRIPT_URL="https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh"
DEFAULT_SNI=www.apache.org

[[ $EUID -eq 0 ]] || { echo "请使用 root 权限运行此脚本"; exit 1; }
[[ -t 0 ]] || { echo "请勿通过管道直接执行，请使用 bash <(curl -fsSL ...) 运行"; exit 1; }
if command -v apt-get >/dev/null && command -v systemctl >/dev/null; then
  OS=debian
elif command -v apk >/dev/null && command -v rc-service >/dev/null; then
  OS=alpine
else
  echo "当前系统不受支持，仅兼容 Debian (systemd) 与 Alpine (OpenRC)"
  exit 1
fi

# ───────── 界面样式与交互引擎 ─────────
B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
RL_B=$'\001\e[1m\002' RL_D=$'\001\e[2m\002' RL_N=$'\001\e[0m\002'
_UTF8_CHAR="中"
UI_W=58
RULE=""

info() { printf "  ${D}·${N} %s\n" "$*"; }
note() { printf "  ${C}i${N} %s\n" "$*"; }
warn() { printf "  ${Y}!${N} %s\n" "$*"; }
ok() { printf "  ${G}✓${N} %s\n" "$*"; }
err() { printf "  ${R}✗${N} %s\n" "$*"; }
clr() { clear 2>/dev/null || printf '\033[H\033[2J'; }
sleep_frac() { sleep "$1" 2>/dev/null || sleep 1; }

show_toast() { # $1=函数名 $2=消息
  [[ -n ${2:-} ]] || return 0
  echo
  "$1" "$2"
}

_repeat_ch() {
  local out=""
  (($2 <= 0)) && return 0
  printf -v out '%*s' "$2" ''
  printf '%s' "${out// /$1}"
}

_str_width() { # $1=文本 -> 设置 _W
  local s=$1 ascii
  ascii=${s//[^ -~]/}
  if ((${#_UTF8_CHAR} == 1)); then
    _W=$((${#s} * 2 - ${#ascii}))
  else
    _W=$((${#ascii} + (${#s} - ${#ascii}) * 2 / 3))
  fi
}

ui_refresh() {
  local cols=""
  [[ -t 1 ]] && cols=$(stty size 2>/dev/null | awk '{print $2}') || true
  [[ $cols =~ ^[0-9]+$ ]] || cols=${COLUMNS:-58}
  ((cols < 54)) && cols=54
  ((cols > 68)) && cols=68
  UI_W=$cols
  RULE="${D}$(_repeat_ch '─' $((UI_W - 2)))${N}"
}

pad_print() { # $1=文本 $2=目标宽度 [$3=前缀色 [$4=后缀色]]
  local s=$1 target=$2 pre=${3:-} suf=${4:-} pad
  _str_width "$s"
  pad=$((target - _W))
  ((pad < 1)) && pad=1
  printf "%s%s%s%*s" "$pre" "$s" "$suf" "$pad" ""
}

ui_kv() { # $1=标签 $2=值 [$3=值颜色]
  printf "  "
  pad_print "$1" 12 "$D" "$N"
  printf "%s%s${N}\n" "${3:-}" "$2"
}

ui_step() { # $1=当前步骤 $2=总步骤 $3=标题
  printf "\n  ${C}[%s/%s]${N} ${B}%s${N}\n" "$1" "$2" "$3"
}

read_key() { # 读取单键并过滤方向键序列 -> REPLY (ESC|ENTER|char)；EOF 返回 1
  local k seq ch
  IFS= read -rsn1 k || return 1
  if [[ $k == $'\e' ]]; then
    if IFS= read -rsn1 -t 0.05 seq 2>/dev/null; then
      if [[ $seq == "[" || $seq == "O" ]]; then
        while IFS= read -rsn1 -t 0.02 ch 2>/dev/null; do
          [[ $ch =~ [A-Za-z~] ]] && break
        done
      fi
      REPLY=""
      return 0
    fi
    REPLY="ESC"
    return 0
  fi
  [[ -z $k ]] && { REPLY="ENTER"; return 0; }
  REPLY=$k
}

prompt_key() {
  echo
  printf "${C}›${N} "
  read_key || return 1
  echo
}

pause() {
  echo
  printf "${D}  按任意键继续…${N}"
  read_key >/dev/null 2>&1 || true
  echo
}

title() {
  header
  printf "  ${C}▸${N} ${B}%s${N}\n\n" "$1"
}

ask() { # $1=提示 $2=默认值 -> REPLY；EOF 返回 1（支持左右键行内编辑）
  local p
  if [[ -n $2 ]]; then
    p="  ${RL_B}$1${RL_N} ${RL_D}[$2]${RL_N}: "
    read -erp "$p" REPLY || return 1
    REPLY=${REPLY:-$2}
  else
    p="  ${RL_B}$1${RL_N}: "
    read -erp "$p" REPLY || return 1
  fi
}

ask_c() { ask "$@" && [[ $REPLY != 0 ]] || return 2; } # 0 / EOF 取消返回 2

# 通用带校验输入：$1=提示 $2=默认值 $3=校验函数 $4=错误提示 [$5=flags: empty_ok|reject_same|clear_dash|rand=<fn>]
# 返回：0=有效输入(REPLY)  1=与默认值相同(reject_same)  2=取消(0/EOF)
ask_valid() {
  local prompt=$1 def=$2 check=$3 errmsg=$4 opts=${5:-} rand_fn=""
  [[ $opts =~ rand=([^[:space:]]+) ]] && rand_fn=${BASH_REMATCH[1]}
  while :; do
    ask_c "$prompt" "$def" || return 2
    if [[ $opts == *reject_same* && $REPLY == "$def" ]]; then
      return 1
    fi
    if [[ -n $rand_fn && $REPLY =~ ^[Rr]$ ]]; then
      REPLY=$($rand_fn)
      return 0
    fi
    if [[ $opts == *clear_dash* && $REPLY == - ]]; then
      [[ -z $def && $opts == *reject_same* ]] && return 1
      REPLY=""
      return 0
    fi
    if [[ -z $REPLY && $opts == *empty_ok* ]]; then
      return 0
    fi
    if [[ -z $check ]] || "$check" "$REPLY"; then
      return 0
    fi
    err "$errmsg"
  done
}

confirm() { # $1=提示；默认 N，支持单键 y/n/Enter/Esc
  printf "  ${Y}?${N} %s ${D}[y/N]${N}: " "$1"
  local rc=0
  read_key || rc=$?
  echo
  ((rc == 0)) && [[ $REPLY =~ ^[Yy]$ ]]
}

os_label() {
  [[ $OS == debian ]] && echo "Debian (systemd)" || echo "Alpine (OpenRC)"
}

proto_name() {
  case $1 in
    vless) echo "VLESS" ;;
    hysteria2) echo "Hysteria2" ;;
    trojan) echo "Trojan" ;;
    vmess) echo "VMess" ;;
    shadowsocks) echo "Shadowsocks" ;;
    socks) echo "SOCKS5" ;;
    *) echo "$1" ;;
  esac
}

proto_l4() {
  case $1 in
    hysteria2) echo udp ;;
    shadowsocks | socks) echo both ;;
    *) echo tcp ;;
  esac
}

l4_label() {
  case $1 in
    udp) echo UDP ;;
    both) echo TCP+UDP ;;
    *) echo TCP ;;
  esac
}

LOCK_DIR=/run/xr-panel.lock
LOCK_OWNED=0
RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/xr-panel.XXXXXX") || { err "无法创建临时目录"; exit 1; }
CONF_TMP="$RUN_TMP/config.json"
PENDING_BAK=""
CONF_DIRTY=0
WAS_ENABLED=0

node_count() { [[ -f $NODES ]] && jq length "$NODES" 2>/dev/null || echo 0; }
xr_installed() { [[ -x $XR_BIN ]]; }
xr_version() { "$XR_BIN" version 2>/dev/null | awk 'NR==1{print $2}'; }

acquire_lock() {
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_OWNED=1
    printf '%s\n' "$$" >"$LOCK_DIR/pid"
    return 0
  fi
  local old_pid=""
  [[ -f $LOCK_DIR/pid ]] && old_pid=$(<"$LOCK_DIR/pid")
  if [[ $old_pid =~ ^[0-9]+$ ]] && ! kill -0 "$old_pid" 2>/dev/null; then
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      LOCK_OWNED=1
      printf '%s\n' "$$" >"$LOCK_DIR/pid"
      return 0
    fi
  fi
  err "检测到另一个面板实例正在运行${old_pid:+（PID: $old_pid）}，请勿并发操作"
  exit 1
}

_restore_snapshot() { # $1=快照文件
  local bak=$1
  [[ -n $bak && -f $bak && -n ${NODES:-} ]] || return 0
  cp "$bak" "$NODES" 2>/dev/null || true
  chmod 600 "$NODES" 2>/dev/null || true
  if [[ ${CONF_DIRTY:-0} == 1 ]] && xr_installed; then
    if gen_config 2>/dev/null && chmod 600 "$CONF_TMP" 2>/dev/null && mv "$CONF_TMP" "$CONF" 2>/dev/null; then
      if (($(node_count) == 0)); then
        svc_ctl stop || true
        [[ ${WAS_ENABLED:-0} == 0 ]] && svc_ctl disable || true
      else
        svc_ctl restart || true
      fi
    fi
  fi
  cleanup_unused_certs 2>/dev/null || true
  PENDING_BAK=""
  CONF_DIRTY=0
}

cleanup() {
  trap - EXIT INT TERM
  _restore_snapshot "${PENDING_BAK:-}"
  [[ -n ${RUN_TMP:-} ]] && rm -rf "$RUN_TMP"
  [[ ${LOCK_OWNED:-0} == 1 && -n ${LOCK_DIR:-} ]] && rm -rf "$LOCK_DIR" 2>/dev/null || true
}
trap cleanup EXIT
trap 'echo; exit 130' INT
trap 'exit 143' TERM

# ───────── 基础环境与服务 ─────────
ensure_deps() {
  local pk=() c log="$RUN_TMP/deps.log"
  for c in curl jq openssl unzip ss; do
    command -v "$c" >/dev/null && continue
    [[ $c == ss ]] && pk+=(iproute2) || pk+=("$c")
  done
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || pk+=(ca-certificates)
  [[ ${#pk[@]} -eq 0 ]] && return 0
  info "正在安装必要依赖：${pk[*]}…"
  if [[ $OS == debian ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >"$log" 2>&1 \
      && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${pk[@]}" >>"$log" 2>&1
  else
    apk add --no-cache "${pk[@]}" >"$log" 2>&1
  fi || {
    err "依赖安装失败，请检查软件源或网络连接"
    tail -n 20 "$log" 2>/dev/null
    exit 1
  }
}

svc_install() { # [$1=force]
  if [[ $OS == debian ]]; then
    [[ -f /etc/systemd/system/xray.service && ${1:-} != force ]] && return 0
    cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
ExecStart=$XR_BIN run -c $CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  else
    [[ -f /etc/init.d/xray && ${1:-} != force ]] && return 0
    cat >/etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="xray"
command="$XR_BIN"
command_args="run -c $CONF"
command_background=true
pidfile="/run/xray.pid"
rc_ulimit="-n 1048576"
output_log="$XR_LOG"
error_log="$XR_LOG"
depend() {
  need net
  after firewall
  use dns logger
}
start_pre() {
  if [ -f "$XR_LOG" ] && [ "\$(wc -c < "$XR_LOG" 2>/dev/null || echo 0)" -gt 20971520 ]; then
    tail -c 2097152 "$XR_LOG" > "$XR_LOG.tmp" 2>/dev/null && mv -f "$XR_LOG.tmp" "$XR_LOG" || : > "$XR_LOG"
  fi
  touch "$XR_LOG" && chmod 600 "$XR_LOG"
}
EOF
    chmod 755 /etc/init.d/xray
    if [[ -d /etc/logrotate.d ]]; then
      cat >/etc/logrotate.d/xray <<EOF
$XR_LOG {
  weekly
  rotate 4
  compress
  missingok
  notifempty
  copytruncate
}
EOF
    fi
  fi
}

svc_ctl() { # is-active | is-enabled | enable | disable | restart | stop
  if [[ $OS == debian ]]; then
    case $1 in
      is-active | is-enabled) systemctl "$1" --quiet xray ;;
      stop)
        systemctl is-active --quiet xray || return 0
        systemctl stop xray >/dev/null 2>&1
        ;;
      *) systemctl "$1" xray >/dev/null 2>&1 ;;
    esac
  else
    case $1 in
      is-active) rc-service xray status >/dev/null 2>&1 ;;
      is-enabled) rc-update show default 2>/dev/null | awk '$1=="xray"{f=1} END{exit !f}' ;;
      enable) rc-update add xray default >/dev/null 2>&1 ;;
      disable) rc-update del xray default >/dev/null 2>&1 ;;
      restart)
        rc-service xray stop >/dev/null 2>&1 || true
        rc-service xray start >/dev/null 2>&1
        ;;
      stop)
        rc-service xray status >/dev/null 2>&1 || return 0
        rc-service xray stop >/dev/null 2>&1
        ;;
    esac
  fi
}

svc_logs() {
  local out=""
  if [[ $OS == debian ]]; then
    out=$(journalctl -u xray -n 40 --no-pager -o cat 2>/dev/null)
  elif [[ -f $XR_LOG ]]; then
    out=$(tail -n 40 "$XR_LOG" 2>/dev/null)
  fi
  if [[ -n $out ]]; then
    printf "  ${D}最近 40 条日志：${N}\n  %s\n%s\n" "$RULE" "$out"
  else
    info "暂无运行日志"
  fi
}

_fetch_ip() { # $1=-4|-6
  local ip u a b c d colons
  for u in "https://api${1#-}.ipify.org" "https://ip.sb" "https://ifconfig.me"; do
    ip=$(curl -fsS "$1" -m 2 "$u" 2>/dev/null | tr -d '[:space:]') || continue
    if [[ $1 == -4 && $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      IFS=. read -r a b c d <<<"$ip"
      ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255)) && { echo "$ip"; return 0; }
    elif [[ $1 == -6 && $ip =~ ^[0-9a-fA-F:]+$ && ${#ip} -le 45 \
      && $ip != :: && $ip != ::1 && $ip != *:::* && $ip != *::*::* \
      && ($ip != :* || $ip == ::*) && ($ip != *: || $ip == *::) \
      && ! $ip =~ [0-9a-fA-F]{5} ]]; then
      colons=${ip//[^:]/}
      if [[ $ip == *::* ]] || ((${#colons} == 7)); then
        echo "$ip"; return 0
      fi
    fi
  done
}

detect_ips() {
  [[ -n ${IP_DETECTED:-} ]] && return
  IP_DETECTED=1
  printf "  ${D}· 正在检测公网 IP…${N}"
  _fetch_ip -4 >"$RUN_TMP/ip4" &
  _fetch_ip -6 >"$RUN_TMP/ip6" &
  wait
  printf "\r\033[K"
  [[ -s $RUN_TMP/ip4 ]] && PUBIP4=$(<"$RUN_TMP/ip4") || PUBIP4=""
  [[ -s $RUN_TMP/ip6 ]] && PUBIP6=$(<"$RUN_TMP/ip6") || PUBIP6=""
}

init_dirs() {
  mkdir -p "$XR_DIR" "$CERT_DIR" && chmod 700 "$XR_DIR" "$CERT_DIR"
  [[ -f $NODES ]] || { echo '[]' >"$NODES"; chmod 600 "$NODES"; }
}

_valid_ver() { [[ $1 =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[A-Za-z0-9.]+)?$ ]]; }

_download_xray() { # $1=ver $2=arch $3=tmp_dir
  local base_url="https://github.com/XTLS/Xray-core/releases/download/v$1/Xray-linux-$2.zip"
  local expected actual
  command -v sha256sum >/dev/null || { err "缺少 sha256sum 工具，无法校验安装包"; return 1; }
  info "正在下载 Xray-core v$1（$2）…"
  curl -fsSL -o "$3/xr.zip" "$base_url" 2>/dev/null || { err "安装包下载失败"; return 1; }
  info "正在校验安装包 SHA256…"
  curl -fsSL -o "$3/xr.zip.dgst" "$base_url.dgst" 2>/dev/null || { err "校验文件下载失败，已中止安装"; return 1; }
  expected=$(awk -F'=' '/^SHA2?-?256[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print tolower($2); exit}' "$3/xr.zip.dgst")
  [[ -n $expected ]] || { err "无法解析安装包 SHA256 校验值"; return 1; }
  actual=$(sha256sum "$3/xr.zip" | awk '{print tolower($1)}')
  [[ $expected == "$actual" ]] || { err "安装包 SHA256 校验未通过，文件可能已损坏"; return 1; }
  info "正在安装二进制文件与系统服务…"
  if ! unzip -qo "$3/xr.zip" xray -d "$3" 2>/dev/null \
    || ! install -m755 "$3/xray" "$XR_BIN.new" 2>/dev/null \
    || ! mv -f "$XR_BIN.new" "$XR_BIN" 2>/dev/null; then
    rm -f "$XR_BIN.new"
    err "解压或写入可执行文件失败"
    return 1
  fi
}

install_xray() {
  local arch ver tmp eff_url v rc=0 was_installed=0
  xr_installed && was_installed=1
  case $(uname -m) in
    x86_64 | amd64) arch=64 ;;
    aarch64 | arm64) arch=arm64-v8a ;;
    armv7l) arch=arm32-v7a ;;
    i386 | i686) arch=32 ;;
    *) err "不支持的系统架构：$(uname -m)"; return 1 ;;
  esac
  info "正在查询最新 Xray-core 版本…"
  eff_url=$(curl -fsSLI -m 10 -o /dev/null -w '%{url_effective}' https://github.com/XTLS/Xray-core/releases/latest 2>/dev/null)
  ver=${eff_url##*/}
  ver=${ver#v}
  if ! _valid_ver "$ver"; then
    ver=$(curl -fsSL -m 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
  fi
  _valid_ver "$ver" || { err "获取最新版本信息失败，请检查网络连接"; return 1; }
  if ((was_installed == 1)) && [[ $(xr_version) == "$ver" ]]; then
    ok "当前已是最新版本 v$ver"
    confirm "是否强制重新安装？" || return 2
  fi
  tmp=$(mktemp -d "$RUN_TMP"/dl.XXXXXX) || { err "创建临时下载目录失败"; return 1; }
  _download_xray "$ver" "$arch" "$tmp" || rc=$?
  rm -rf "$tmp"
  ((rc == 0)) || return 1
  init_dirs
  ((was_installed == 0)) && svc_install force || svc_install
  v=$(xr_version)
  [[ -n $v ]] || { err "安装完成但无法执行 Xray-core"; return 1; }
  ok "Xray-core v$v 安装完成"
}

# ───────── 配置生成（路由仅依赖 CIDR 与域名，无需 geoip/geosite）─────────
_listen_mode() {
  if [[ ! -s /proc/net/if_inet6 ]]; then
    echo v4
  elif [[ $(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null) == 1 ]] && ip -4 route show default 2>/dev/null | grep -q .; then
    if ip -6 route show default 2>/dev/null | grep -q .; then
      echo dual_split
    else
      echo v4
    fi
  else
    echo dual
  fi
}

_listen_label() {
  case $(_listen_mode) in
    v4) echo "仅 IPv4 (0.0.0.0)" ;;
    dual_split) echo "分栈双听 (0.0.0.0 + ::)" ;;
    *) echo "双栈监听 (::)" ;;
  esac
}

gen_config() {
  jq --arg mode "$(_listen_mode)" '{
    log: {loglevel: "warning"},
    inbounds: ([
      .[] |
      (.local // 0) as $loc |
      (if .type == "socks" then
        {
          port: .port, protocol: "socks",
          settings: {auth: "password", users: [{user: .user, pass: .pass}], udp: true}
        }
      elif .type == "shadowsocks" then
        {
          port: .port, protocol: "shadowsocks",
          settings: {network: "tcp,udp", method: .method, password: .password}
        }
      elif .type == "trojan" then
        {
          port: .port, protocol: "trojan",
          settings: {users: [{password: .password}]},
          streamSettings: {
            network: "raw", security: "tls",
            tlsSettings: {alpn: ["h2", "http/1.1"], certificates: [{certificateFile: .cert, keyFile: .key}]}
          }
        }
      elif .type == "vless" then
        {
          port: .port, protocol: "vless",
          settings: {
            users: [(if (.transport // "raw") == "xhttp" then {id: .uuid} else {id: .uuid, flow: "xtls-rprx-vision"} end)],
            decryption: "none"
          },
          streamSettings: (
            {
              network: (.transport // "raw"),
              security: "reality",
              realitySettings: {
                target: (.sni + ":443"), serverNames: [.sni],
                privateKey: .priv, shortIds: [.sid]
              }
            } + (if (.transport // "raw") == "xhttp" then {xhttpSettings: ({path: (.path // "/")} + (if (.xhost // "") != "" then {host: .xhost} else {} end))} else {} end)
          )
        }
      elif .type == "vmess" then
        {
          port: .port, protocol: "vmess",
          settings: {users: [{id: .uuid}]},
          streamSettings: {
            network: "websocket",
            wsSettings: {path: .path},
            security: "tls",
            tlsSettings: {alpn: ["http/1.1"], certificates: [{certificateFile: .cert, keyFile: .key}]}
          }
        }
      elif .type == "hysteria2" then
        {
          port: .port, protocol: "hysteria",
          settings: {version: 2, users: [{auth: .password}]},
          streamSettings: {
            network: "hysteria",
            hysteriaSettings: {version: 2},
            security: "tls",
            tlsSettings: {alpn: ["h3"], certificates: [{certificateFile: .cert, keyFile: .key}]}
          }
        }
      else empty end) as $base |
      ($base + {sniffing: {enabled: true, destOverride: ["http", "tls", "quic"], routeOnly: true}}) as $inb |
      if $loc == 1 then
        [$inb + {tag: .tag, listen: "127.0.0.1"}]
      elif $mode == "v4" then
        [$inb + {tag: .tag, listen: "0.0.0.0"}]
      elif $mode == "dual_split" then
        [
          $inb + {tag: .tag, listen: "0.0.0.0"},
          $inb + {tag: (.tag + "-v6"), listen: "::"}
        ]
      else
        [$inb + {tag: .tag, listen: "::"}]
      end
    ] | add // []),
    outbounds: [
      {protocol: "freedom", tag: "direct"},
      {protocol: "blackhole", tag: "block"}
    ],
    routing: {
      domainStrategy: "IPIfNonMatch",
      rules: [
        {
          type: "field",
          domain: ["domain:localhost"],
          outboundTag: "block"
        },
        {
          type: "field",
          ip: [
            "0.0.0.0/8", "127.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10",
            "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16",
            "::/128", "::1/128", "::ffff:0:0/96", "fc00::/7", "fe80::/10"
          ],
          outboundTag: "block"
        }
      ]
    }
  }' "$NODES" >"$CONF_TMP"
}

apply() {
  info "正在校验并应用配置…"
  gen_config || { err "生成配置文件失败"; rm -f "$CONF_TMP"; return 1; }
  local out i ok_cnt=0
  if ! out=$("$XR_BIN" run -test -c "$CONF_TMP" 2>&1); then
    err "配置校验未通过："
    printf '%s\n' "$out"
    rm -f "$CONF_TMP"
    return 1
  fi
  if ! { chmod 600 "$CONF_TMP" && mv "$CONF_TMP" "$CONF"; }; then
    err "写入配置文件失败"
    rm -f "$CONF_TMP"
    return 1
  fi
  CONF_DIRTY=1
  if (($(node_count) == 0)); then
    svc_ctl stop || true
    PENDING_BAK=""
    CONF_DIRTY=0
    ok "当前无可用节点，已自动停止服务"
    return 0
  fi
  if ! svc_ctl restart; then
    err "服务重启命令执行失败，请前往「运行日志」排查原因"
    return 1
  fi
  for i in 1 2 3 4 5 6; do
    sleep_frac 0.5
    if svc_ctl is-active; then
      ((ok_cnt++))
      if ((ok_cnt >= 2)); then
        svc_ctl enable || warn "开启开机自启失败，请手动检查服务状态"
        PENDING_BAK=""
        CONF_DIRTY=0
        ok "配置已生效，服务运行正常"
        return 0
      fi
    else
      ok_cnt=0
    fi
  done
  err "服务未能稳定运行，请前往「运行日志」排查原因"
  return 1
}

# ───────── 通用校验与输入封装 ─────────
rnd() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_sni() { [[ ${#1} -le 253 && $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$ ]]; }
valid_path() { [[ $1 == /* && ! $1 =~ [[:space:]] ]]; }
valid_cred() { [[ -n $1 && ! $1 =~ [[:cntrl:]] ]]; }
valid_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; }
valid_sid() { [[ $1 =~ ^([0-9a-fA-F]{2}){1,8}$ ]]; }
valid_ss2022_psk() {
  local need=16 blen=24 decoded
  [[ $1 == 2022-blake3-aes-128-gcm ]] || { need=32; blen=44; }
  [[ ${#2} -eq $blen && $2 =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
  decoded=$(printf %s "$2" | base64 -d 2>/dev/null | wc -c; exit "${PIPESTATUS[1]}") || return 1
  ((decoded == need))
}
_valid_node_pw() {
  valid_cred "$1" || return 1
  [[ ${_PW_SSM:-} != 2022-blake3-* ]] || valid_ss2022_psk "$_PW_SSM" "$1"
}

check_reality_sni() {
  local sni=$1 rc=0
  curl -sI -m 3 -o /dev/null --tlsv1.3 "https://$sni" 2>/dev/null || rc=$?
  ((rc != 0 && rc != 2)) && warn "本机访问 https://$sni (TLS 1.3) 未成功响应，请确认目标域名可达且支持 TLS 1.3"
  return 0
}

port_free() { # $1=port $2=tcp|udp|both(默认 both)
  local p=$1 l4=${2:-both} ss_opt="-lntu" col=5
  valid_port "$p" || return 1
  case $l4 in
    tcp) ss_opt="-lnt"; col=4 ;;
    udp) ss_opt="-lnu"; col=4 ;;
  esac
  ! ss "$ss_opt" 2>/dev/null | awk -v c="$col" 'NR>1{print $c}' | grep -qE ":$p$" \
    && ! jq -e --argjson p "$p" --arg l4 "$l4" '
      def l4of: if .type == "hysteria2" then "udp"
                elif .type == "shadowsocks" or .type == "socks" then "both"
                else "tcp" end;
      any(.[]; .port == $p and ($l4 == "both" or l4of == "both" or l4of == $l4))
    ' "$NODES" >/dev/null 2>&1
}

ask_port() { # $1=协议类型 [$2=当前端口] -> 设置 PORT；1=未改 2=取消
  local l4 l4_txt def=${2:-} p
  l4=$(proto_l4 "$1")
  l4_txt=$(l4_label "$l4")
  if [[ -z $def ]]; then
    while :; do
      def=$((20000 + RANDOM % 30000))
      port_free "$def" "$l4" && break
    done
  fi
  while :; do
    ask_valid "监听端口（$l4_txt）" "$def" valid_port "端口无效，请输入 1-65535 之间的整数" "${2:+reject_same}" || return $?
    p=$((10#$REPLY))
    if port_free "$p" "$l4"; then
      PORT=$p
      return 0
    fi
    err "端口 $p（$l4_txt）已被占用，请更换其他端口"
  done
}

ask_sni() { # $1=提示 $2=变量名 [$3=默认值] [$4=opts]
  local var=${2:-SNI} def=${3:-$DEFAULT_SNI}
  ask_valid "$1" "$def" valid_sni "域名 / SNI 格式无效（须为合法域名，如 example.com）" "${4:-}" || return $?
  printf -v "$var" '%s' "$REPLY"
}

ask_path() { # $1=提示 $2=默认值 $3=变量名 [$4=opts]
  local var=${3:-WPATH}
  ask_valid "$1" "$2" valid_path "路径须以 / 开头且不能包含空白字符" "${4:-}" || return $?
  printf -v "$var" '%s' "$REPLY"
}

ask_cred() { # $1=提示 $2=默认值 $3=变量名 [$4=opts]
  local var=$3
  ask_valid "$1" "$2" valid_cred "输入不能为空或包含控制字符" "${4:-}" || return $?
  printf -v "$var" '%s' "$REPLY"
}

gen_self_cert() { # $1=sni -> 设置 CERT 和 KEY
  local sni=$1 pub_c="" pub_k=""
  CERT=$CERT_DIR/$sni.crt
  KEY=$CERT_DIR/$sni.key
  if [[ -f $CERT && -f $KEY ]]; then
    pub_c=$(openssl x509 -noout -pubkey -in "$CERT" 2>/dev/null || true)
    pub_k=$(openssl pkey -pubout -in "$KEY" 2>/dev/null || true)
    if [[ -n $pub_c && $pub_c == "$pub_k" ]] && openssl x509 -noout -checkend 86400 -in "$CERT" >/dev/null 2>&1; then
      return 0
    fi
    rm -f "$CERT" "$KEY"
  fi
  local ossl=(req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1
    -keyout "$KEY" -out "$CERT" -days 3650 -subj "/CN=$sni")
  openssl "${ossl[@]}" -addext "subjectAltName=DNS:$sni" >/dev/null 2>&1 \
    || openssl "${ossl[@]}" >/dev/null 2>&1 \
    || { err "自签证书生成失败"; rm -f "$CERT" "$KEY"; return 1; }
  chmod 600 "$KEY"
  chmod 644 "$CERT"
}

cleanup_unused_certs() {
  [[ -d $CERT_DIR && -f $NODES ]] || return 0
  local f used
  used=$(jq -r '[.[].cert, .[].key] | flatten | map(select(type == "string" and length > 0)) | .[]' "$NODES" 2>/dev/null)
  for f in "$CERT_DIR"/*.crt "$CERT_DIR"/*.key; do
    [[ -e $f ]] || continue
    grep -Fqx "$f" <<<"$used" || rm -f "$f"
  done
}

ask_cert() { # $1=1 显示取消提示 [$2=默认SNI]；返回 0=成功 1=错误 2=取消
  local sfx="" def_sni=${2:-$DEFAULT_SNI} pub_c pub_k
  [[ ${1:-0} == 1 ]] && sfx="（0 取消）"
  ask_sni "域名 / SNI$sfx" SNI "$def_sni" || return 2
  while :; do
    ask_c "证书路径（留空自动自签${sfx:+，0 取消}）" "" || return 2
    CERT=$REPLY
    if [[ -z $CERT ]]; then
      gen_self_cert "$SNI" || return 1
      INSECURE=1
      HOST=""
      info "已使用自签证书（$SNI）"
      return 0
    fi
    ask_c "私钥路径$sfx" "" || return 2
    KEY=$REPLY
    if [[ ! -f $CERT || ! -f $KEY ]]; then
      err "证书或私钥文件不存在（留空证书路径可改用自签证书）"
      continue
    fi
    if ! openssl x509 -noout -in "$CERT" >/dev/null 2>&1 || ! openssl pkey -noout -in "$KEY" >/dev/null 2>&1; then
      err "证书或私钥格式无效（须为标准 PEM 格式）"
      continue
    fi
    pub_c=$(openssl x509 -noout -pubkey -in "$CERT" 2>/dev/null)
    pub_k=$(openssl pkey -pubout -in "$KEY" 2>/dev/null)
    if [[ -z $pub_c || $pub_c != "$pub_k" ]]; then
      err "证书与私钥不匹配，请重新输入"
      continue
    fi
    openssl x509 -noout -checkend 0 -in "$CERT" >/dev/null 2>&1 || warn "注意：所选证书已过期"
    INSECURE=0
    HOST=$SNI
    return 0
  done
}

# ───────── 数据读写与事务辅助 ─────────
jqw() {
  local t
  t=$(mktemp "$RUN_TMP"/jq.XXXXXX) || return 1
  jq "$@" "$NODES" >"$t" && chmod 600 "$t" && mv "$t" "$NODES"
}

snapshot() {
  BAK="$RUN_TMP/nodes.$$.$RANDOM.bak"
  cp "$NODES" "$BAK"
  PENDING_BAK=$BAK
  CONF_DIRTY=0
  WAS_ENABLED=0
  svc_ctl is-enabled && WAS_ENABLED=1 || true
}

clear_snapshot() {
  rm -f "${BAK:-}"
  PENDING_BAK=""
  cleanup_unused_certs 2>/dev/null || true
}

rollback() {
  _restore_snapshot "$1"
  rm -f "$1"
  [[ -n ${2:-} ]] && err "$2"
}

setf() { jqw --argjson i "$1" --arg k "$2" --arg v "$3" '.[$i][$k]=$v'; }

node_load() { # 单次 jq 加载 $1(默认 IDX) 节点全部字段到 _N_* 变量
  local i=${1:-$IDX} raw
  raw=$(jq -r --argjson i "$i" '
    (.[$i] // {}) | [
      (.tag // ""), (.type // ""), (.port // "" | tostring), (.transport // "raw"),
      (.sni // ""), (.host // ""), (.insecure // 0 | tostring), (.local // 0 | tostring),
      (.user // ""), (.pass // ""), (.method // ""), (.password // ""),
      (.uuid // ""), (.pub // ""), (.sid // ""), (.path // ""), (.xhost // "")
    ] | join("\u001f")
  ' "$NODES")
  IFS=$'\x1f' read -r _N_TAG _N_TYPE _N_PORT _N_TR _N_SNI _N_HOST _N_INSEC _N_LOCAL \
    _N_USER _N_PASS _N_METHOD _N_PW _N_UUID _N_PUB _N_SID _N_PATH _N_XHOST <<<"$raw"
}

choose_node() { # 交互选择节点并设置 IDX；取消返回 1
  local n
  n=$(node_count)
  if ((n <= 9)); then
    echo
    printf "  ${D}输入节点编号 [1-%s]${N}" "$n"
    ((n == 1)) && printf " ${D}（回车默认 1）${N}"
    printf "  ${D}[0/q/Esc] 返回${N}"
    while :; do
      prompt_key || return 1
      case $REPLY in
        "") continue ;;
        0 | q | Q | ESC) return 1 ;;
        ENTER)
          if ((n == 1)); then
            IDX=0
            return 0
          fi
          err "请输入节点编号 1-$n"
          ;;
        [1-9])
          if ((REPLY <= n)); then
            IDX=$((REPLY - 1))
            return 0
          fi
          err "编号无效，请输入 1-$n"
          ;;
        *) err "编号无效，请输入 1-$n" ;;
      esac
    done
  fi
  echo
  while :; do
    ask_c "节点编号（1-$n，0 返回）" "" || return 1
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      IDX=$((10#$REPLY - 1))
      return 0
    fi
    [[ -n $REPLY ]] && err "编号无效，请输入 1-$n"
  done
}

gen_reality() {
  local out
  out=$("$XR_BIN" x25519 2>/dev/null) || { err "生成 Reality 密钥失败"; return 1; }
  RPRIV=$(awk -F': *' '/^Private/{print $2; exit}' <<<"$out" | tr -d '[:space:]')
  RPUB=$(awk -F': *' '/^(Public ?[Kk]ey|Password):/{print $2; exit}' <<<"$out" | tr -d '[:space:]')
  [[ -n $RPRIV && -n $RPUB ]] || { err "解析 xray x25519 输出失败"; return 1; }
  RSID=$(openssl rand -hex 4)
}

gen_uuid() { "$XR_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
gen_sid() { openssl rand -hex 4; }

pick_vless_tr() { # $1=默认值 $2=提示 -> VLESS_TR；取消返回 2
  printf "    ${C}[1]${N}  RAW + Reality (Vision)  ${D}推荐${N}\n"
  printf "    ${C}[2]${N}  XHTTP + Reality\n"
  printf "    ${D}[0]  取消  ·  回车默认 [%s]${N}\n" "$1"
  while :; do
    prompt_key || return 2
    case $REPLY in
      "") continue ;;
      ENTER) VLESS_TR=$1; return 0 ;;
      0 | q | Q | ESC) return 2 ;;
      1) VLESS_TR=raw; return 0 ;;
      2) VLESS_TR=xhttp; return 0 ;;
      *) err "无效选项，请按 1 或 2" ;;
    esac
  done
}

pick_ss_method() { # 设置 SS_M 和 SS_P；取消返回 2
  printf "    ${C}[1]${N}  2022-blake3-aes-128-gcm      ${D}推荐 · 回车默认${N}\n"
  printf "    ${C}[2]${N}  2022-blake3-aes-256-gcm\n"
  printf "    ${C}[3]${N}  2022-blake3-chacha20-poly1305\n"
  printf "    ${C}[4]${N}  aes-256-gcm\n"
  printf "    ${C}[5]${N}  chacha20-ietf-poly1305\n"
  printf "    ${D}[0]  取消${N}\n"
  while :; do
    prompt_key || return 2
    case $REPLY in
      "") continue ;;
      0 | q | Q | ESC) return 2 ;;
      1 | ENTER) SS_M=2022-blake3-aes-128-gcm; SS_P=$(openssl rand -base64 16); return 0 ;;
      2) SS_M=2022-blake3-aes-256-gcm; SS_P=$(openssl rand -base64 32); return 0 ;;
      3) SS_M=2022-blake3-chacha20-poly1305; SS_P=$(openssl rand -base64 32); return 0 ;;
      4) SS_M=aes-256-gcm; SS_P=$(rnd 16); return 0 ;;
      5) SS_M=chacha20-ietf-poly1305; SS_P=$(rnd 16); return 0 ;;
      *) err "无效选项，请按 1-5" ;;
    esac
  done
}

# ───────── 添加节点（向导流程）─────────
add_socks() {
  warn "SOCKS5 为明文协议，直接暴露公网存在密码与流量被窃听风险，建议仅作内网或隧道落地使用"
  ui_step 1 3 "监听端口"
  ask_port socks || return 2
  ui_step 2 3 "监听范围"
  printf "    ${C}[1]${N}  公网监听  ${D}回车默认${N}\n"
  printf "    ${C}[2]${N}  仅本机监听 127.0.0.1  ${D}推荐用于隧道落地${N}\n"
  printf "    ${D}[0]  取消${N}\n"
  local loc=0 host="" u p
  while :; do
    prompt_key || return 2
    case $REPLY in
      "") continue ;;
      0 | q | Q | ESC) return 2 ;;
      1 | ENTER) loc=0; break ;;
      2) loc=1; host="127.0.0.1"; break ;;
      *) err "无效选项，请按 1 或 2" ;;
    esac
  done
  ui_step 3 3 "认证凭据"
  ask_cred "用户名" "u$(rnd 5)" u || return 2
  ask_cred "密码" "$(rnd 12)" p || return 2
  jqw --argjson port "$PORT" --arg u "$u" --arg p "$p" --argjson loc "$loc" --arg h "$host" \
    '. + [{type:"socks",tag:("socks-"+($port|tostring)),port:$port,user:$u,pass:$p,local:$loc}
     + (if $h != "" then {host:$h} else {} end)]'
}

add_ss() {
  ui_step 1 2 "监听端口"
  ask_port shadowsocks || return 2
  ui_step 2 2 "加密方式"
  pick_ss_method || return 2
  jqw --argjson port "$PORT" --arg m "$SS_M" --arg p "$SS_P" \
    '. + [{type:"shadowsocks",tag:("ss-"+($port|tostring)),port:$port,method:$m,password:$p}]'
}

_add_tls_pw() { # $1=type $2=tag前缀
  ui_step 1 3 "监听端口"
  ask_port "$1" || return 2
  ui_step 2 3 "域名与 TLS 证书"
  ask_cert || return $?
  ui_step 3 3 "连接密码"
  local p
  ask_cred "连接密码" "$(rnd 16)" p || return 2
  jqw --arg t "$1" --arg pfx "$2" --argjson port "$PORT" --arg p "$p" \
    --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:$t,tag:($pfx+"-"+($port|tostring)),port:$port,password:$p,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

add_vless() {
  ui_step 1 3 "监听端口"
  ask_port vless || return 2
  ui_step 2 3 "传输方式"
  local tr sni path="" xhost=""
  pick_vless_tr "raw" "传输方式" || return 2
  tr=$VLESS_TR
  local total=3
  [[ $tr == xhttp ]] && total=4
  ui_step 3 "$total" "Reality 伪装域名"
  ask_sni "Reality 伪装域名" sni || return 2
  check_reality_sni "$sni"
  if [[ $tr == xhttp ]]; then
    ui_step 4 4 "XHTTP 路径与 Host"
    ask_path "XHTTP 路径" "/$(rnd 8)" path || return 2
    ask_valid "XHTTP Host（留空不限）" "" valid_sni "Host 格式无效" "empty_ok" || return 2
    xhost=$REPLY
  fi
  gen_reality || return 1
  jqw --argjson port "$PORT" --arg tr "$tr" --arg sni "$sni" --arg path "$path" --arg xhost "$xhost" \
    --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" --arg uuid "$(gen_uuid)" \
    '. + [{type:"vless",tag:("vless-"+($port|tostring)),port:$port,transport:$tr,uuid:$uuid,sni:$sni,priv:$priv,pub:$pub,sid:$sid}
     + (if $tr=="xhttp" then ({path:$path} + (if $xhost != "" then {xhost:$xhost} else {} end)) else {} end)]'
}

add_vmess() {
  ui_step 1 3 "监听端口"
  ask_port vmess || return 2
  ui_step 2 3 "域名与 TLS 证书"
  ask_cert || return $?
  ui_step 3 3 "WebSocket 路径"
  local path
  ask_path "WebSocket 路径" "/$(rnd 8)" path || return 2
  jqw --argjson port "$PORT" --arg uuid "$(gen_uuid)" --arg path "$path" \
    --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"vmess",tag:("vmess-"+($port|tostring)),port:$port,uuid:$uuid,path:$path,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

menu_add() {
  local c toast_msg="" rc=0 n ptype
  local types=(vless hysteria2 trojan vmess shadowsocks socks)
  while :; do
    title "添加节点"
    printf "    ${C}[1]${N}  "; pad_print "VLESS" 13; printf "${D}RAW / XHTTP + Reality（推荐）${N}\n"
    printf "    ${C}[2]${N}  "; pad_print "Hysteria2" 13; printf "${D}QUIC + TLS（高速抗丢包）${N}\n"
    printf "    ${C}[3]${N}  "; pad_print "Trojan" 13; printf "${D}RAW + TLS${N}\n"
    printf "    ${C}[4]${N}  "; pad_print "VMess" 13; printf "${D}WebSocket + TLS${N}\n"
    printf "    ${C}[5]${N}  "; pad_print "Shadowsocks" 13; printf "${D}SS 2022 / AEAD${N}\n"
    printf "    ${C}[6]${N}  "; pad_print "SOCKS5" 13; printf "${D}账号密码认证${N}\n"
    echo
    printf "    ${D}[0]  返回主菜单${N}\n"
    show_toast err "$toast_msg"
    toast_msg=""
    prompt_key || return
    c=$REPLY
    case $c in
      "" | ENTER) continue ;;
      0 | q | Q | ESC) return ;;
      [1-6]) break ;;
      *) toast_msg="无效选项，请按 1-6（0 返回）" ;;
    esac
  done

  ptype=${types[$((c - 1))]}
  title "添加 $(proto_name "$ptype") 节点"
  info "直接回车采用默认值，文本输入阶段输入 0 可随时取消"

  n=$(node_count)
  snapshot
  case $ptype in
    vless) add_vless || rc=$? ;;
    hysteria2) _add_tls_pw hysteria2 hy2 || rc=$? ;;
    trojan) _add_tls_pw trojan trojan || rc=$? ;;
    vmess) add_vmess || rc=$? ;;
    shadowsocks) add_ss || rc=$? ;;
    socks) add_socks || rc=$? ;;
  esac
  if ((rc == 2)); then
    clear_snapshot
    return
  elif ((rc != 0)) || (($(node_count) == n)); then
    clear_snapshot
    pause
    return
  fi
  echo
  IDX=$n
  if apply; then
    clear_snapshot
    echo
    show_link "$IDX"
    echo
    [[ $_N_LOCAL == 1 ]] || note "请在防火墙 / 安全组放行端口 ${B}${_N_PORT}/$(l4_label "$(proto_l4 "$ptype")")${N}"
  else
    rollback "$BAK" "配置未生效，已撤销本次添加"
  fi
  pause
}

# ───────── 节点列表与详情分享 ─────────
list_nodes() {
  (($(node_count) == 0)) && {
    info "暂无节点，按 ${B}a${N} 立即添加，或前往主菜单选择「添加节点」"
    return 1
  }
  printf "  "
  pad_print "#" 5 "$D" "$N"
  pad_print "协议" 13 "$D" "$N"
  pad_print "端口" 15 "$D" "$N"
  printf "${D}%s${N}\n  %s\n" "配置摘要" "$RULE"
  jq -r 'to_entries[] | [
    (.key+1 | tostring),
    .value.type,
    (.value.port | tostring),
    (if .value.type == "shadowsocks" then .value.method
     elif .value.type == "vless" then
       (if (.value.transport // "raw") == "xhttp" then ("XHTTP · " + (.value.path // "/")) else ("Reality · " + .value.sni) end)
     elif .value.type == "trojan" or .value.type == "hysteria2" then
       ((if (.value.insecure // 0) == 1 then "自签 TLS · " else "TLS · " end) + .value.sni)
     elif .value.type == "vmess" then ("WS+TLS · " + .value.path)
     else ((if (.value.local // 0) == 1 then "本机 · " else "" end) + "用户 " + .value.user) end)
  ] | join("\u001f")' "$NODES" \
    | while IFS=$'\x1f' read -r i t p d; do
      printf "  "
      pad_print "$i" 5 "$C" "$N"
      pad_print "$(proto_name "$t")" 13
      pad_print "$p/$(l4_label "$(proto_l4 "$t")")" 15 "$B" "$N"
      printf "${D}%s${N}\n" "$d"
    done
}

menu_nodes() {
  local n c toast_msg=""
  while :; do
    title "节点列表"
    n=$(node_count)
    list_nodes || true
    echo
    printf "  %s\n" "$RULE"
    if ((n > 0)); then
      if ((n <= 9)); then
        printf "  ${D}操作：${N}${C}[1-%s]${N} ${D}链接  ${C}[a]${N} 添加  ${C}[e]${N} 编辑  ${C}[d]${N} 删除  ${D}[0] 返回${N}\n" "$n"
      else
        printf "  ${D}操作：${N}${C}[l]${N} ${D}链接  ${C}[a]${N} 添加  ${C}[e]${N} 编辑  ${C}[d]${N} 删除  ${D}[0] 返回${N}\n"
      fi
    else
      printf "  ${D}操作：${N}${C}[a]${N} ${D}添加节点  ${D}[0] 返回主菜单${N}\n"
    fi
    show_toast err "$toast_msg"
    toast_msg=""
    prompt_key || return
    c=$REPLY
    case $c in
      "") continue ;;
      0 | q | Q | ESC | ENTER) return ;;
      a | A) menu_add ;;
      e | E) ((n > 0)) && menu_edit || toast_msg="暂无可编辑的节点" ;;
      d | D) ((n > 0)) && menu_del || toast_msg="暂无可删除的节点" ;;
      l | L) ((n > 0)) && menu_links || toast_msg="暂无节点" ;;
      [1-9])
        if ((n > 0 && n <= 9 && c <= n)); then
          title "节点详情"
          show_link "$((c - 1))"
          pause
        else
          toast_msg="编号无效"
        fi
        ;;
      *) toast_msg="无效按键" ;;
    esac
  done
}

build_link() { # $1=raw_ip；单次 jq 完成编码与拼接
  jq -r --argjson i "$IDX" --arg ip "$1" '
    def br: if test(":") then "[" + . + "]" else . end;
    def e: (. // "") | @uri;
    def b64: @base64 | gsub("\\+"; "-") | gsub("/"; "_") | sub("=+$"; "");
    (.[$i] // {}) as $n | ($ip | br) as $h
    | if $n.type == "socks" then
        "socks5://\($n.user | e):\($n.pass | e)@\($h):\($n.port)#\($n.tag | e)"
      elif $n.type == "shadowsocks" then
        "ss://\(($n.method // "") + ":" + ($n.password // "") | b64)@\($h):\($n.port)#\($n.tag | e)"
      elif $n.type == "trojan" then
        "trojan://\($n.password | e)@\($h):\($n.port)?security=tls&sni=\($n.sni | e)&allowInsecure=\($n.insecure // 0)#\($n.tag | e)"
      elif $n.type == "vless" then
        if ($n.transport // "raw") == "xhttp" then
          "vless://\($n.uuid | e)@\($h):\($n.port)?encryption=none&security=reality&sni=\($n.sni | e)&fp=chrome&pbk=\($n.pub | e)&sid=\($n.sid | e)&type=xhttp"
          + (if ($n.xhost // "") != "" then "&host=\($n.xhost | e)" else "" end)
          + "&path=\(($n.path // "/") | e)&mode=auto#\($n.tag | e)"
        else
          "vless://\($n.uuid | e)@\($h):\($n.port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\($n.sni | e)&fp=chrome&pbk=\($n.pub | e)&sid=\($n.sid | e)&type=tcp#\($n.tag | e)"
        end
      elif $n.type == "hysteria2" then
        "hysteria2://\($n.password | e)@\($h):\($n.port)/?sni=\($n.sni | e)&insecure=\($n.insecure // 0)#\($n.tag | e)"
      elif $n.type == "vmess" then
        "vmess://" + ({
          v: "2", ps: ($n.tag // ""), add: $ip, port: ($n.port | tostring),
          id: ($n.uuid // ""), aid: "0", scy: "auto", net: "ws", type: "none",
          host: ($n.sni // ""), path: ($n.path // "/"), tls: "tls",
          sni: ($n.sni // ""), allowInsecure: ($n.insecure // 0)
        } | tojson | @base64)
      else "" end
  ' "$NODES"
}

show_link() {
  IDX=$1
  node_load "$IDX"
  local lmode cert_txt
  printf "  ${C}▸${N} ${B}%s${N}  ${D}%s · %s/%s${N}\n\n" "$_N_TAG" "$(proto_name "$_N_TYPE")" "$_N_PORT" "$(l4_label "$(proto_l4 "$_N_TYPE")")"

  case $_N_TYPE in
    vless)
      if [[ $_N_TR == xhttp ]]; then
        ui_kv "传输模式" "XHTTP + Reality"
        ui_kv "Path" "${_N_PATH:-/}"
        [[ -n $_N_XHOST ]] && ui_kv "Host" "$_N_XHOST"
      else
        ui_kv "传输模式" "RAW + Reality (Vision)"
      fi
      ui_kv "UUID" "$_N_UUID"
      ui_kv "SNI" "$_N_SNI"
      ui_kv "PublicKey" "$_N_PUB"
      ui_kv "ShortID" "$_N_SID"
      ;;
    trojan | hysteria2)
      cert_txt="自定义证书"
      [[ $_N_INSEC == 1 ]] && cert_txt="自签证书 (insecure=1)"
      ui_kv "密码" "$_N_PW"
      ui_kv "SNI" "$_N_SNI"
      ui_kv "证书" "$cert_txt"
      ;;
    vmess)
      cert_txt="自定义证书"
      [[ $_N_INSEC == 1 ]] && cert_txt="自签证书 (insecure=1)"
      ui_kv "UUID" "$_N_UUID"
      ui_kv "WS 路径" "${_N_PATH:-/}"
      ui_kv "SNI" "$_N_SNI"
      ui_kv "证书" "$cert_txt"
      ;;
    shadowsocks)
      ui_kv "加密方式" "$_N_METHOD"
      ui_kv "密码" "$_N_PW"
      ;;
    socks)
      ui_kv "监听范围" "$([[ $_N_LOCAL == 1 ]] && echo "仅本机 127.0.0.1" || echo "公网监听")"
      ui_kv "用户名" "$_N_USER"
      ui_kv "密码" "$_N_PASS"
      ;;
  esac

  echo
  if [[ -n $_N_HOST ]]; then
    printf "  ${D}连接地址（%s）${N}\n  ${G}%s${N}\n" "$_N_HOST" "$(build_link "$_N_HOST")"
  else
    detect_ips
    lmode=$(_listen_mode)
    if [[ $lmode != v4 && -n $PUBIP4 && -n $PUBIP6 ]]; then
      printf "  ${D}IPv4 链接${N}\n  ${G}%s${N}\n\n  ${D}IPv6 链接${N}\n  ${G}%s${N}\n" "$(build_link "$PUBIP4")" "$(build_link "$PUBIP6")"
    elif [[ -n $PUBIP4 ]]; then
      printf "  ${D}IPv4 链接${N}\n  ${G}%s${N}\n" "$(build_link "$PUBIP4")"
    elif [[ $lmode != v4 && -n $PUBIP6 ]]; then
      printf "  ${D}IPv6 链接${N}\n  ${G}%s${N}\n" "$(build_link "$PUBIP6")"
    else
      warn "未检测到可用公网 IP，以下链接中的 YOUR_IP 请手动替换为服务器地址"
      printf "  ${G}%s${N}\n" "$(build_link "YOUR_IP")"
    fi
  fi
  if [[ $_N_TYPE == vmess && $_N_INSEC == 1 ]]; then
    echo
    note "部分客户端不识别 VMess 链接中的 allowInsecure，若连接失败请手动开启「跳过证书验证」"
  fi
}

show_all_links() {
  local n=$1 i
  title "分享链接 · 全部节点"
  for ((i = 0; i < n; i++)); do
    show_link "$i"
    ((i < n - 1)) && printf "\n  %s\n\n" "$RULE"
  done
}

menu_links() {
  title "分享链接"
  local n
  n=$(node_count)
  if ((n == 1)); then
    show_link 0
    pause
    return
  fi
  list_nodes || { pause; return; }
  echo
  if ((n <= 9)); then
    printf "  ${D}按编号 [1-%s] 查看  [a/Enter] 全部  [0/q] 返回${N}" "$n"
    while :; do
      prompt_key || return
      case $REPLY in
        "") continue ;;
        0 | q | Q | ESC) return ;;
        a | A | ENTER) show_all_links "$n"; pause; return ;;
        [1-9])
          if ((REPLY <= n)); then
            title "分享链接"
            show_link "$((REPLY - 1))"
            pause
            return
          fi
          err "编号无效，请输入 1-$n"
          ;;
        *) err "无效按键，请输入 1-$n、a 或 0" ;;
      esac
    done
  fi
  while :; do
    ask_c "节点编号（a 全部，0 返回）" "a" || return
    if [[ $REPLY =~ ^[Aa]$ ]]; then
      show_all_links "$n"
      break
    fi
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      title "分享链接"
      show_link "$((10#$REPLY - 1))"
      break
    fi
    err "输入无效，请输入 1-$n、a 或 0"
  done
  pause
}

# ───────── 编辑节点 ─────────
node_fields() {
  case $_N_TYPE in
    socks) FIELDS=("port:监听端口" "user:用户名" "pass:密码") ;;
    shadowsocks) FIELDS=("port:监听端口" "method:加密方式" "password:密码") ;;
    trojan | hysteria2) FIELDS=("port:监听端口" "password:连接密码" "sni:域名 / SNI" "_cert:TLS 证书") ;;
    vless)
      FIELDS=("port:监听端口" "transport:传输方式" "sni:伪装域名")
      [[ $_N_TR == xhttp ]] && FIELDS+=("path:XHTTP 路径" "xhost:XHTTP Host")
      FIELDS+=("uuid:UUID" "sid:ShortID" "_reality:Reality 密钥")
      ;;
    vmess) FIELDS=("port:监听端口" "uuid:UUID" "path:WebSocket 路径" "sni:域名 / SNI" "_cert:TLS 证书") ;;
  esac
}

_field_display() { # 读取 node_load 缓存后的字段展示值
  case $1 in
    port) echo "$_N_PORT" ;;
    user) echo "$_N_USER" ;;
    pass) echo "$_N_PASS" ;;
    method) echo "$_N_METHOD" ;;
    password) echo "$_N_PW" ;;
    transport) echo "$_N_TR" ;;
    sni) echo "$_N_SNI" ;;
    path) echo "${_N_PATH:-—}" ;;
    xhost) echo "${_N_XHOST:-不限}" ;;
    uuid) echo "$_N_UUID" ;;
    sid) echo "$_N_SID" ;;
    _cert) [[ $_N_INSEC == 1 ]] && echo "自签 (${_N_SNI})" || echo "自定义 (${_N_SNI})" ;;
    _reality) echo "重新生成密钥对与 ShortID" ;;
  esac
}

edit_field() {
  local k=$1 np new_val
  EDIT_NOTICE=""
  node_load "$IDX"
  case $k in
    port)
      ask_port "$_N_TYPE" "$_N_PORT" || return 1
      np=$PORT
      jqw --argjson i "$IDX" --arg cur "$_N_PORT" --argjson p "$np" \
        '.[$i].tag |= sub("-" + $cur + "$"; "-" + ($p|tostring)) | .[$i].port=$p' || return 1
      EDIT_NOTICE="端口已更新为 $np"
      ;;
    method)
      pick_ss_method || return 1
      jqw --argjson i "$IDX" --arg m "$SS_M" --arg p "$SS_P" '.[$i].method=$m | .[$i].password=$p' || return 1
      EDIT_NOTICE="加密方式已切换为 $SS_M，密码已同步重新生成"
      ;;
    password)
      _PW_SSM=""
      [[ $_N_TYPE == shadowsocks ]] && _PW_SSM=$_N_METHOD
      local msg_pw="密码不能为空或包含控制字符"
      [[ $_PW_SSM == 2022-blake3-* ]] && msg_pw="SS 2022 密码须为对应长度（16 或 32 字节）的标准 Base64"
      ask_valid "新密码（0 取消）" "$_N_PW" _valid_node_pw "$msg_pw" "reject_same" || return 1
      setf "$IDX" password "$REPLY" || return 1
      EDIT_NOTICE="密码已更新"
      ;;
    transport)
      pick_vless_tr "$_N_TR" "传输方式" || return 1
      [[ $VLESS_TR == "$_N_TR" ]] && return 1
      if [[ $VLESS_TR == xhttp ]]; then
        local np_path np_xhost=""
        ask_path "XHTTP 路径（0 取消）" "${_N_PATH:-/$(rnd 8)}" np_path || return 1
        ask_valid "XHTTP Host（留空不限，0 取消）" "" valid_sni "Host 格式无效" "empty_ok" || return 1
        np_xhost=$REPLY
        jqw --argjson i "$IDX" --arg p "$np_path" --arg h "$np_xhost" \
          '.[$i].transport="xhttp" | .[$i].path=$p | (if $h != "" then .[$i].xhost=$h else del(.[$i].xhost) end)' || return 1
        EDIT_NOTICE="传输方式已切换为 XHTTP"
      else
        jqw --argjson i "$IDX" '.[$i].transport="raw" | del(.[$i].path, .[$i].xhost)' || return 1
        EDIT_NOTICE="传输方式已切换为 RAW (Vision)"
      fi
      ;;
    sni)
      ask_sni "新域名 / SNI（0 取消）" new_val "$_N_SNI" "reject_same" || return 1
      if [[ $_N_INSEC == 1 ]]; then
        gen_self_cert "$new_val" || { pause; return 1; }
        jqw --argjson i "$IDX" --arg s "$new_val" --arg c "$CERT" --arg k "$KEY" '.[$i].sni=$s | .[$i].cert=$c | .[$i].key=$k' || return 1
        EDIT_NOTICE="SNI 已更新，并已同步生成对应自签证书"
      elif [[ $_N_INSEC == 0 && -n $_N_HOST ]]; then
        jqw --argjson i "$IDX" --arg s "$new_val" '.[$i].sni=$s | .[$i].host=$s' || return 1
        EDIT_NOTICE="SNI 与分享域名已同步更新，请确保证书匹配新域名"
      else
        setf "$IDX" sni "$new_val" || return 1
        [[ $_N_TYPE == vless ]] && check_reality_sni "$new_val"
        EDIT_NOTICE="SNI 已更新为 $new_val"
      fi
      ;;
    path)
      ask_path "新路径（0 取消）" "$_N_PATH" new_val "reject_same" || return 1
      setf "$IDX" path "$new_val" || return 1
      EDIT_NOTICE="路径已更新为 $new_val"
      ;;
    xhost)
      ask_valid "新 XHTTP Host（输入 - 清空，0 取消）" "$_N_XHOST" valid_sni "Host 格式无效" "reject_same clear_dash" || return 1
      if [[ -z $REPLY ]]; then
        jqw --argjson i "$IDX" 'del(.[$i].xhost)' || return 1
        EDIT_NOTICE="已清空 XHTTP Host 限制"
      else
        setf "$IDX" xhost "$REPLY" || return 1
        EDIT_NOTICE="XHTTP Host 已更新为 $REPLY"
      fi
      ;;
    uuid)
      ask_valid "新 UUID（输入 r 随机生成，0 取消）" "$_N_UUID" valid_uuid "UUID 格式无效" "reject_same rand=gen_uuid" || return 1
      setf "$IDX" uuid "$REPLY" || return 1
      EDIT_NOTICE="UUID 已更新"
      ;;
    sid)
      ask_valid "新 ShortID（输入 r 随机，偶数十六进制 2-16 位，0 取消）" "$_N_SID" valid_sid "ShortID 格式无效" "reject_same rand=gen_sid" || return 1
      setf "$IDX" sid "$REPLY" || return 1
      EDIT_NOTICE="ShortID 已更新"
      ;;
    _cert)
      local rc=0
      ask_cert 1 "$_N_SNI" || rc=$?
      ((rc == 0)) || { ((rc != 2)) && pause; return 1; }
      jqw --argjson i "$IDX" --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson in "$INSECURE" \
        '.[$i] += {cert:$c,key:$k,sni:$sni,host:$h,insecure:$in}' || return 1
      EDIT_NOTICE="证书配置已更新"
      ;;
    _reality)
      gen_reality || { pause; return 1; }
      jqw --argjson i "$IDX" --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" \
        '.[$i] += {priv:$priv,pub:$pub,sid:$sid}' || return 1
      EDIT_NOTICE="已重新生成 Reality 密钥对与 ShortID"
      ;;
    user)
      ask_cred "新用户名（0 取消）" "$_N_USER" new_val "reject_same" || return 1
      setf "$IDX" user "$new_val" || return 1
      EDIT_NOTICE="用户名已更新"
      ;;
    pass)
      ask_cred "新密码（0 取消）" "$_N_PASS" new_val "reject_same" || return 1
      setf "$IDX" pass "$new_val" || return 1
      EDIT_NOTICE="密码已更新"
      ;;
  esac
}

menu_edit() {
  title "编辑节点"
  list_nodes || { pause; return; }
  choose_node || return
  local dirty=0 i f k c toast_fn="" toast_msg="" tag_title
  snapshot
  while :; do
    node_load "$IDX"
    tag_title="编辑节点 · $_N_TAG"
    ((dirty)) && tag_title+="  ${Y}[未保存]${N}"
    title "$tag_title"
    node_fields
    i=1
    for f in "${FIELDS[@]}"; do
      k=${f%%:*}
      printf "    ${C}[%s]${N}  " "$i"
      pad_print "${f#*:}" 18
      printf "${D}%s${N}\n" "$(_field_display "$k")"
      ((i++))
    done
    echo
    printf "  %s\n" "$RULE"
    if ((dirty)); then
      printf "  ${C}[1-%s]${N} 修改   ${G}[s]${N} 保存并应用   ${D}[0/q] 放弃返回${N}\n" "${#FIELDS[@]}"
    else
      printf "  ${C}[1-%s]${N} 修改   ${D}[0/q] 返回${N}\n" "${#FIELDS[@]}"
    fi
    show_toast "$toast_fn" "$toast_msg"
    toast_fn=""
    toast_msg=""
    prompt_key || {
      ((dirty)) && rollback "$BAK" "已取消修改" || clear_snapshot
      return
    }
    c=$REPLY
    case $c in
      "" | ENTER) continue ;;
      0 | q | Q | ESC)
        if ((dirty)); then
          confirm "当前有未保存的修改，确认放弃？" || continue
          rollback "$BAK" ""
        else
          clear_snapshot
        fi
        return
        ;;
      s | S)
        ((dirty)) && break
        toast_fn=err
        toast_msg="当前没有未保存的修改"
        ;;
      [1-9])
        if ((c <= ${#FIELDS[@]})); then
          echo
          if edit_field "${FIELDS[$((c - 1))]%%:*}"; then
            dirty=1
            toast_fn=note
            toast_msg=$EDIT_NOTICE
          fi
        else
          toast_fn=err
          toast_msg="无效选项，请按 1-${#FIELDS[@]}"
        fi
        ;;
      *)
        toast_fn=err
        toast_msg="无效按键"
        ;;
    esac
  done
  echo
  if apply; then
    clear_snapshot
    echo
    show_link "$IDX"
  else
    rollback "$BAK" "配置校验或启动失败，已回滚全部修改"
  fi
  pause
}

# ───────── 删除节点 / 服务管理 / 卸载 ─────────
menu_del() {
  title "删除节点"
  list_nodes || { pause; return; }
  choose_node || return
  node_load "$IDX"
  echo
  confirm "确认删除节点 ${B}$_N_TAG${N}（$(proto_name "$_N_TYPE") · 端口 $_N_PORT）？" || return
  snapshot
  jqw --argjson i "$IDX" 'del(.[$i])' || { rollback "$BAK" "更新节点列表失败"; pause; return; }
  echo
  if apply; then
    clear_snapshot
    ok "节点 $_N_TAG 已删除"
  else
    rollback "$BAK" "配置应用失败，已撤销删除"
  fi
  pause
}

menu_service() {
  local c st auto toast_fn="" toast_msg=""
  while :; do
    title "服务管理"
    st="${D}○ 已停止${N}"
    svc_ctl is-active && st="${G}● 运行中${N}"
    auto="${D}已关闭${N}"
    svc_ctl is-enabled && auto="${G}已开启${N}"

    ui_kv "运行状态" "$st"
    ui_kv "开机自启" "$auto"
    ui_kv "监听模式" "$(_listen_label)"
    ui_kv "节点配置" "$NODES（$(node_count) 个节点）"
    echo
    printf "    ${C}[1]${N}  "; pad_print "启动 / 重启服务" 20; printf "${C}[3]${N}  切换开机自启\n"
    printf "    ${C}[2]${N}  "; pad_print "停止服务" 20; printf "${C}[4]${N}  查看运行日志\n"
    echo
    printf "    ${D}[0]  返回主菜单${N}\n"
    show_toast "$toast_fn" "$toast_msg"
    toast_fn=""
    toast_msg=""
    prompt_key || return
    c=$REPLY
    case $c in
      "" | ENTER) continue ;;
      0 | q | Q | ESC) return ;;
      1)
        echo
        if apply; then
          toast_fn=ok
          toast_msg="服务已重新加载并运行正常"
        else
          pause
        fi
        ;;
      2)
        if svc_ctl stop; then
          toast_fn=ok
          toast_msg="服务已停止"
        else
          toast_fn=err
          toast_msg="停止服务失败，请查看运行日志"
        fi
        ;;
      3)
        if svc_ctl is-enabled; then
          svc_ctl disable && { toast_fn=ok; toast_msg="已关闭开机自启"; } || { toast_fn=err; toast_msg="关闭开机自启失败"; }
        else
          svc_ctl enable && { toast_fn=ok; toast_msg="已开启开机自启"; } || { toast_fn=err; toast_msg="开启开机自启失败"; }
        fi
        ;;
      4) title "运行日志"; svc_logs; pause ;;
      *) toast_fn=err; toast_msg="无效选项，请按 1-4" ;;
    esac
  done
}

uninstall() {
  title "${R}彻底卸载${N}"
  local n svc_file="/etc/init.d/xray"
  n=$(node_count)
  [[ $OS == debian ]] && svc_file="/etc/systemd/system/xray.service"
  warn "此操作将彻底清除 Xray-core 及其全部数据，且不可恢复"
  ((n > 0)) && warn "当前仍有 $n 个节点配置，卸载后将一并删除"
  echo
  ui_kv "内核文件" "$XR_BIN"
  ui_kv "快捷命令" "/usr/local/bin/xr"
  ui_kv "配置目录" "$XR_DIR（含节点与证书）"
  ui_kv "服务文件" "$svc_file"
  [[ $OS == alpine ]] && ui_kv "运行日志" "$XR_LOG"
  echo
  confirm "确认彻底卸载 Xray-core？" || return
  echo
  info "正在停止服务并清理文件…"
  svc_ctl stop || true
  svc_ctl disable || true
  rm -f /etc/systemd/system/xray.service /etc/init.d/xray /etc/logrotate.d/xray \
    "$XR_BIN" /usr/local/bin/xr "$XR_LOG" /run/xray.pid
  rm -rf "$XR_DIR"
  if [[ $OS == debian ]]; then
    systemctl daemon-reload
    systemctl reset-failed xray 2>/dev/null || true
  fi
  ok "已彻底卸载并清理全部数据"
  exit 0
}

# ───────── 主界面 ─────────
header() {
  ui_refresh
  clr
  local fill
  if xr_installed; then
    local st="${D}○ 已停止${N}" v auto="关闭" lmode="双栈"
    svc_ctl is-active && st="${G}● 运行中${N}"
    svc_ctl is-enabled && auto="开启"
    case $(_listen_mode) in
      v4) lmode="仅 IPv4" ;;
      dual_split) lmode="分栈" ;;
    esac
    v=$(xr_version)
    v=${v:-?}
    fill=$((UI_W - 26 - ${#v}))
    ((fill < 2)) && fill=2
    printf "${C}╭─${N} ${B}Xray-core${N}  %s  ${D}v%s${N} ${C}%s${N}\n" "$st" "$v" "$(_repeat_ch '─' "$fill")"
    printf "${C}│${N}  ${D}节点 %s 个 · 自启 %s · %s · %s${N}\n" "$(node_count)" "$auto" "$lmode" "$(os_label)"
    printf "${C}╰%s${N}\n" "$(_repeat_ch '─' $((UI_W - 1)))"
  else
    fill=$((UI_W - 21))
    ((fill < 2)) && fill=2
    printf "${C}╭─${N} ${B}Xray-core${N}  ${D}未安装${N} ${C}%s${N}\n" "$(_repeat_ch '─' "$fill")"
    printf "${C}│${N}  ${D}系统环境：%s · 尚未安装内核${N}\n" "$(os_label)"
    printf "${C}╰%s${N}\n" "$(_repeat_ch '─' $((UI_W - 1)))"
  fi
  echo
}

main_menu() {
  local c toast_msg="" urc xr_bak=""
  while :; do
    header
    printf "  "
    pad_print "节点管理" 26 "$D" "$N"
    printf "${D}%s${N}\n" "系统维护"
    printf "    ${C}[1]${N}  "; pad_print "查看节点" 21; printf "${C}[6]${N}  服务管理\n"
    printf "    ${C}[2]${N}  "; pad_print "添加节点" 21; printf "${C}[7]${N}  运行日志\n"
    printf "    ${C}[3]${N}  "; pad_print "编辑节点" 21; printf "${C}[8]${N}  更新内核\n"
    printf "    ${C}[4]${N}  "; pad_print "删除节点" 21; printf "${R}[9]${N}  彻底卸载\n"
    printf "    ${C}[5]${N}  "; pad_print "分享链接" 21; printf "${D}[0]  退出面板${N}\n"
    echo
    printf "  %s\n" "$RULE"
    printf "  ${D}单键直达 · 按 [0/q/Esc] 退出${N}\n"
    show_toast err "$toast_msg"
    toast_msg=""
    prompt_key || exit 0
    c=$REPLY
    case $c in
      "" | ENTER) continue ;;
      1) menu_nodes ;;
      2) menu_add ;;
      3) menu_edit ;;
      4) menu_del ;;
      5) menu_links ;;
      6) menu_service ;;
      7) title "运行日志"; svc_logs; pause ;;
      8)
        title "更新内核"
        urc=0
        xr_bak=""
        xr_installed && { xr_bak="$RUN_TMP/xray.bak"; cp -a "$XR_BIN" "$xr_bak" 2>/dev/null || xr_bak=""; }
        install_xray || urc=$?
        if ((urc == 0)); then
          echo
          if ! apply && [[ -n $xr_bak && -f $xr_bak ]]; then
            warn "新内核应用配置失败，正在回滚至旧版本内核…"
            install -m755 "$xr_bak" "$XR_BIN" 2>/dev/null && apply || err "回滚旧内核失败，请手动检查"
          fi
          rm -f "$xr_bak"
          pause
        elif ((urc == 1)); then
          rm -f "$xr_bak"
          pause
        else
          rm -f "$xr_bak"
        fi
        ;;
      9) uninstall ;;
      0 | q | Q | ESC) clr; exit 0 ;;
      *) toast_msg="无效按键，请按 0-9" ;;
    esac
  done
}

# ───────── 入口 ─────────
acquire_lock
ensure_deps
if ! xr_installed; then
  header
  info "尚未安装 Xray-core"
  echo
  confirm "是否立即下载并安装？" || exit 0
  echo
  install_xray || exit 1
  sleep_frac 0.6
fi
init_dirs
if [[ $0 != bash && $0 != -bash && -f $0 && $(readlink -f "$0") != /usr/local/bin/xr ]] \
  && head -n 1 "$0" 2>/dev/null | grep -q '^#!'; then
  if [[ ! -x /usr/local/bin/xr ]] || ! cmp -s "$0" /usr/local/bin/xr 2>/dev/null; then
    local_xr_existed=0
    [[ -x /usr/local/bin/xr ]] && local_xr_existed=1
    install -m755 "$0" /usr/local/bin/xr 2>/dev/null && {
      ((local_xr_existed)) && note "已同步更新快捷命令 xr" || note "已创建快捷命令 xr，后续可直接输入 xr 启动面板"
      sleep_frac 0.8
    }
  fi
elif [[ ! -x /usr/local/bin/xr && (! -f $0 || $0 == bash || $0 == -bash) && -n $SCRIPT_URL ]]; then
  echo
  if confirm "是否安装快捷命令 xr（便于后续一键启动）？"; then
    if curl -fsSL "$SCRIPT_URL" -o "$RUN_TMP/xr.sh" 2>/dev/null && head -n 1 "$RUN_TMP/xr.sh" | grep -q '^#!'; then
      install -m755 "$RUN_TMP/xr.sh" /usr/local/bin/xr 2>/dev/null && ok "快捷命令 xr 已安装"
    else
      err "快捷命令下载失败"
    fi
    sleep_frac 0.8
  fi
fi
main_menu
