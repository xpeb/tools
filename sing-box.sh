#!/usr/bin/env bash
# sing-box 极简交互式面板（支持 Debian systemd / Alpine OpenRC，Alpine 需预装 bash）
# 支持协议：VLESS (Reality) / Hysteria2 / AnyTLS / TUIC v5 / Trojan (TLS) / VMess (WS+TLS) / Shadowsocks / SOCKS5

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

SB_BIN=/usr/local/bin/sing-box
SB_DIR=/etc/sing-box
CERT_DIR=/etc/sing-box/cert
NODES=/etc/sing-box/nodes.json
CONF=/etc/sing-box/config.json
SB_LOG=/var/log/sing-box.log
SCRIPT_URL="https://raw.githubusercontent.com/xpeb/vps-tools/main/sing-box.sh"
DEFAULT_SNI=www.apache.org

[[ $EUID -eq 0 ]] || { echo "请使用 root 权限运行此脚本"; exit 1; }
if command -v apt-get >/dev/null && command -v systemctl >/dev/null; then
  OS=debian
elif command -v apk >/dev/null && command -v rc-service >/dev/null; then
  OS=alpine
else
  echo "当前系统不受支持，仅兼容 Debian (systemd) 与 Alpine (OpenRC)"
  exit 1
fi

# ───────── 界面样式与交互辅助 ─────────
B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
RULE="${D}────────────────────────────────────────────────${N}"
_UTF8_CHAR="中"

info() { printf "${D}·${N} %s\n" "$*"; }
note() { printf "${C}i${N} %s\n" "$*"; }
warn() { printf "${Y}!${N} %s\n" "$*"; }
ok() { printf "${G}✓${N} %s\n" "$*"; }
err() { printf "${R}✗${N} %s\n" "$*"; }

pad_print() { # $1=文本 $2=目标宽度 [$3=前缀色 [$4=后缀色]]
  local s=$1 target=$2 pre=${3:-} suf=${4:-} ascii w pad
  ascii=${s//[^ -~]/}
  if ((${#_UTF8_CHAR} == 1)); then
    w=$((${#s} * 2 - ${#ascii}))
  else
    w=$((${#ascii} + (${#s} - ${#ascii}) * 2 / 3))
  fi
  pad=$((target - w))
  ((pad < 1)) && pad=1
  printf "%s%s%s%*s" "$pre" "$s" "$suf" "$pad" ""
}

pause() {
  echo
  read -rsp "${D}按回车键返回…${N}" _
  echo
}

title() {
  header
  printf "${C}▸${N} ${B}%s${N}\n\n" "$1"
}

ask() { # $1=提示 $2=默认值 -> REPLY；EOF 返回 1
  if [[ -n $2 ]]; then
    read -rp "${B}$1${N} ${D}[$2]${N}: " REPLY || return 1
    REPLY=${REPLY:-$2}
  else
    read -rp "${B}$1${N}: " REPLY || return 1
  fi
}

ask_c() { ask "$@" && [[ $REPLY != 0 ]] || return 2; } # 支持 0 / EOF 取消（返回 2）

confirm() { # $1=提示；默认 N
  read -rp "${Y}?${N} $1 ${D}[y/N]${N}: " REPLY || return 1
  [[ $REPLY =~ ^[Yy]$ ]]
}

prompt_choice() {
  echo
  read -rp "${C}›${N} " REPLY
}

show_toast() { # $1=函数名 $2=消息
  [[ -n $2 ]] || return 0
  echo
  "$1" "$2"
}

proto_name() {
  case $1 in
    vless) echo "VLESS" ;;
    hysteria2) echo "Hysteria2" ;;
    anytls) echo "AnyTLS" ;;
    tuic) echo "TUIC" ;;
    trojan) echo "Trojan" ;;
    vmess) echo "VMess" ;;
    shadowsocks) echo "Shadowsocks" ;;
    socks) echo "SOCKS5" ;;
    *) echo "$1" ;;
  esac
}

proto_l4() {
  case $1 in
    hysteria2 | tuic) echo udp ;;
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

RUN_TMP=$(mktemp -d -t sb-panel.XXXXXX) || { err "无法创建临时目录"; exit 1; }
CONF_TMP="$RUN_TMP/config.json"
PENDING_BAK=""
CONF_DIRTY=0
SB_VER=""

node_count() { [[ -f $NODES ]] && jq length "$NODES" 2>/dev/null || echo 0; }
sb_installed() { [[ -x $SB_BIN ]]; }
sb_version() { "$SB_BIN" version 2>/dev/null | awk 'NR==1{print $3}'; }

_restore_snapshot() { # $1=快照文件
  local bak=$1
  [[ -n $bak && -f $bak && -n ${NODES:-} ]] || return 0
  cp "$bak" "$NODES" 2>/dev/null || true
  chmod 600 "$NODES" 2>/dev/null || true
  if [[ ${CONF_DIRTY:-0} == 1 ]] && sb_installed; then
    if gen_config 2>/dev/null && chmod 600 "$CONF_TMP" 2>/dev/null && mv "$CONF_TMP" "$CONF" 2>/dev/null; then
      (($(node_count) == 0)) && svc_ctl stop || svc_ctl restart
    fi
  fi
  PENDING_BAK=""
  CONF_DIRTY=0
}

cleanup() {
  _restore_snapshot "${PENDING_BAK:-}"
  [[ -n ${RUN_TMP:-} ]] && rm -rf "$RUN_TMP"
}
trap cleanup EXIT
trap 'cleanup; echo; exit 130' INT TERM

# ───────── 基础环境与服务 ─────────
ensure_deps() {
  local pk=() c log="$RUN_TMP/deps.log"
  for c in curl jq openssl tar ss; do
    command -v "$c" >/dev/null && continue
    [[ $c == ss ]] && pk+=(iproute2) || pk+=("$c")
  done
  [[ ${#pk[@]} -eq 0 ]] && return 0
  info "正在安装必要依赖：${pk[*]}…"
  if [[ $OS == debian ]]; then
    apt-get update -qq >"$log" 2>&1 && apt-get install -y -qq "${pk[@]}" ca-certificates >>"$log" 2>&1
  else
    apk add --no-cache "${pk[@]}" ca-certificates >"$log" 2>&1
  fi || {
    err "依赖安装失败，请检查软件源或网络连接"
    tail -n 20 "$log" 2>/dev/null
    exit 1
  }
}

svc_install() {
  local first=0
  if [[ $OS == debian ]]; then
    [[ -f /etc/systemd/system/sing-box.service ]] || first=1
    cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
ExecStart=$SB_BIN run -c $CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  else
    [[ -f /etc/init.d/sing-box ]] || first=1
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
}
EOF
    chmod 755 /etc/init.d/sing-box
    if [[ -d /etc/logrotate.d ]]; then
      cat >/etc/logrotate.d/sing-box <<EOF
$SB_LOG {
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
  ((first)) && svc_ctl enable
}

svc_ctl() { # is-active | is-enabled | enable | disable | restart | stop
  if [[ $OS == debian ]]; then
    case $1 in
      is-active | is-enabled) systemctl "$1" --quiet sing-box ;;
      *) systemctl "$1" sing-box >/dev/null 2>&1 ;;
    esac
  else
    case $1 in
      is-active) rc-service sing-box status >/dev/null 2>&1 ;;
      is-enabled) rc-update show default 2>/dev/null | grep -qw sing-box ;;
      enable) rc-update add sing-box default >/dev/null 2>&1 ;;
      disable) rc-update del sing-box default >/dev/null 2>&1 ;;
      restart)
        rc-service sing-box stop >/dev/null 2>&1 || true
        rc-service sing-box start >/dev/null 2>&1
        ;;
      stop) rc-service sing-box stop >/dev/null 2>&1 ;;
    esac
  fi
}

