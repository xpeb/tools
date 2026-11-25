#!/usr/bin/env sh
# shellcheck shell=bash
# CLIProxyAPI 运维管理脚本 (Debian / Ubuntu / Alpine)
# 安全策略: 强制绑定 127.0.0.1:8317，禁止公网直连，支持域名反代

if [ -z "${BASH_VERSION:-}" ]; then
  [ -f /etc/alpine-release ] && ! command -v bash >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ] && apk add --no-cache bash >/dev/null 2>&1
  [ -f "$0" ] && command -v bash >/dev/null 2>&1 && exec bash "$0" "$@"
  echo "[错误] 请先安装 bash 并使用 bash 运行此脚本！" >&2
  exit 1
fi

set -o pipefail

# 补齐 su 切换 root 后可能缺失的 sbin 路径
for _p in /usr/local/sbin /usr/sbin /sbin /usr/local/bin /usr/bin /bin; do
  case ":${PATH:-}:" in
    *":${_p}:"*) ;;
    *) PATH="${PATH:+${PATH}:}${_p}" ;;
  esac
done
unset _p
export PATH

SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "${BASH_SOURCE[0]:-$0}")"
SCRIPT_LINK="/usr/local/bin/cpapi"

# ───────── UI ─────────
B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'
info() { printf '%s[信息]%s %s\n' "$D" "$N" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$Y" "$N" "$*"; }
ok() { printf '%s[正确]%s %s\n' "$G" "$N" "$*"; }
err() { printf '%s[错误]%s %s\n' "$R" "$N" "$*" >&2; }
pause() {
  read -rsp $'按回车返回…' _ || true
  echo
}

WORK_DIR="/root/cliproxyapi"
AUTH_DIR="${WORK_DIR}/auth"
BIN_PATH="${WORK_DIR}/cli-proxy-api"
CONFIG_PATH="${WORK_DIR}/config.yaml"
DOMAIN_FILE="${WORK_DIR}/.domain"
BACKUP_DIR="${WORK_DIR}/backup"
LOG_FILE="/var/log/cliproxy.log"
OFFICIAL_REPO="router-for-me/CLIProxyAPI"

LOCKED_HOST="127.0.0.1"
LOCKED_PORT="8317"
LISTEN_ADDR="${LOCKED_HOST}:${LOCKED_PORT}"
TMP_EXTRACT_DIR=""
LAST_BIN_BACKUP=""

GH_PROXY="${GH_PROXY:+${GH_PROXY%/}/}"

cleanup_tmp() {
  [[ -n "${TMP_EXTRACT_DIR:-}" && -d "$TMP_EXTRACT_DIR" ]] && rm -rf -- "$TMP_EXTRACT_DIR"
  TMP_EXTRACT_DIR=""
  rm -f "${CONFIG_PATH}.tmp."* 2>/dev/null || true
}

on_signal() {
  local sig="$1"
  cleanup_tmp
  trap - "$sig" EXIT
  kill -s "$sig" "$$" 2>/dev/null || exit 130
}

trap cleanup_tmp EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM
trap 'on_signal HUP' HUP

# --- UI 输出与安全交互组件 ---
kv() { printf '%s%-10s%s  %b\n' "$D" "$1" "$N" "$2"; }

header() {
  clear 2>/dev/null || true
  local ver cur_dom dom_badge
  ver=$(get_local_version)
  cur_dom=$(get_domain)
  dom_badge="${cur_dom:-未绑定}"
  if [[ "$ver" =~ ^(未安装|未知)$ ]]; then
    printf '%sCLIProxyAPI%s  %s  %s快捷命令: cpapi%s\n' "$B" "$N" "$(fmt_status)" "$D" "$N"
  else
    printf '%sCLIProxyAPI%s  %s  %sv%s · 快捷命令: cpapi%s\n' "$B" "$N" "$(fmt_status)" "$D" "$ver" "$N"
  fi
  printf '%s%s · %s · 域名: %s · 凭据: %s 个%s\n' \
    "$D" "${OS_SHORT:-${OS_NAME:-Linux}}" "$LISTEN_ADDR" "$dom_badge" "$(auth_file_count)" "$N"
}

title() {
  header
  printf '%s▸%s %s%s%s\n' "$C" "$N" "$B" "$1" "$N"
}

bye() {
  clear 2>/dev/null || true
  info "$1"
  exit 0
}

# --- 0. 权限与环境初始化 ---
check_root() {
  [[ "$EUID" -eq 0 ]] || {
    err "请使用 root 用户运行此脚本！"
    exit 1
  }
}

check_os() {
  [[ -f /etc/os-release ]] || {
    err "无法识别操作系统！"
    exit 1
  }
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID,,}"
  OS_NAME="${PRETTY_NAME:-$OS_ID}"
  OS_SHORT="${NAME:-$OS_ID} ${VERSION_ID:-}"
  OS_SHORT="${OS_SHORT% }"
  case "$OS_ID" in
    debian | ubuntu) SERVICE_PATH="/etc/systemd/system/cliproxy.service" ;;
    alpine) SERVICE_PATH="/etc/init.d/cliproxy" ;;
    *)
      err "不支持当前系统 (${OS_NAME})，仅支持 Debian / Ubuntu / Alpine！"
      exit 1
      ;;
  esac
}

