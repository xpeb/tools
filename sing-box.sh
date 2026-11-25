#!/usr/bin/env bash
# sing-box 极简交互式面板（仅支持 Debian / Alpine）
# 协议：SOCKS / Shadowsocks / Hysteria2 / VLESS(Reality) / AnyTLS / Snell(v5/v6)

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

SB_BIN=/usr/local/bin/sing-box
SB_DIR=/etc/sing-box
CONF=$SB_DIR/config.json
NODES=$SB_DIR/nodes.json
CERT_DIR=$SB_DIR/cert
SB_LOG=/var/log/sing-box.log
SCRIPT_URL="https://raw.githubusercontent.com/xpeb/vps-tools/main/sing-box.sh"
MIN_VER=1.14.0
DEFAULT_SNI=www.apache.org

# ───────── UI ─────────
B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
RULE="──────────────────────────────────────────"
line() { printf "  ${D}%s${N}\n" "$RULE"; }
info() { printf "  ${D}[信息]${N} %s\n" "$*"; }
note() { printf "  ${C}[注意]${N} %s\n" "$*"; }
warn() { printf "  ${Y}[警告]${N} %s\n" "$*"; }
ok() { printf "  ${G}[正确]${N} %s\n" "$*"; }
err() { printf "  ${R}[错误]${N} %s\n" "$*"; }
pause() {
  read -rsp $'\n  按回车返回…' _
  echo
}
ask() {
  local v
  read -rp "  $1${2:+ [$2]}: " v
  REPLY="${v:-${2:-}}"
}
confirm() {
  local v
  read -rp "  $1 [y/N]: " v
  [[ $v =~ ^[Yy]$ ]]
}
title() {
  header
  printf "  ${B}%s${N}\n" "$1"
  line
}

RUN_TMP=$(mktemp -d -t sb-panel.XXXXXX)
CONF_TMP="$RUN_TMP/config.json.new"
cleanup() { [[ -n $RUN_TMP ]] && rm -rf "$RUN_TMP"; }
trap cleanup EXIT
trap 'cleanup; echo; exit 130' INT TERM
init_dirs() {
  mkdir -p "$SB_DIR" "$CERT_DIR" && chmod 700 "$SB_DIR" "$CERT_DIR"
  [[ -f $NODES ]] || {
    echo '[]' >"$NODES"
    chmod 600 "$NODES"
  }
}

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
LimitNOFILE=infinity

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
  local out=""
  if [[ $OS == debian ]]; then
    out=$(journalctl -u sing-box -n 40 --no-pager -o cat 2>/dev/null)
  elif [[ -f $SB_LOG ]]; then
    out=$(tail -n 40 "$SB_LOG" 2>/dev/null)
  fi
  if [[ -n $out ]]; then
    printf '%s\n' "$out" | sed 's/^/  /'
  else
    info "暂无日志"
  fi
}

_fetch_ip() { # $1=-4|-6 $2=regex
  local ip u
  for u in https://api${1#-}.ipify.org https://ip.sb https://ifconfig.me; do
    ip=$(curl -s "$1" -m 2 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ $2 ]] && {
      echo "$ip"
      return 0
    }
  done
}

detect_ips() {
  [[ -n ${IP_DETECTED:-} ]] && return
  IP_DETECTED=1
  _fetch_ip -4 '^[0-9.]+$' >"$RUN_TMP/ip4" &
  _fetch_ip -6 '^[0-9a-fA-F:]+:[0-9a-fA-F:]*$' >"$RUN_TMP/ip6" &
  wait
  [[ -s $RUN_TMP/ip4 ]] && PUBIP4=$(<"$RUN_TMP/ip4") || PUBIP4=""
  [[ -s $RUN_TMP/ip6 ]] && PUBIP6=$(<"$RUN_TMP/ip6") || PUBIP6=""
}

