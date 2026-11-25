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

trap 'rm -rf "${TMPDIR:-/tmp}"/sb-panel.* "$CONF.new" 2>/dev/null' EXIT INT TERM
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
  if [[ $OS == debian ]]; then
    journalctl -u sing-box -n 40 --no-pager -o cat 2>/dev/null | sed 's/^/  /'
  elif [[ -f $SB_LOG ]]; then
    tail -n 40 "$SB_LOG" | sed 's/^/  /'
  else
    info "暂无日志"
  fi
}

_fetch_ip() { # $1=-4|-6 $2=regex
  local ip u
  for u in https://api${1#-}.ipify.org https://ip.sb https://ifconfig.me; do
    ip=$(curl -s "$1" -m 3 "$u" 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ $2 ]] && {
      echo "$ip"
      return 0
    }
  done
}

detect_ips() {
  [[ -n ${IP_DETECTED:-} ]] && return
  IP_DETECTED=1
  PUBIP4=$(_fetch_ip -4 '^[0-9.]+$')
  PUBIP6=$(_fetch_ip -6 '^[0-9a-fA-F:]+:[0-9a-fA-F:]*$')
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
  local arch ver tmp
  case $(uname -m) in
    x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;;
    armv7l) arch=armv7 ;; i386 | i686) arch=386 ;;
    *)
      err "不支持的架构：$(uname -m)"
      return 1
      ;;
  esac
  ver=$(curl -fsSL -m 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
  if [[ -z $ver ]]; then
    err "获取最新版本失败"
    confirm "是否改用最低支持版本 $MIN_VER 安装？" || return 1
    ver=$MIN_VER
  fi
  tmp=$(mktemp -d -t sb-panel.XXXXXX)
  if ! curl -fsSL -o "$tmp/sb.tgz" "https://github.com/SagerNet/sing-box/releases/download/v$ver/sing-box-$ver-linux-$arch.tar.gz" 2>/dev/null \
    || ! tar -xzf "$tmp/sb.tgz" -C "$tmp" 2>/dev/null || ! install -m755 "$tmp"/sing-box-*/sing-box "$SB_BIN" 2>/dev/null; then
    err "下载或安装失败"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  init_dirs
  svc_install
  ok "sing-box $(sb_version) 已安装"
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
  }' "$NODES" >"$CONF.new"
}

apply() {
  gen_config
  local out
  if ! out=$("$SB_BIN" check -c "$CONF.new" 2>&1); then
    err "配置校验失败"
    echo "$out" | sed 's/^/    /'
    core_ok || warn "Snell / gecko 需要 sing-box >= $MIN_VER，请先更新内核"
    rm -f "$CONF.new"
    return 1
  fi
  chmod 600 "$CONF.new" && mv "$CONF.new" "$CONF"
  if [[ $(jq length "$NODES") -eq 0 ]]; then
    svc_ctl stop
    return 0
  fi
  svc_ctl enable
  svc_ctl restart
  sleep 1
  svc_ctl is-active && ok "配置已生效" || {
    err "服务启动失败，请查看日志"
    return 1
  }
}

# ───────── 通用辅助 ─────────
rnd() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-16}"; }
b64u() { printf %s "$1" | base64 | tr -d '\r\n' | tr '+/' '-_' | tr -d '='; }
uri_enc() { jq -rn --arg v "$1" '$v|@uri'; }
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
  t=$(mktemp -t sb-panel.XXXXXX)
  jq "$@" "$NODES" >"$t" && chmod 600 "$t" && mv "$t" "$NODES"
}
rollback() {
  cp "$1" "$NODES"
  chmod 600 "$NODES"
  err "$2"
}
setf() { jqw --argjson i "$1" --arg k "$2" --arg v "$3" '.[$i][$k]=$v'; }
setn() { jqw --argjson i "$1" --arg k "$2" --argjson v "$3" '.[$i][$k]=$v'; }
delk() { jqw --argjson i "$1" --arg k "$2" 'del(.[$i][$k])'; }
g() { jq -r --argjson i "$IDX" --arg k "$1" '.[$i][$k] // empty' "$NODES"; }