setup_shortcut() {
  [[ "$SCRIPT_SELF" == /* && -f "$SCRIPT_SELF" && ! "$SCRIPT_SELF" =~ ^/(dev|proc|usr/s?bin|s?bin)/ ]] || return 0
  mkdir -p /usr/local/bin
  if [[ "$(readlink -f "$SCRIPT_LINK" 2>/dev/null)" != "$SCRIPT_SELF" ]]; then
    ln -sf "$SCRIPT_SELF" "$SCRIPT_LINK" 2>/dev/null && chmod +x "$SCRIPT_LINK" 2>/dev/null || true
  fi
}

# --- 1. 核心工具函数 ---
ensure_deps() {
  local pkgs=() cmd
  for cmd in curl tar awk; do command -v "$cmd" &>/dev/null || pkgs+=("$cmd"); done
  [[ -z "$(ls -A /etc/ssl/certs 2>/dev/null)" ]] && pkgs+=("ca-certificates")
  [[ ${#pkgs[@]} -eq 0 ]] && return 0
  info "正在安装基础依赖: ${pkgs[*]} ..."
  if [[ "$OS_ID" == "alpine" ]]; then
    apk add --no-cache "${pkgs[@]}"
  else
    DEBIAN_FRONTEND=noninteractive apt-get update -y && DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  fi
}

ensure_work_dirs() {
  mkdir -p "$WORK_DIR" "$AUTH_DIR" && chmod 700 "$WORK_DIR" "$AUTH_DIR"
}

parse_yaml_val() {
  [[ -f "$CONFIG_PATH" ]] || return 0
  awk -v k="$1" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (substr(line, 1, length(k)) == k) {
        rest = substr(line, length(k) + 1)
        if (rest ~ /^[[:space:]]*:/) {
          sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
          q = substr(rest, 1, 1)
          if (q == "\"") {
            rest = substr(rest, 2)
            out = ""; esc = 0
            for (i = 1; i <= length(rest); i++) {
              c = substr(rest, i, 1)
              if (esc) { out = out c; esc = 0 }
              else if (c == "\\") { esc = 1 }
              else if (c == "\"") { break }
              else { out = out c }
            }
            print out; exit
          } else if (q == "'"'"'") {
            rest = substr(rest, 2)
            sub(/'"'"'.*$/, "", rest)
            print rest; exit
          } else {
            sub(/[[:space:]]+#.*$/, "", rest)
            sub(/[[:space:]]+$/, "", rest)
            print rest; exit
          }
        }
      }
    }
  ' "$CONFIG_PATH" 2>/dev/null
}

get_domain() { [[ -f "$DOMAIN_FILE" ]] && head -n 1 "$DOMAIN_FILE" 2>/dev/null | tr -d '[:space:]'; }
auth_file_count() { [[ -d "$AUTH_DIR" ]] && find "$AUTH_DIR" -type f 2>/dev/null | wc -l | tr -d '[:space:]' || echo 0; }

sanitize_domain() {
  local d="${1//[[:space:]]/}"
  d="${d,,}"
  d="${d#http://}"
  d="${d#https://}"
  d="${d%%/*}"
  d="${d%%:*}"
  [[ -z "$d" ]] && {
    echo ""
    return 0
  }
  if ((${#d} <= 253)) && [[ "$d" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$d" != *..* && "$d" != *.-* && "$d" != *-.* ]]; then
    echo "$d"
    return 0
  fi
  return 1
}

enforce_local_binding() {
  [[ -f "$CONFIG_PATH" ]] || return 0
  local tmp
  tmp=$(umask 077 && mktemp "${CONFIG_PATH}.tmp.XXXXXX") || return 1
  if awk -v h="$LOCKED_HOST" -v p="$LOCKED_PORT" '
        /^server:[[:space:]]*(#.*)?$/ { print "server:\n  host: \"" h "\"\n  port: " p; s=1; has_h=1; has_p=1; next }
        /^[^[:space:]#]/ { s=0 }
        s && /^[[:space:]]+(host|port):[[:space:]]*/ { next }
        !s && /^host:[[:space:]]*/ { print "host: \"" h "\""; has_h=1; next }
        !s && /^port:[[:space:]]*/ { print "port: " p; has_p=1; next }
        { print }
        END {
          if (!has_h && !has_p) print "\nserver:\n  host: \"" h "\"\n  port: " p
          else {
            if (!has_h) print "host: \"" h "\""
            if (!has_p) print "port: " p
          }
        }
    ' "$CONFIG_PATH" >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$CONFIG_PATH" && chmod 600 "$CONFIG_PATH"
  else
    rm -f "$tmp"
    return 1
  fi
}

write_config() {
  local k="${1//\\/\\\\}"
  k="${k//\"/\\\"}"
  ensure_work_dirs
  (
    umask 077 && cat >"$CONFIG_PATH" <<YAML
config-version: 8

server:
  host: "${LOCKED_HOST}"
  port: ${LOCKED_PORT}

management:
  allow-remote: true
  secret-key: "${k}"

oauth:
  auth-dir: "auth"
YAML
  )
}

replace_binary() {
  rm -f "${BIN_PATH}.new"
  install -m 755 "$1" "${BIN_PATH}.new" && mv -f "${BIN_PATH}.new" "$BIN_PATH"
}

svc_ctl() {
  if [[ "$OS_ID" == "alpine" ]]; then
    rc-service cliproxy "$1" >/dev/null 2>&1
  else
    case "$1" in
      status) systemctl is-active --quiet cliproxy 2>/dev/null ;;
      restart) systemctl daemon-reload && systemctl restart cliproxy ;;
      *) systemctl "$1" cliproxy 2>/dev/null ;;
    esac
  fi
}

