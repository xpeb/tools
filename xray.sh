#!/usr/bin/env bash
# Xray-core 极简交互式面板（仅支持 Debian / Alpine）
# 协议：SOCKS / Shadowsocks / Trojan(TLS) / VLESS(Reality: RAW/XHTTP) / VMess(WS+TLS) / Hysteria2

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

XR_BIN=/usr/local/bin/xray
XR_DIR=/etc/xray
CERT_DIR=/etc/xray/cert
NODES=/etc/xray/nodes.json
CONF=/etc/xray/config.json
XR_LOG=/var/log/xray.log
SCRIPT_URL="https://raw.githubusercontent.com/xpeb/vps-tools/main/xray.sh"
DEFAULT_SNI=www.apache.org

[[ $EUID -eq 0 ]] || {
  echo "请用 root 运行"
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

# ───────── UI ─────────
B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
info() { printf "  ${D}[信息]${N} %s\n" "$*"; }
note() { printf "  ${C}[注意]${N} %s\n" "$*"; }
warn() { printf "  ${Y}[警告]${N} %s\n" "$*"; }
ok() { printf "  ${G}[正确]${N} %s\n" "$*"; }
err() { printf "  ${R}[错误]${N} %s\n" "$*"; }
pause() {
  echo
  read -rsp "  按回车返回…" _
  echo
}
title() {
  header
  printf "  ${C}▸${N} ${B}%s${N}\n\n" "$1"
}

ask() { # $1=提示 $2=默认 -> REPLY
  if [[ -n $2 ]]; then
    read -rp "  $1 [$2]: " REPLY
    REPLY=${REPLY:-$2}
  else
    read -rp "  $1: " REPLY
  fi
}

confirm() {
  read -rp "  $1 [y/N]: " REPLY
  [[ $REPLY =~ ^[Yy]$ ]]
}

RUN_TMP=$(mktemp -d -t xr-panel.XXXXXX)
CONF_TMP="$RUN_TMP/config.json"
cleanup() { [[ -n $RUN_TMP ]] && rm -rf "$RUN_TMP"; }
trap cleanup EXIT
trap 'cleanup; echo; exit 130' INT TERM

# ───────── 基础环境与服务 ─────────
ensure_deps() {
  local pk=() c
  for c in curl jq openssl unzip ss; do
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
    cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
ExecStart=$XR_BIN run -c $CONF
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
  else
    cat >/etc/init.d/xray <<EOF
#!/sbin/openrc-run
name="xray"
command="$XR_BIN"
command_args="run -c $CONF"
command_background=true
pidfile="/run/xray.pid"
output_log="$XR_LOG"
error_log="$XR_LOG"
depend() {
  need net
}
EOF
    chmod 755 /etc/init.d/xray
  fi
}

svc_ctl() { # is-active | is-enabled | enable | disable | restart | stop
  if [[ $OS == debian ]]; then
    case $1 in
      is-active | is-enabled) systemctl "$1" --quiet xray ;;
      *) systemctl "$1" xray >/dev/null 2>&1 ;;
    esac
  else
    case $1 in
      is-active) rc-service xray status >/dev/null 2>&1 ;;
      is-enabled) rc-update show default 2>/dev/null | grep -qw xray ;;
      enable) rc-update add xray default >/dev/null 2>&1 ;;
      disable) rc-update del xray default >/dev/null 2>&1 ;;
      restart)
        rc-service xray stop >/dev/null 2>&1 || true
        rc-service xray start >/dev/null 2>&1
        ;;
      stop) rc-service xray stop >/dev/null 2>&1 ;;
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

xr_installed() { [[ -x $XR_BIN ]]; }
xr_version() { "$XR_BIN" version 2>/dev/null | awk 'NR==1{print $2}'; }
init_dirs() {
  mkdir -p "$XR_DIR" "$CERT_DIR" && chmod 700 "$XR_DIR" "$CERT_DIR"
  [[ -f $NODES ]] || {
    echo '[]' >"$NODES"
    chmod 600 "$NODES"
  }
}

