#!/usr/bin/env sh
# shellcheck shell=bash
# CLIProxyAPI 现代交互式运维面板 (Debian / Ubuntu systemd · Alpine OpenRC)
# 安全策略: 强制绑定 127.0.0.1:8317，禁止公网直连，支持域名反代与客户端 API Key 鉴权

if [ -z "${BASH_VERSION:-}" ]; then
  if [ ! -t 0 ] && [ ! -f "$0" ]; then
    echo "[错误] 请勿通过管道直接执行，请使用 bash <(curl -fsSL ...) 运行" >&2
    exit 1
  fi
  if [ -f /etc/alpine-release ] && ! command -v bash >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
    apk add --no-cache bash >/dev/null 2>&1
  fi
  if [ -f "$0" ] && command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  echo "[错误] 请先安装 bash 并使用 bash 运行此脚本！" >&2
  exit 1
fi

# 补齐 su 切换 root 后可能缺失的 sbin 路径
for _p in /usr/local/sbin /usr/sbin /sbin /usr/local/bin /usr/bin /bin; do
  case ":${PATH:-}:" in
    *":${_p}:"*) ;;
    *) PATH="${PATH:+${PATH}:}${_p}" ;;
  esac
done
unset _p
export PATH

SCRIPT_URL="https://raw.githubusercontent.com/xpeb/vps-tools/main/cliproxyapi.sh"
SCRIPT_LINK="/usr/local/bin/cpapi"

WORK_DIR="/root/cliproxyapi"
AUTH_DIR="${WORK_DIR}/auth"
BIN_PATH="${WORK_DIR}/cli-proxy-api"
CONFIG_PATH="${WORK_DIR}/config.yaml"
DOMAIN_FILE="${WORK_DIR}/.domain"
VERSION_FILE="${WORK_DIR}/.version"
BACKUP_DIR="${WORK_DIR}/backup"
LOG_FILE="/var/log/cliproxy.log"
OFFICIAL_REPO="router-for-me/CLIProxyAPI"

LOCKED_HOST="127.0.0.1"
LOCKED_PORT="8317"
LISTEN_ADDR="${LOCKED_HOST}:${LOCKED_PORT}"

LOCK_DIR="/run/cpapi-panel.lock"
[[ -d /run ]] || LOCK_DIR="${TMPDIR:-/tmp}/cpapi-panel.lock"
LOCK_OWNED=0
RUN_TMP=""
LOCAL_VER=""
LAST_BIN_BACKUP=""
LAST_CFG_BACKUP=""
OS_TYPE=""
OS_ID=""
OS_NAME=""
OS_SHORT=""
SERVICE_PATH=""
IS_MUSL=0

# ───────── 界面样式与交互引擎 ─────────
B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
RL_B=$'\001\e[1m\002' RL_D=$'\001\e[2m\002' RL_N=$'\001\e[0m\002'
_UTF8_CHAR="中"
UI_W=60
RULE=""

info() { printf "  ${D}·${N} %s\n" "$*"; }
note() { printf "  ${C}i${N} %s\n" "$*"; }
warn() { printf "  ${Y}!${N} %s\n" "$*"; }
ok() { printf "  ${G}✓${N} %s\n" "$*"; }
err() { printf "  ${R}✗${N} %s\n" "$*" >&2; }
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
  [[ $cols =~ ^[0-9]+$ ]] || cols=${COLUMNS:-60}
  ((cols < 56)) && cols=56
  ((cols > 72)) && cols=72
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
      if [[ -z $seq ]]; then
        REPLY="ESC"
        return 0
      fi
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
  [[ -z $k ]] && {
    REPLY="ENTER"
    return 0
  }
  REPLY=$k
}

prompt_key() {
  echo
  printf "  ${C}›${N} "
  read_key || return 1
  echo
}

pause() {
  echo
  printf "  ${D}按任意键继续…${N}"
  read_key >/dev/null 2>&1 || true
  echo
}

ask() { # $1=提示 [$2=默认值] -> REPLY；EOF 返回 1
  local p
  if [[ -n ${2:-} ]]; then
    p="  ${RL_B}$1${RL_N} ${RL_D}[$2]${RL_N}: "
    read -erp "$p" REPLY || return 1
    REPLY=${REPLY:-$2}
  else
    p="  ${RL_B}$1${RL_N}: "
    read -erp "$p" REPLY || return 1
  fi
}

ask_c() { ask "$@" && [[ $REPLY != 0 ]] || return 2; } # 0 / EOF 取消返回 2

confirm() { # $1=提示；默认 N，支持单键 y/n/Enter/Esc
  printf "  ${Y}?${N} %s ${D}[y/N]${N}: " "$1"
  local rc=0
  read_key || rc=$?
  echo
  ((rc == 0)) && [[ $REPLY =~ ^[Yy]$ ]]
}

confirm_y() { # $1=提示；默认 Y，支持单键 y/Enter/n/Esc
  printf "  ${Y}?${N} %s ${D}[Y/n]${N}: " "$1"
  local rc=0
  read_key || rc=$?
  echo
  ((rc == 0)) && [[ $REPLY != [Nn] && $REPLY != "ESC" ]]
}

# ───────── 运行时环境、并发锁与信号清理 ─────────
normalize_gh_proxy() {
  local p="${1:-${GH_PROXY:-}}"
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  if [[ -n $p ]]; then
    [[ $p =~ ^https?:// ]] || p="https://${p}"
    p="${p%/}/"
  fi
  printf '%s' "$p"
}

cleanup_runtime() {
  trap - EXIT INT TERM HUP
  [[ -t 0 ]] && stty echo 2>/dev/null || true
  [[ -n ${RUN_TMP:-} && -d $RUN_TMP ]] && rm -rf -- "$RUN_TMP"
  RUN_TMP=""
  rm -f "${CONFIG_PATH}.tmp."* 2>/dev/null || true
  if ((LOCK_OWNED == 1)) && [[ -n ${LOCK_DIR:-} ]]; then
    rm -rf -- "$LOCK_DIR" 2>/dev/null || true
    LOCK_OWNED=0
  fi
}

on_signal() {
  local sig="$1"
  cleanup_runtime
  echo >&2
  case "$sig" in
    INT) exit 130 ;;
    TERM) exit 143 ;;
    HUP) exit 129 ;;
    *) exit 1 ;;
  esac
}

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
  err "检测到另一个 CLIProxyAPI 面板实例正在运行${old_pid:+（PID: $old_pid）}，请勿并发操作"
  exit 1
}

init_runtime() {
  set -o pipefail
  GH_PROXY=$(normalize_gh_proxy "${GH_PROXY:-}")
  RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cpapi-panel.XXXXXX") || {
    err "无法创建临时工作目录！"
    exit 1
  }
  trap cleanup_runtime EXIT
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP' HUP
}

check_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || {
    err "请使用 root 用户运行此脚本！"
    exit 1
  }
}

check_os() {
  [[ -f /etc/os-release ]] || {
    err "无法识别操作系统（缺少 /etc/os-release）！"
    exit 1
  }
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID,,}"
  local os_like="${ID_LIKE,,}"
  OS_NAME="${PRETTY_NAME:-$OS_ID}"
  OS_SHORT="${NAME:-$OS_ID} ${VERSION_ID:-}"
  OS_SHORT="${OS_SHORT% }"

  if [[ $OS_ID == debian || $OS_ID == ubuntu || " $os_like " == *" debian "* || " $os_like " == *" ubuntu "* ]] \
    && command -v apt-get >/dev/null 2>&1; then
    if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
      err "检测到 ${OS_NAME}，但当前环境未运行 systemd (PID 1)，无法托管后台服务！"
      exit 1
    fi
    OS_TYPE="debian"
    SERVICE_PATH="/etc/systemd/system/cliproxy.service"
  elif [[ $OS_ID == alpine || " $os_like " == *" alpine "* ]] \
    && command -v apk >/dev/null 2>&1; then
    if ! command -v rc-service >/dev/null 2>&1; then
      err "检测到 Alpine 系统，但缺少 OpenRC (rc-service)，无法托管后台服务！"
      exit 1
    fi
    OS_TYPE="alpine"
    SERVICE_PATH="/etc/init.d/cliproxy"
    [[ -d /run/openrc ]] || warn "未检测到 /run/openrc，容器环境可能无法启动 OpenRC 服务"
  else
    err "不支持当前系统 (${OS_NAME})，仅支持 Debian / Ubuntu (systemd) 与 Alpine (OpenRC)！"
    exit 1
  fi

  if [[ $OS_TYPE == alpine ]] || ldd --version 2>&1 | grep -qi musl; then
    IS_MUSL=1
  else
    IS_MUSL=0
  fi
}