sb_installed() { [[ -x $SB_BIN ]]; }
sb_version() { sb_installed && "$SB_BIN" version 2>/dev/null | awk 'NR==1{print $3}'; }
core_ok() {
  local a
  a=$(sb_version)
  a=${a%%-*}
  [[ -n $a && $(printf '%s\n%s\n' "$MIN_VER" "$a" | sort -V | head -1) == "$MIN_VER" ]]
}

install_singbox() {
  local arch ver tmp libc="-glibc"
  case $(uname -m) in
    x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;;
    armv7l) arch=armv7 ;; i386 | i686) arch=386 ;;
    *)
      err "不支持的架构：$(uname -m)"
      return 1
      ;;
  esac
  [[ $OS == alpine ]] && libc="-musl"
  ver=$(curl -fsSL -m 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
  if [[ -z $ver ]]; then
    err "获取最新版本失败"
    confirm "是否改用最低支持版本 $MIN_VER 安装？" || return 1
    ver=$MIN_VER
  elif sb_installed && [[ $(sb_version) == "$ver" ]]; then
    ok "当前已是最新版本 v$ver"
    confirm "是否强制重新安装？" || return 1
  fi
  tmp=$(mktemp -d "$RUN_TMP"/dl.XXXXXX)
  if ! curl -fsSL -o "$tmp/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-linux-$arch$libc.tar.gz" 2>/dev/null \
    || ! tar -xzf "$tmp/sb.tgz" -C "$tmp" 2>/dev/null || ! install -m755 "$tmp"/sing-box-*/sing-box "$SB_BIN" 2>/dev/null; then
    err "下载或安装失败"
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
  ok "sing-box $v 已安装"
}