wait_for_service() {
  local i=12
  while ((i-- > 0)); do
    if svc_ctl status && { (echo >/dev/tcp/"$LOCKED_HOST"/"$LOCKED_PORT") 2>/dev/null || curl -sS --max-time 1 "http://${LISTEN_ADDR}/" >/dev/null 2>&1; }; then
      return 0
    fi
    sleep 0.5
  done
  svc_ctl status
}

fmt_status() {
  if svc_ctl status; then
    printf '%s● 运行中%s' "$G" "$N"
  elif [[ -f "$SERVICE_PATH" || -x "$BIN_PATH" ]]; then
    printf '%s● 已停止%s' "$R" "$N"
  else
    printf '%s○ 未安装%s' "$D" "$N"
  fi
}

restart_cliproxy() { [[ -f "$SERVICE_PATH" ]] && enforce_local_binding && svc_ctl restart && wait_for_service; }

manage_service() {
  [[ -f "$SERVICE_PATH" ]] || {
    warn "服务尚未安装，请先执行 [5 安装部署]。"
    pause
    return 1
  }
  case "$1" in
    start)
      if svc_ctl status; then
        info "服务已在运行中。"
      elif enforce_local_binding && svc_ctl start && wait_for_service; then
        ok "服务已启动！"
      else
        err "启动失败，请查看日志。"
      fi
      ;;
    stop)
      if ! svc_ctl status; then
        info "服务当前已处于停止状态。"
      elif svc_ctl stop; then
        ok "服务已停止。"
      else
        err "停止服务失败，请查看日志。"
      fi
      ;;
    restart)
      if restart_cliproxy; then
        ok "服务已重启！"
      else
        err "重启失败，请查看日志。"
      fi
      ;;
  esac
  pause
}

# --- 2. 版本与二进制管理 ---
parse_binary_version() {
  local target="${1:-$BIN_PATH}" out
  [[ -x "$target" ]] || return 0
  out=$("$target" --version 2>&1 || "$target" --help 2>&1 || true)
  [[ "$out" =~ ([0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.]+)?) ]] && echo "${BASH_REMATCH[1]}"
}

get_local_version() {
  [[ -x "$BIN_PATH" ]] || {
    echo "未安装"
    return
  }
  local v
  v=$(parse_binary_version "$BIN_PATH" 2>/dev/null)
  echo "${v:-未知}"
}

fmt_ver() {
  [[ "$1" =~ ^(未安装|未知)$ ]] && printf '%s%s%s' "$D" "$1" "$N" || printf '%sv%s%s' "$C" "$1" "$N"
}