ensure_deps() {
  local pkgs=() c log="${RUN_TMP}/deps.log"
  for c in curl jq openssl tar awk ss; do
    command -v "$c" >/dev/null 2>&1 && continue
    case "$c" in
      ss) pkgs+=(iproute2) ;;
      awk) [[ $OS_TYPE == debian ]] && pkgs+=(mawk) || pkgs+=(gawk) ;;
      *) pkgs+=("$c") ;;
    esac
  done
  [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/ssl/cert.pem ]] || pkgs+=(ca-certificates)
  [[ ${#pkgs[@]} -eq 0 ]] && return 0

  info "正在安装必要依赖：${pkgs[*]}…"
  if [[ $OS_TYPE == alpine ]]; then
    apk add --no-cache "${pkgs[@]}" >"$log" 2>&1
  else
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >"$log" 2>&1 \
      && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${pkgs[@]}" >>"$log" 2>&1
  fi || {
    err "依赖安装失败，请检查软件源或网络连接！"
    tail -n 20 "$log" 2>/dev/null || true
    return 1
  }
}

setup_shortcut() {
  local self=""
  self=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")
  if [[ $self == /* && -f $self && ! $self =~ ^/(dev|proc)/ ]]; then
    if [[ $self != "$SCRIPT_LINK" ]]; then
      if [[ ! -x $SCRIPT_LINK ]] || ! cmp -s "$self" "$SCRIPT_LINK" 2>/dev/null; then
        local existed=0
        [[ -x $SCRIPT_LINK ]] && existed=1
        mkdir -p /usr/local/bin
        if install -m 755 "$self" "$SCRIPT_LINK" 2>/dev/null; then
          ((existed)) && note "已同步更新快捷命令 cpapi" || note "已创建快捷命令 cpapi，后续可直接输入 cpapi 打开面板"
          sleep_frac 0.7
        fi
      fi
    fi
  elif [[ ! -x $SCRIPT_LINK && -n ${SCRIPT_URL:-} ]]; then
    echo
    if confirm_y "是否安装快捷命令 cpapi（便于后续一键启动）？"; then
      local dl_ok=0 u
      for u in "${GH_PROXY}${SCRIPT_URL}" "$SCRIPT_URL"; do
        [[ -n $u ]] || continue
        if curl -fsSL --connect-timeout 6 --max-time 20 "$u" -o "$RUN_TMP/cpapi.sh" 2>/dev/null \
          && head -n 1 "$RUN_TMP/cpapi.sh" | grep -q '^#!' \
          && grep -q 'CLIProxyAPI' "$RUN_TMP/cpapi.sh"; then
          dl_ok=1
          break
        fi
      done
      if ((dl_ok == 1)); then
        mkdir -p /usr/local/bin
        if install -m 755 "$RUN_TMP/cpapi.sh" "$SCRIPT_LINK" 2>/dev/null; then
          ok "快捷命令 cpapi 已安装，后续可直接输入 cpapi 启动"
        else
          warn "写入 ${SCRIPT_LINK} 失败"
        fi
      else
        warn "快捷命令下载失败，可稍后手动保存脚本"
      fi
      sleep_frac 0.7
    fi
  fi
}

ensure_work_dirs() {
  mkdir -p "$WORK_DIR" "$AUTH_DIR" && chmod 700 "$WORK_DIR" "$AUTH_DIR"
}

# ───────── 工具与 YAML 安全引擎 ─────────
gen_random_secret() { # [$1=字节数，默认16 -> 32 hex]
  local bytes="${1:-16}" val=""
  if command -v openssl >/dev/null 2>&1; then
    val=$(openssl rand -hex "$bytes" 2>/dev/null || true)
  fi
  if [[ -z $val ]]; then
    val=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c $((bytes * 2)) || true)
  fi
  [[ -n $val ]] || val="cpa_$(date +%s)_$$"
  printf '%s' "$val"
}

gen_api_key() {
  printf 'sk-cpa-%s' "$(gen_random_secret 16)"
}

mask_secret() {
  local s="${1:-}" len
  len=${#s}
  if ((len <= 8)); then
    printf '%s****' "${s:0:2}"
  else
    printf '%s****%s' "${s:0:6}" "${s: -4}"
  fi
}

yaml_escape_dq() {
  local s="${1//$'\r'/}"
  s="${s//$'\n'/}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

parse_yaml_val() { # $1=key [$2=父级section] [$3=文件路径]
  local key="$1" sec="${2:-}" file="${3:-$CONFIG_PATH}"
  [[ -f $file ]] || return 0
  awk -v k="$key" -v sec="$sec" '
    function unquote(val,    q, rest, out, i, c, esc) {
      sub(/^[[:space:]]+/, "", val)
      q = substr(val, 1, 1)
      if (q == "\"") {
        rest = substr(val, 2)
        out = ""; esc = 0
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (esc) {
            if (c == "n") out = out "\n"
            else if (c == "t") out = out "\t"
            else out = out c
            esc = 0
          } else if (c == "\\") {
            esc = 1
          } else if (c == "\"") {
            break
          } else {
            out = out c
          }
        }
        return out
      } else if (q == "'"'"'") {
        rest = substr(val, 2)
        out = ""
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (c == "'"'"'") {
            if (substr(rest, i + 1, 1) == "'"'"'") {
              out = out "'"'"'"
              i++
            } else {
              break
            }
          } else {
            out = out c
          }
        }
        return out
      }
      sub(/[[:space:]]+#.*$/, "", val)
      sub(/[[:space:]]+$/, "", val)
      return val
    }
    BEGIN { in_sec = (sec == "" ? 1 : 0); sec_ind = -1 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*(#.*)?$/) next
      match(line, /^[[:space:]]*/)
      ind = RLENGTH
      trimmed = substr(line, ind + 1)

      if (sec != "") {
        if (ind == 0) {
          if (trimmed ~ ("^" sec ":[[:space:]]*(#.*)?$")) {
            in_sec = 1; sec_ind = -1; next
          } else {
            in_sec = 0; next
          }
        }
        if (!in_sec) next
        if (sec_ind == -1) sec_ind = ind
        if (ind != sec_ind) next
      }

      if (substr(trimmed, 1, length(k)) == k) {
        rest = substr(trimmed, length(k) + 1)
        if (rest ~ /^[[:space:]]*:/) {
          sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
          print unquote(rest)
          exit
        }
      }
    }
  ' "$file" 2>/dev/null
}

parse_yaml_list() { # $1=key [$2=父级section] [$3=文件路径]
  local key="$1" sec="${2:-}" file="${3:-$CONFIG_PATH}"
  [[ -f $file ]] || return 0
  awk -v k="$key" -v sec="$sec" '
    function unquote(val,    q, rest, out, i, c, esc) {
      sub(/^[[:space:]]+/, "", val)
      q = substr(val, 1, 1)
      if (q == "\"") {
        rest = substr(val, 2)
        out = ""; esc = 0
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (esc) { out = out c; esc = 0 }
          else if (c == "\\") { esc = 1 }
          else if (c == "\"") { break }
          else { out = out c }
        }
        return out
      } else if (q == "'"'"'") {
        rest = substr(val, 2)
        out = ""
        for (i = 1; i <= length(rest); i++) {
          c = substr(rest, i, 1)
          if (c == "'"'"'") {
            if (substr(rest, i + 1, 1) == "'"'"'") { out = out "'"'"'"; i++ }
            else break
          } else { out = out c }
        }
        return out
      }
      sub(/[[:space:]]+#.*$/, "", val)
      sub(/[[:space:]]+$/, "", val)
      return val
    }
    BEGIN { in_sec = (sec == "" ? 1 : 0); in_list = 0; key_ind = -1 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (line ~ /^[[:space:]]*(#.*)?$/) next
      match(line, /^[[:space:]]*/)
      ind = RLENGTH
      trimmed = substr(line, ind + 1)

      if (in_list) {
        if (ind < key_ind || (ind == key_ind && trimmed !~ /^-[[:space:]]/)) {
          exit
        }
        if (trimmed ~ /^-[[:space:]]+/) {
          val = trimmed
          sub(/^-[[:space:]]+/, "", val)
          item = unquote(val)
          if (item != "") print item
          next
        }
        exit
      }

      if (sec != "") {
        if (ind == 0) {
          if (trimmed ~ ("^" sec ":[[:space:]]*(#.*)?$")) { in_sec = 1; next }
          else { in_sec = 0; next }
        }
        if (!in_sec) next
      }

      if (substr(trimmed, 1, length(k)) == k) {
        rest = substr(trimmed, length(k) + 1)
        if (rest ~ /^[[:space:]]*:/) {
          sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
          sub(/[[:space:]]+#.*$/, "", rest)
          sub(/[[:space:]]+$/, "", rest)
          if (rest == "[]") exit
          in_list = 1
          key_ind = ind
          next
        }
      }
    }
  ' "$file" 2>/dev/null
}

get_api_keys() {
  local keys=""
  keys=$(parse_yaml_list "api-keys" "access")
  [[ -n $keys ]] || keys=$(parse_yaml_list "api-keys" "")
  printf '%s' "$keys"
}

api_key_count() {
  local keys
  keys=$(get_api_keys)
  [[ -n $keys ]] && printf '%s\n' "$keys" | wc -l | tr -d '[:space:]' || echo 0
}

get_domain() {
  [[ -f $DOMAIN_FILE ]] && head -n 1 "$DOMAIN_FILE" 2>/dev/null | tr -d '[:space:]' || true
}

auth_file_count() {
  [[ -d $AUTH_DIR ]] && find "$AUTH_DIR" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0
}

sanitize_domain() {
  local d="${1//[[:space:]]/}"
  d="${d,,}"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  d="${d%%:*}"
  d="${d%.}"
  [[ -z $d ]] && {
    echo ""
    return 0
  }
  # 拒绝纯 IPv4 及无点号的单标签域名，避免反代证书申请失败
  [[ $d == *.* ]] || return 1
  [[ $d =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 1
  [[ ${d##*.} =~ ^[0-9]+$ ]] && return 1
  if ((${#d} <= 253)) \
    && [[ $d =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] \
    && [[ $d != *..* && $d != *.-* && $d != *-.* ]]; then
    local lbl
    local IFS=.
    for lbl in $d; do
      ((${#lbl} >= 1 && ${#lbl} <= 63)) || return 1
      [[ $lbl != -* && $lbl != *- ]] || return 1
    done
    echo "$d"
    return 0
  fi
  return 1
}

enforce_local_binding() {
  [[ -f $CONFIG_PATH ]] || return 0
  local tmp has_v8=0 has_srv=0
  tmp=$(umask 077 && mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1

  tr -d '\r' <"$CONFIG_PATH" >"${tmp}.in" 2>/dev/null || {
    rm -f "$tmp" "${tmp}.in"
    return 1
  }
  grep -qE '^config-version:[[:space:]]*8([[:space:]]*(#.*)?)?$' "${tmp}.in" && has_v8=1
  grep -qE '^server:[[:space:]]*(\{\}[[:space:]]*)?(#.*)?$' "${tmp}.in" && has_srv=1

  if awk -v h="$LOCKED_HOST" -v p="$LOCKED_PORT" -v is_v8="$has_v8" -v has_srv="$has_srv" '
    BEGIN { in_srv=0; srv_ind=""; done_hp=0; top_h=0; top_p=0; emitted_srv=0 }
    {
      line = $0
      if (line ~ /^server:[[:space:]]*(\{\}[[:space:]]*)?(#.*)?$/) {
        print "server:"
        in_srv = 1
        srv_ind = ""
        done_hp = 0
        emitted_srv = 1
        next
      }
      if (in_srv) {
        if (line ~ /^[^[:space:]#]/) {
          if (!done_hp) {
            ind = (srv_ind != "" ? srv_ind : "  ")
            print ind "host: \"" h "\""
            print ind "port: " p
            done_hp = 1
          }
          in_srv = 0
        } else {
          if (line ~ /^[[:space:]]*(#.*)?$/) {
            print line
            next
          }
          match(line, /^[[:space:]]*/)
          cur_ind = substr(line, 1, RLENGTH)
          if (srv_ind == "") {
            srv_ind = cur_ind
            print srv_ind "host: \"" h "\""
            print srv_ind "port: " p
            done_hp = 1
          }
          if (cur_ind == srv_ind) {
            trimmed = substr(line, length(cur_ind) + 1)
            if (trimmed ~ /^(host|port):[[:space:]]*/) next
          }
          print line
          next
        }
      }

      if (is_v8 || has_srv) {
        if (line ~ /^(host|port):[[:space:]]*/) next
      } else {
        if (line ~ /^host:[[:space:]]*/) { print "host: \"" h "\""; top_h = 1; next }
        if (line ~ /^port:[[:space:]]*/) { print "port: " p; top_p = 1; next }
      }
      print line
    }
    END {
      if (in_srv && !done_hp) {
        ind = (srv_ind != "" ? srv_ind : "  ")
        print ind "host: \"" h "\""
        print ind "port: " p
      } else if (is_v8 || has_srv) {
        if (!emitted_srv) {
          print ""
          print "server:"
          print "  host: \"" h "\""
          print "  port: " p
        }
      } else {
        if (!top_h && !top_p) {
          print ""
          print "server:"
          print "  host: \"" h "\""
          print "  port: " p
        } else {
          if (!top_h) print "host: \"" h "\""
          if (!top_p) print "port: " p
        }
      }
    }
  ' "${tmp}.in" >"$tmp" 2>/dev/null; then
    rm -f "${tmp}.in"
    mv -f "$tmp" "$CONFIG_PATH" && chmod 600 "$CONFIG_PATH"
  else
    rm -f "$tmp" "${tmp}.in"
    return 1
  fi
}

write_config() { # $1=mgmt_secret [$2=allow_remote(true|false)] [$3=api_keys_multiline]
  local mgmt_k allow_remote="${2:-true}" raw_keys="${3:-}"
  mgmt_k=$(yaml_escape_dq "$1")
  [[ -n $raw_keys ]] || raw_keys=$(gen_api_key)

  ensure_work_dirs
  (
    umask 077
    {
      cat <<YAML
config-version: 8

server:
  host: "${LOCKED_HOST}"
  port: ${LOCKED_PORT}

management:
  allow-remote: ${allow_remote}
  secret-key: "${mgmt_k}"

access:
  api-keys:
YAML
      local k esc_k
      while IFS= read -r k; do
        [[ -n $k ]] || continue
        esc_k=$(yaml_escape_dq "$k")
        printf '    - "%s"\n' "$esc_k"
      done <<<"$raw_keys"
      cat <<YAML

oauth:
  auth-dir: "${AUTH_DIR}"
YAML
    } >"$CONFIG_PATH"
  )
}

update_yaml_scalar() { # $1=section $2=key $3=raw_value(带或不带引号由$4=quote控制) [$4=1加双引号|0原样]
  local sec="$1" key="$2" val="$3" quote="${4:-1}" tmp out_val
  [[ -f $CONFIG_PATH ]] || return 1
  if ((quote == 1)); then
    out_val="\"$(yaml_escape_dq "$val")\""
  else
    out_val="$val"
  fi
  tmp=$(umask 077 && mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  tr -d '\r' <"$CONFIG_PATH" >"${tmp}.in" 2>/dev/null || {
    rm -f "$tmp" "${tmp}.in"
    return 1
  }
  if awk -v sec="$sec" -v k="$key" -v v="$out_val" '
    BEGIN { in_sec=0; found_sec=0; replaced=0; sec_ind="  " }
    {
      line = $0
      if (line ~ ("^" sec ":[[:space:]]*(#.*)?$")) {
        in_sec = 1; found_sec = 1; print line; next
      }
      if (in_sec) {
        if (line ~ /^[^[:space:]#]/) {
          if (!replaced) { print sec_ind k ": " v; replaced = 1 }
          in_sec = 0
        } else {
          if (line !~ /^[[:space:]]*(#.*)?$/) {
            match(line, /^[[:space:]]*/)
            cur_ind = substr(line, 1, RLENGTH)
            if (sec_ind == "  " && length(cur_ind) > 0) sec_ind = cur_ind
            trimmed = substr(line, length(cur_ind) + 1)
            if (cur_ind == sec_ind && substr(trimmed, 1, length(k)) == k && substr(trimmed, length(k) + 1) ~ /^[[:space:]]*:/) {
              print cur_ind k ": " v
              replaced = 1
              next
            }
          }
          print line
          next
        }
      }
      print line
    }
    END {
      if (in_sec && !replaced) {
        print sec_ind k ": " v
      } else if (!found_sec) {
        print ""
        print sec ":"
        print "  " k ": " v
      }
    }
  ' "${tmp}.in" >"$tmp" 2>/dev/null; then
    rm -f "${tmp}.in"
    mv -f "$tmp" "$CONFIG_PATH" && chmod 600 "$CONFIG_PATH"
  else
    rm -f "$tmp" "${tmp}.in"
    return 1
  fi
}

replace_yaml_api_keys() { # $1=换行分隔的 api-keys 列表
  local raw_keys="$1" tmp keys_file
  [[ -f $CONFIG_PATH ]] || return 1
  tmp=$(umask 077 && mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  keys_file="${tmp}.keys"
  : >"$keys_file"
  local k esc_k
  while IFS= read -r k; do
    [[ -n $k ]] || continue
    esc_k=$(yaml_escape_dq "$k")
    printf '    - "%s"\n' "$esc_k" >>"$keys_file"
  done <<<"$raw_keys"

  tr -d '\r' <"$CONFIG_PATH" >"${tmp}.in" 2>/dev/null || {
    rm -f "$tmp" "${tmp}.in" "$keys_file"
    return 1
  }

  if awk -v kfile="$keys_file" '
    function emit_keys(    l, has_any) {
      has_any = 0
      while ((getline l < kfile) > 0) {
        if (!has_any) {
          print "  api-keys:"
          has_any = 1
        }
        print l
      }
      close(kfile)
      if (!has_any) print "  api-keys: []"
    }
    BEGIN { in_acc=0; found_acc=0; in_list=0; in_old_list=0; done=0; list_ind=-1 }
    {
      line = $0
      if (line ~ /^access:[[:space:]]*(#.*)?$/) {
        in_acc = 1; found_acc = 1; print line; next
      }
      if (in_acc) {
        if (line ~ /^[^[:space:]#]/) {
          if (!done) { emit_keys(); done = 1 }
          in_acc = 0; in_list = 0
        } else {
          if (in_list) {
            if (line ~ /^[[:space:]]*(#.*)?$/) next
            match(line, /^[[:space:]]*/)
            ind = RLENGTH
            trimmed = substr(line, ind + 1)
            if (ind > list_ind || (ind == list_ind && trimmed ~ /^-[[:space:]]/)) next
            in_list = 0
          }
          if (line ~ /^[[:space:]]+api-keys:[[:space:]]*(\[\][[:space:]]*)?(#.*)?$/) {
            match(line, /^[[:space:]]*/)
            list_ind = RLENGTH
            emit_keys()
            done = 1
            in_list = 1
            next
          }
          print line
          next
        }
      }
      # 同时清理旧版顶级 api-keys 列表
      if (line ~ /^api-keys:[[:space:]]*(\[\][[:space:]]*)?(#.*)?$/) {
        in_old_list = 1; next
      }
      if (in_old_list) {
        if (line ~ /^[[:space:]]+-/ || line ~ /^[[:space:]]*(#.*)?$/) next
        in_old_list = 0
      }
      print line
    }
    END {
      if (in_acc && !done) {
        emit_keys()
      } else if (!found_acc) {
        print ""
        print "access:"
        emit_keys()
      }
    }
  ' "${tmp}.in" >"$tmp" 2>/dev/null; then
    rm -f "${tmp}.in" "$keys_file"
    mv -f "$tmp" "$CONFIG_PATH" && chmod 600 "$CONFIG_PATH"
  else
    rm -f "$tmp" "${tmp}.in" "$keys_file"
    return 1
  fi
}

replace_binary() {
  rm -f "${BIN_PATH}.new"
  install -m 755 "$1" "${BIN_PATH}.new" && mv -f "${BIN_PATH}.new" "$BIN_PATH"
}

# ───────── 服务托管与健康检查 ─────────
svc_ctl() { # is-active | is-enabled | enable | disable | start | stop | restart
  if [[ $OS_TYPE == alpine ]]; then
    case "$1" in
      is-active) rc-service cliproxy status >/dev/null 2>&1 ;;
      is-enabled) rc-update show default 2>/dev/null | awk '$1=="cliproxy"{f=1} END{exit !f}' ;;
      enable) rc-update add cliproxy default >/dev/null 2>&1 ;;
      disable) rc-update del cliproxy default >/dev/null 2>&1 ;;
      restart)
        rc-service cliproxy stop >/dev/null 2>&1 || rc-service cliproxy zap >/dev/null 2>&1 || true
        rc-service cliproxy start >/dev/null 2>&1
        ;;
      stop)
        rc-service cliproxy stop >/dev/null 2>&1 || {
          rc-service cliproxy status >/dev/null 2>&1
          (($? == 3))
        }
        ;;
      *) rc-service cliproxy "$1" >/dev/null 2>&1 ;;
    esac
  else
    case "$1" in
      is-active | is-enabled) systemctl "$1" --quiet cliproxy 2>/dev/null ;;
      stop)
        systemctl is-active --quiet cliproxy 2>/dev/null || return 0
        systemctl stop cliproxy >/dev/null 2>&1
        ;;
      restart)
        systemctl daemon-reload >/dev/null 2>&1
        systemctl restart cliproxy >/dev/null 2>&1
        ;;
      *) systemctl "$1" cliproxy >/dev/null 2>&1 ;;
    esac
  fi
}

wait_for_service() {
  local i=20
  while ((i-- > 0)); do
    if svc_ctl is-active && curl -sS --max-time 1 -o /dev/null "http://${LISTEN_ADDR}/" 2>/dev/null; then
      return 0
    fi
    sleep_frac 0.5
  done
  return 1
}

fmt_status() {
  if svc_ctl is-active; then
    printf '%s● 运行中%s' "$G" "$N"
  elif [[ -f $SERVICE_PATH && -x $BIN_PATH ]]; then
    printf '%s○ 已停止%s' "$R" "$N"
  elif [[ -x $BIN_PATH ]]; then
    printf '%s○ 未注册服务%s' "$Y" "$N"
  else
    printf '%s○ 未安装%s' "$D" "$N"
  fi
}

restart_cliproxy() {
  [[ -f $SERVICE_PATH ]] || return 1
  enforce_local_binding || return 1
  svc_ctl restart && wait_for_service
}

install_service_unit() {
  if [[ $OS_TYPE == alpine ]]; then
    cat <<INIT >"$SERVICE_PATH"
#!/sbin/openrc-run
name="CLIProxyAPI"
supervisor="supervise-daemon"
respawn_delay=3
directory="${WORK_DIR}"
command="${BIN_PATH}"
command_args="-config ${CONFIG_PATH}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
rc_ulimit="-n 65535"
depend() { need net; after firewall; }
start_pre() {
  if [ -f "${LOG_FILE}" ] && [ "\$(wc -c < "${LOG_FILE}" 2>/dev/null || echo 0)" -gt 20971520 ]; then
    tail -c 2097152 "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null && mv -f "${LOG_FILE}.tmp" "${LOG_FILE}" || : > "${LOG_FILE}"
  fi
  touch "${LOG_FILE}" && chmod 600 "${LOG_FILE}"
}
INIT
    chmod 755 "$SERVICE_PATH"
    if [[ -d /etc/logrotate.d ]]; then
      cat <<LOGROTATE >/etc/logrotate.d/cliproxy
${LOG_FILE} {
    daily
    rotate 7
    size 20M
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LOGROTATE
    fi
    svc_ctl enable || true
  else
    cat <<UNIT >"$SERVICE_PATH"
[Unit]
Description=CLIProxyAPI Service (${OFFICIAL_REPO})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORK_DIR}
ExecStart=${BIN_PATH} -config ${CONFIG_PATH}
Restart=on-failure
RestartSec=3
TimeoutStopSec=15
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$SERVICE_PATH"
    systemctl daemon-reload >/dev/null 2>&1
    svc_ctl enable || true
  fi
}

# ───────── 版本、下载、校验与二进制兼容性预检 ─────────
extract_ver_str() {
  local s="${1:-}"
  if [[ $s =~ v?([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

_run_with_timeout() {
  local secs="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    local out="" rc=0
    out=$(timeout "$secs" "$@" 2>&1) || rc=$?
    if ((rc == 1)) && [[ $out == *"BusyBox"* || $out == *"invalid option"* ]]; then
      rc=0
      out=$(timeout -t "$secs" "$@" 2>&1) || rc=$?
    fi
    printf '%s' "$out"
    return "$rc"
  fi
  "$@" 2>&1
}

parse_binary_version() {
  local target="${1:-$BIN_PATH}" out=""
  [[ -x $target ]] || return 0
  out=$(_run_with_timeout 2 "$target" --version || true)
  # 若二进制不支持 --version（输出含 flag provided），则不把噪声当版本
  [[ $out == *"flag provided but not defined"* ]] && return 0
  extract_ver_str "$out" || true
}

save_local_version() {
  local v="${1:-}"
  if [[ -n $v && ! $v =~ ^(未安装|未知)$ ]]; then
    ensure_work_dirs
    (umask 077 && printf '%s\n' "$v" >"$VERSION_FILE")
    LOCAL_VER="$v"
  else
    LOCAL_VER=""
  fi
}

get_local_version() {
  [[ -x $BIN_PATH ]] || {
    LOCAL_VER=""
    echo "未安装"
    return
  }
  if [[ -n ${LOCAL_VER:-} && ! $LOCAL_VER =~ ^(未安装|未知)$ ]]; then
    echo "$LOCAL_VER"
    return
  fi
  local v=""
  if [[ -f $VERSION_FILE ]]; then
    v=$(head -n 1 "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
    v=$(extract_ver_str "$v")
  fi
  [[ -n $v ]] || v=$(parse_binary_version "$BIN_PATH" 2>/dev/null)
  if [[ -z $v ]]; then
    local log_line=""
    if [[ $OS_TYPE == alpine && -f $LOG_FILE ]]; then
      log_line=$(grep -oE 'CLIProxyAPI Version: v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?' "$LOG_FILE" 2>/dev/null | tail -n 1 || true)
    elif [[ $OS_TYPE == debian ]] && command -v journalctl >/dev/null 2>&1; then
      log_line=$(journalctl -u cliproxy -n 80 --no-pager -o cat 2>/dev/null | grep -oE 'CLIProxyAPI Version: v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?' | tail -n 1 || true)
    fi
    v=$(extract_ver_str "$log_line")
  fi
  if [[ -n $v ]]; then
    LOCAL_VER="$v"
    echo "$v"
  else
    echo "未知"
  fi
}

fmt_ver() {
  [[ $1 =~ ^(未安装|未知)$ ]] && printf '%s%s%s' "$D" "$1" "$N" || printf '%sv%s%s' "$C" "$1" "$N"
}

verify_binary_compat() {
  local bin="$1" magic="" out="" rc=0
  magic=$(LC_ALL=C head -c 4 "$bin" 2>/dev/null || true)
  [[ $magic == $'\x7fELF' ]] || {
    err "文件不是有效的 Linux ELF 可执行程序"
    return 1
  }
  out=$(_run_with_timeout 3 "$bin" --help) || rc=$?
  # Go flag --help 默认退出码为 2；124/137/143=超时, 126/127=无法执行/缺动态链接器, >=128=信号崩溃
  if ((rc == 124 || rc == 126 || rc == 127 || rc >= 128)); then
    err "二进制兼容性预检失败 (exit=${rc})："
    [[ -n $out ]] && printf '  %s\n' "$out" | head -n 5 >&2
    return 1
  fi
  if ((rc != 0)) && [[ $out != *"Usage"* && $out != *"config"* && $out != *"CLIProxyAPI"* && $out != *"flag"* ]]; then
    err "二进制预检异常输出 (exit=${rc})："
    [[ -n $out ]] && printf '  %s\n' "$out" | head -n 5 >&2
    return 1
  fi
  return 0
}

fetch_release_info() {
  local arch_p arch_a variant="" api_json="" eff_url="" html=""
  case "$(uname -m)" in
    x86_64 | amd64)
      arch_p="amd64"
      arch_a="x86_64"
      ;;
    aarch64 | arm64)
      arch_p="arm64"
      arch_a="aarch64"
      ;;
    *)
      err "不支持的系统架构: $(uname -m)"
      return 1
      ;;
  esac
  ((IS_MUSL == 1)) && variant="_no-plugin"

  local rel_page="https://github.com/${OFFICIAL_REPO}/releases/latest"
  local rel_proxy="${GH_PROXY}${rel_page}"
  local api_direct="https://api.github.com/repos/${OFFICIAL_REPO}/releases/latest"
  local api_proxy="${GH_PROXY}${api_direct}"

  LATEST_TAG=""
  LATEST_VER=""
  CANDIDATE_URLS=()
  declare -gA CANDIDATE_SHA=()

  # 1) 优先直连 GitHub API（短超时）；若设置了 GH_PROXY 且直连失败再尝试代理 API
  api_json=$(curl -fsSL --connect-timeout 6 --max-time 10 "$api_direct" 2>/dev/null || true)
  if [[ -z $api_json && -n $GH_PROXY ]]; then
    api_json=$(curl -fsSL --connect-timeout 6 --max-time 10 "$api_proxy" 2>/dev/null || true)
  fi

  if [[ -n $api_json ]] && jq -e '.tag_name' >/dev/null 2>&1 <<<"$api_json"; then
    LATEST_TAG=$(jq -r '.tag_name // empty' <<<"$api_json")
    local asset_lines="" line url digest
    asset_lines=$(jq -r --arg ap "$arch_p" --arg aa "$arch_a" '
      (.assets // [])[]
      | select((.name | ascii_downcase | contains("linux"))
        and ((.name | contains($ap)) or (.name | contains($aa)))
        and (.name | test("\\.(tar\\.gz|tgz)$")))
      | "\(.browser_download_url)\t\(.digest // "")"
    ' <<<"$api_json" 2>/dev/null || true)

    local no_plugin_urls=() std_urls=()
    while IFS=$'\t' read -r url digest; do
      [[ -n $url ]] || continue
      local dl_u="$url"
      [[ -n $GH_PROXY ]] && dl_u="${GH_PROXY}${url#"${GH_PROXY}"}"
      digest="${digest#sha256:}"
      digest="${digest,,}"
      [[ $digest =~ ^[0-9a-f]{64}$ ]] && CANDIDATE_SHA["$dl_u"]="$digest"
      if [[ $url == *"_no-plugin"* ]]; then
        no_plugin_urls+=("$dl_u")
      else
        std_urls+=("$dl_u")
      fi
    done <<<"$asset_lines"

    if ((IS_MUSL == 1)); then
      CANDIDATE_URLS+=("${no_plugin_urls[@]}" "${std_urls[@]}")
    else
      CANDIDATE_URLS+=("${std_urls[@]}" "${no_plugin_urls[@]}")
    fi
  fi

  # 2) API 受限或无响应时，降级通过 Redirect / HTML 解析 tag_name
  if [[ -z $LATEST_TAG ]]; then
    local probe_u
    for probe_u in "$rel_proxy" "$rel_page"; do
      [[ -n $probe_u ]] || continue
      eff_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --connect-timeout 8 --max-time 12 "$probe_u" 2>/dev/null || true)
      LATEST_TAG=$(printf '%s' "$eff_url" | awk -F'/tag/' '/\/tag\// {gsub(/[\r\n?[:space:]#].*/, "", $2); print $2; exit}')
      [[ -n $LATEST_TAG ]] && break
      html=$(curl -fsSL --connect-timeout 8 --max-time 12 "$probe_u" 2>/dev/null || true)
      LATEST_TAG=$(printf '%s' "$html" | grep -oE "/${OFFICIAL_REPO}/releases/tag/v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?" | head -n 1 | awk -F'/tag/' '{print $2}')
      [[ -n $LATEST_TAG ]] && break
    done
  fi

  [[ -n $LATEST_TAG ]] || {
    err "无法获取最新版本信息，请检查网络或配置 GH_PROXY！"
    return 1
  }
  LATEST_VER="${LATEST_TAG#v}"

  local base_dl="${GH_PROXY}https://github.com/${OFFICIAL_REPO}/releases/download/${LATEST_TAG}"
  local a u
  for a in "$arch_p" "$arch_a"; do
    if ((IS_MUSL == 1)); then
      u="${base_dl}/CLIProxyAPI_${LATEST_VER}_linux_${a}_no-plugin.tar.gz"
      [[ " ${CANDIDATE_URLS[*]} " == *" $u "* ]] || CANDIDATE_URLS+=("$u")
    fi
    u="${base_dl}/CLIProxyAPI_${LATEST_VER}_linux_${a}.tar.gz"
    [[ " ${CANDIDATE_URLS[*]} " == *" $u "* ]] || CANDIDATE_URLS+=("$u")
    if ((IS_MUSL == 0)); then
      u="${base_dl}/CLIProxyAPI_${LATEST_VER}_linux_${a}_no-plugin.tar.gz"
      [[ " ${CANDIDATE_URLS[*]} " == *" $u "* ]] || CANDIDATE_URLS+=("$u")
    fi
  done

  # 3) 若 API 未返回资产 SHA256，尝试抓取 release 中的 checksums.txt
  if ((${#CANDIDATE_SHA[@]} == 0)); then
    local csum_txt="" cname csum
    for csum_u in "${base_dl}/checksums.txt" "https://github.com/${OFFICIAL_REPO}/releases/download/${LATEST_TAG}/checksums.txt"; do
      csum_txt=$(curl -fsSL --connect-timeout 6 --max-time 10 "$csum_u" 2>/dev/null || true)
      [[ -n $csum_txt ]] && break
    done
    if [[ -n $csum_txt ]]; then
      for u in "${CANDIDATE_URLS[@]}"; do
        cname="${u##*/}"
        csum=$(awk -v f="$cname" '$2 == f || $2 == ("*" f) {print tolower($1); exit}' <<<"$csum_txt")
        [[ $csum =~ ^[0-9a-f]{64}$ ]] && CANDIDATE_SHA["$u"]="$csum"
      done
    fi
  fi
}

install_release_binary() {
  local dl_dir ext_dir found="" cand="" url dl_ok=0 expected_sha="" actual_sha=""
  dl_dir=$(mktemp -d "${RUN_TMP}/dl.XXXXXX") || {
    err "创建临时下载目录失败！"
    return 1
  }
  ext_dir="${dl_dir}/extract"
  ensure_work_dirs

  info "正在下载官方程序包 (v${LATEST_VER})…"
  for url in "${CANDIDATE_URLS[@]}"; do
    found=""
    actual_sha=""
    if ((IS_MUSL == 1)) && [[ $url != *"_no-plugin"* ]]; then
      warn "未命中 musl (_no-plugin) 程序包，正在尝试兼容包: ${url##*/}"
    fi
    rm -rf "$ext_dir" && mkdir -p "$ext_dir"
    curl -fsSL --connect-timeout 10 --max-time 180 -o "${dl_dir}/pkg.tar.gz" "$url" 2>/dev/null || continue

    expected_sha="${CANDIDATE_SHA[$url]:-}"
    if [[ -n $expected_sha ]]; then
      actual_sha=$(sha256sum "${dl_dir}/pkg.tar.gz" 2>/dev/null | awk '{print tolower($1)}')
      if [[ $actual_sha != "$expected_sha" ]]; then
        warn "SHA256 校验未通过 (${url##*/})，尝试下一候选地址…"
        rm -f "${dl_dir}/pkg.tar.gz"
        continue
      fi
      ok "SHA256 完整性校验通过"
    else
      warn "未获取到上游 SHA256 摘要，跳过完整性校验"
    fi

    if tar -zxf "${dl_dir}/pkg.tar.gz" -C "$ext_dir" 2>/dev/null; then
      # 先精确匹配主程序名，再模糊匹配并校验 ELF 魔数
      while IFS= read -r cand; do
        [[ -n $cand ]] || continue
        if [[ $(LC_ALL=C head -c 4 "$cand" 2>/dev/null || true) == $'\x7fELF' ]]; then
          found="$cand"
          break
        fi
      done < <(
        find "$ext_dir" -type f \( -iname "cli-proxy-api" -o -iname "cliproxyapi" \) 2>/dev/null
        find "$ext_dir" -type f \( -iname "cli-proxy-api*" -o -iname "cliproxyapi*" \) \
          ! -name "*.yaml" ! -name "*.yml" ! -name "*.md" ! -name "*.txt" ! -name "*.tar.gz" \
          ! -name "*.tgz" ! -name "*.sh" ! -name "*.json" ! -name "*.service" ! -name "*.conf" \
          ! -name "*.pdf" ! -name "*.1" 2>/dev/null
      )

      if [[ -n $found ]]; then
        chmod +x "$found"
        if verify_binary_compat "$found"; then
          dl_ok=1
          break
        fi
      fi
    fi
    rm -f "${dl_dir}/pkg.tar.gz"
  done

  if ((dl_ok != 1)); then
    err "程序包下载、校验或兼容性预检失败，请检查网络或系统兼容性！"
    rm -rf "$dl_dir"
    return 1
  fi

  if ! replace_binary "$found"; then
    err "替换主程序文件失败！"
    rm -rf "$dl_dir"
    return 1
  fi

  local example_cfg="" bin_ver=""
  example_cfg=$(find "$ext_dir" -type f -name "config.example.yaml" | head -n 1)
  if [[ -n $example_cfg ]]; then
    install -m 600 "$example_cfg" "${WORK_DIR}/config.example.yaml" 2>/dev/null || true
  fi

  bin_ver=$(parse_binary_version "$BIN_PATH" 2>/dev/null || true)
  save_local_version "${bin_ver:-$LATEST_VER}"
  rm -rf "$dl_dir"
  ok "主程序安装完成 ($(fmt_ver "$(get_local_version)"))"
}

# ───────── 备份与轮转 ─────────
sort_backups_desc() { # 读取标准输入的路径列表，按内嵌 YYYYMMDD_HHMMSS 时间戳降序排列
  awk '
    {
      path = $0
      base = path
      sub(/^.*\//, "", base)
      ts = "00000000_000000"
      if (match(base, /[0-9]{8}_[0-9]{6}/)) {
        ts = substr(base, RSTART, RLENGTH)
      }
      print ts "\t" path
    }
  ' | sort -r | cut -f2-
}

prune_old_backups() {
  local pat list=() i
  for pat in "$@"; do
    mapfile -t list < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$pat" 2>/dev/null | sort_backups_desc)
    for ((i = 3; i < ${#list[@]}; i++)); do
      rm -f -- "${list[$i]}"
    done
  done
}

create_backup() {
  local mode="${1:-auto}" skip_prune="${2:-0}" ts cur_v v_tag=""
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  ts=$(date +"%Y%m%d_%H%M%S")
  cur_v=$(get_local_version)
  [[ ! $cur_v =~ ^(未安装|未知)$ ]] && v_tag="_v${cur_v}"

  LAST_BIN_BACKUP=""
  LAST_CFG_BACKUP=""
  if [[ -f $CONFIG_PATH ]]; then
    LAST_CFG_BACKUP="${BACKUP_DIR}/config_${mode}_${ts}${v_tag}.yaml"
    install -m 600 "$CONFIG_PATH" "$LAST_CFG_BACKUP"
  fi
  if [[ -f $BIN_PATH ]]; then
    LAST_BIN_BACKUP="${BACKUP_DIR}/cli-proxy-api_${mode}_${ts}${v_tag}"
    install -m 755 "$BIN_PATH" "$LAST_BIN_BACKUP"
  fi
  if [[ $mode == "manual" ]] && (($(auth_file_count) > 0)); then
    (umask 077 && tar -czf "${BACKUP_DIR}/auth_manual_${ts}${v_tag}.tar.gz" -C "$WORK_DIR" auth 2>/dev/null) || true
  fi
  if [[ $skip_prune != "1" ]]; then
    prune_old_backups "config_auto_*" "cli-proxy-api_auto_*"
  fi
}

# ───────── 业务功能模块 ─────────
deploy() {
  ensure_deps || {
    pause
    return 1
  }
  title "安装与配置向导"

  if [[ -x $BIN_PATH && -f $CONFIG_PATH ]]; then
    warn "检测到已安装 CLIProxyAPI ($(fmt_ver "$(get_local_version)"))"
    echo
    printf "    ${C}[1]${N}  平滑升级 ${D}(保留现有配置、API Key 与凭据)${N}\n"
    printf "    ${C}[2]${N}  重新配置 ${D}(先创建备份，再重设密钥与反代域名)${N}\n"
    printf "    ${D}[0]  返回主菜单${N}\n"
    while true; do
      prompt_key || return
      case "$REPLY" in
        1 | ENTER)
          upgrade_lossless
          return
          ;;
        2)
          create_backup "auto"
          break
          ;;
        0 | q | Q | ESC) return ;;
        *) warn "无效按键，请按 1 / 2 / 0" ;;
      esac
    done
    title "重新配置向导"
  fi

  local old_key old_remote old_keys default_mgmt default_api
  local SECRET_KEY="" CLIENT_KEYS="" raw_client_key="" raw_domain="" PROXY_DOMAIN="" old_domain=""

  old_key=$(parse_yaml_val "secret-key" "management")
  [[ -n $old_key ]] || old_key=$(parse_yaml_val "secret-key" "remote-management")
  local key_is_hashed=0
  if [[ $old_key == \$2[abxy]\$* ]]; then
    key_is_hashed=1
    old_key=""
  fi
  old_remote=$(parse_yaml_val "allow-remote" "management")
  [[ -n $old_remote ]] || old_remote=$(parse_yaml_val "allow-remote" "remote-management")
  old_remote="${old_remote:-true}"

  old_keys=$(get_api_keys)
  old_domain=$(get_domain)

  ui_step 1 3 "安全凭据配置"
  info "安全策略: 强制绑定本地回环 ${Y}http://${LISTEN_ADDR}${N}（公网不可直连）"
  ((key_is_hashed == 1)) && warn "检测到原管理密钥已 bcrypt 加密存储；直接回车将重置为下方新生成的密钥"

  default_mgmt="${old_key:-cpa_$(gen_random_secret 12)}"
  while true; do
    ask "管理面板密钥 (secret-key)" "$default_mgmt" || return 1
    SECRET_KEY="$REPLY"
    if [[ $SECRET_KEY =~ [[:cntrl:]] ]]; then
      err "密钥不能包含控制字符，请重新输入！"
    elif [[ -z ${SECRET_KEY//[[:space:]]/} ]]; then
      err "管理密钥不能为空！"
    else
      break
    fi
  done

  if [[ -n $old_keys ]]; then
    local existing_cnt
    existing_cnt=$(printf '%s\n' "$old_keys" | wc -l | tr -d '[:space:]')
    info "当前已配置 ${existing_cnt} 个客户端 API Key（如：$(mask_secret "$(head -n1 <<<"$old_keys")")）"
    if confirm_y "是否保留现有客户端 API Key？"; then
      CLIENT_KEYS="$old_keys"
    fi
  fi
  if [[ -z $CLIENT_KEYS ]]; then
    default_api=$(gen_api_key)
    while true; do
      ask "客户端访问密钥 (access.api-keys)" "$default_api" || return 1
      raw_client_key="$REPLY"
      if [[ $raw_client_key =~ [[:cntrl:]] || -z ${raw_client_key//[[:space:]]/} ]]; then
        err "客户端密钥不能为空或包含控制字符！"
      else
        CLIENT_KEYS="$raw_client_key"
        break
      fi
    done
  fi

  ui_step 2 3 "反代域名配置"
  while true; do
    ask "反代域名 (如 api.example.com，留空跳过${old_domain:+，输入 - 清除})" "$old_domain" || return 1
    raw_domain="$REPLY"
    if [[ $raw_domain == "-" ]]; then
      PROXY_DOMAIN=""
      break
    fi
    if PROXY_DOMAIN=$(sanitize_domain "$raw_domain"); then
      break
    fi
    err "域名格式无效（需为合法公网域名，不支持纯 IP 或 localhost），请重新输入！"
  done

  ui_step 3 3 "下载程序与部署服务"
  local update_bin="y"
  if [[ -x $BIN_PATH ]]; then
    confirm_y "是否更新主程序至官方最新版？" || update_bin="n"
  fi
  if [[ $update_bin == "y" ]]; then
    # 先完成下载、SHA256 与兼容性预检，再停用线上服务
    if ! fetch_release_info || ! install_release_binary; then
      pause
      return 1
    fi
  fi

  ensure_work_dirs
  if [[ -n $PROXY_DOMAIN ]]; then
    (umask 077 && printf '%s\n' "$PROXY_DOMAIN" >"$DOMAIN_FILE")
  else
    rm -f "$DOMAIN_FILE"
  fi

  svc_ctl stop || true
  write_config "$SECRET_KEY" "$old_remote" "$CLIENT_KEYS"
  install_service_unit

  info "正在启动 CLIProxyAPI 服务并探测就绪状态…"
  if ! svc_ctl restart || ! wait_for_service; then
    err "服务启动或端口探活失败，请通过 [3 运行日志] 排查原因！"
    pause
    return 1
  fi

  local base_url="${PROXY_DOMAIN:+https://${PROXY_DOMAIN}}"
  base_url="${base_url:-http://${LISTEN_ADDR}}"

  title "部署完成"
  ui_kv "当前版本" "$(fmt_ver "$(get_local_version)")（${OS_NAME}）"
  ui_kv "运行状态" "$(fmt_status)"
  ui_kv "本地监听" "${Y}http://${LISTEN_ADDR}${N} ${G}(公网已隔离)${N}"
  if [[ -n $PROXY_DOMAIN ]]; then
    ui_kv "反代域名" "${C}https://${PROXY_DOMAIN}${N}"
  else
    ui_kv "反代域名" "${D}未设置（可在主菜单 [5 反代指引] 配置）${N}"
  fi
  ui_kv "管理面板" "${C}${base_url}/management.html${N}"
  ui_kv "管理密钥" "${G}${SECRET_KEY}${N}"
  local first_api_key
  first_api_key=$(head -n 1 <<<"$CLIENT_KEYS")
  ui_kv "客户端 Key" "${G}${first_api_key}${N}"
  ui_kv "OpenAI" "${C}${base_url}/v1/chat/completions${N}"
  ui_kv "Claude" "${C}${base_url}/v1/messages${N}"
  ui_kv "Gemini" "${C}${base_url}/v1beta/models${N}"
  pause
}

upgrade_lossless() {
  ensure_deps || {
    pause
    return 1
  }
  title "CLIProxyAPI 无损平滑升级"

  if [[ ! -x $BIN_PATH ]]; then
    warn "尚未安装主程序，即将跳转至安装向导…"
    sleep_frac 0.8
    deploy
    return
  fi

  local local_ver
  local_ver=$(get_local_version)
  ui_kv "本地版本" "$(fmt_ver "$local_ver")"
  info "正在查询 GitHub 最新发行版…"
  fetch_release_info || {
    pause
    return 1
  }
  ui_kv "官方最新" "${G}v${LATEST_VER}${N}"
  echo

  if [[ $local_ver == "$LATEST_VER" ]]; then
    ok "当前已是最新版本。"
    confirm "是否强制重新下载并校验覆盖安装？" || return 0
  else
    confirm_y "确认平滑升级至 v${LATEST_VER}？" || return 0
  fi

  local prev_ver="$local_ver"
  create_backup "auto" "1"
  if ! install_release_binary; then
    pause
    return 1
  fi

  info "正在重启服务并验证端口就绪…"
  if ! restart_cliproxy; then
    err "新版本启动异常，正在自动回滚程序与配置…"
    [[ -n $LAST_BIN_BACKUP && -f $LAST_BIN_BACKUP ]] && replace_binary "$LAST_BIN_BACKUP"
    [[ -n $LAST_CFG_BACKUP && -f $LAST_CFG_BACKUP ]] && install -m 600 "$LAST_CFG_BACKUP" "$CONFIG_PATH"
    if [[ ! $prev_ver =~ ^(未安装|未知)$ ]]; then
      save_local_version "$prev_ver"
    else
      rm -f "$VERSION_FILE"
      LOCAL_VER=""
    fi
    if restart_cliproxy; then
      ok "已安全回滚至旧版本 ($(fmt_ver "$(get_local_version)"))"
    else
      err "回滚后启动仍失败，请通过 [3 运行日志] 排查！"
    fi
    pause
    return 1
  fi

  prune_old_backups "config_auto_*" "cli-proxy-api_auto_*"
  ok "平滑升级成功：$(fmt_ver "$prev_ver") -> $(fmt_ver "$(get_local_version)")"
  pause
}

rollback_menu() {
  title "历史版本回滚"
  local list=() f idx=1 bver choice bname
  [[ -d $BACKUP_DIR ]] && mapfile -t list < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "cli-proxy-api_*" 2>/dev/null | sort_backups_desc)
  if ((${#list[@]} == 0)); then
    warn "暂无可用的主程序历史备份！"
    pause
    return 1
  fi

  ui_kv "当前版本" "$(fmt_ver "$(get_local_version)")"
  echo
  for f in "${list[@]}"; do
    bname=$(basename "$f")
    bver=$(extract_ver_str "$bname")
    [[ -n $bver ]] || bver=$(parse_binary_version "$f" 2>/dev/null || true)
    bver="${bver:-未知}"
    printf "    ${C}[%s]${N}  " "$idx"
    pad_print "$bname" 42
    printf " %s\n" "$(fmt_ver "$bver")"
    ((idx++))
  done
  echo
  printf "    ${D}[0]  返回${N}\n"
  echo
  ask_c "请选择要回滚的备份编号 [0-${#list[@]}]" "" || return 0
  choice="$REPLY"
  if [[ ! $choice =~ ^[0-9]+$ ]] || ((10#$choice < 1 || 10#$choice > ${#list[@]})); then
    err "编号无效！"
    pause
    return 1
  fi

  local picked="${list[$((10#$choice - 1))]}"
  if ! verify_binary_compat "$picked"; then
    err "所选备份文件无法通过兼容性校验！"
    pause
    return 1
  fi

  local picked_ver
  picked_ver=$(extract_ver_str "$(basename "$picked")")
  [[ -n $picked_ver ]] || picked_ver=$(parse_binary_version "$picked" 2>/dev/null || true)

  if replace_binary "$picked" && restart_cliproxy; then
    if [[ -n $picked_ver ]]; then
      save_local_version "$picked_ver"
    else
      rm -f "$VERSION_FILE"
      LOCAL_VER=""
    fi
    ok "已成功回滚至 $(fmt_ver "$(get_local_version)")！"
  else
    err "回滚后启动失败，请检查运行日志！"
  fi
  pause
}

service_menu() {
  local toast_fn="" toast_msg="" auto_lbl=""
  while true; do
    title "服务控制"
    svc_ctl is-enabled && auto_lbl="${G}已开启${N}" || auto_lbl="${D}已关闭${N}"
    ui_kv "运行状态" "$(fmt_status)"
    ui_kv "开机自启" "$auto_lbl"
    ui_kv "服务单元" "${SERVICE_PATH}"
    echo
    printf "    ${C}[1]${N}  "; pad_print "启动服务" 18; printf "${C}[3]${N}  重启服务\n"
    printf "    ${C}[2]${N}  "; pad_print "停止服务" 18; printf "${C}[4]${N}  切换开机自启\n"
    echo
    printf "    ${D}[0]  返回主菜单${N}\n"
    show_toast "$toast_fn" "$toast_msg"
    toast_fn=""
    toast_msg=""
    prompt_key || return

    case "$REPLY" in
      "" | ENTER) continue ;;
      0 | q | Q | ESC) return ;;
      1 | 2 | 3 | 4)
        if [[ ! -f $SERVICE_PATH ]]; then
          toast_fn=warn
          toast_msg="服务尚未安装，请先执行 [6 安装部署]"
          continue
        fi
        ;;
      *)
        toast_fn=err
        toast_msg="无效按键，请按 0-4"
        continue
        ;;
    esac

    case "$REPLY" in
      1)
        if svc_ctl is-active; then
          toast_fn=info; toast_msg="服务已在运行中"
        elif enforce_local_binding && svc_ctl start && wait_for_service; then
          toast_fn=ok; toast_msg="服务已启动并就绪"
        else
          toast_fn=err; toast_msg="启动失败，请查看 [3 运行日志]"
        fi
        ;;
      2)
        if ! svc_ctl is-active; then
          toast_fn=info; toast_msg="服务当前已处于停止状态"
        elif svc_ctl stop; then
          toast_fn=ok; toast_msg="服务已停止"
        else
          toast_fn=err; toast_msg="停止服务失败"
        fi
        ;;
      3)
        if restart_cliproxy; then
          toast_fn=ok; toast_msg="服务已重启并就绪"
        else
          toast_fn=err; toast_msg="重启失败，请查看 [3 运行日志]"
        fi
        ;;
      4)
        if svc_ctl is-enabled; then
          svc_ctl disable && { toast_fn=ok; toast_msg="已关闭开机自启"; } || { toast_fn=err; toast_msg="关闭开机自启失败"; }
        else
          svc_ctl enable && { toast_fn=ok; toast_msg="已开启开机自启"; } || { toast_fn=err; toast_msg="开启开机自启失败"; }
        fi
        ;;
    esac
  done
}

view_status() {
  title "服务运行状态详情"
  local cur_domain auto_lbl allow_rem key_cnt key_badge
  cur_domain=$(get_domain)
  svc_ctl is-enabled && auto_lbl="${G}已开启${N}" || auto_lbl="${D}已关闭${N}"
  allow_rem=$(parse_yaml_val "allow-remote" "management")
  [[ -n $allow_rem ]] || allow_rem=$(parse_yaml_val "allow-remote" "remote-management")
  key_cnt=$(api_key_count)
  if ((key_cnt > 0)); then
    key_badge="${G}已配置 (${key_cnt} 个)${N}"
  else
    key_badge="${R}未配置 (若公网反代存在开放风险！)${N}"
  fi

  ui_kv "系统环境" "${OS_NAME}"
  ui_kv "当前版本" "$(fmt_ver "$(get_local_version)")"
  ui_kv "运行状态" "$(fmt_status)"
  ui_kv "开机自启" "$auto_lbl"
  ui_kv "监听地址" "${Y}${LISTEN_ADDR}${N} ${G}(仅限本机回环)${N}"
  ui_kv "反代域名" "${cur_domain:+${C}https://${cur_domain}${N}}${cur_domain:-${D}未设置${N}}"
  ui_kv "客户端 Key" "$key_badge"
  ui_kv "远程管理" "${allow_rem:-未配置}"
  ui_kv "授权凭据" "${G}$(auth_file_count)${N} 个 ${D}(${AUTH_DIR})${N}"
  ui_kv "配置文件" "${CONFIG_PATH}"
  echo
  printf "  ${B}本地端口监听检测:${N}\n"

  local sock_out=""
  if command -v ss >/dev/null 2>&1; then
    sock_out=$(ss -H -ltn "sport = :${LOCKED_PORT}" 2>/dev/null || ss -tulpn 2>/dev/null | grep -E ":${LOCKED_PORT}([[:space:]]|$)" || true)
  elif command -v netstat >/dev/null 2>&1; then
    sock_out=$(netstat -ltn 2>/dev/null | grep -E ":${LOCKED_PORT}([[:space:]]|$)" || true)
  fi

  if [[ -n $sock_out ]]; then
    printf '%s\n' "$sock_out" | sed 's/^/  /'
  elif curl -sS --max-time 1 -o /dev/null "http://${LISTEN_ADDR}/" 2>/dev/null; then
    printf "  ${G}tcp  LISTEN  %s${N} ${D}(HTTP 探测可达)${N}\n" "$LISTEN_ADDR"
  else
    printf "  ${D}(当前未检测到监听端口)${N}\n"
  fi
  pause
}

view_logs() {
  if [[ ! -f $SERVICE_PATH ]]; then
    warn "服务尚未安装！"
    pause
    return 1
  fi
  title "运行日志 (最近 50 条)"
  local out=""
  if [[ $OS_TYPE == alpine ]]; then
    [[ -f $LOG_FILE ]] || (umask 037 && : >"$LOG_FILE")
    out=$(tail -n 50 "$LOG_FILE" 2>/dev/null || true)
  else
    out=$(journalctl -u cliproxy -n 50 --no-pager -o cat 2>/dev/null || true)
  fi

  if [[ -n $out ]]; then
    printf "  %s\n%s\n  %s\n" "$RULE" "$out" "$RULE"
  else
    info "暂无运行日志"
  fi
  echo
  printf "  ${C}[f]${N} 进入实时跟踪模式   ${D}[任意键] 返回${N}\n"
  prompt_key || return 0
  if [[ $REPLY =~ ^[fF]$ ]]; then
    title "实时运行日志 (按 Ctrl+C 结束跟踪)"
    trap 'echo ""' INT
    if [[ $OS_TYPE == alpine ]]; then
      tail -n 30 -f "$LOG_FILE" || true
    else
      journalctl -u cliproxy -n 30 -f || true
    fi
    trap 'on_signal INT' INT
    pause
  fi
}

config_manage() {
  if [[ ! -f $CONFIG_PATH ]]; then
    warn "配置文件不存在，请先执行 [6 安装部署]！"
    pause
    return 1
  fi

  local toast_fn="" toast_msg=""
  while true; do
    title "密钥与配置管理"
    local cur_dom base_url keys_raw key_cnt allow_rem mgmt_state
    cur_dom=$(get_domain)
    base_url="${cur_dom:+https://${cur_dom}}"
    base_url="${base_url:-http://${LISTEN_ADDR}}"

    keys_raw=$(get_api_keys)
    key_cnt=$(api_key_count)
    allow_rem=$(parse_yaml_val "allow-remote" "management")
    [[ -n $allow_rem ]] || allow_rem=$(parse_yaml_val "allow-remote" "remote-management")
    mgmt_state=$(parse_yaml_val "secret-key" "management")
    [[ -n $mgmt_state ]] || mgmt_state=$(parse_yaml_val "secret-key" "remote-management")

    ui_kv "管理面板" "${C}${base_url}/management.html${N}"
    if [[ $mgmt_state == \$2[abxy]\$* ]]; then
      ui_kv "管理密钥" "${G}已配置（bcrypt 已加密）${N}"
    elif [[ -n $mgmt_state ]]; then
      ui_kv "管理密钥" "${Y}$(mask_secret "$mgmt_state")（待服务加密）${N}"
    else
      ui_kv "管理密钥" "${R}未设置（面板将返回 404）${N}"
    fi
    ui_kv "远程管理" "${allow_rem:-未设置}"
    ui_kv "客户端 Key" "${key_cnt} 个"
    echo
    printf "    ${C}[1]${N}  "; pad_print "查看 API Key 与端点" 22; printf "${C}[4]${N}  重置管理密钥\n"
    printf "    ${C}[2]${N}  "; pad_print "新增客户端 API Key" 22; printf "${C}[5]${N}  切换远程管理开关\n"
    printf "    ${C}[3]${N}  "; pad_print "删除客户端 API Key" 22; printf "${C}[6]${N}  校验并锁定本地端口\n"
    echo
    printf "    ${D}[0]  返回主菜单${N}\n"
    show_toast "$toast_fn" "$toast_msg"
    toast_fn=""
    toast_msg=""
    prompt_key || return

    case "$REPLY" in
      "" | ENTER) continue ;;
      0 | q | Q | ESC) return ;;
      1)
        title "端点与客户端 API Key 总览"
        ui_kv "管理面板" "${C}${base_url}/management.html${N}"
        ui_kv "OpenAI" "${C}${base_url}/v1/chat/completions${N}"
        ui_kv "Claude" "${C}${base_url}/v1/messages${N}"
        ui_kv "Gemini" "${C}${base_url}/v1beta/models${N}"
        echo
        printf "  ${B}客户端 API Keys (access.api-keys):${N}\n"
        if [[ -n $keys_raw ]]; then
          local i=1 k
          while IFS= read -r k; do
            [[ -n $k ]] || continue
            printf "    ${C}[%s]${N}  %s\n" "$i" "$k"
            ((i++))
          done <<<"$keys_raw"
        else
          warn "当前未配置任何客户端 API Key！"
        fi
        pause
        ;;
      2)
        echo
        local def_k new_k updated_keys
        def_k=$(gen_api_key)
        ask "请输入新的客户端 API Key" "$def_k" || continue
        new_k="$REPLY"
        if [[ $new_k =~ [[:cntrl:]] || -z ${new_k//[[:space:]]/} ]]; then
          toast_fn=err; toast_msg="API Key 不能为空或包含控制字符"
          continue
        fi
        create_backup "auto"
        updated_keys="${keys_raw:+${keys_raw}$'\n'}${new_k}"
        if replace_yaml_api_keys "$updated_keys"; then
          if svc_ctl is-active; then
            restart_cliproxy && { toast_fn=ok; toast_msg="已新增 API Key 并重启生效"; } || { toast_fn=err; toast_msg="已写入配置，但重启服务失败"; }
          else
            toast_fn=ok; toast_msg="已新增 API Key"
          fi
        else
          toast_fn=err; toast_msg="写入配置文件失败"
        fi
        ;;
      3)
        if [[ -z $keys_raw ]]; then
          toast_fn=warn; toast_msg="当前没有可删除的客户端 API Key"
          continue
        fi
        echo
        local karr=() i=1 pick new_list=""
        mapfile -t karr <<<"$keys_raw"
        for k in "${karr[@]}"; do
          printf "    ${C}[%s]${N}  %s\n" "$i" "$(mask_secret "$k")"
          ((i++))
        done
        printf "    ${D}[0]  取消${N}\n\n"
        ask_c "请选择要删除的序号 [1-${#karr[@]}]" "" || continue
        pick="$REPLY"
        if [[ ! $pick =~ ^[0-9]+$ ]] || ((10#$pick < 1 || 10#$pick > ${#karr[@]})); then
          toast_fn=err; toast_msg="编号无效"
          continue
        fi
        if ((${#karr[@]} == 1)); then
          confirm "这是最后一个客户端 API Key，删除后接口将无鉴权，确认继续？" || continue
        fi
        create_backup "auto"
        for ((i = 0; i < ${#karr[@]}; i++)); do
          ((i == 10#$pick - 1)) && continue
          new_list+="${new_list:+$'\n'}${karr[$i]}"
        done
        if replace_yaml_api_keys "$new_list"; then
          if svc_ctl is-active; then
            restart_cliproxy && { toast_fn=ok; toast_msg="已删除选中 API Key 并重启生效"; } || { toast_fn=err; toast_msg="已更新配置，但重启服务失败"; }
          else
            toast_fn=ok; toast_msg="已删除选中 API Key"
          fi
        else
          toast_fn=err; toast_msg="更新配置文件失败"
        fi
        ;;
      4)
        echo
        local def_mk="cpa_$(gen_random_secret 12)" new_mk mgmt_sec="management"
        grep -qE '^management:[[:space:]]*(#.*)?$' "$CONFIG_PATH" || {
          grep -qE '^remote-management:[[:space:]]*(#.*)?$' "$CONFIG_PATH" && mgmt_sec="remote-management"
        }
        ask "请输入新的管理后台密钥 (secret-key)" "$def_mk" || continue
        new_mk="$REPLY"
        if [[ $new_mk =~ [[:cntrl:]] || -z ${new_mk//[[:space:]]/} ]]; then
          toast_fn=err; toast_msg="管理密钥不能为空或包含控制字符"
          continue
        fi
        create_backup "auto"
        if update_yaml_scalar "$mgmt_sec" "secret-key" "$new_mk" 1; then
          if svc_ctl is-active; then
            restart_cliproxy && { toast_fn=ok; toast_msg="管理密钥已重置为 ${new_mk} 并重启生效"; } || { toast_fn=err; toast_msg="密钥已写入，但重启失败"; }
          else
            toast_fn=ok; toast_msg="管理密钥已重置为 ${new_mk}"
          fi
        else
          toast_fn=err; toast_msg="重置管理密钥失败"
        fi
        ;;
      5)
        local next_rem="true" mgmt_sec="management"
        grep -qE '^management:[[:space:]]*(#.*)?$' "$CONFIG_PATH" || {
          grep -qE '^remote-management:[[:space:]]*(#.*)?$' "$CONFIG_PATH" && mgmt_sec="remote-management"
        }
        [[ $allow_rem == "true" ]] && next_rem="false"
        create_backup "auto"
        if update_yaml_scalar "$mgmt_sec" "allow-remote" "$next_rem" 0; then
          if svc_ctl is-active; then
            restart_cliproxy && { toast_fn=ok; toast_msg="allow-remote 已切换为 ${next_rem} 并重启生效"; } || { toast_fn=err; toast_msg="已修改配置，但重启失败"; }
          else
            toast_fn=ok; toast_msg="allow-remote 已切换为 ${next_rem}"
          fi
        else
          toast_fn=err; toast_msg="修改 allow-remote 失败"
        fi
        ;;
      6)
        if enforce_local_binding; then
          if svc_ctl is-active; then
            restart_cliproxy && { toast_fn=ok; toast_msg="已锁定 ${LISTEN_ADDR} 并重启生效"; } || { toast_fn=err; toast_msg="已锁定端口，但重启失败"; }
          else
            toast_fn=ok; toast_msg="已确保配置锁定监听 ${LISTEN_ADDR}"
          fi
        else
          toast_fn=err; toast_msg="校验或写入配置失败"
        fi
        ;;
      *)
        toast_fn=err
        toast_msg="无效按键，请按 0-6"
        ;;
    esac
  done
}

backup_manage() {
  local toast_fn="" toast_msg=""
  while true; do
    title "备份、还原与版本回滚"
    printf "    ${C}[1]${N}  "; pad_print "创建完整备份" 20; printf "${C}[4]${N}  还原凭据归档\n"
    printf "    ${C}[2]${N}  "; pad_print "历史版本回滚" 20; printf "${C}[5]${N}  查看备份列表\n"
    printf "    ${C}[3]${N}  "; pad_print "还原配置文件" 20; printf "${R}[6]${N}  清空历史备份\n"
    echo
    printf "    ${D}[0]  返回主菜单${N}\n"
    show_toast "$toast_fn" "$toast_msg"
    toast_fn=""
    toast_msg=""
    prompt_key || return

    case "$REPLY" in
      "" | ENTER) continue ;;
      0 | q | Q | ESC) return ;;
      1)
        create_backup "manual"
        toast_fn=ok; toast_msg="完整备份已保存至 ${BACKUP_DIR}"
        ;;
      2)
        rollback_menu
        ;;
      3)
        local baks=() f i=1 pick
        [[ -d $BACKUP_DIR ]] && mapfile -t baks < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "config_*.yaml" 2>/dev/null | sort_backups_desc)
        if ((${#baks[@]} == 0)); then
          toast_fn=warn; toast_msg="暂无配置文件备份！"
          continue
        fi
        title "还原配置文件"
        for f in "${baks[@]}"; do
          printf "    ${C}[%s]${N}  %s\n" "$((i++))" "$(basename "$f")"
        done
        printf "\n    ${D}[0]  取消${N}\n\n"
        ask_c "请选择要恢复的编号 [1-${#baks[@]}]" "" || continue
        pick="$REPLY"
        if [[ $pick =~ ^[0-9]+$ ]] && ((10#$pick >= 1 && 10#$pick <= ${#baks[@]})); then
          if install -m 600 "${baks[$((10#$pick - 1))]}" "$CONFIG_PATH" && enforce_local_binding; then
            if svc_ctl is-active; then
              restart_cliproxy && { toast_fn=ok; toast_msg="配置已恢复、锁定 ${LISTEN_ADDR} 并重启生效"; } \
                || { toast_fn=err; toast_msg="配置已恢复，但服务重启失败，请检查日志"; }
            else
              toast_fn=ok; toast_msg="配置已恢复并锁定 ${LISTEN_ADDR}"
            fi
          else
            toast_fn=err; toast_msg="恢复配置失败"
          fi
        else
          toast_fn=err; toast_msg="编号无效"
        fi
        ;;
      4)
        local abaks=() f i=1 pick unpack_dir=""
        [[ -d $BACKUP_DIR ]] && mapfile -t abaks < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "auth_*.tar.gz" 2>/dev/null | sort_backups_desc)
        if ((${#abaks[@]} == 0)); then
          toast_fn=warn; toast_msg="暂无 OAuth 凭据归档备份！"
          continue
        fi
        title "还原凭据归档"
        for f in "${abaks[@]}"; do
          printf "    ${C}[%s]${N}  %s\n" "$((i++))" "$(basename "$f")"
        done
        printf "\n    ${D}[0]  取消${N}\n\n"
        ask_c "请选择要恢复的凭据归档 [1-${#abaks[@]}]" "" || continue
        pick="$REPLY"
        if [[ ! $pick =~ ^[0-9]+$ ]] || ((10#$pick < 1 || 10#$pick > ${#abaks[@]})); then
          toast_fn=err; toast_msg="编号无效"
          continue
        fi
        unpack_dir=$(mktemp -d "${RUN_TMP}/auth_res.XXXXXX") || continue
        if ! tar -tzf "${abaks[$((10#$pick - 1))]}" 2>/dev/null | grep -qE '^(\./)?auth(/|$)'; then
          rm -rf "$unpack_dir"
          toast_fn=err; toast_msg="归档结构异常（缺少 auth 目录）"
          continue
        fi
        if tar -zxf "${abaks[$((10#$pick - 1))]}" -C "$unpack_dir" 2>/dev/null && [[ -d $unpack_dir/auth ]]; then
          ensure_work_dirs
          if (($(auth_file_count) > 0)); then
            local pre_ts
            pre_ts=$(date +"%Y%m%d_%H%M%S")
            (umask 077 && tar -czf "${BACKUP_DIR}/auth_pre_restore_${pre_ts}.tar.gz" -C "$WORK_DIR" auth 2>/dev/null) || true
          fi
          rm -rf "${AUTH_DIR}.old"
          mv "$AUTH_DIR" "${AUTH_DIR}.old" 2>/dev/null || true
          if mv "$unpack_dir/auth" "$AUTH_DIR"; then
            rm -rf "${AUTH_DIR}.old" "$unpack_dir"
            chmod 700 "$AUTH_DIR"
            find "$AUTH_DIR" -type f -exec chmod 600 {} + 2>/dev/null || true
            if svc_ctl is-active; then
              restart_cliproxy && { toast_fn=ok; toast_msg="凭据已恢复并重启生效"; } || { toast_fn=err; toast_msg="凭据已恢复，但重启失败"; }
            else
              toast_fn=ok; toast_msg="凭据归档已恢复（共 $(auth_file_count) 个）"
            fi
          else
            mv "${AUTH_DIR}.old" "$AUTH_DIR" 2>/dev/null || true
            rm -rf "$unpack_dir"
            toast_fn=err; toast_msg="替换凭据目录失败"
          fi
        else
          rm -rf "$unpack_dir"
          toast_fn=err; toast_msg="解压凭据归档失败"
        fi
        ;;
      5)
        title "备份列表 (${BACKUP_DIR})"
        local list_all=() f sz
        if [[ -d $BACKUP_DIR ]]; then
          mapfile -t list_all < <(find "$BACKUP_DIR" -maxdepth 1 -type f 2>/dev/null | sort_backups_desc)
        fi
        if ((${#list_all[@]} == 0)); then
          info "当前暂无任何备份文件"
        else
          for f in "${list_all[@]}"; do
            sz=$(du -h "$f" 2>/dev/null | awk '{print $1}')
            printf "  "
            pad_print "$(basename "$f")" 44
            printf " %s\n" "${D}${sz:-?}${N}"
          done
        fi
        pause
        ;;
      6)
        echo
        if confirm "确认清空 ${BACKUP_DIR} 下的所有备份归档？"; then
          rm -rf "${BACKUP_DIR:?}"/* 2>/dev/null || true
          toast_fn=ok; toast_msg="所有备份归档已清空"
        else
          toast_fn=info; toast_msg="已取消"
        fi
        ;;
      *)
        toast_fn=err
        toast_msg="无效按键，请按 0-6"
        ;;
    esac
  done
}

proxy_guide() {
  title "域名反向代理配置指引"
  local cur_domain raw_domain new_domain
  cur_domain=$(get_domain)
  ui_kv "本地上游" "${Y}http://${LISTEN_ADDR}${N} ${G}(仅本机可访问)${N}"
  ui_kv "当前域名" "${cur_domain:-${D}未设置${N}}"
  echo
  while true; do
    ask "输入/更新反代域名 (回车保持${cur_domain:+ [${cur_domain}]，输入 - 清除})" "" || break
    raw_domain="$REPLY"
    [[ -z $raw_domain ]] && break
    if [[ $raw_domain == "-" ]]; then
      rm -f "$DOMAIN_FILE"
      cur_domain=""
      ok "已清除反代域名绑定"
      break
    fi
    if new_domain=$(sanitize_domain "$raw_domain") && [[ -n $new_domain ]]; then
      ensure_work_dirs
      (umask 077 && printf '%s\n' "$new_domain" >"$DOMAIN_FILE")
      cur_domain="$new_domain"
      ok "反代域名已更新: ${cur_domain}"
      break
    else
      err "域名格式无效（需为合法公网域名，不支持纯 IP 或 localhost）！"
    fi
  done

  local d="${cur_domain:-api.example.com}"
  echo
  printf "  ${C}▸${N} ${B}方案 A：Caddy 配置 (/etc/caddy/Caddyfile)${N}\n"
  cat <<CADDY
${d} {
    # 可选安全加固：限制管理面板与管理 API 仅指定 IP 访问（默认示例仅允许本机）
    # @admin path /management* /v0/management* /v8/management*
    # handle @admin {
    #     @blocked not remote_ip 127.0.0.1
    #     respond @blocked 403
    # }

    reverse_proxy ${LISTEN_ADDR} {
        flush_interval -1
    }
}
CADDY

  echo
  printf "  ${C}▸${N} ${B}方案 B：Nginx 配置 (支持 SSE 流式输出与 WebSocket)${N}\n"
  cat <<NGINX
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      '';
}

server {
    listen 80;
    listen 443 ssl http2; # 若 Nginx >= 1.25.1，可改为 listen 443 ssl; 并在下方加 http2 on;
    server_name ${d};

    # ssl_certificate     /path/to/fullchain.pem;
    # ssl_certificate_key /path/to/privkey.pem;
    client_max_body_size 50m;

    # 可选安全加固：限制管理面板与管理 API 仅指定 IP 访问
    # location ~ ^/(v0/|v8/)?management {
    #     allow 127.0.0.1;
    #     deny all;
    #     proxy_pass http://${LISTEN_ADDR};
    #     proxy_http_version 1.1;
    #     proxy_set_header Host \$host;
    #     proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    #     proxy_set_header X-Forwarded-Proto \$scheme;
    # }

    location / {
        proxy_pass http://${LISTEN_ADDR};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        proxy_connect_timeout 10s;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
NGINX
  pause
}

uninstall_cliproxy() {
  title "${R}卸载与彻底清理${N}"
  local auth_cnt
  auth_cnt=$(auth_file_count)
  warn "此操作将停止并移除 CLIProxyAPI 服务、主程序、配置与备份归档！"
  ((auth_cnt > 0)) && warn "当前存在 ${auth_cnt} 个 OAuth 授权凭据，稍后可单独选择是否保留"
  echo
  ui_kv "主程序" "$BIN_PATH"
  ui_kv "配置文件" "$CONFIG_PATH"
  ui_kv "服务单元" "${SERVICE_PATH:-未识别}"
  ui_kv "快捷命令" "$SCRIPT_LINK"
  ui_kv "备份目录" "$BACKUP_DIR"
  ui_kv "凭据目录" "${AUTH_DIR}（${auth_cnt} 个）"
  [[ $OS_TYPE == alpine ]] && ui_kv "日志文件" "$LOG_FILE"
  echo

  confirm "确认卸载 CLIProxyAPI？" || return 0
  echo
  info "正在停止服务并清理文件…"
  svc_ctl stop || true
  svc_ctl disable || true
  if [[ $OS_TYPE == alpine ]]; then
    rm -f "$SERVICE_PATH" "$LOG_FILE" "${LOG_FILE}.tmp" /etc/logrotate.d/cliproxy
  else
    rm -f "$SERVICE_PATH"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed cliproxy >/dev/null 2>&1 || true
  fi
  rm -f "$BIN_PATH" "${BIN_PATH}.new" "$CONFIG_PATH" "$DOMAIN_FILE" "$VERSION_FILE" "${WORK_DIR}/config.example.yaml" "$SCRIPT_LINK"
  rm -rf "$BACKUP_DIR"
  LOCAL_VER=""

  if ((auth_cnt > 0)); then
    if confirm "是否同时删除 ${AUTH_DIR} 下的所有授权凭据？"; then
      rm -rf "$WORK_DIR"
      ok "已彻底卸载并清理全部凭据。"
    else
      ok "已卸载程序，授权凭据已保留于: ${AUTH_DIR}"
    fi
  else
    rm -rf "$WORK_DIR" 2>/dev/null || true
    ok "CLIProxyAPI 已彻底卸载。"
  fi
  exit 0
}

# ───────── 主界面与程序入口 ─────────
header() {
  ui_refresh
  clr
  local ver cur_dom dom_lbl auth_cnt key_cnt key_lbl auto_lbl fill
  ver=$(get_local_version)
  cur_dom=$(get_domain)
  dom_lbl="${cur_dom:-未绑定}"
  auth_cnt=$(auth_file_count)
  key_cnt=$(api_key_count)
  ((key_cnt > 0)) && key_lbl="API Key ${key_cnt} 个" || key_lbl="API Key 未设"
  svc_ctl is-enabled && auto_lbl="开启" || auto_lbl="关闭"

  local st_plain v_lbl="" shortcut_tag=""
  if svc_ctl is-active; then
    st_plain="● 运行中"
  elif [[ -f $SERVICE_PATH && -x $BIN_PATH ]]; then
    st_plain="○ 已停止"
  elif [[ -x $BIN_PATH ]]; then
    st_plain="○ 未注册服务"
  else
    st_plain="○ 未安装"
  fi
  [[ ! $ver =~ ^(未安装|未知)$ ]] && v_lbl="v${ver}"
  [[ -x $SCRIPT_LINK ]] && shortcut_tag="cpapi"

  _str_width "$st_plain"
  local st_w="$_W"
  local title_len=$((17 + st_w + (${#v_lbl} > 0 ? ${#v_lbl} + 2 : 0) + (${#shortcut_tag} > 0 ? ${#shortcut_tag} + 3 : 0)))
  fill=$((UI_W - title_len))
  ((fill < 2)) && fill=2

  printf "${C}╭─${N} ${B}CLIProxyAPI${N}  %s" "$(fmt_status)"
  if [[ -n $v_lbl ]]; then printf "  ${D}%s${N}" "$v_lbl"; fi
  if [[ -n $shortcut_tag ]]; then printf " ${D}· %s${N}" "$shortcut_tag"; fi
  printf " ${C}%s${N}\n" "$(_repeat_ch '─' "$fill")"

  printf "${C}│${N}  ${D}%s · %s · 域名: %s${N}\n" "$LISTEN_ADDR" "${OS_SHORT:-$OS_NAME}" "$dom_lbl"
  printf "${C}│${N}  ${D}凭据 %s 个 · %s · 自启 %s${N}\n" "$auth_cnt" "$key_lbl" "$auto_lbl"
  printf "${C}╰%s${N}\n\n" "$(_repeat_ch '─' $((UI_W - 1)))"
}

title() {
  header
  printf "  ${C}▸${N} ${B}%s${N}\n\n" "$1"
}

bye() {
  clr
  info "$1"
  exit 0
}

main() {
  [[ -t 0 ]] || {
    echo "[错误] 请勿通过管道直接执行，请使用 bash <(curl -fsSL ...) 运行" >&2
    exit 1
  }
  init_runtime
  check_root
  check_os
  acquire_lock
  ensure_deps || exit 1
  setup_shortcut

  local toast_fn="" toast_msg=""
  while true; do
    header
    printf "  "
    pad_print "日常运维" 28 "$D" "$N"
    printf "${D}%s${N}\n" "部署与维护"
    printf "    ${C}[1]${N}  "; pad_print "服务控制" 23; printf "${C}[6]${N}  安装部署\n"
    printf "    ${C}[2]${N}  "; pad_print "运行状态" 23; printf "${C}[7]${N}  平滑升级\n"
    printf "    ${C}[3]${N}  "; pad_print "运行日志" 23; printf "${C}[8]${N}  备份回滚\n"
    printf "    ${C}[4]${N}  "; pad_print "密钥配置" 23; printf "${R}[9]${N}  彻底卸载\n"
    printf "    ${C}[5]${N}  "; pad_print "反代指引" 23; printf "${D}[0]  退出面板${N}\n"
    echo
    printf "  %s\n" "$RULE"
    printf "  ${D}单键直达 · 按 [0/q/Esc] 退出${N}\n"
    show_toast "$toast_fn" "$toast_msg"
    toast_fn=""
    toast_msg=""

    prompt_key || bye "已退出 CLIProxyAPI 管理面板"
    case "$REPLY" in
      "" | ENTER) continue ;;
      0 | q | Q | ESC)
        if [[ -x $SCRIPT_LINK ]]; then
          bye "已退出 CLIProxyAPI 管理面板（输入 cpapi 可再次打开）"
        else
          bye "已退出 CLIProxyAPI 管理面板"
        fi
        ;;
      1) service_menu ;;
      2) view_status ;;
      3) view_logs ;;
      4) config_manage ;;
      5) proxy_guide ;;
      6) deploy ;;
      7) upgrade_lossless ;;
      8) backup_manage ;;
      9) uninstall_cliproxy ;;
      *)
        toast_fn=err
        toast_msg="无效按键，请按 0-9"
        ;;
    esac
  done
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