# ───────── 配置生成（严格遵循 sing-box 官方结构）─────────
gen_config() {
  jq '{
    log: {level: "warn", timestamp: true},
    inbounds: [ .[] |
      if .type == "socks" then
        {type: "socks", tag: .tag, listen: "::", listen_port: .port,
         users: [{username: .user, password: .pass}]}
      elif .type == "shadowsocks" then
        {type: "shadowsocks", tag: .tag, listen: "::", listen_port: .port,
         method: .method, password: .password}
      elif .type == "hysteria2" then
        {type: "hysteria2", tag: .tag, listen: "::", listen_port: .port,
         users: [{name: .tag, password: .password}],
         tls: {enabled: true, server_name: .sni, alpn: ["h3"], certificate_path: .cert, key_path: .key}}
        + (if (.obfs // "") != "" then {obfs: {type: (.obfs_type // "salamander"), password: .obfs}} else {} end)
      elif .type == "vless" then
        {type: "vless", tag: .tag, listen: "::", listen_port: .port,
         users: [{name: .tag, uuid: .uuid, flow: "xtls-rprx-vision"}],
         tls: {enabled: true, server_name: .sni,
               reality: {enabled: true, handshake: {server: .sni, server_port: 443},
                         private_key: .priv, short_id: [.sid]}}}
      elif .type == "anytls" then
        {type: "anytls", tag: .tag, listen: "::", listen_port: .port,
         users: [{name: .tag, password: .password}],
         tls: {enabled: true, server_name: .sni, certificate_path: .cert, key_path: .key}}
      elif .type == "snell" then
        {type: "snell", tag: .tag, listen: "::", listen_port: .port,
         version: .version, psk: .psk}
        + (if .version == 6 then {mode: (.mode // "default")} else {obfs_mode: (.obfs // "none")} end)
      else empty end
    ],
    outbounds: [{type: "direct", tag: "direct"}],
    route: {final: "direct"}
  }' "$NODES" >"$CONF_TMP"
}

apply() {
  gen_config
  local out
  if ! out=$("$SB_BIN" check -c "$CONF_TMP" 2>&1); then
    err "配置校验失败"
    echo "$out" | sed 's/^/    /'
    core_ok || warn "Snell / gecko 需要 sing-box >= $MIN_VER，请先更新内核"
    rm -f "$CONF_TMP"
    return 1
  fi
  if ! { chmod 600 "$CONF_TMP" && mv "$CONF_TMP" "$CONF"; }; then
    err "写入配置失败"
    rm -f "$CONF_TMP"
    return 1
  fi
  if [[ $(jq length "$NODES") -eq 0 ]]; then
    svc_ctl stop
    return 0
  fi
  svc_ctl enable
  svc_ctl restart
  local i
  for i in 1 2 3 4 5 6; do
    sleep 0.5
    svc_ctl is-active && {
      ok "配置已生效"
      return 0
    }
  done
  err "服务启动失败，请查看日志"
  return 1
}

# ───────── 通用辅助 ─────────
rnd() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }
valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_sni() { [[ -n $1 && ! $1 =~ [[:space:]/\\:] ]]; }
valid_ss2022_psk() {
  local need=16 raw
  [[ $1 == 2022-blake3-aes-256-gcm ]] && need=32
  raw=$(printf %s "$2" | base64 -d 2>/dev/null | wc -c)
  ((raw == need))
}
valid_snell_psk() { [[ -n $2 ]] && (($1 != 6 || (${#2} >= 12 && ${#2} <= 255))); }
port_free() {
  ss -lntu 2>/dev/null | awk 'NR>1{print $5}' | grep -qE "[:.]$1$" && return 1
  jq -e --argjson p "$1" 'any(.[]; .port==$p)' "$NODES" >/dev/null 2>&1 && return 1
  return 0
}

ask_port() {
  local def
  while :; do
    def=$((((RANDOM << 15 | RANDOM) % 40001) + 20000))
    port_free "$def" && break
  done
  while :; do
    ask "端口" "$def"
    valid_port "$REPLY" || {
      err "端口无效 (1-65535)"
      continue
    }
    PORT=$((10#$REPLY))
    port_free "$PORT" || {
      err "端口已被占用"
      continue
    }
    break
  done
}

ask_sni() { # $1=提示 $2=变量名（默认 SNI）
  local var=${2:-SNI}
  while :; do
    ask "$1" "$DEFAULT_SNI"
    valid_sni "$REPLY" && {
      printf -v "$var" '%s' "$REPLY"
      return 0
    }
    err "域名 / SNI 格式无效（不能含空格、斜杠或冒号）"
  done
}

ask_cert() {
  ask_sni "域名 / SNI" SNI
  while :; do
    ask "证书路径（留空=自签）" ""
    CERT=$REPLY
    if [[ -z $CERT ]]; then
      CERT=$CERT_DIR/$SNI.crt
      KEY=$CERT_DIR/$SNI.key
      if [[ ! -f $CERT || ! -f $KEY ]]; then
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
      ask "私钥路径" ""
      KEY=$REPLY
      [[ -f $CERT && -f $KEY ]] && {
        INSECURE=0
        HOST=$SNI
        return 0
      }
      err "证书或私钥文件不存在（留空证书路径可改用自签）"
    fi
  done
}

jqw() {
  local t
  t=$(mktemp "$RUN_TMP"/jq.XXXXXX)
  jq "$@" "$NODES" >"$t" && chmod 600 "$t" && mv "$t" "$NODES"
}
snapshot() {
  BAK="$RUN_TMP/nodes.$$.$RANDOM.bak"
  cp "$NODES" "$BAK"
}
rollback() {
  cp "$1" "$NODES"
  chmod 600 "$NODES"
  gen_config 2>/dev/null && chmod 600 "$CONF_TMP" && mv "$CONF_TMP" "$CONF"
  svc_ctl restart
  err "$2"
}
setf() { jqw --argjson i "$1" --arg k "$2" --arg v "$3" '.[$i][$k]=$v'; }
g() { jq -r --argjson i "$IDX" --arg k "$1" '.[$i][$k] // empty' "$NODES"; }

choose_node() { # 交互选择节点并设置 IDX；取消返回 1
  local n def=""
  n=$(jq length "$NODES")
  [[ $n -eq 1 ]] && def=1
  while :; do
    ask "编号（0=返回）" "$def"
    [[ $REPLY == 0 || $REPLY == q ]] && return 1
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      IDX=$((10#$REPLY - 1))
      return 0
    fi
    [[ -n $REPLY ]] && err "编号无效（1-$n）"
  done
}

ensure_core() {
  core_ok && return 0
  warn "$1 需要 sing-box >= $MIN_VER（当前 $(sb_version)）"
  confirm "立即更新内核？" && install_singbox && core_ok
}

# ───────── 添加节点 ─────────
add_socks() {
  ask_port
  ask "用户名" "$(rnd 6)"
  local u=$REPLY
  ask "密码" "$(rnd 12)"
  local p=$REPLY
  jqw --argjson port "$PORT" --arg u "$u" --arg p "$p" \
    '. + [{type:"socks",tag:("socks-"+($port|tostring)),port:$port,user:$u,pass:$p}]'
}

pick_ss_method() {
  printf "   ${C}1${N}  2022-blake3-aes-128-gcm\n   ${C}2${N}  2022-blake3-aes-256-gcm\n"
  printf "   ${C}3${N}  aes-256-gcm\n   ${C}4${N}  chacha20-ietf-poly1305\n"
  ask "加密方式" "1"
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
  ask_port
  pick_ss_method
  jqw --argjson port "$PORT" --arg m "$SS_M" --arg p "$SS_P" \
    '. + [{type:"shadowsocks",tag:("ss-"+($port|tostring)),port:$port,method:$m,password:$p}]'
}

pick_hy2_obfs() { # 设置 OBFS_T
  printf "   ${C}0${N}  不启用\n   ${C}1${N}  salamander\n   ${C}2${N}  gecko  ${D}(需 sing-box>=1.14)${N}\n"
  ask "QUIC 混淆" "0"
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
  ask_port
  ask_cert || return 1
  ask "密码" "$(rnd 16)"
  local p=$REPLY o=""
  pick_hy2_obfs || return 1
  [[ -n $OBFS_T ]] && {
    ask "混淆密码" "$(rnd 16)"
    o=$REPLY
  }
  jqw --argjson port "$PORT" --arg p "$p" --arg o "$o" --arg ot "$OBFS_T" --arg c "$CERT" --arg k "$KEY" \
    --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"hysteria2",tag:("hy2-"+($port|tostring)),port:$port,password:$p,obfs_type:$ot,obfs:$o,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

gen_reality() {
  local out
  out=$("$SB_BIN" generate reality-keypair)
  RPRIV=$(awk '/PrivateKey/{print $2}' <<<"$out")
  RPUB=$(awk '/PublicKey/{print $2}' <<<"$out")
  RSID=$(openssl rand -hex 4)
}

add_vless() {
  ask_port
  local sni
  ask_sni "Reality 伪装域名" sni
  gen_reality
  jqw --argjson port "$PORT" --arg sni "$sni" --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" \
    --arg uuid "$(cat /proc/sys/kernel/random/uuid)" \
    '. + [{type:"vless",tag:("vless-"+($port|tostring)),port:$port,uuid:$uuid,sni:$sni,priv:$priv,pub:$pub,sid:$sid}]'
}

add_anytls() {
  ask_port
  ask_cert || return 1
  ask "密码" "$(rnd 16)"
  local p=$REPLY
  jqw --argjson port "$PORT" --arg p "$p" --arg c "$CERT" --arg k "$KEY" \
    --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"anytls",tag:("anytls-"+($port|tostring)),port:$port,password:$p,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

add_snell() {
  ensure_core "Snell" || return 1
  ask_port
  local v o=none psk oh=""
  while :; do
    ask "版本 5/6" "5"
    [[ $REPLY == 5 || $REPLY == 6 ]] && {
      v=$REPLY
      break
    }
    err "仅支持版本 5 或 6"
  done
  while :; do
    ask "PSK" "$(rnd 20)"
    psk=$REPLY
    valid_snell_psk "$v" "$psk" && break
    [[ $v == 6 ]] && err "v6 的 PSK 须为 12-255 字节" || err "PSK 不能为空"
  done
  if [[ $v == 5 ]]; then
    while :; do
      ask "HTTP 混淆 none/http" "none"
      [[ $REPLY == none || $REPLY == http ]] && {
        o=$REPLY
        break
      }
      err "仅支持 none 或 http"
    done
    [[ $o == http ]] && ask_sni "混淆域名" oh
  fi
  jqw --argjson port "$PORT" --argjson v "$v" --arg p "$psk" --arg o "$o" --arg oh "$oh" \
    '. + [{type:"snell",tag:("snell-"+($port|tostring)),port:$port,version:$v,psk:$p}
     + (if $v==6 then {mode:"default"} elif $o=="http" then {obfs:$o,obfs_host:$oh} else {obfs:$o} end)]'
}

menu_add() {
  local c
  while :; do
    title "添加节点"
    printf "   ${C}1${N}  SOCKS          ${C}4${N}  VLESS (Reality)\n"
    printf "   ${C}2${N}  Shadowsocks    ${C}5${N}  AnyTLS\n"
    printf "   ${C}3${N}  Hysteria2      ${C}6${N}  Snell\n"
    printf "   ${C}0${N}  返回\n"
    line
    read -rp "  > " c || return
    [[ -z $c ]] && continue
    [[ $c == 0 || $c == q ]] && return
    break
  done
  echo
  local n
  n=$(jq length "$NODES")
  snapshot
  case $c in
    1) add_socks ;; 2) add_ss ;; 3) add_hy2 ;; 4) add_vless ;; 5) add_anytls ;; 6) add_snell ;;
    *)
      err "无效选项"
      sleep 0.8
      return
      ;;
  esac
  if [[ $(jq length "$NODES") -eq $n ]]; then
    return
  fi
  IDX=$n
  if apply; then
    echo
    show_link "$IDX"
    note "云服务器请在安全组放行端口 $(g port)"
  else
    rollback "$BAK" "已撤销本次添加"
  fi
  pause
}

# ───────── 列表 / 链接 ─────────
list_nodes() {
  if [[ $(jq length "$NODES") -eq 0 ]]; then
    info "暂无节点"
    return 1
  fi
  printf "  ${D}%-3s %-13s %-7s %s${N}\n" "#" "协议" "端口" "摘要"
  jq -r 'to_entries[] | .key+1 as $i | .value |
    "\($i) \(.type) \(.port) " +
    (if .type=="shadowsocks" then .method
     elif .type=="snell" then "v\(.version)" + (if .version==6 then "/\(.mode)" else (if .obfs=="http" then "/http" else "" end) end)
     elif .type=="hysteria2" then .sni + (if (.obfs//"")!="" then "/\(.obfs_type)" else "" end)
     elif .sni then .sni
     else .user end)' "$NODES" \
    | while read -r i t p m; do printf "  ${C}%-3s${N} %-13s %-7s ${D}%s${N}\n" "$i" "$t" "$p" "$m"; done
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
        + (if ($n.obfs // "") != "" then "&obfs=\(($n.obfs_type // "salamander") | e)&obfs-password=\($n.obfs | e)" else "" end)
        + "#\($n.tag | e)"
      elif $n.type == "vless" then
        "vless://\($n.uuid | e)@\($h):\($n.port)?encryption=none&flow=xtls-rprx-vision&security=reality&sni=\($n.sni | e)&fp=chrome&pbk=\($n.pub | e)&sid=\($n.sid | e)&type=tcp#\($n.tag | e)"
      elif $n.type == "anytls" then
        "anytls://\($n.password | e)@\($h):\($n.port)/?sni=\($n.sni | e)&insecure=\($n.insecure // 0)#\($n.tag | e)"
      elif $n.type == "snell" then
        "\($n.tag) = snell, \($ip), \($n.port), psk=\($n.psk // ""), version=\($n.version // ""), reuse=true, tfo=true"
        + (if ($n.version == 5 and $n.obfs == "http") then ", obfs=http, obfs-host=\($n.obfs_host // $dsn)" else "" end)
      else "" end
  ' "$NODES"
}

show_link() {
  IDX=$1
  local name t host meta
  meta=$(jq -r --argjson i "$IDX" '(.[$i] // {}) | [(.tag // ""), (.type // ""), (.host // "")] | join("\u001f")' "$NODES")
  IFS=$'\x1f' read -r name t host <<<"$meta"
  printf "  ${B}%s${N}" "$name"
  [[ $t == snell ]] && printf "  ${D}(Surge)${N}"
  echo
  if [[ -n $host ]]; then
    printf "  ${G}%s${N}\n\n" "$(build_link "$host")"
    return
  fi
  detect_ips
  if [[ -n $PUBIP4 && -n $PUBIP6 ]]; then
    printf "  ${D}[IPv4]${N} ${G}%s${N}\n" "$(build_link "$PUBIP4")"
    printf "  ${D}[IPv6]${N} ${G}%s${N}\n\n" "$(build_link "$PUBIP6")"
  elif [[ -n $PUBIP4 ]]; then
    printf "  ${G}%s${N}\n\n" "$(build_link "$PUBIP4")"
  elif [[ -n $PUBIP6 ]]; then
    printf "  ${G}%s${N}\n\n" "$(build_link "$PUBIP6")"
  else
    printf "  ${G}%s${N}\n\n" "$(build_link "YOUR_IP")"
  fi
}

menu_links() {
  title "分享链接"
  list_nodes || {
    sleep 1
    return
  }
  local n
  n=$(jq length "$NODES")
  line
  local i
  while :; do
    ask "编号（a=全部，0=返回）" "a"
    [[ -z $REPLY || $REPLY == 0 || $REPLY == q ]] && return
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
  pause
}

# ───────── 修改入站 ─────────
node_fields() {
  case $(g type) in
    socks) FIELDS=("port:端口" "user:用户名" "pass:密码") ;;
    shadowsocks) FIELDS=("port:端口" "method:加密方式" "password:密码") ;;
    hysteria2) FIELDS=("port:端口" "password:密码" "obfs_type:QUIC 混淆" "obfs:混淆密码" "_cert:证书 / SNI") ;;
    vless) FIELDS=("port:端口" "sni:伪装域名" "uuid:UUID" "sid:ShortID" "_reality:重置 Reality 密钥对") ;;
    anytls) FIELDS=("port:端口" "password:密码" "_cert:证书 / SNI") ;;
    snell)
      FIELDS=("port:端口" "psk:PSK" "version:版本")
      if [[ $(g version) == 6 ]]; then
        FIELDS+=("mode:流量整形")
      else
        FIELDS+=("obfs:HTTP 混淆")
        [[ $(g obfs) == http ]] && FIELDS+=("obfs_host:混淆域名")
      fi
      ;;
  esac
}

edit_field() {
  local k=$1 cur np psk
  cur=$(g "$k")
  case $k in
    port)
      while :; do
        ask "新端口（0=取消）" "$cur"
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        valid_port "$REPLY" || {
          err "端口无效 (1-65535)"
          continue
        }
        np=$((10#$REPLY))
        port_free "$np" && break
        err "端口已被占用"
      done
      local tag
      tag=$(g tag | sed "s/-$cur\$/-$np/")
      jqw --argjson i "$IDX" --arg t "$tag" --argjson p "$np" '.[$i].tag=$t | .[$i].port=$p'
      ;;
    method)
      pick_ss_method
      jqw --argjson i "$IDX" --arg m "$SS_M" --arg p "$SS_P" '.[$i].method=$m | .[$i].password=$p'
      note "已按新加密方式重新生成密码"
      sleep 0.8
      ;;
    password)
      while :; do
        ask "新密码（0=取消）" "$cur"
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
        ask "$label（0=取消）" "$def"
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        valid_sni "$REPLY" && break
        err "域名 / SNI 格式无效"
      done
      setf "$IDX" "$k" "$REPLY"
      ;;
    version)
      while :; do
        ask "版本 5/6（0=取消）" "$cur"
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        [[ $REPLY == 5 || $REPLY == 6 ]] && break
        err "仅支持 5 或 6"
      done
      if [[ $REPLY == 6 ]]; then
        psk=$(g psk)
        if ((${#psk} >= 12 && ${#psk} <= 255)); then
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
          ask "HTTP 混淆 none/http（0=取消）" "${cur:-none}"
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
        ask "新混淆密码（-=关闭）" "$cur"
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
      while :; do
        ask "模式 default/unshaped/unsafe-raw（0=取消）" "${cur:-default}"
        [[ $REPLY == 0 || $REPLY == "${cur:-default}" ]] && return 1
        [[ $REPLY == default || $REPLY == unshaped || $REPLY == unsafe-raw ]] && break
        err "模式无效"
      done
      setf "$IDX" mode "$REPLY"
      ;;
    psk)
      while :; do
        ask "新 PSK（0=取消）" "$cur"
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        valid_snell_psk "$(g version)" "$REPLY" && break
        err "PSK 无效（v6 须为 12-255 字节）"
      done
      setf "$IDX" psk "$REPLY"
      ;;
    uuid)
      while :; do
        ask "新 UUID（0=取消）" "$cur"
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        [[ $REPLY =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] && break
        err "UUID 格式无效"
      done
      setf "$IDX" uuid "$REPLY"
      ;;
    sid)
      while :; do
        ask "新 ShortID（偶数位十六进制，最长 16 位，0=取消）" "$cur"
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        [[ $REPLY =~ ^([0-9a-fA-F]{2}){1,8}$ ]] && break
        err "ShortID 格式无效"
      done
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
      gen_reality
      jqw --argjson i "$IDX" --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" \
        '.[$i] += {priv:$priv,pub:$pub,sid:$sid}'
      ok "已生成新的密钥对"
      sleep 0.8
      ;;
    *)
      while :; do
        ask "新值（0=取消）" "$cur"
        [[ $REPLY == 0 || $REPLY == "$cur" ]] && return 1
        [[ -n $REPLY ]] && break
        err "不能为空"
      done
      setf "$IDX" "$k" "$REPLY"
      ;;
  esac
}

menu_edit() {
  title "编辑节点"
  list_nodes || {
    sleep 1
    return
  }
  line
  choose_node || return
  local dirty=0 i f k v
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
      printf "   ${C}%-2s${N} %-14s ${D}%s${N}\n" "$i" "${f#*:}" "$v"
      ((i++))
    done
    printf "   ${C}0${N}  保存并返回\n"
    line
    read -rp "  > " c || break
    [[ -z $c ]] && continue
    [[ $c == 0 || $c == q ]] && break
    if [[ $c =~ ^[0-9]{1,2}$ ]] && ((10#$c >= 1 && 10#$c <= ${#FIELDS[@]})); then
      echo
      edit_field "${FIELDS[$((10#$c - 1))]%%:*}" && dirty=1
    fi
  done
  if [[ $dirty == 1 ]]; then
    echo
    if apply; then
      echo
      show_link "$IDX"
    else
      rollback "$BAK" "配置无效，已回滚修改"
    fi
    pause
  fi
}

# ───────── 删除 / 服务 / 日志 / 卸载 ─────────
menu_del() {
  title "删除节点"
  list_nodes || {
    sleep 1
    return
  }
  line
  choose_node || return
  local port
  port=$(g port)
  confirm "确认删除 $(g type):$port ?" || return
  snapshot
  jqw --argjson i "$IDX" 'del(.[$i])'
  if apply; then
    ok "已删除"
  else
    rollback "$BAK" "配置应用失败，已撤销删除"
  fi
  sleep 0.8
}

menu_service() {
  local c auto
  while :; do
    title "服务管理"
    auto="${D}[已关闭]${N}"
    svc_ctl is-enabled && auto="${G}[已开启]${N}"
    printf "   ${C}1${N}  启动 / 重启\n   ${C}2${N}  停止服务\n   ${C}3${N}  开机自启  %s\n   ${C}0${N}  返回\n" "$auto"
    line
    read -rp "  > " c || return
    [[ -z $c ]] && continue
    [[ $c == 0 || $c == q ]] && return
    case $c in
      1) apply ;;
      2)
        svc_ctl stop
        ok "服务已停止"
        ;;
      3)
        if svc_ctl is-enabled; then
          svc_ctl disable
          ok "已关闭开机自启"
        else
          svc_ctl enable
          ok "已开启开机自启"
        fi
        ;;
      *)
        err "无效选项"
        sleep 0.8
        continue
        ;;
    esac
    sleep 0.8
    return
  done
}