fetch_release_info() {
  local arch_p arch_a variant="" api_json dl_urls hdr eff_url a
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
      err "不支持的架构: $(uname -m)"
      return 1
      ;;
  esac
  [[ "$OS_ID" == "alpine" ]] && variant="_no-plugin"

  local rel_url="${GH_PROXY}https://github.com/${OFFICIAL_REPO}/releases/latest"
  local api_url="${GH_PROXY}https://api.github.com/repos/${OFFICIAL_REPO}/releases/latest"
  LATEST_TAG=""
  CANDIDATE_URLS=()

  api_json=$(curl -fsSL --connect-timeout 10 --max-time 15 "$api_url" 2>/dev/null || true)
  if [[ -n "$api_json" ]]; then
    LATEST_TAG=$(echo "$api_json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4)
    dl_urls=$(echo "$api_json" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4 | grep -i "linux" | grep -E "(${arch_p}|${arch_a})" | grep -E '\.(tar\.gz|tgz)$' || true)
    if [[ -n "$dl_urls" ]]; then
      local matched=""
      [[ -n "$variant" ]] && matched=$(echo "$dl_urls" | grep -F "$variant" | head -n 1)
      [[ -z "$matched" ]] && matched=$(echo "$dl_urls" | grep -v "no-plugin" | head -n 1)
      [[ -z "$matched" ]] && matched=$(echo "$dl_urls" | head -n 1)
      [[ -n "$matched" ]] && CANDIDATE_URLS+=("${GH_PROXY}${matched#"${GH_PROXY}"}")
    fi
  fi

  if [[ -z "$LATEST_TAG" ]]; then
    hdr=$(curl -sI --connect-timeout 10 --max-time 15 "$rel_url" 2>/dev/null || true)
    LATEST_TAG=$(echo "$hdr" | awk -F'/tag/' 'tolower($0) ~ /^location:.*\/tag\// {gsub(/[\r\n?[:space:]].*/, "", $2); print $2; exit}')
  fi
  if [[ -z "$LATEST_TAG" ]]; then
    eff_url=$(curl -sSL -o /dev/null -w '%{url_effective}' --connect-timeout 10 --max-time 15 "$rel_url" 2>/dev/null || true)
    LATEST_TAG=$(echo "$eff_url" | awk -F'/tag/' '/\/tag\// {gsub(/[\r\n?[:space:]].*/, "", $2); print $2; exit}')
  fi

  [[ -n "$LATEST_TAG" ]] || {
    err "无法获取最新版本信息，请检查网络或配置 GH_PROXY！"
    return 1
  }
  LATEST_VER="${LATEST_TAG#v}"

  local base_dl="${GH_PROXY}https://github.com/${OFFICIAL_REPO}/releases/download/${LATEST_TAG}"
  for a in "$arch_p" "$arch_a"; do
    [[ -n "$variant" ]] && CANDIDATE_URLS+=("${base_dl}/CLIProxyAPI_${LATEST_VER}_linux_${a}${variant}.tar.gz")
    CANDIDATE_URLS+=("${base_dl}/CLIProxyAPI_${LATEST_VER}_linux_${a}.tar.gz")
  done
}

install_release_binary() {
  local found="" test_out="" example_cfg="" url dl_ok=0
  cleanup_tmp
  TMP_EXTRACT_DIR=$(mktemp -d)
  ensure_work_dirs

  info "正在下载官方程序包 (v${LATEST_VER})..."
  for url in "${CANDIDATE_URLS[@]}"; do
    if curl -fsSL --connect-timeout 10 --max-time 180 -o "${TMP_EXTRACT_DIR}/pkg.tar.gz" "$url" 2>/dev/null \
      && tar -zxf "${TMP_EXTRACT_DIR}/pkg.tar.gz" -C "$TMP_EXTRACT_DIR" 2>/dev/null; then
      dl_ok=1
      break
    fi
    rm -f "${TMP_EXTRACT_DIR}/pkg.tar.gz"
  done
  [[ "$dl_ok" -eq 1 ]] || {
    err "程序包下载或解压失败，请检查网络连接！"
    cleanup_tmp
    return 1
  }

  found=$(find "$TMP_EXTRACT_DIR" -type f \( -iname "cli-proxy-api*" -o -iname "cliproxyapi*" \) ! -name "*.yaml" ! -name "*.yml" ! -name "*.md" ! -name "*.txt" ! -name "*.tar.gz" ! -name "*.sh" | head -n 1)
  if [[ -n "$found" ]]; then
    chmod +x "$found"
  else
    err "压缩包内未找到可执行主程序！"
    cleanup_tmp
    return 1
  fi

  if ! test_out=$("$found" --help 2>&1) && ! test_out=$("$found" --version 2>&1); then
    err "二进制兼容性预检未通过：\n${test_out}"
    cleanup_tmp
    return 1
  fi

  replace_binary "$found" || {
    err "替换主程序文件失败！"
    cleanup_tmp
    return 1
  }

  example_cfg=$(find "$TMP_EXTRACT_DIR" -type f -name "config.example.yaml" | head -n 1)
  [[ -n "$example_cfg" ]] && install -m 600 "$example_cfg" "${WORK_DIR}/config.example.yaml" 2>/dev/null || true
  cleanup_tmp
  ok "主程序安装完成 (v${LATEST_VER})"
}

# --- 3. 备份与轮转 ---
prune_old_backups() {
  local pat list=() i
  for pat in "$@"; do
    mapfile -t list < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$pat" 2>/dev/null | sort -r)
    for ((i = 3; i < ${#list[@]}; i++)); do rm -f -- "${list[$i]}"; done
  done
}

create_backup() {
  local mode="${1:-auto}" skip_prune="${2:-0}" ts cur_v v_tag=""
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  ts=$(date +"%Y%m%d_%H%M%S")
  cur_v=$(get_local_version)
  [[ ! "$cur_v" =~ ^(未安装|未知)$ ]] && v_tag="_v${cur_v}"

  LAST_BIN_BACKUP=""
  [[ -f "$CONFIG_PATH" ]] && install -m 600 "$CONFIG_PATH" "${BACKUP_DIR}/config_${mode}${v_tag}_${ts}.yaml"
  if [[ -f "$BIN_PATH" ]]; then
    LAST_BIN_BACKUP="${BACKUP_DIR}/cli-proxy-api_${mode}${v_tag}_${ts}"
    cp -a "$BIN_PATH" "$LAST_BIN_BACKUP"
  fi
  if [[ "$mode" == "manual" ]] && (($(auth_file_count) > 0)); then
    (umask 077 && tar -czf "${BACKUP_DIR}/auth_manual_${ts}.tar.gz" -C "$WORK_DIR" auth 2>/dev/null) || true
  fi
  if [[ "$skip_prune" != "1" ]]; then
    prune_old_backups "config_auto_*" "cli-proxy-api_auto_*"
  fi
}

# --- 4. 业务功能模块 ---
deploy() {
  ensure_deps || {
    pause
    return 1
  }
  title "安装与配置向导"

  if [[ -x "$BIN_PATH" && -f "$CONFIG_PATH" ]]; then
    warn "检测到已安装 CLIProxyAPI ($(fmt_ver "$(get_local_version)"))"
    printf '%b\n' "${C}1${N}  平滑升级 ${D}(保留现有配置与凭据)${N}"
    printf '%b\n' "${C}2${N}  重新配置 ${D}(备份并重写配置)${N}"
    printf '%b\n' "${C}0${N}  返回"
    local dep_opt
    while true; do
      read -rp "请选择 [0-2，默认 1]: " dep_opt || return
      case "${dep_opt:-1}" in
        1)
          upgrade_lossless
          return
          ;;
        2)
          create_backup "auto"
          break
          ;;
        0 | q | Q) return ;;
        *) err "无效选项，请输入 0-2！" ;;
      esac
    done
  fi

  local old_key old_domain SECRET_KEY default_key raw_domain PROXY_DOMAIN=""
  old_key=$(parse_yaml_val "secret-key")
  [[ "$old_key" == \$2[abxy]\$* ]] && old_key=""
  old_domain=$(get_domain)

  info "安全策略: 固定监听本地回环 ${Y}http://${LISTEN_ADDR}${N} (禁止外部直连)"
  default_key=${old_key:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 24 || true)}
  [[ -z "$default_key" ]] && default_key="cpa_$(date +%s)_secret"

  while true; do
    read -rp "管理密钥 Secret Key [默认: ${default_key}]: " SECRET_KEY || return 1
    SECRET_KEY=${SECRET_KEY:-$default_key}
    [[ ! "$SECRET_KEY" =~ [[:cntrl:]] ]] && break
    err "密钥不能包含控制字符，请重新输入！"
  done

  while true; do
    read -rp "反代域名 (如 api.example.com，留空跳过)${old_domain:+ [默认: $old_domain]}: " raw_domain || return 1
    PROXY_DOMAIN=$(sanitize_domain "${raw_domain:-$old_domain}") && break
    err "域名格式无效，请重新输入！"
  done

  ensure_work_dirs
  if [[ -n "$PROXY_DOMAIN" ]]; then
    (umask 077 && echo "$PROXY_DOMAIN" >"$DOMAIN_FILE")
  else
    rm -f "$DOMAIN_FILE"
  fi
  svc_ctl stop || true

  local update_bin="y"
  [[ -x "$BIN_PATH" ]] && { read -rp "是否更新主程序至官方最新版？[Y/n]: " update_bin || return 1; }
  if [[ ! "$update_bin" =~ ^[nN]$ ]]; then
    if ! fetch_release_info || ! install_release_binary; then
      pause
      return 1
    fi
  fi

  write_config "$SECRET_KEY"

  if [[ "$OS_ID" == "alpine" ]]; then
    cat <<INIT >"$SERVICE_PATH"