install_xray() {
  local arch ver tmp
  case $(uname -m) in
    x86_64 | amd64) arch=64 ;;
    aarch64 | arm64) arch=arm64-v8a ;;
    armv7l) arch=arm32-v7a ;;
    i386 | i686) arch=32 ;;
    *)
      err "不支持的架构：$(uname -m)"
      return 1
      ;;
  esac
  ver=$(curl -fsSL -m 10 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
  if [[ -z $ver ]]; then
    err "获取最新版本失败"
    return 1
  elif xr_installed && [[ $(xr_version) == "$ver" ]]; then
    ok "当前已是最新版本 v$ver"
    confirm "是否强制重新安装？" || return 1
  fi
  tmp=$(mktemp -d "$RUN_TMP"/dl.XXXXXX)
  if ! curl -fsSL -o "$tmp/xr.zip" "https://github.com/XTLS/Xray-core/releases/download/v$ver/Xray-linux-$arch.zip" 2>/dev/null \
    || ! unzip -qo "$tmp/xr.zip" xray -d "$tmp" 2>/dev/null || ! install -m755 "$tmp/xray" "$XR_BIN" 2>/dev/null; then
    err "下载或安装失败"
    rm -rf "$tmp"
    return 1
  fi
  rm -rf "$tmp"
  init_dirs
  svc_install
  local v
  v=$(xr_version)
  if [[ -z $v ]]; then
    err "安装后无法执行"
    return 1
  fi
  ok "xray $v 已安装"
}

# ───────── 配置生成（严格遵循 Xray-core 官方文档标准）─────────
gen_config() {
  jq '{
    log: {loglevel: "warning"},
    inbounds: map(
      if .type == "socks" then
        {
          tag: .tag, listen: "::", port: .port, protocol: "socks",
          settings: {auth: "password", users: [{user: .user, pass: .pass}], udp: true}
        }
      elif .type == "shadowsocks" then
        {
          tag: .tag, listen: "::", port: .port, protocol: "shadowsocks",
          settings: {network: "tcp,udp", method: .method, password: .password}
        }
      elif .type == "trojan" then
        {
          tag: .tag, listen: "::", port: .port, protocol: "trojan",
          settings: {users: [{password: .password}]},
          streamSettings: {
            network: "raw", security: "tls",
            tlsSettings: {certificates: [{certificateFile: .cert, keyFile: .key}]}
          }
        }
      elif .type == "vless" then
        {
          tag: .tag, listen: "::", port: .port, protocol: "vless",
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
            } + (if (.transport // "raw") == "xhttp" then {xhttpSettings: {path: (.path // "/")}} else {} end)
          )
        }
      elif .type == "vmess" then
        {
          tag: .tag, listen: "::", port: .port, protocol: "vmess",
          settings: {users: [{id: .uuid}]},
          streamSettings: {
            network: "ws",
            wsSettings: {path: .path},
            security: "tls",
            tlsSettings: {certificates: [{certificateFile: .cert, keyFile: .key}]}
          }
        }
      elif .type == "hysteria2" then
        {
          tag: .tag, listen: "::", port: .port, protocol: "hysteria",
          settings: {version: 2, users: [{auth: .password}]},
          streamSettings: {
            network: "hysteria",
            hysteriaSettings: {version: 2, auth: .password},
            security: "tls",
            tlsSettings: {alpn: ["h3"], certificates: [{certificateFile: .cert, keyFile: .key}]}
          }
        }
      else empty end
    ),
    outbounds: [{protocol: "freedom", tag: "direct"}],
    routing: {domainStrategy: "AsIs", rules: []}
  }' "$NODES" >"$CONF_TMP"
}