uninstall() {
  title "${R}彻底卸载${N}"
  warn "将删除内核、配置、节点、证书、日志及快捷命令，不可恢复"
  read -rp "  输入 yes 确认卸载: " v
  [[ $v == yes ]] || return
  svc_ctl stop
  svc_ctl disable
  rm -f /etc/systemd/system/sing-box.service /etc/init.d/sing-box \
    "$SB_BIN" /usr/local/bin/sb "$SB_LOG" /run/sing-box.pid
  rm -rf "$SB_DIR"
  [[ -f $0 && $(readlink -f "$0") != /usr/local/bin/sb ]] && rm -f "$0"
  [[ $OS == debian ]] && systemctl daemon-reload
  ok "已彻底卸载并清理全部数据"
  exit 0
}

# ───────── 主界面 ─────────
header() {
  clear
  echo
  if sb_installed; then
    local st n=0 v
    [[ -f $NODES ]] && n=$(jq length "$NODES" 2>/dev/null || echo 0)
    if svc_ctl is-active; then
      st="${G}● 运行中${N}"
    else st="${D}○ 已停止${N}"; fi
    v=$(sb_version)
    printf "  ${B}sing-box${N}  %s  ${D}v%s · %s 节点${N}\n" "$st" "${v:-?}" "$n"
  else
    printf "  ${B}sing-box${N}\n"
  fi
  line
}