choose_node() { # 交互选择节点并设置 IDX；取消返回 1
  local n def=0
  n=$(jq length "$NODES")
  [[ $n -eq 1 ]] && def=1
  while :; do
    ask "编号（0=返回）" "$def"
    [[ -z $REPLY || $REPLY == 0 || $REPLY == q ]] && return 1
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      IDX=$((10#$REPLY - 1))
      return 0
    fi
    err "编号无效（1-$n）"
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
  local v o=none psk
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
  fi
  jqw --argjson port "$PORT" --argjson v "$v" --arg p "$psk" --arg o "$o" \
    '. + [{type:"snell",tag:("snell-"+($port|tostring)),port:$port,version:$v,psk:$p}
     + (if $v==6 then {mode:"default"} else {obfs:$o} end)]'
}

menu_add() {
  title "添加节点"
  printf "   ${C}1${N}  SOCKS          ${C}4${N}  VLESS (Reality)\n"
  printf "   ${C}2${N}  Shadowsocks    ${C}5${N}  AnyTLS\n"
  printf "   ${C}3${N}  Hysteria2      ${C}6${N}  Snell\n"
  printf "   ${D}0  返回${N}\n"
  line
  read -rp "  > " c
  echo
  [[ -z $c || $c == 0 || $c == q ]] && return
  local n bak
  n=$(jq length "$NODES")
  bak=$(mktemp -t sb-panel.XXXXXX)
  cp "$NODES" "$bak"
  case $c in
    1) add_socks ;; 2) add_ss ;; 3) add_hy2 ;; 4) add_vless ;; 5) add_anytls ;; 6) add_snell ;;
    *)
      err "无效选项"
      rm -f "$bak"
      pause
      return
      ;;
  esac
  if [[ $(jq length "$NODES") -eq $n ]]; then
    rm -f "$bak"
    pause
    return
  fi
  IDX=$n
  if apply; then
    echo
    show_link "$IDX"
    note "云服务器请在安全组放行端口 $(g port)"
  else
    rollback "$bak" "已撤销本次添加"
  fi
  rm -f "$bak"
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

build_link() { # $1=raw_ip
  local raw_ip=$1 ip=$1 ot ver
  [[ $ip == *:* ]] && ip="[$ip]"
  case $t in
    socks)
      echo "socks5://$(uri_enc "$(g user)"):$(uri_enc "$(g pass)")@$ip:$port#$(uri_enc "$name")"
      ;;
    shadowsocks)
      echo "ss://$(b64u "$(g method):$(g password)")@$ip:$port#$(uri_enc "$name")"
      ;;
    hysteria2)
      ot=$(g obfs_type)
      local l="hysteria2://$(uri_enc "$(g password)")@$ip:$port/?sni=$(uri_enc "$(g sni)")&insecure=$(g insecure)"
      [[ -n $(g obfs) ]] && l+="&obfs=$(uri_enc "${ot:-salamander}")&obfs-password=$(uri_enc "$(g obfs)")"
      echo "$l#$(uri_enc "$name")"
      ;;
    vless)
      echo "vless://$(uri_enc "$(g uuid)")@$ip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(uri_enc "$(g sni)")&fp=chrome&pbk=$(uri_enc "$(g pub)")&sid=$(uri_enc "$(g sid)")&type=tcp#$(uri_enc "$name")"
      ;;
    anytls)
      echo "anytls://$(uri_enc "$(g password)")@$ip:$port/?sni=$(uri_enc "$(g sni)")&insecure=$(g insecure)#$(uri_enc "$name")"
      ;;
    snell)
      ver=$(g version)
      local l="$name = snell, $raw_ip, $port, psk=$(g psk), version=$ver, reuse=true, tfo=true"
      [[ $ver == 5 && $(g obfs) == http ]] && l+=", obfs=http, obfs-host=$DEFAULT_SNI"
      echo "$l"
      ;;
  esac
}

show_link() {
  IDX=$1
  local t port host name
  t=$(g type)
  port=$(g port)
  name=$(g tag)
  host=$(g host)
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
    pause
    return
  }
  local n
  n=$(jq length "$NODES")
  line
  while :; do
    ask "编号（a=全部，0=返回）" "a"
    [[ $REPLY == 0 || $REPLY == q ]] && return
    if [[ $REPLY == a ]]; then
      echo
      local i
      for ((i = 0; i < n; i++)); do show_link "$i"; done
      break
    elif [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      echo
      show_link "$((10#$REPLY - 1))"
      break
    else
      err "编号无效（1-$n 或 a）"
    fi
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
      [[ $(g version) == 6 ]] && FIELDS+=("mode:流量整形") || FIELDS+=("obfs:HTTP 混淆")
      ;;
  esac
}