apply() {
  gen_config
  local out
  if ! out=$("$XR_BIN" run -test -c "$CONF_TMP" 2>&1); then
    err "配置校验失败"
    echo "$out" | sed 's/^/    /'
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
    ok "节点已清空，服务已停止"
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
valid_path() { [[ $1 == /* && ! $1 =~ [[:space:]] ]]; }
valid_ss2022_psk() {
  local need=16 raw
  [[ $1 == 2022-blake3-aes-128-gcm ]] || need=32
  raw=$(printf %s "$2" | base64 -d 2>/dev/null | wc -c)
  ((raw == need))
}

port_free() {
  ! ss -lntu 2>/dev/null | awk 'NR>1{print $5}' | grep -qE "[:.]$1$" \
    && ! jq -e --argjson p "$1" 'any(.[]; .port == $p)' "$NODES" >/dev/null 2>&1
}

ask_port() {
  local def
  while :; do
    def=$((20000 + RANDOM % 30000))
    port_free "$def" && break
  done
  while :; do
    ask "端口" "$def"
    valid_port "$REPLY" || {
      err "端口无效 (1-65535)"
      continue
    }
    PORT=$((10#$REPLY))
    port_free "$PORT" && return 0
    err "端口 $PORT 已被占用"
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

ask_path() { # $1=提示 $2=默认值 $3=变量名
  local var=${3:-WPATH}
  while :; do
    ask "$1" "$2"
    valid_path "$REPLY" && {
      printf -v "$var" '%s' "$REPLY"
      return 0
    }
    err "路径须以 / 开头且不含空格"
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
    [[ $REPLY == 0 ]] && return 1
    if [[ $REPLY =~ ^[0-9]{1,4}$ ]] && ((10#$REPLY >= 1 && 10#$REPLY <= n)); then
      IDX=$((10#$REPLY - 1))
      return 0
    fi
    [[ -n $REPLY ]] && err "编号无效（1-$n）"
  done
}

gen_reality() {
  local out
  out=$("$XR_BIN" x25519)
  RPRIV=$(awk -F': ' '/Private/{print $2}' <<<"$out")
  RPUB=$(awk -F': ' '/PublicKey|Public/{print $2}' <<<"$out")
  RSID=$(openssl rand -hex 4)
}

gen_uuid() { "$XR_BIN" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }

pick_ss_method() { # 设置 SS_M 和 SS_P
  printf "   ${C}1${N}  2022-blake3-aes-128-gcm      ${D}(推荐)${N}\n"
  printf "   ${C}2${N}  2022-blake3-aes-256-gcm\n"
  printf "   ${C}3${N}  2022-blake3-chacha20-poly1305\n"
  printf "   ${C}4${N}  aes-256-gcm\n"
  printf "   ${C}5${N}  chacha20-ietf-poly1305\n"
  ask "加密方式" "1"
  case $REPLY in
    2)
      SS_M=2022-blake3-aes-256-gcm
      SS_P=$(openssl rand -base64 32)
      ;;
    3)
      SS_M=2022-blake3-chacha20-poly1305
      SS_P=$(openssl rand -base64 32)
      ;;
    4)
      SS_M=aes-256-gcm
      SS_P=$(rnd 16)
      ;;
    5)
      SS_M=chacha20-ietf-poly1305
      SS_P=$(rnd 16)
      ;;
    *)
      SS_M=2022-blake3-aes-128-gcm
      SS_P=$(openssl rand -base64 16)
      ;;
  esac
}

# ───────── 添加入站 ─────────
add_socks() {
  ask_port
  ask "用户名" "u$(rnd 5)"
  local u=$REPLY
  ask "密码" "$(rnd 12)"
  local p=$REPLY
  jqw --argjson port "$PORT" --arg u "$u" --arg p "$p" \
    '. + [{type:"socks",tag:("socks-"+($port|tostring)),port:$port,user:$u,pass:$p}]'
}

add_ss() {
  ask_port
  pick_ss_method
  jqw --argjson port "$PORT" --arg m "$SS_M" --arg p "$SS_P" \
    '. + [{type:"shadowsocks",tag:("ss-"+($port|tostring)),port:$port,method:$m,password:$p}]'
}

_add_tls_pw() { # $1=type $2=tag前缀
  ask_port
  ask_cert || return 1
  ask "密码" "$(rnd 16)"
  local p=$REPLY
  jqw --arg t "$1" --arg pfx "$2" --argjson port "$PORT" --arg p "$p" \
    --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:$t,tag:($pfx+"-"+($port|tostring)),port:$port,password:$p,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

add_vless() {
  ask_port
  local tr=raw sni path=""
  printf "   ${C}1${N}  RAW + Reality (Vision)  ${D}(推荐)${N}\n"
  printf "   ${C}2${N}  XHTTP + Reality\n"
  while :; do
    ask "传输方式" "1"
    case $REPLY in
      1 | raw)
        tr=raw
        break
        ;;
      2 | xhttp)
        tr=xhttp
        break
        ;;
      *) err "仅支持 1 (RAW) 或 2 (XHTTP)" ;;
    esac
  done
  ask_sni "Reality 伪装域名" sni
  [[ $tr == xhttp ]] && ask_path "XHTTP 路径" "/$(rnd 8)" path
  gen_reality
  jqw --argjson port "$PORT" --arg tr "$tr" --arg sni "$sni" --arg path "$path" \
    --arg priv "$RPRIV" --arg pub "$RPUB" --arg sid "$RSID" --arg uuid "$(gen_uuid)" \
    '. + [{type:"vless",tag:("vless-"+($port|tostring)),port:$port,transport:$tr,uuid:$uuid,sni:$sni,priv:$priv,pub:$pub,sid:$sid}
     + (if $tr=="xhttp" then {path:$path} else {} end)]'
}

add_vmess() {
  ask_port
  ask_cert || return 1
  local path
  ask_path "WebSocket 路径" "/$(rnd 8)" path
  jqw --argjson port "$PORT" --arg uuid "$(gen_uuid)" --arg path "$path" \
    --arg c "$CERT" --arg k "$KEY" --arg sni "$SNI" --arg h "$HOST" --argjson i "$INSECURE" \
    '. + [{type:"vmess",tag:("vmess-"+($port|tostring)),port:$port,uuid:$uuid,path:$path,cert:$c,key:$k,sni:$sni,host:$h,insecure:$i}]'
}

menu_add() {
  local c
  while :; do
    title "添加节点"
    printf "   ${C}1${N}  VLESS          ${C}2${N}  Hysteria2\n"
    printf "   ${C}3${N}  Trojan         ${C}4${N}  VMess\n"
    printf "   ${C}5${N}  Shadowsocks    ${C}6${N}  SOCKS\n"
    printf "   ${C}0${N}  返回\n\n"
    read -rp "  > " c || return
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && return
    [[ $c =~ ^[1-6]$ ]] && break
    err "无效选项"
    sleep 0.6
  done
  echo
  local n
  n=$(jq length "$NODES")
  snapshot
  case $c in
    1) add_vless ;;
    2) _add_tls_pw hysteria2 hy2 ;;
    3) _add_tls_pw trojan trojan ;;
    4) add_vmess ;;
    5) add_ss ;;
    6) add_socks ;;
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

# ───────── 列表与分享链接 ─────────
list_nodes() {
  local n
  n=$(jq length "$NODES")
  [[ $n -eq 0 ]] && {
    info "暂无节点"
    return 1
  }
  printf "  ${D}%-4s %-15s %-7s %s${N}\n" "编号" "协议" "端口" "摘要"
  jq -r 'to_entries[] | [
    (.key+1),
    .value.type,
    .value.port,
    (if .value.type == "shadowsocks" then .value.method
     elif .value.type == "vless" then
       (if (.value.transport // "raw") == "xhttp" then ("XHTTP · " + (.value.path // "/")) else ("Reality · " + .value.sni) end)
     elif .value.type == "trojan" or .value.type == "hysteria2" then ("TLS · " + .value.sni)
     elif .value.type == "vmess" then ("WS+TLS · " + .value.path)
     else .value.user end)
  ] | @tsv' "$NODES" \
    | while IFS=$'\t' read -r i t p d; do
      printf "  ${C}%-4s${N} %-15s ${B}%-7s${N} ${D}%s${N}\n" "$i" "$t" "$p" "$d"
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
          "vless://\($n.uuid | e)@\($h):\($n.port)?encryption=none&security=reality&sni=\($n.sni | e)&fp=chrome&pbk=\($n.pub | e)&sid=\($n.sid | e)&type=xhttp&path=\(($n.path // "/") | e)&mode=auto#\($n.tag | e)"
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
  local name host meta
  meta=$(jq -r --argjson i "$IDX" '(.[$i] // {}) | [(.tag // ""), (.host // "")] | join("\u001f")' "$NODES")
  IFS=$'\x1f' read -r name host <<<"$meta"
  printf "  ${B}%s${N}\n" "$name"
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
  local n i
  n=$(jq length "$NODES")
  echo
  while :; do
    ask "编号（a=全部，0=返回）" "a"
    [[ $REPLY == 0 ]] && return
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

# ───────── 编辑节点 ─────────
node_fields() {
  case $(g type) in
    socks) FIELDS=("port:端口" "user:用户名" "pass:密码") ;;
    shadowsocks) FIELDS=("port:端口" "method:加密方式" "password:密码") ;;
    trojan | hysteria2) FIELDS=("port:端口" "password:密码" "sni:SNI" "_cert:更换证书") ;;
    vless)
      FIELDS=("port:端口" "transport:传输方式" "sni:伪装域名")
      [[ $(g transport) == xhttp ]] && FIELDS+=("path:XHTTP 路径")
      FIELDS+=("uuid:UUID" "sid:ShortID" "_reality:重置 Reality")
      ;;
    vmess) FIELDS=("port:端口" "uuid:UUID" "path:WS 路径" "sni:SNI" "_cert:更换证书") ;;
  esac
}

_ask_match() { # $1=提示 $2=默认 $3=原值 $4=正则 $5=错误提示
  while :; do
    ask "$1（0=取消）" "$2"
    [[ $REPLY == 0 || $REPLY == "$3" ]] && return 1
    [[ $REPLY =~ $4 ]] && return 0
    err "$5"
  done
}

edit_field() {
  local k=$1 cur np
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
    transport)
      local nt
      printf "   ${C}1${N}  RAW (Vision)\n   ${C}2${N}  XHTTP\n"
      while :; do
        ask "传输方式（0=取消）" "${cur:-raw}"
        [[ $REPLY == 0 ]] && return 1
        case $REPLY in
          1 | raw)
            nt=raw
            break
            ;;
          2 | xhttp)
            nt=xhttp
            break
            ;;
          *) err "仅支持 1 (RAW) 或 2 (XHTTP)" ;;
        esac
      done
      [[ $nt == "${cur:-raw}" ]] && return 1
      if [[ $nt == xhttp ]]; then
        local np_path
        np_path=$(g path)
        [[ -n $np_path ]] || np_path="/$(rnd 8)"
        jqw --argjson i "$IDX" --arg p "$np_path" '.[$i].transport="xhttp" | .[$i].path=$p'
      else
        jqw --argjson i "$IDX" '.[$i].transport="raw" | del(.[$i].path)'
      fi
      ;;
    sni)
      _ask_match "新伪装域名" "$cur" "$cur" '^[^[:space:]/\:]+$' "域名 / SNI 格式无效" || return 1
      setf "$IDX" sni "$REPLY"
      ;;
    path)
      _ask_match "新路径" "$cur" "$cur" '^/[^[:space:]]*$' "路径须以 / 开头且不含空格" || return 1
      setf "$IDX" path "$REPLY"
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
      gen_reality
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
}

menu_edit() {
  title "编辑节点"
  list_nodes || {
    sleep 1
    return
  }
  echo
  choose_node || return
  local dirty=0 i f k v
  snapshot
  while :; do
    title "$(g tag)"
    node_fields
    i=1
    for f in "${FIELDS[@]}"; do
      k=${f%%:*}
      if [[ $k == _* ]]; then
        v=""
      else
        v=$(g "$k")
        [[ -z $v ]] && v="—"
      fi
      printf "   ${C}%-2s${N} %-14s ${D}%s${N}\n" "$i" "${f#*:}" "$v"
      ((i++))
    done
    printf "   ${C}0${N}  保存并返回\n"
    echo
    read -rp "  > " c || break
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && break
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
  echo
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
    echo
    read -rp "  > " c || return
    [[ -z $c ]] && continue
    [[ $c == 0 ]] && return
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
  rm -f /etc/systemd/system/xray.service /etc/init.d/xray \
    "$XR_BIN" /usr/local/bin/xr "$XR_LOG" /run/xray.pid
  rm -rf "$XR_DIR"
  [[ -f $0 && $(readlink -f "$0") != /usr/local/bin/xr ]] && rm -f "$0"
  [[ $OS == debian ]] && systemctl daemon-reload
  ok "已彻底卸载并清理全部数据"
  exit 0
}

# ───────── 主界面 ─────────
header() {
  clear
  echo
  if xr_installed; then
    local st n=0 v
    [[ -f $NODES ]] && n=$(jq length "$NODES" 2>/dev/null || echo 0)
    if svc_ctl is-active; then
      st="${G}● 运行中${N}"
    else st="${D}○ 已停止${N}"; fi
    v=$(xr_version)
    printf "  ${B}xray${N}  %s  ${D}v%s · %s 节点${N}\n" "$st" "${v:-?}" "$n"
  else
    printf "  ${B}xray${N}\n"
  fi
  echo
}

main_menu() {
  while :; do
    header
    printf "   ${C}1${N}  节点列表       ${C}6${N}  服务管理\n"
    printf "   ${C}2${N}  添加节点       ${C}7${N}  运行日志\n"
    printf "   ${C}3${N}  编辑节点       ${C}8${N}  更新内核\n"
    printf "   ${C}4${N}  删除节点       ${C}9${N}  彻底卸载\n"
    printf "   ${C}5${N}  分享链接       ${C}0${N}  退出\n"
    echo
    read -rp "  > " c || exit 0
    case $c in
      1)
        title "节点列表"
        list_nodes
        pause
        ;;
      2) menu_add ;;
      3) menu_edit ;;
      4) menu_del ;;
      5) menu_links ;;
      6) menu_service ;;
      7)
        title "运行日志"
        svc_logs
        pause
        ;;
      8)
        title "更新内核"
        install_xray && apply
        sleep 1
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
ensure_deps
if ! xr_installed; then
  header
  info "未检测到 xray"
  confirm "是否安装？" || exit 0
  install_xray || exit 1
  sleep 0.8
fi
init_dirs
if [[ -f $0 && $(readlink -f "$0") != /usr/local/bin/xr ]]; then
  install -m755 "$0" /usr/local/bin/xr 2>/dev/null
elif [[ ! -f $0 && ! -x /usr/local/bin/xr && -n $SCRIPT_URL ]]; then
  curl -fsSL "$SCRIPT_URL" -o /usr/local/bin/xr 2>/dev/null && chmod 755 /usr/local/bin/xr
fi
main_menu