main_menu() {
  while :; do
    header
    printf "   ${C}1${N}  节点列表       ${C}6${N}  服务管理\n"
    printf "   ${C}2${N}  添加节点       ${C}7${N}  运行日志\n"
    printf "   ${C}3${N}  编辑节点       ${C}8${N}  更新内核\n"
    printf "   ${C}4${N}  删除节点       ${C}9${N}  彻底卸载\n"
    printf "   ${C}5${N}  分享链接       ${C}0${N}  退出\n"
    line
    read -rp "  > " c || exit 0
    case $c in
      1)
        title "节点列表"
        list_nodes
        pause
        ;;
      2) menu_add ;; 3) menu_edit ;; 4) menu_del ;; 5) menu_links ;;
      6) menu_service ;;
      7)
        title "运行日志"
        svc_logs
        pause
        ;;
      8)
        title "更新内核"
        install_singbox && apply
        sleep 1
        ;;
      9) uninstall ;;
      0 | q)
        clear
        exit 0
        ;;
    esac
  done
}

# ───────── 入口 ─────────
ensure_deps
if ! sb_installed; then
  header
  info "未检测到 sing-box"
  confirm "是否安装？" || exit 0
  install_singbox || exit 1
  sleep 0.8
fi
init_dirs
if [[ -f $0 && $(readlink -f "$0") != /usr/local/bin/sb ]]; then
  install -m755 "$0" /usr/local/bin/sb 2>/dev/null
elif [[ ! -f $0 && ! -x /usr/local/bin/sb && -n $SCRIPT_URL ]]; then
  curl -fsSL "$SCRIPT_URL" -o /usr/local/bin/sb 2>/dev/null && chmod 755 /usr/local/bin/sb
fi
main_menu