#!/sbin/openrc-run
name="CLIProxyAPI"
supervisor="supervise-daemon"
respawn_delay=3
directory="${WORK_DIR}"
command="${BIN_PATH}"
command_args="--config ${CONFIG_PATH}"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
rc_ulimit="-n 65535"
depend() { need net; after firewall; }
INIT
    chmod +x "$SERVICE_PATH"
    [[ -d /etc/logrotate.d ]] && cat <<LOGROTATE >/etc/logrotate.d/cliproxy
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
    rc-update add cliproxy default >/dev/null 2>&1 || true
    svc_ctl restart || svc_ctl start
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
ExecStart=${BIN_PATH} --config ${CONFIG_PATH}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$SERVICE_PATH"
    systemctl daemon-reload && systemctl enable --now cliproxy >/dev/null 2>&1
  fi

  wait_for_service || {
    err "服务启动失败，请通过 [4 实时日志] 排查原因！"
    pause
    return 1
  }

  local base_url="${PROXY_DOMAIN:+https://${PROXY_DOMAIN}}"
  base_url="${base_url:-http://${LISTEN_ADDR}}"

  title "部署完成"
  kv "当前版本" "$(fmt_ver "$(get_local_version)") (${OS_NAME})"
  kv "运行状态" "$(fmt_status)"
  kv "本地监听" "${Y}http://${LISTEN_ADDR}${N} ${G}(公网已隔离)${N}"
  kv "反代域名" "${PROXY_DOMAIN:+${C}https://${PROXY_DOMAIN}${N}}${PROXY_DOMAIN:-${D}未设置 (可在菜单 10 配置)${N}}"
  kv "管理面板" "${C}${base_url}/management.html${N}"
  kv "管理密钥" "${G}${SECRET_KEY}${N}"
  kv "OpenAI" "${C}${base_url}/v1/chat/completions${N}"
  kv "Claude" "${C}${base_url}/v1/messages${N}"
  kv "Models" "${C}${base_url}/v1/models${N}"
  pause
}