edit_field() {
  local k=$1 cur np psk
  cur=$(g "$k")
  case $k in
    port)
      ask "新端口" "$cur"
      valid_port "$REPLY" || {
        err "端口无效 (1-65535)"
        return 1
      }
      np=$((10#$REPLY))
      [[ $np == "$cur" ]] && return 1
      port_free "$np" || {
        err "端口已被占用"
        return 1
      }
      setf "$IDX" tag "$(g tag | sed "s/-$cur\$/-$np/")"
      setn "$IDX" port "$np"
      ;;
    method)
      pick_ss_method
      setf "$IDX" method "$SS_M"
      setf "$IDX" password "$SS_P"
      note "已按新加密方式重新生成密码"
      ;;
    password)
      ask "新密码" "$cur"
      [[ -n $REPLY ]] || {
        err "不能为空"
        return 1
      }
      if [[ $(g type) == shadowsocks && $(g method) == 2022-blake3-* ]]; then
        valid_ss2022_psk "$(g method)" "$REPLY" || {
          err "SS 2022 密码须为对应长度（16/32 字节）的 Base64"
          return 1
        }
      fi
      setf "$IDX" password "$REPLY"
      ;;
    sni)
      ask "新伪装域名" "$cur"
      valid_sni "$REPLY" || {
        err "域名 / SNI 格式无效"
        return 1
      }
      setf "$IDX" sni "$REPLY"
      ;;
    version)
      ask "版本 5/6" "$cur"
      [[ $REPLY == 5 || $REPLY == 6 ]] || {
        err "仅支持 5 或 6"
        return 1
      }
      [[ $REPLY == "$cur" ]] && return 1
      setn "$IDX" version "$REPLY"
      if [[ $REPLY == 6 ]]; then
        setf "$IDX" mode default
        delk "$IDX" obfs
        psk=$(g psk)
        ((${#psk} >= 12 && ${#psk} <= 255)) || {
          setf "$IDX" psk "$(rnd 20)"
          note "v6 要求 PSK 12-255 字节，已重新生成"
        }
      else
        setf "$IDX" obfs none
        delk "$IDX" mode
      fi
      ;;
    obfs)
      if [[ $(g type) == snell ]]; then
        ask "HTTP 混淆 none/http" "${cur:-none}"
        [[ $REPLY == none || $REPLY == http ]] || {
          err "仅支持 none 或 http"
          return 1
        }
        setf "$IDX" obfs "$REPLY"
      else
        ask "新混淆密码（-=关闭）" "$cur"
        [[ $REPLY == "-" ]] && REPLY=""
        setf "$IDX" obfs "$REPLY"
        if [[ -z $REPLY ]]; then
          setf "$IDX" obfs_type ""
        elif [[ -z $(g obfs_type) ]]; then setf "$IDX" obfs_type salamander; fi
      fi
      ;;
    obfs_type)
      pick_hy2_obfs || return 1
      if [[ -n $OBFS_T ]]; then
        local op
        op=$(g obfs)
        [[ -n $op ]] || {
          op=$(rnd 16)
          note "已生成混淆密码"
        }
        jqw --argjson i "$IDX" --arg ot "$OBFS_T" --arg op "$op" '.[$i] += {obfs_type:$ot,obfs:$op}'
      else
        jqw --argjson i "$IDX" '.[$i] += {obfs_type:"",obfs:""}'
      fi
      ;;
    mode)
      ask "模式 default/unshaped/unsafe-raw" "${cur:-default}"
      [[ $REPLY == default || $REPLY == unshaped || $REPLY == unsafe-raw ]] || {
        err "模式无效"
        return 1
      }
      setf "$IDX" mode "$REPLY"
      ;;
    psk)
      ask "新 PSK" "$cur"
      valid_snell_psk "$(g version)" "$REPLY" || {
        err "PSK 无效（v6 须为 12-255 字节）"
        return 1
      }
      setf "$IDX" psk "$REPLY"
      ;;
    uuid)
      ask "新 UUID" "$cur"
      [[ $REPLY =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]] || {
        err "UUID 格式无效"
        return 1
      }
      setf "$IDX" uuid "$REPLY"
      ;;
    sid)
      ask "新 ShortID（偶数位十六进制，最长 16 位）" "$cur"
      [[ $REPLY =~ ^([0-9a-fA-F]{2}){1,8}$ ]] || {
        err "ShortID 格式无效"
        return 1
      }
      setf "$IDX" sid "$REPLY"
      ;;
    _cert)
      ask_cert || return 1
      jqw --argjson i "$IDX" --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson in "$INSECURE" \
        '.[$i] += {cert:$c,key:$k,sni:$sni,host:$h,insecure:$in}'
      ;;
    _reality)
      gen_reality
      jqw --argjson i "$IDX" --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" \
        '.[$i] += {priv:$priv,pub:$pub,sid:$sid}'
      ok "已生成新的密钥对"
      ;;
    *)
      ask "新值" "$cur"
      [[ -n $REPLY ]] || {
        err "不能为空"
        return 1
      }
      setf "$IDX" "$k" "$REPLY"
      ;;
  esac
}