svc_logs() {
  local out=""
  if [[ $OS == debian ]]; then
    out=$(journalctl -u sing-box -n 40 --no-pager -o cat 2>/dev/null)
  elif [[ -f $SB_LOG ]]; then
    out=$(tail -n 40 "$SB_LOG" 2>/dev/null)
  fi
  if [[ -n $out ]]; then
    printf "${D}最近 40 条日志：${N}\n%s\n%s\n" "$RULE" "$out"
  else
    info "暂无运行日志"
  fi
}

_fetch_ip() { # $1=-4|-6 $2=regex
  local ip u
  for u in https://api${1#-}.ipify.org https://ip.sb https://ifconfig.me; do
    ip=$(curl -s "$1" -m 2 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ $2 ]] && { echo "$ip"; return 0; }
  done
}

detect_ips() {
  [[ -n ${IP_DETECTED:-} ]] && return
  IP_DETECTED=1
  printf "${D}· 正在检测公网 IP…${N}"
  _fetch_ip -4 '^[0-9.]+$' >"$RUN_TMP/ip4" &
  _fetch_ip -6 '^[0-9a-fA-F:]+:[0-9a-fA-F:]*$' >"$RUN_TMP/ip6" &
  wait
  printf "\r\033[K"
  [[ -s $RUN_TMP/ip4 ]] && PUBIP4=$(<"$RUN_TMP/ip4") || PUBIP4=""
  [[ -s $RUN_TMP/ip6 ]] && PUBIP6=$(<"$RUN_TMP/ip6") || PUBIP6=""
}

init_dirs() {
  mkdir -p "$SB_DIR" "$CERT_DIR" && chmod 700 "$SB_DIR" "$CERT_DIR"
  [[ -f $NODES ]] || { echo '[]' >"$NODES"; chmod 600 "$NODES"; }
}

_download_sb() { # $1=ver $2=target $3=tmp_dir [$4=expected_sha256]
  local pkg="sing-box-$1-linux-$2"
  local url="https://github.com/SagerNet/sing-box/releases/download/v$1/$pkg.tar.gz"
  local expected=${4:-} actual bin_path new_ver err_out
  info "正在下载 sing-box v$1（$2）…"
  curl -fsSL -o "$3/sb.tar.gz" "$url" 2>/dev/null || { err "安装包下载失败"; return 1; }
  if [[ -n $expected ]]; then
    info "正在校验安装包 SHA256…"
    actual=$(sha256sum "$3/sb.tar.gz" | awk '{print $1}')
    [[ $expected == "$actual" ]] || { err "安装包 SHA256 校验未通过，文件可能已损坏"; return 1; }
  else
    warn "未获取到上游 SHA256 摘要，跳过完整性校验"
  fi
  info "正在验证并安装二进制文件…"
  tar -xzf "$3/sb.tar.gz" -C "$3" 2>/dev/null || { err "解压安装包失败"; return 1; }
  bin_path=$(find "$3" -maxdepth 2 -type f -name sing-box | head -n 1)
  if [[ -z $bin_path ]] || ! install -m755 "$bin_path" "$SB_BIN.new" 2>/dev/null; then
    rm -f "$SB_BIN.new"
    err "提取或写入可执行文件失败"
    return 1
  fi
  # 原子替换前先冒烟验证，防止异常包破坏现有可用内核
  err_out=$("$SB_BIN.new" version 2>&1) || true
  new_ver=$(awk 'NR==1 && $1=="sing-box"{print $3}' <<<"$err_out")
  if [[ -z $new_ver ]]; then
    rm -f "$SB_BIN.new"
    err "下载的二进制文件无法在当前系统执行"
    [[ -n $err_out ]] && printf '%s\n' "$err_out" | head -n 3
    return 1
  fi
  mv -f "$SB_BIN.new" "$SB_BIN" 2>/dev/null || { rm -f "$SB_BIN.new"; err "替换可执行文件失败"; return 1; }
  SB_VER=$new_ver
}