upgrade_lossless() {
  ensure_deps || {
    pause
    return 1
  }
  title "CLIProxyAPI 无损平滑升级"

  [[ -x "$BIN_PATH" ]] || {
    warn "尚未安装主程序，即将跳转至安装向导..."
    sleep 1
    deploy
    return
  }

  local local_ver confirm_up="y"
  local_ver=$(get_local_version)
  kv "本地版本" "$(fmt_ver "$local_ver")"
  info "正在查询 GitHub 最新发行版..."
  fetch_release_info || {
    pause
    return 1
  }
  kv "官方最新" "${G}v${LATEST_VER}${N}"

  if [[ "$local_ver" == "$LATEST_VER" ]]; then
    ok "当前已是最新版本。"
    read -rp "是否强制重新下载覆盖安装？[y/N]: " confirm_up || return 0
    [[ "$confirm_up" =~ ^[yY]$ ]] || return 0
  else
    read -rp "确认平滑升级至 v${LATEST_VER}？[Y/n]: " confirm_up || return 0
    [[ ! "$confirm_up" =~ ^[nN]$ ]] || return 0
  fi

  create_backup "auto" "1"
  install_release_binary || {
    pause
    return 1
  }

  info "正在重启服务..."
  if ! restart_cliproxy; then
    err "新版本启动异常，正在自动回滚..."
    [[ -n "$LAST_BIN_BACKUP" && -f "$LAST_BIN_BACKUP" ]] && replace_binary "$LAST_BIN_BACKUP"
    if restart_cliproxy; then
      ok "已回滚至旧版本 ($(fmt_ver "$(get_local_version)"))"
    else
      err "回滚启动失败，请检查日志！"
    fi
    pause
    return 1
  fi

  prune_old_backups "config_auto_*" "cli-proxy-api_auto_*"
  ok "平滑升级成功：${Y}v${local_ver}${N} -> ${G}v$(get_local_version)${N}"
  pause
}