menu_edit() {
  title "编辑节点"
  list_nodes || {
    pause
    return
  }
  line
  choose_node || return
  local dirty=0 bak i f k v
  bak=$(mktemp -t sb-panel.XXXXXX)
  cp "$NODES" "$bak"
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
    printf "   ${D}0  保存并返回${N}\n"
    line
    read -rp "  > " c
    [[ -z $c || $c == 0 || $c == q ]] && break
    if [[ $c =~ ^[0-9]{1,2}$ ]] && ((10#$c >= 1 && 10#$c <= ${#FIELDS[@]})); then
      echo
      if edit_field "${FIELDS[$((10#$c - 1))]%%:*}"; then
        dirty=1
      else pause; fi
    fi
  done
  if [[ $dirty == 1 ]]; then
    echo
    if apply; then
      echo
      show_link "$IDX"
    else
      rollback "$bak" "配置无效，已回滚修改"
    fi
    pause
  fi
  rm -f "$bak"
}

# ───────── 删除 / 服务 / 日志 / 卸载 ─────────
menu_del() {
  title "删除节点"
  list_nodes || {
    pause
    return
  }
  line
  choose_node || return
  local port bak
  port=$(g port)
  confirm "确认删除 $(g type):$port ?" || return
  bak=$(mktemp -t sb-panel.XXXXXX)
  cp "$NODES" "$bak"
  jqw --argjson i "$IDX" 'del(.[$i])'
  if apply; then
    ok "已删除"
  else
    rollback "$bak" "配置应用失败，已撤销删除"
  fi
  rm -f "$bak"
  pause
}

menu_service() {
  title "服务管理"
  printf "   ${C}1${N}  启动 / 重启\n   ${C}2${N}  停止服务\n   ${C}3${N}  开机自启 切换\n   ${D}0  返回${N}\n"
  line
  read -rp "  > " c
  [[ -z $c || $c == 0 || $c == q ]] && return
  case $c in
    1) apply ;;
    2)
      svc_ctl stop
      ok "服务已停止"
      ;;
    3) if svc_ctl is-enabled; then
      svc_ctl disable
      ok "已关闭开机自启"
    else
      svc_ctl enable
      ok "已开启开机自启"
    fi ;;
    *) return ;;
  esac
  pause
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
    local st n=0
    [[ -f $NODES ]] && n=$(jq length "$NODES" 2>/dev/null || echo 0)
    if svc_ctl is-active; then
      st="${G}● 运行中${N}"
    else st="${D}○ 已停止${N}"; fi
    printf "  ${B}sing-box${N}  %s  ${D}v%s · %s 节点${N}\n" "$st" "$(sb_version)" "$n"
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
    printf "   ${C}5${N}  分享链接       ${D}0  退出${N}\n"
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
        pause
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
  pause
fi
init_dirs
if [[ -f $0 && $(readlink -f "$0") != /usr/local/bin/sb ]]; then
  install -m755 "$0" /usr/local/bin/sb 2>/dev/null
elif [[ ! -f $0 && ! -x /usr/local/bin/sb && -n $SCRIPT_URL ]]; then
  curl -fsSL "$SCRIPT_URL" -o /usr/local/bin/sb 2>/dev/null && chmod 755 /usr/local/bin/sb
fi
main_menu