install_sb() {
  local arch target ver tmp eff_url rel_json sha="" rc=0
  case $(uname -m) in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    armv7l) arch=armv7 ;;
    i386 | i686) arch=386 ;;
    *) err "不支持的系统架构：$(uname -m)"; return 1 ;;
  esac
  target=$arch
  if [[ $OS == alpine ]] || ldd --version 2>&1 | grep -qi musl; then
    target+="-musl"
  fi
  info "正在查询最新 sing-box 版本…"
  rel_json=$(curl -fsSL -m 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null || true)
  if [[ -n $rel_json ]]; then
    ver=$(jq -r '.tag_name // empty' <<<"$rel_json" 2>/dev/null | sed 's/^v//')
    if [[ -n $ver ]]; then
      sha=$(jq -r --arg name "sing-box-$ver-linux-$target.tar.gz" \
        '(.assets // [])[] | select(.name == $name) | .digest // empty' <<<"$rel_json" 2>/dev/null | sed 's/^sha256://')
    fi
  fi
  if [[ -z $ver ]]; then
    eff_url=$(curl -fsSLI -m 10 -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null)
    ver=${eff_url##*/}
    ver=${ver#v}
    [[ $ver == latest ]] && ver=""
  fi
  [[ -n $ver ]] || { err "获取最新版本信息失败，请检查网络连接"; return 1; }
  if sb_installed; then
    [[ -n $SB_VER ]] || SB_VER=$(sb_version)
    if [[ $SB_VER == "$ver" ]]; then
      ok "当前已是最新版本 v$ver"
      confirm "是否强制重新安装？" || return 2
    fi
  fi
  tmp=$(mktemp -d "$RUN_TMP"/dl.XXXXXX) || { err "创建临时下载目录失败"; return 1; }
  _download_sb "$ver" "$target" "$tmp" "$sha" || rc=$?
  rm -rf "$tmp"
  ((rc == 0)) || return 1
  init_dirs
  svc_install
  ok "sing-box v$SB_VER 安装完成"
}

# ───────── 配置生成（严格遵循 sing-box 官方文档 1.14+ 标准）─────────
gen_config() {
  local listen_ip="::"
  [[ -s /proc/net/if_inet6 ]] || listen_ip="0.0.0.0"
  jq --arg l "$listen_ip" '
    def base: {type: .type, tag: .tag, listen: $l, listen_port: .port};
    def tls($alpn):
      {enabled: true, server_name: .sni, certificate_path: .cert, key_path: .key}
      + (if $alpn != null then {alpn: $alpn} else {} end);
    {
      log: {level: "warn", timestamp: true},
      dns: {
        servers: [{type: "local", tag: "local"}],
        final: "local",
        optimistic: true
      },
      inbounds: map(
        if .type == "socks" then
          base + {users: [{username: .user, password: .pass}]}
        elif .type == "shadowsocks" then
          base + {method: .method, password: .password}
        elif .type == "trojan" then
          base + {users: [{name: .tag, password: .password}], tls: tls(["h2", "http/1.1"])}
        elif .type == "anytls" then
          base + {users: [{name: .tag, password: .password}], tls: tls(null)}
        elif .type == "vless" then
          base + {
            users: [{name: .tag, uuid: .uuid, flow: "xtls-rprx-vision"}],
            tls: {
              enabled: true, server_name: .sni,
              reality: {
                enabled: true,
                handshake: {server: .sni, server_port: 443},
                private_key: .priv,
                short_id: [.sid]
              }
            }
          }
        elif .type == "vmess" then
          base + {
            users: [{name: .tag, uuid: .uuid, alterId: 0}],
            tls: tls(["http/1.1"]),
            transport: {type: "ws", path: .path}
          }
        elif .type == "hysteria2" then
          base + {
            users: [{name: .tag, password: .password}],
            bbr_profile: (.bbr_profile // "standard"),
            tls: tls(["h3"])
          }
        elif .type == "tuic" then
          base + {
            users: [{name: .tag, uuid: .uuid, password: .password}],
            congestion_control: (.cc // "bbr"),
            zero_rtt_handshake: false,
            tls: tls(["h3"])
          }
        else empty end
      ),
      outbounds: [{type: "direct", tag: "direct"}],
      route: {
        rules: [
          {action: "sniff"},
          {action: "resolve"},
          {ip_is_private: true, action: "reject"}
        ],
        final: "direct",
        default_domain_resolver: "local"
      }
    }
  ' "$NODES" >"$CONF_TMP"
}

apply() {
  info "正在校验并应用配置…"
  gen_config || { err "生成配置文件失败"; rm -f "$CONF_TMP"; return 1; }
  local out i
  if ! out=$("$SB_BIN" check -c "$CONF_TMP" 2>&1); then
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
    svc_ctl stop
    PENDING_BAK=""
    CONF_DIRTY=0
    ok "当前无可用节点，已自动停止服务"
    return 0
  fi
  svc_ctl restart
  for i in 1 2 3 4 5 6; do
    sleep 0.5
    svc_ctl is-active && {
      PENDING_BAK=""
      CONF_DIRTY=0
      ok "配置已生效，服务运行正常"
      return 0
    }
  done
  [[ -n $PENDING_BAK ]] || CONF_DIRTY=0
  err "服务未能正常启动，请前往「运行日志」排查原因"
  return 1
}

# ───────── 通用校验与辅助 ─────────
rnd() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_sni() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
    && [[ $1 != *..* && $1 != *.-* && $1 != *-.* ]]
}
valid_path() { [[ $1 == /* && ! $1 =~ [[:space:]] ]]; }
valid_ss2022_psk() {
  local need=16 decoded
  [[ $1 == 2022-blake3-aes-128-gcm ]] || need=32
  [[ $2 =~ ^[A-Za-z0-9+/]+=*$ ]] || return 1
  decoded=$(printf %s "$2" | base64 -d 2>/dev/null | wc -c; exit "${PIPESTATUS[1]}") || return 1
  ((decoded == need))
}

port_free() { # $1=port $2=tcp|udp|both [$3=豁免的本节点原端口]
  local p=$1 l4=${2:-both} own=${3:-} ss_opt="-lntu"
  case $l4 in
    tcp) ss_opt="-lnt" ;;
    udp) ss_opt="-lnu" ;;
  esac
  if [[ -z $own || $p != "$own" ]]; then
    ss "$ss_opt" 2>/dev/null | awk 'NR>1{print $5}' | grep -qE "[:.]$p$" && return 1
  fi
  ! jq -e --argjson p "$p" --arg l4 "$l4" '
    def l4of: if .type == "hysteria2" or .type == "tuic" then "udp"
              elif .type == "shadowsocks" or .type == "socks" then "both"
              else "tcp" end;
    any(.[]; .port == $p and ($l4 == "both" or l4of == "both" or l4of == $l4))
  ' "$NODES" >/dev/null 2>&1
}

ask_port() { # $1=协议类型 [$2=当前值(编辑模式) [$3=豁免原端口]]；取消或未变更返回 2
  local l4 l4_txt def prompt cur=${2:-} own=${3:-}
  l4=$(proto_l4 "$1")
  l4_txt=$(l4_label "$l4")
  if [[ -n $cur ]]; then
    def=$cur
    prompt="新端口（$l4_txt，0 取消）"
  else
    while :; do
      def=$((20000 + RANDOM % 30000))
      port_free "$def" "$l4" && break
    done
    prompt="监听端口（$l4_txt）"
  fi
  while :; do
    ask_c "$prompt" "$def" || return 2
    [[ -n $cur && $REPLY == "$cur" ]] && return 2
    valid_port "$REPLY" || { err "端口无效，请输入 1-65535 之间的整数"; continue; }
    PORT=$((10#$REPLY))
    port_free "$PORT" "$l4" "$own" && return 0
    err "端口 $PORT（$l4_txt）已被占用，请更换其他端口"
  done
}

ask_sni() { # $1=提示 $2=变量名(默认 SNI) [$3=默认值]；取消返回 2
  local var=${2:-SNI} def=${3:-$DEFAULT_SNI}
  while :; do
    ask_c "$1" "$def" || return 2
    valid_sni "$REPLY" && { printf -v "$var" '%s' "$REPLY"; return 0; }
    err "域名 / SNI 格式无效（仅支持字母、数字、点与连字符）"
  done
}

ask_path() { # $1=提示 $2=默认值 $3=变量名；取消返回 2
  local var=${3:-WPATH}
  while :; do
    ask_c "$1" "$2" || return 2
    valid_path "$REPLY" && { printf -v "$var" '%s' "$REPLY"; return 0; }
    err "路径须以 / 开头且不能包含空白字符"
  done
}

gen_self_cert() { # $1=sni -> 设置 CERT 和 KEY
  local sni=$1
  CERT=$CERT_DIR/$sni.crt
  KEY=$CERT_DIR/$sni.key
  if [[ ! -f $CERT || ! -f $KEY ]]; then
    local ossl=(req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1
      -keyout "$KEY" -out "$CERT" -days 3650 -subj "/CN=$sni")
    openssl "${ossl[@]}" -addext "subjectAltName=DNS:$sni" >/dev/null 2>&1 \
      || openssl "${ossl[@]}" >/dev/null 2>&1 \
      || { err "自签证书生成失败"; rm -f "$CERT" "$KEY"; return 1; }
    chmod 600 "$KEY"
    chmod 644 "$CERT"
  fi
}

ask_cert() { # $1=1 显示取消提示；返回 0=成功 1=错误 2=取消
  local sfx=""
  [[ ${1:-0} == 1 ]] && sfx="（0 取消）"
  ask_sni "域名 / SNI$sfx" SNI || return 2
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
    INSECURE=0
    HOST=$SNI
    return 0
  done
}

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
}
rollback() {
  _restore_snapshot "$1"
  [[ -n ${2:-} ]] && err "$2"
}
setf() { jqw --argjson i "$1" --arg k "$2" --arg v "$3" '.[$i][$k]=$v'; }
g() { jq -r --argjson i "$IDX" --arg k "$1" '.[$i][$k] // empty' "$NODES"; }

choose_node() { # 交互选择节点并设置 IDX；取消返回 1
  local n def=""
  n=$(node_count)
  ((n == 1)) && def=1
  echo
  while :; do
    ask_c "节点编号（0 返回）" "$def" || return 1
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      IDX=$((10#$REPLY - 1))
      return 0
    fi
    [[ -n $REPLY ]] && err "编号无效，请输入 1-$n"
  done
}

gen_reality() {
  local out
  out=$("$SB_BIN" generate reality-keypair 2>/dev/null) || { err "生成 Reality 密钥失败"; return 1; }
  RPRIV=$(awk -F': *' '/^PrivateKey:/{print $2; exit}' <<<"$out" | tr -d '[:space:]')
  RPUB=$(awk -F': *' '/^PublicKey:/{print $2; exit}' <<<"$out" | tr -d '[:space:]')
  [[ -n $RPRIV && -n $RPUB ]] || { err "解析 sing-box reality-keypair 输出失败"; return 1; }
  RSID=$(openssl rand -hex 4)
}

gen_uuid() { "$SB_BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }

pick_tuic_cc() { # $1=默认值 $2=提示 -> TUIC_CC；取消返回 2
  printf "  ${C}1${N}  bbr        ${D}推荐${N}\n  ${C}2${N}  cubic\n  ${C}3${N}  new_reno\n"
  while :; do
    ask_c "$2" "$1" || return 2
    case $REPLY in
      1 | bbr) TUIC_CC=bbr; return 0 ;;
      2 | cubic) TUIC_CC=cubic; return 0 ;;
      3 | new_reno) TUIC_CC=new_reno; return 0 ;;
      *) err "仅支持 1 (bbr)、2 (cubic) 或 3 (new_reno)" ;;
    esac
  done
}

pick_hy2_bbr() { # $1=默认值 $2=提示 -> HY2_BBR；取消返回 2
  printf "  ${C}1${N}  standard      ${D}默认${N}\n  ${C}2${N}  conservative  ${D}保守${N}\n  ${C}3${N}  aggressive    ${D}激进${N}\n"
  while :; do
    ask_c "$2" "$1" || return 2
    case $REPLY in
      1 | standard) HY2_BBR=standard; return 0 ;;
      2 | conservative) HY2_BBR=conservative; return 0 ;;
      3 | aggressive) HY2_BBR=aggressive; return 0 ;;
      *) err "仅支持 1 (standard)、2 (conservative) 或 3 (aggressive)" ;;
    esac
  done
}

pick_ss_method() { # $1=1 显示取消提示；设置 SS_M 和 SS_P；取消返回 2
  local prompt="加密方式"
  [[ ${1:-0} == 1 ]] && prompt="加密方式（0 取消）"
  printf "  ${C}1${N}  2022-blake3-aes-128-gcm      ${D}推荐${N}\n"
  printf "  ${C}2${N}  2022-blake3-aes-256-gcm\n"
  printf "  ${C}3${N}  2022-blake3-chacha20-poly1305\n"
  printf "  ${C}4${N}  aes-256-gcm\n"
  printf "  ${C}5${N}  chacha20-ietf-poly1305\n"
  while :; do
    ask_c "$prompt" "1" || return 2
    case $REPLY in
      1) SS_M=2022-blake3-aes-128-gcm; SS_P=$(openssl rand -base64 16); return 0 ;;
      2) SS_M=2022-blake3-aes-256-gcm; SS_P=$(openssl rand -base64 32); return 0 ;;
      3) SS_M=2022-blake3-chacha20-poly1305; SS_P=$(openssl rand -base64 32); return 0 ;;
      4) SS_M=aes-256-gcm; SS_P=$(rnd 16); return 0 ;;
      5) SS_M=chacha20-ietf-poly1305; SS_P=$(rnd 16); return 0 ;;
      *) err "无效选项，请输入 1-5" ;;
    esac
  done
}

# ───────── 添加节点 ─────────
add_socks() {
  ask_port socks || return $?
  ask_c "用户名" "u$(rnd 5)" || return 2
  local u=$REPLY
  ask_c "密码" "$(rnd 12)" || return 2
  local p=$REPLY
  jqw --argjson port "$PORT" --arg u "$u" --arg p "$p" \
    '. + [{type:"socks",tag:("socks-"+($port|tostring)),port:$port,user:$u,pass:$p}]'
}

add_ss() {
  ask_port shadowsocks || return $?
  pick_ss_method || return $?
  jqw --argjson port "$PORT" --arg m "$SS_M" --arg p "$SS_P" \
    '. + [{type:"shadowsocks",tag:("ss-"+($port|tostring)),port:$port,method:$m,password:$p}]'
}

_add_tls_pw() { # $1=type $2=tag前缀
  ask_port "$1" || return $?
  ask_cert || return $?
  ask_c "连接密码" "$(rnd 16)" || return 2
  local p=$REPLY
  jqw --arg t "$1" --arg pfx "$2" --argjson port "$PORT" --arg p "$p" \
    --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:$t,tag:($pfx+"-"+($port|tostring)),port:$port,password:$p,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}
     + (if $t=="hysteria2" then {bbr_profile:"standard"} else {} end)]'
}

add_tuic() {
  ask_port tuic || return $?
  ask_cert || return $?
  pick_tuic_cc "1" "拥塞控制算法" || return 2
  ask_c "连接密码" "$(rnd 16)" || return 2
  local p=$REPLY
  jqw --argjson port "$PORT" --arg uuid "$(gen_uuid)" --arg p "$p" --arg cc "$TUIC_CC" \
    --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"tuic",tag:("tuic-"+($port|tostring)),port:$port,uuid:$uuid,password:$p,cc:$cc,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

add_vless() {
  ask_port vless || return $?
  local sni
  ask_sni "Reality 伪装域名" sni || return $?
  gen_reality || return 1
  jqw --argjson port "$PORT" --arg sni "$sni" --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" --arg uuid "$(gen_uuid)" \
    '. + [{type:"vless",tag:("vless-"+($port|tostring)),port:$port,uuid:$uuid,sni:$sni,priv:$priv,pub:$pub,sid:$sid}]'
}

add_vmess() {
  ask_port vmess || return $?
  ask_cert || return $?
  local path
  ask_path "WebSocket 路径" "/$(rnd 8)" path || return $?
  jqw --argjson port "$PORT" --arg uuid "$(gen_uuid)" --arg path "$path" \
    --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"vmess",tag:("vmess-"+($port|tostring)),port:$port,uuid:$uuid,path:$path,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

menu_add() {
  local c msg="" rc=0 n ptype
  local types=(vless hysteria2 anytls tuic trojan vmess shadowsocks socks)
  while :; do
    title "添加节点"
    printf "  ${C}1${N}  %-13s ${D}%s${N}\n" "VLESS" "Vision + Reality（推荐）"
    printf "  ${C}2${N}  %-13s ${D}%s${N}\n" "Hysteria2" "QUIC + TLS（高速抗丢包）"
    printf "  ${C}3${N}  %-13s ${D}%s${N}\n" "AnyTLS" "TLS 填充防特征（原生支持）"
    printf "  ${C}4${N}  %-13s ${D}%s${N}\n" "TUIC" "TUIC v5 · QUIC + TLS"
    printf "  ${C}5${N}  %-13s ${D}%s${N}\n" "Trojan" "TCP + TLS"
    printf "  ${C}6${N}  %-13s ${D}%s${N}\n" "VMess" "WebSocket + TLS"
    printf "  ${C}7${N}  %-13s ${D}%s${N}\n" "Shadowsocks" "SS 2022 / AEAD"
    printf "  ${C}8${N}  %-13s ${D}%s${N}\n\n" "SOCKS5" "账号密码认证"
    printf "  ${D}0  返回主菜单${N}\n"
    show_toast err "$msg"
    msg=""
    prompt_choice || return
    c=$REPLY
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && return
    [[ $c =~ ^[1-8]$ ]] && break
    msg="无效选项，请输入 1-8"
  done

  ptype=${types[$((c - 1))]}
  title "添加 $(proto_name "$ptype") 节点"
  printf "${D}提示：直接回车采用默认值，任意步骤输入 0 可取消${N}\n\n"

  n=$(node_count)
  snapshot
  case $ptype in
    vless) add_vless || rc=$? ;;
    hysteria2) _add_tls_pw hysteria2 hy2 || rc=$? ;;
    anytls) _add_tls_pw anytls anytls || rc=$? ;;
    tuic) add_tuic || rc=$? ;;
    trojan) _add_tls_pw trojan trojan || rc=$? ;;
    vmess) add_vmess || rc=$? ;;
    shadowsocks) add_ss || rc=$? ;;
    socks) add_socks || rc=$? ;;
  esac
  if ((rc == 2)); then
    PENDING_BAK=""
    return
  elif ((rc != 0)) || (($(node_count) == n)); then
    PENDING_BAK=""
    pause
    return
  fi
  echo
  IDX=$n
  if apply; then
    echo
    show_link "$IDX"
    echo
    note "请在防火墙 / 安全组放行端口 ${B}$(g port)/$(l4_label "$(proto_l4 "$ptype")")${N}"
  else
    rollback "$BAK" "配置未生效，已撤销本次添加"
  fi
  pause
}

# ───────── 节点列表与分享链接 ─────────
list_nodes() {
  (($(node_count) == 0)) && {
    info "暂无节点，可前往主菜单选择「添加节点」"
    return 1
  }
  pad_print "编号" 6 "$D" "$N"
  pad_print "协议" 14 "$D" "$N"
  pad_print "端口" 15 "$D" "$N"
  printf "${D}%s${N}\n%s\n" "配置摘要" "$RULE"
  jq -r 'to_entries[] | [
    (.key+1),
    .value.type,
    .value.port,
    (if .value.type == "shadowsocks" then .value.method
     elif .value.type == "vless" then ("Reality · " + .value.sni)
     elif .value.type == "tuic" then
       ((.value.cc // "bbr") + " · " + (if (.value.insecure // 0) == 1 then "自签 TLS · " else "TLS · " end) + .value.sni)
     elif .value.type == "trojan" or .value.type == "hysteria2" or .value.type == "anytls" then
       ((if (.value.insecure // 0) == 1 then "自签 TLS · " else "TLS · " end) + .value.sni)
     elif .value.type == "vmess" then ("WS+TLS · " + .value.path)
     else ("用户 " + .value.user) end)
  ] | @tsv' "$NODES" \
    | while IFS=$'\t' read -r i t p d; do
      pad_print "$i" 6 "$C" "$N"
      pad_print "$(proto_name "$t")" 14
      pad_print "$p/$(l4_label "$(proto_l4 "$t")")" 15 "$B" "$N"
      printf "${D}%s${N}\n" "$d"
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
      elif $n.type == "anytls" then
        "anytls://\($n.password | e)@\($h):\($n.port)/?sni=\($n.sni | e)&insecure=\($n.insecure // 0)#\($n.tag | e)"
      elif $n.type == "vless" then
        "vless://\($n.uuid | e)@\($h):\($n.port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\($n.sni | e)&fp=chrome&pbk=\($n.pub | e)&sid=\($n.sid | e)&type=tcp#\($n.tag | e)"
      elif $n.type == "hysteria2" then
        "hysteria2://\($n.password | e)@\($h):\($n.port)/?sni=\($n.sni | e)&insecure=\($n.insecure // 0)#\($n.tag | e)"
      elif $n.type == "tuic" then
        "tuic://\($n.uuid | e):\($n.password | e)@\($h):\($n.port)/?sni=\($n.sni | e)&alpn=h3&udp_relay_mode=native&congestion_control=\(($n.cc // "bbr") | e)&allow_insecure=\($n.insecure // 0)#\($n.tag | e)"
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
  local name host ptype port meta
  meta=$(jq -r --argjson i "$IDX" '(.[$i] // {}) | [(.tag // ""), (.host // ""), (.type // ""), (.port // "" | tostring)] | join("\u001f")' "$NODES")
  IFS=$'\x1f' read -r name host ptype port <<<"$meta"
  printf "${C}▸${N} ${B}%s${N}  ${D}%s · %s/%s${N}\n" "$name" "$(proto_name "$ptype")" "$port" "$(l4_label "$(proto_l4 "$ptype")")"
  if [[ -n $host ]]; then
    printf "${G}%s${N}\n" "$(build_link "$host")"
    return
  fi
  detect_ips
  if [[ -n $PUBIP4 && -n $PUBIP6 ]]; then
    printf "${D}IPv4${N}\n${G}%s${N}\n${D}IPv6${N}\n${G}%s${N}\n" "$(build_link "$PUBIP4")" "$(build_link "$PUBIP6")"
  elif [[ -n $PUBIP4 ]]; then
    printf "${G}%s${N}\n" "$(build_link "$PUBIP4")"
  elif [[ -n $PUBIP6 ]]; then
    printf "${G}%s${N}\n" "$(build_link "$PUBIP6")"
  else
    warn "未检测到公网 IP，以下链接中的 YOUR_IP 请手动替换为服务器地址"
    printf "${G}%s${N}\n" "$(build_link "YOUR_IP")"
  fi
}

menu_links() {
  title "分享链接"
  local n i
  n=$(node_count)
  if ((n == 1)); then
    show_link 0
    pause
    return
  fi
  list_nodes || { pause; return; }
  echo
  while :; do
    ask_c "节点编号（a 全部，0 返回）" "a" || return
    if [[ $REPLY =~ ^[Aa]$ ]]; then
      title "分享链接 · 全部节点"
      for ((i = 0; i < n; i++)); do
        show_link "$i"
        ((i < n - 1)) && echo
      done
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
  case $(g type) in
    socks) FIELDS=("port:监听端口" "user:用户名" "pass:密码") ;;
    shadowsocks) FIELDS=("port:监听端口" "method:加密方式" "password:密码") ;;
    trojan | anytls) FIELDS=("port:监听端口" "password:连接密码" "sni:域名 / SNI" "_cert:更换证书") ;;
    hysteria2) FIELDS=("port:监听端口" "password:连接密码" "bbr_profile:BBR 配置" "sni:域名 / SNI" "_cert:更换证书") ;;
    tuic) FIELDS=("port:监听端口" "uuid:UUID" "password:连接密码" "cc:拥塞控制" "sni:域名 / SNI" "_cert:更换证书") ;;
    vless) FIELDS=("port:监听端口" "sni:伪装域名" "uuid:UUID" "sid:ShortID" "_reality:重置 Reality 密钥") ;;
    vmess) FIELDS=("port:监听端口" "uuid:UUID" "path:WebSocket 路径" "sni:域名 / SNI" "_cert:更换证书") ;;
  esac
}

field_val() { # $1=field_key -> 展示值
  [[ $1 == _* ]] && return 0
  local v
  v=$(g "$1")
  if [[ -z $v ]]; then
    case $1 in
      bbr_profile) v=standard ;;
      cc) v=bbr ;;
      *) v="—" ;;
    esac
  fi
  printf '%s' "$v"
}

_ask_match() { # $1=提示 $2=默认 $3=正则 $4=错误提示
  while :; do
    ask_c "$1（0 取消）" "$2" || return 1
    [[ $REPLY == "$2" ]] && return 1
    [[ $REPLY =~ $3 ]] && return 0
    err "$4"
  done
}

edit_field() {
  local k=$1 cur ptype
  EDIT_NOTICE=""
  cur=$(g "$k")
  ptype=$(g type)
  case $k in
    port)
      ask_port "$ptype" "$cur" "$ORIG_PORT" || return 1
      jqw --argjson i "$IDX" --arg t "$(g tag | sed "s/-$cur\$/-$PORT/")" --argjson p "$PORT" '.[$i].tag=$t | .[$i].port=$p'
      EDIT_NOTICE="端口已更新为 $PORT"
      ;;
    method)
      pick_ss_method 1 || return 1
      jqw --argjson i "$IDX" --arg m "$SS_M" --arg p "$SS_P" '.[$i].method=$m | .[$i].password=$p'
      EDIT_NOTICE="加密方式已切换为 $SS_M，密码已同步重新生成"
      ;;
    password)
      local ssm=""
      [[ $ptype == shadowsocks ]] && ssm=$(g method)
      while :; do
        ask_c "新密码（0 取消）" "$cur" || return 1
        [[ $REPLY == "$cur" ]] && return 1
        [[ -n $REPLY ]] || { err "密码不能为空"; continue; }
        if [[ $ssm == 2022-blake3-* ]]; then
          valid_ss2022_psk "$ssm" "$REPLY" || { err "SS 2022 密码须为对应长度（16 或 32 字节）的标准 Base64"; continue; }
        fi
        break
      done
      setf "$IDX" password "$REPLY"
      EDIT_NOTICE="密码已更新"
      ;;
    cc)
      pick_tuic_cc "${cur:-bbr}" "拥塞控制算法（0 取消）" || return 1
      [[ $TUIC_CC == "${cur:-bbr}" ]] && return 1
      setf "$IDX" cc "$TUIC_CC"
      EDIT_NOTICE="拥塞控制算法已切换为 $TUIC_CC"
      ;;
    bbr_profile)
      pick_hy2_bbr "${cur:-standard}" "BBR 配置（0 取消）" || return 1
      [[ $HY2_BBR == "${cur:-standard}" ]] && return 1
      setf "$IDX" bbr_profile "$HY2_BBR"
      EDIT_NOTICE="BBR 配置已切换为 $HY2_BBR"
      ;;
    sni)
      local new_sni insec
      ask_sni "新域名 / SNI（0 取消）" new_sni "$cur" || return 1
      [[ $new_sni == "$cur" ]] && return 1
      insec=$(g insecure)
      if [[ $insec == 1 ]]; then
        gen_self_cert "$new_sni" || { pause; return 1; }
        jqw --argjson i "$IDX" --arg s "$new_sni" --arg c "$CERT" --arg k "$KEY" '.[$i].sni=$s | .[$i].cert=$c | .[$i].key=$k'
        EDIT_NOTICE="SNI 已更新，并已同步生成对应自签证书"
      elif [[ $insec == 0 && -n $(g host) ]]; then
        jqw --argjson i "$IDX" --arg s "$new_sni" '.[$i].sni=$s | .[$i].host=$s'
        EDIT_NOTICE="SNI 与分享域名已同步更新，请确保证书匹配新域名"
      else
        setf "$IDX" sni "$new_sni"
        EDIT_NOTICE="SNI 已更新为 $new_sni"
      fi
      ;;
    path)
      local new_path
      ask_path "新路径（0 取消）" "$cur" new_path || return 1
      [[ $new_path == "$cur" ]] && return 1
      setf "$IDX" path "$new_path"
      EDIT_NOTICE="路径已更新为 $new_path"
      ;;
    uuid)
      _ask_match "新 UUID" "$cur" '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' "UUID 格式无效" || return 1
      setf "$IDX" uuid "$REPLY"
      EDIT_NOTICE="UUID 已更新"
      ;;
    sid)
      _ask_match "新 ShortID（偶数位十六进制，最长 16 位）" "$cur" '^([0-9a-fA-F]{2}){1,8}$' "ShortID 格式无效" || return 1
      setf "$IDX" sid "$REPLY"
      EDIT_NOTICE="ShortID 已更新"
      ;;
    _cert)
      local rc=0
      ask_cert 1 || rc=$?
      ((rc == 0)) || { ((rc != 2)) && pause; return 1; }
      jqw --argjson i "$IDX" --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson in "$INSECURE" \
        '.[$i] += {cert:$c,key:$k,sni:$sni,host:$h,insecure:$in}'
      EDIT_NOTICE="证书配置已更新"
      ;;
    _reality)
      gen_reality || { pause; return 1; }
      jqw --argjson i "$IDX" --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" \
        '.[$i] += {priv:$priv,pub:$pub,sid:$sid}'
      EDIT_NOTICE="已重新生成 Reality 密钥对与 ShortID"
      ;;
    *)
      local lbl="新值"
      [[ $k == pass ]] && lbl="新密码"
      [[ $k == user ]] && lbl="新用户名"
      _ask_match "$lbl" "$cur" '.+' "输入不能为空" || return 1
      setf "$IDX" "$k" "$REPLY"
      EDIT_NOTICE="${lbl#新}已更新"
      ;;
  esac
}

menu_edit() {
  title "编辑节点"
  list_nodes || { pause; return; }
  choose_node || return
  local dirty=0 i f c toast_fn="" toast_msg="" tag_title
  ORIG_PORT=$(g port)
  snapshot
  while :; do
    tag_title="编辑节点 · $(g tag)"
    ((dirty)) && tag_title+=" ${Y}*${N}"
    title "$tag_title"
    node_fields
    i=1
    for f in "${FIELDS[@]}"; do
      printf "  ${C}%-2s${N} " "$i"
      pad_print "${f#*:}" 20
      printf "${D}%s${N}\n" "$(field_val "${f%%:*}")"
      ((i++))
    done
    echo
    if ((dirty)); then
      printf "  ${G}s${N}  保存并应用    ${D}0  放弃修改并返回${N}\n"
    else
      printf "  ${D}0  返回主菜单${N}\n"
    fi
    show_toast "$toast_fn" "$toast_msg"
    toast_fn=""
    toast_msg=""
    prompt_choice || {
      ((dirty)) && rollback "$BAK" "已取消修改" || PENDING_BAK=""
      return
    }
    c=$REPLY
    [[ -z $c ]] && continue
    if [[ $c == 0 ]]; then
      if ((dirty)); then
        confirm "当前有未保存的修改，确认放弃？" || continue
        rollback "$BAK" ""
      else
        PENDING_BAK=""
      fi
      return
    fi
    ((dirty)) && [[ $c =~ ^[Ss]$ ]] && break
    if [[ $c =~ ^[0-9]{1,2}$ ]] && ((10#$c >= 1 && 10#$c <= ${#FIELDS[@]})); then
      echo
      if edit_field "${FIELDS[$((10#$c - 1))]%%:*}"; then
        dirty=1
        toast_fn=note
        toast_msg=$EDIT_NOTICE
      fi
    else
      toast_fn=err
      toast_msg="无效选项，请输入 1-${#FIELDS[@]}"
    fi
  done
  echo
  if apply; then
    echo
    show_link "$IDX"
  else
    rollback "$BAK" "配置校验或启动失败，已回滚全部修改"
  fi
  pause
}

# ───────── 删除节点 / 服务管理 / 日志 / 卸载 ─────────
menu_del() {
  title "删除节点"
  list_nodes || { pause; return; }
  choose_node || return
  local tag
  tag=$(g tag)
  echo
  confirm "确认删除节点 ${B}$tag${N}（$(proto_name "$(g type)") · 端口 $(g port)）？" || return
  snapshot
  jqw --argjson i "$IDX" 'del(.[$i])'
  echo
  if apply; then
    ok "节点 $tag 已删除"
  else
    rollback "$BAK" "配置应用失败，已撤销删除"
  fi
  pause
}

menu_service() {
  local c auto toast_fn="" toast_msg=""
  while :; do
    title "服务管理"
    auto="${D}已关闭${N}"
    svc_ctl is-enabled && auto="${G}已开启${N}"
    printf "  ${C}1${N}  启动 / 重启服务\n"
    printf "  ${C}2${N}  停止服务\n"
    printf "  ${C}3${N}  开机自启  ${D}[${N}%s${D}]${N}\n\n" "$auto"
    printf "  ${D}0  返回主菜单${N}\n"
    show_toast "$toast_fn" "$toast_msg"
    toast_fn=""
    toast_msg=""
    prompt_choice || return
    c=$REPLY
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && return
    case $c in
      1)
        echo
        if apply; then
          if (($(node_count) == 0)); then
            toast_fn=info
            toast_msg="当前无节点，服务已保持停止"
          else
            toast_fn=ok
            toast_msg="服务已重新加载并运行正常"
          fi
        else
          pause
        fi
        ;;
      2)
        svc_ctl stop
        toast_fn=ok
        toast_msg="服务已停止"
        ;;
      3)
        if svc_ctl is-enabled; then
          svc_ctl disable
          toast_fn=ok
          toast_msg="已关闭开机自启"
        else
          svc_ctl enable
          toast_fn=ok
          toast_msg="已开启开机自启"
        fi
        ;;
      *)
        toast_fn=err
        toast_msg="无效选项，请输入 1-3"
        ;;
    esac
  done
}

uninstall() {
  title "${R}彻底卸载${N}"
  local n svc_file="/etc/init.d/sing-box"
  n=$(node_count)
  [[ $OS == debian ]] && svc_file="/etc/systemd/system/sing-box.service"
  warn "此操作将彻底清除 sing-box 及其全部数据，且不可恢复"
  ((n > 0)) && warn "当前仍有 $n 个节点配置，卸载后将一并删除"
  echo
  printf "${D}即将移除以下内容：${N}\n"
  printf "  ${D}·${N} 内核文件  %s\n" "$SB_BIN"
  printf "  ${D}·${N} 快捷命令  /usr/local/bin/sb\n"
  printf "  ${D}·${N} 配置目录  %s（含节点与证书）\n" "$SB_DIR"
  printf "  ${D}·${N} 服务文件  %s\n" "$svc_file"
  [[ $OS == alpine ]] && printf "  ${D}·${N} 运行日志  %s\n" "$SB_LOG"
  echo
  confirm "确认彻底卸载 sing-box？" || return
  echo
  info "正在停止服务并清理文件…"
  svc_ctl stop
  svc_ctl disable
  rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box /etc/logrotate.d/sing-box \
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
    local st="${D}○ 已停止${N}"
    svc_ctl is-active && st="${G}● 运行中${N}"
    [[ -n $SB_VER ]] || SB_VER=$(sb_version)
    printf "${B}sing-box${N}   %s   ${D}v%s · %s 个节点${N}\n" "$st" "${SB_VER:-?}" "$(node_count)"
  else
    printf "${B}sing-box${N}   ${D}未安装${N}\n"
  fi
  printf '%s\n' "$RULE"
}

main_menu() {
  local c msg="" urc
  while :; do
    header
    printf "  "
    pad_print "节点管理" 22 "$D" "$N"
    printf "${D}%s${N}\n" "系统维护"
    printf "  ${C}1${N}  "; pad_print "查看节点" 19; printf "${C}6${N}  服务管理\n"
    printf "  ${C}2${N}  "; pad_print "添加节点" 19; printf "${C}7${N}  运行日志\n"
    printf "  ${C}3${N}  "; pad_print "编辑节点" 19; printf "${C}8${N}  更新内核\n"
    printf "  ${C}4${N}  "; pad_print "删除节点" 19; printf "${R}9${N}  彻底卸载\n"
    printf "  ${C}5${N}  "; pad_print "分享链接" 19; printf "${D}0  退出面板${N}\n"
    show_toast err "$msg"
    msg=""
    prompt_choice || exit 0
    c=$REPLY
    case $c in
      "") continue ;;
      1) title "节点列表"; list_nodes; pause ;;
      2) menu_add ;;
      3) menu_edit ;;
      4) menu_del ;;
      5) menu_links ;;
      6) menu_service ;;
      7) title "运行日志"; svc_logs; pause ;;
      8)
        title "更新内核"
        urc=0
        install_sb || urc=$?
        if ((urc == 0)); then
          echo
          apply
          pause
        elif ((urc == 1)); then
          pause
        fi
        ;;
      9) uninstall ;;
      0) clear; exit 0 ;;
      *) msg="无效选项，请输入 0-9" ;;
    esac
  done
}

# ───────── 入口 ─────────
ensure_deps
if ! sb_installed; then
  header
  info "尚未安装 sing-box"
  echo
  confirm "是否立即下载并安装？" || exit 0
  echo
  install_sb || exit 1
  sleep 0.6
fi
init_dirs
if [[ ! -x /usr/local/bin/sb ]]; then
  if [[ -f $0 && $(readlink -f "$0") != /usr/local/bin/sb ]]; then
    install -m755 "$0" /usr/local/bin/sb 2>/dev/null && {
      note "已创建快捷命令 sb，后续可直接输入 sb 启动面板"
      sleep 0.8
    }
  elif [[ ! -f $0 && -n $SCRIPT_URL ]]; then
    echo
    if confirm "是否安装快捷命令 sb（便于后续一键启动）？"; then
      if curl -fsSL "$SCRIPT_URL" -o "$RUN_TMP/sb.sh" 2>/dev/null && head -n 1 "$RUN_TMP/sb.sh" | grep -q '^#!'; then
        install -m755 "$RUN_TMP/sb.sh" /usr/local/bin/sb 2>/dev/null && ok "快捷命令 sb 已安装"
      else
        err "快捷命令下载失败"
      fi
      sleep 0.8
    fi
  fi
fi
main_menu