rollback() {
  title "历史版本回滚"
  local list=() f idx=1 bver choice
  [[ -d "$BACKUP_DIR" ]] && mapfile -t list < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "cli-proxy-api_*" 2>/dev/null | sort -r)
  [[ ${#list[@]} -gt 0 ]] || {
    warn "暂无可用的主程序历史备份！"
    pause
    return 1
  }

  kv "当前版本" "$(fmt_ver "$(get_local_version)")"
  for f in "${list[@]}"; do
    bver=$(parse_binary_version "$f" 2>/dev/null || echo "未知")
    printf '%b\n' "${C}$((idx++))${N}  $(printf '%-40s' "$(basename "$f")") $(fmt_ver "$bver")"
  done
  printf '%b\n' "${C}0${N}  返回"
  read -rp "请选择备份编号 [0-${#list[@]}]: " choice || return 0
  [[ -z "$choice" || "$choice" == "0" ]] && return 0
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((10#$choice < 1 || 10#$choice > ${#list[@]})); then
    err "编号无效！"
    pause
    return 1
  fi

  if replace_binary "${list[$((10#$choice - 1))]}" && restart_cliproxy; then
    ok "已成功回滚至 $(fmt_ver "$(get_local_version)")！"
  else
    err "回滚后启动失败，请查看日志！"
  fi
  pause
}

view_status() {
  title "服务运行状态详情"
  local net_cmd="" cur_domain
  cur_domain=$(get_domain)

  kv "系统环境" "${OS_NAME}"
  kv "当前版本" "$(fmt_ver "$(get_local_version)")"
  kv "运行状态" "$(fmt_status)"
  kv "监听地址" "${Y}${LISTEN_ADDR}${N} ${G}(仅限本机访问)${N}"
  kv "反代域名" "${cur_domain:+${C}https://${cur_domain}${N}}${cur_domain:-${D}未设置${N}}"
  kv "授权凭据" "${G}$(auth_file_count)${N} 个 ${D}(${AUTH_DIR})${N}"
  kv "配置文件" "${CONFIG_PATH}"
  printf '%s本地端口监听套接字:%s\n' "$B" "$N"

  if command -v ss &>/dev/null; then
    net_cmd="ss"
  elif command -v netstat &>/dev/null; then
    net_cmd="netstat"
  fi
  if [[ -n "$net_cmd" ]]; then
    "$net_cmd" -tulpn 2>/dev/null | grep -iE ":${LOCKED_PORT}([[:space:]]|$)|cli-proxy" \
      || printf '%s(当前未检测到监听进程)%s\n' "$D" "$N"
  elif (echo >/dev/tcp/"$LOCKED_HOST"/"$LOCKED_PORT") 2>/dev/null; then
    printf '%stcp  LISTEN  %s%s %s(通过 /dev/tcp 探测可达)%s\n' "$G" "$LISTEN_ADDR" "$N" "$D" "$N"
  else
    printf '%s(当前未检测到监听端口)%s\n' "$D" "$N"
  fi
  pause
}

view_logs() {
  [[ -f "$SERVICE_PATH" ]] || {
    warn "服务尚未安装！"
    pause
    return 1
  }
  title "实时运行日志 (按 Ctrl+C 返回菜单)"
  trap 'echo ""' INT
  if [[ "$OS_ID" == "alpine" ]]; then
    [[ -f "$LOG_FILE" ]] || (umask 037 && : >"$LOG_FILE")
    tail -n 50 -f "$LOG_FILE"
  else
    journalctl -u cliproxy -n 50 -f
  fi
  trap 'on_signal INT' INT
}

backup_manage() {
  while true; do
    title "备份与还原管理"
    printf '%b\n' "${C}1${N}  创建完整备份 ${D}(归档配置、凭据与主程序)${N}"
    printf '%b\n' "${C}2${N}  还原配置文件 ${D}(恢复历史 config.yaml 并锁定本地端口)${N}"
    printf '%b\n' "${C}3${N}  查看备份列表 ${D}(${BACKUP_DIR})${N}"
    printf '%b\n' "${C}4${N}  清空历史备份 ${D}(删除所有备份归档)${N}"
    printf '%b\n' "${C}0${N}  返回"

    local bopt
    read -rp "> " bopt || return
    case "$bopt" in
      1)
        create_backup "manual"
        ok "完整备份已保存至: ${BACKUP_DIR}"
        pause
        ;;
      2)
        local baks=() f i=1 pick
        [[ -d "$BACKUP_DIR" ]] && mapfile -t baks < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name "config_*.yaml" 2>/dev/null | sort -r)
        [[ ${#baks[@]} -gt 0 ]] || {
          warn "暂无配置文件备份！"
          pause
          continue
        }
        for f in "${baks[@]}"; do printf '%b\n' "${C}$((i++))${N}  $(basename "$f")"; done
        printf '%b\n' "${C}0${N}  返回"
        read -rp "请选择要恢复的编号 [0-${#baks[@]}]: " pick || continue
        [[ -z "$pick" || "$pick" == "0" ]] && continue
        if [[ "$pick" =~ ^[0-9]+$ ]] && ((10#$pick >= 1 && 10#$pick <= ${#baks[@]})); then
          install -m 600 "${baks[$((10#$pick - 1))]}" "$CONFIG_PATH" && enforce_local_binding
          ok "配置已恢复并锁定 ${LISTEN_ADDR}"
          svc_ctl status && restart_cliproxy && ok "服务已重启生效。"
        else
          err "编号无效！"
        fi
        pause
        ;;
      3)
        local found_files=0 f
        if [[ -d "$BACKUP_DIR" ]]; then
          for f in "$BACKUP_DIR"/*; do
            [[ -e "$f" ]] || continue
            found_files=1
            printf '%-42s  %s\n' "$(basename "$f")" "$(du -h "$f" 2>/dev/null | awk '{print $1}')"
          done
        fi
        ((found_files == 0)) && info "当前暂无任何备份文件。"
        pause
        ;;
      4)
        local cfm
        read -rp "确认清空所有备份归档？[y/N]: " cfm || continue
        if [[ "$cfm" =~ ^[yY]$ ]]; then
          rm -rf "${BACKUP_DIR:?}"/* 2>/dev/null
          ok "备份已清空。"
        else
          info "已取消。"
        fi
        pause
        ;;
      0 | q | Q) return ;;
      "") continue ;;
      *) err "无效的操作编号，请输入 0-4 之间的数字！" && sleep 0.8 ;;
    esac
  done
}

uninstall_cliproxy() {
  title "卸载与清理"
  warn "即将移除系统服务、主程序、配置文件及备份归档。"
  local confirm del_auth
  read -rp "确认卸载 CLIProxyAPI？[y/N]: " confirm || return 0
  [[ "$confirm" =~ ^[yY]$ ]] || return 0

  svc_ctl stop || true
  if [[ "$OS_ID" == "alpine" ]]; then
    rc-update del cliproxy default >/dev/null 2>&1 || true
    rm -f "$SERVICE_PATH" "$LOG_FILE" /etc/logrotate.d/cliproxy
  else
    systemctl disable cliproxy >/dev/null 2>&1 || true
    rm -f "$SERVICE_PATH" && systemctl daemon-reload
  fi
  rm -f "$BIN_PATH" "${BIN_PATH}.new" "$CONFIG_PATH" "$DOMAIN_FILE" "${WORK_DIR}/config.example.yaml" "$SCRIPT_LINK"
  rm -rf "$BACKUP_DIR"

  if (($(auth_file_count) > 0)); then
    read -rp "是否同时删除 ${AUTH_DIR} 下的所有授权凭据？[y/N]: " del_auth || del_auth="n"
    if [[ "$del_auth" =~ ^[yY]$ ]]; then
      rm -rf "$WORK_DIR"
      ok "已彻底卸载并清理全部凭据。"
    else
      ok "已卸载程序，凭据保留于: ${AUTH_DIR}"
    fi
  else
    rm -rf "$WORK_DIR" 2>/dev/null || true
    ok "CLIProxyAPI 已彻底卸载。"
  fi
  pause
}

proxy_guide() {
  title "域名反向代理配置指引"
  local cur_domain raw_domain new_domain
  cur_domain=$(get_domain)
  kv "本地上游" "${Y}http://${LISTEN_ADDR}${N} ${G}(仅本机可访问)${N}"
  kv "当前域名" "${cur_domain:-未设置}"

  read -rp "输入/更新反代域名 (回车保持 [${cur_domain:-api.example.com}]): " raw_domain || true
  if [[ -n "$raw_domain" ]]; then
    if new_domain=$(sanitize_domain "$raw_domain") && [[ -n "$new_domain" ]]; then
      ensure_work_dirs
      (umask 077 && echo "$new_domain" >"$DOMAIN_FILE")
      cur_domain="$new_domain"
      ok "反代域名已更新: ${cur_domain}"
    else
      err "域名格式无效，保持原配置。"
    fi
  fi
  local d="${cur_domain:-api.example.com}"

  printf '%b\n' "${C}▸${N} ${B}方案 A：Caddy 配置 (/etc/caddy/Caddyfile)${N}"
  cat <<CADDY
${d} {
    # 可选安全加固：限制管理后台仅指定 IP 可访问
    # @admin path /management*
    # handle @admin {
    #     @blocked not remote_ip 127.0.0.1
    #     respond @blocked 403
    # }

    reverse_proxy ${LISTEN_ADDR} {
        flush_interval -1
    }
}
CADDY

  printf '%b\n' "${C}▸${N} ${B}方案 B：Nginx 配置 (支持 SSE 流式输出与 WebSocket)${N}"
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

    # 可选安全加固：限制管理后台仅指定 IP 可访问
    # location ~ ^/management {
    #     allow 127.0.0.1;
    #     deny all;
    #     proxy_pass http://${LISTEN_ADDR};
    # }

    location / {
        proxy_pass http://${LISTEN_ADDR};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;

        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
    }
}
NGINX
  pause
}

# --- 5. 主循环入口 ---
main() {
  check_root
  check_os
  setup_shortcut

  while true; do
    header
    printf '%b\n' "${C}1${N}  启动服务       ${C}7${N}  历史回滚"
    printf '%b\n' "${C}2${N}  停止服务       ${C}8${N}  状态详情"
    printf '%b\n' "${C}3${N}  重启服务       ${C}9${N}  备份还原"
    printf '%b\n' "${C}4${N}  实时日志       ${C}10${N} 反代指引"
    printf '%b\n' "${C}5${N}  安装部署       ${C}11${N} 卸载清理"
    printf '%b\n' "${C}6${N}  平滑升级       ${C}0${N}  退出"

    local opt
    read -rp "> " opt || bye "已退出 CLIProxyAPI 管理面板"
    [[ -z "$opt" ]] && continue
    if [[ "$opt" == "0" || "$opt" =~ ^[qQ]$ ]]; then
      bye "已退出 CLIProxyAPI 管理面板（输入 cpapi 可再次打开）"
    fi

    case "$opt" in
      1) manage_service start ;;
      2) manage_service stop ;;
      3) manage_service restart ;;
      4) view_logs ;;
      5) deploy ;;
      6) upgrade_lossless ;;
      7) rollback ;;
      8) view_status ;;
      9) backup_manage ;;
      10) proxy_guide ;;
      11) uninstall_cliproxy ;;
      *) err "无效的操作编号，请输入 0-11 之间的数字！" && sleep 0.8 ;;
    esac
  done
}

if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
