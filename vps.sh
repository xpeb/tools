#!/usr/bin/env bash
#==============================================================================
# VPS 综合管理工具
# 系统优化 + SSH 密钥管理 + Fail2Ban + SSH 安全配置
# 支持：Debian、Ubuntu、Alpine
#==============================================================================

#------------------------------------------------------------------------------
# 第 1 层：运行时状态与安全退出协调
# 全局变量仅保存检测结果或跨函数事务备份；cleanup_runtime 负责未提交事务回滚。
#------------------------------------------------------------------------------

# ── 终端样式 ──────────────────────────────────────────────────────────
B=$'\e[1m' D=$'\e[2m' G=$'\e[32m' R=$'\e[31m' Y=$'\e[33m' C=$'\e[36m' N=$'\e[0m'

cls() { clear 2>/dev/null || true; }

info() { printf "${D}[信息]${N} %s\n" "$*"; }
note() { printf "${C}[注意]${N} %s\n" "$*"; }
warn() { printf "${Y}[警告]${N} %s\n" "$*"; }
ok() { printf "${G}[正确]${N} %s\n" "$*"; }
err() { printf "${R}[错误]${N} %s\n" "$*" >&2; }

pause() {
  read -rsp $'按回车返回…' _ || true
  echo
}

title() {
  header
  printf "${C}▸${N} ${B}%s${N}\n" "$1"
}

bye() {
  cls
  info "$1"
  exit 0
}

is_q() { [[ "${1:-}" =~ ^[Qq]$ ]]; }

sleep_frac() { sleep "$1" 2>/dev/null || sleep 1; }

read_menu_choice() {
  local prompt="$1" valid="$2" value
  while true; do
    read -rp "$prompt" value || return 1
    if [[ "$value" =~ $valid ]]; then
      REPLY="$value"
      return 0
    fi
    printf '\033[1A\r\033[2K'
    transient_error "无效输入，请重试。"
  done
}

transient_error() {
  printf '\r\033[2K%s[错误]%s %s' "$R" "$N" "$*" >&2
  sleep_frac 0.8
  printf '\r\033[2K' >&2
}

# 补齐 su 切换 root 时可能缺失的 sbin 路径
for _p in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
  case ":${PATH:-}:" in
    *":${_p}:"*) ;;
    *) PATH="${_p}${PATH:+:$PATH}" ;;
  esac
done
unset _p
export PATH

SCRIPT_SELF=""
[ -n "${BASH_SOURCE[0]:-}" ] && SCRIPT_SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
[ -z "$SCRIPT_SELF" ] && SCRIPT_SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
SCRIPT_LINK="/usr/local/bin/vps"

is_real_script_file() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  case "$path" in
    /dev/fd/* | /proc/*/fd/* | pipe:*) return 1 ;;
  esac
  [ -f "$path" ] && [ ! -L "$path" ]
}

setup_shortcut() {
  is_real_script_file "$SCRIPT_SELF" || return 0
  [ "$SCRIPT_SELF" = "$SCRIPT_LINK" ] && {
    chmod +x "$SCRIPT_LINK" 2>/dev/null || true
    return 0
  }
  mkdir -p /usr/local/bin 2>/dev/null || true
  ln -sf "$SCRIPT_SELF" "$SCRIPT_LINK" 2>/dev/null || true
  chmod +x "$SCRIPT_LINK" 2>/dev/null || true
}

JAIL_CONF="/etc/fail2ban/jail.local"
LOG_FILE="/var/log/fail2ban.log"
TARGET_JAIL="sshd"

SSHD_MAIN="/etc/ssh/sshd_config"
SSHD_CONF_DIR="/etc/ssh/sshd_config.d"
SSH_SOCKET_DROPIN_DIR="/etc/systemd/system/ssh.socket.d"
SSH_SOCKET_DROPIN_FILE="${SSH_SOCKET_DROPIN_DIR}/99-vps-port.conf"
SYSCTL_CONF_FILE="/etc/sysctl.d/99-vps-tools.conf"
SYSCTL_LEGACY_FILE="/etc/sysctl.conf"

PKG_MGR=""
INIT_SYS=""
SSH_LOG=""
OS_NAME=""
OS_ID=""
OS_VER=""
OS_SHORT=""
PKG_INDEX_REFRESHED=0
DOCKER_VER=""
COMPOSE_VER=""
LATEST_DOCKER=""
LATEST_COMPOSE=""
SSH_BACKUP_DIR=""
AUTH_BACKUP_FILE=""
AUTH_BACKUP_MISSING=0
AUTH_RESTORE_FAILED=0
F2B_BACKUP_DIR=""
F2B_RESTORE_FAILED=0
SELINUX_SSH_PORT=""
SELINUX_SSH_PORT_ADDED=0
FIREWALL_BACKEND=""
FIREWALL_RULE_ADDED=0
FIREWALL_PORT=""
SYSCTL_BACKUP_FILE=""
SYSCTL_BACKUP_MISSING=0
SYSCTL_LEGACY_BACKUP_FILE=""
SYSCTL_LEGACY_BACKUP_MISSING=0
ZRAM_CONFIG_FILE=""
ZRAM_CONFIG_BACKUP=""
ZRAM_CONFIG_MISSING=0
CONTAINERD_SHARED_USE=0
ACTIVE_PROGRESS_PID=""
ACTIVE_PROGRESS_LOG=""

VPS_RUNTIME_DIR="${VPS_RUNTIME_DIR:-/run}"
[ -d "$VPS_RUNTIME_DIR" ] && [ -w "$VPS_RUNTIME_DIR" ] || VPS_RUNTIME_DIR="/tmp"

cleanup_runtime() {
  if [ -n "${ACTIVE_PROGRESS_PID:-}" ]; then
    if command -v pkill &>/dev/null; then
      pkill -TERM -P "$ACTIVE_PROGRESS_PID" 2>/dev/null || true
    fi
    kill "$ACTIVE_PROGRESS_PID" 2>/dev/null || true
    wait "$ACTIVE_PROGRESS_PID" 2>/dev/null || true
    ACTIVE_PROGRESS_PID=""
  fi
  if [ -n "${ACTIVE_PROGRESS_LOG:-}" ]; then
    rm -f "$ACTIVE_PROGRESS_LOG"
    ACTIVE_PROGRESS_LOG=""
  fi
  if [ -n "${SSH_BACKUP_DIR:-}" ]; then
    if restore_ssh_config >/dev/null 2>&1; then
      restart_sshd >/dev/null 2>&1 || true
      rm -rf "$SSH_BACKUP_DIR"
      SSH_BACKUP_DIR=""
    else
      err "SSH 配置自动恢复失败，备份仍保留在：${SSH_BACKUP_DIR}"
    fi
  fi
  if [ -n "${AUTH_BACKUP_FILE:-}" ]; then
    if ! restore_authorized_keys >/dev/null 2>&1; then
      err "authorized_keys 自动恢复失败，备份仍保留在：${AUTH_BACKUP_FILE}"
    fi
  fi
  if [ -n "${F2B_BACKUP_DIR:-}" ]; then
    local f2b_was_running=0
    [ -f "$F2B_BACKUP_DIR/was-running" ] && f2b_was_running=1
    if restore_f2b_config >/dev/null 2>&1; then
      [ "$f2b_was_running" -eq 1 ] && svc_restart fail2ban >/dev/null 2>&1 || true
      rm -rf "$F2B_BACKUP_DIR"
      F2B_BACKUP_DIR=""
    else
      err "Fail2Ban 配置自动恢复失败，备份仍保留在：${F2B_BACKUP_DIR}"
    fi
  fi
  if [ "${SELINUX_SSH_PORT_ADDED:-0}" -eq 1 ] && command -v semanage &>/dev/null; then
    semanage port -d -t ssh_port_t -p tcp "$SELINUX_SSH_PORT" >/dev/null 2>&1 || true
    SELINUX_SSH_PORT_ADDED=0
  fi
  if [ -n "${FIREWALL_BACKEND:-}" ] && [ "${FIREWALL_RULE_ADDED:-0}" -eq 1 ]; then
    rollback_firewall_rule "${FIREWALL_BACKEND}" "${FIREWALL_PORT:-}" >/dev/null 2>&1 || true
  fi
  if [ -n "${ZRAM_CONFIG_BACKUP:-}" ] || [ -n "${SYSCTL_BACKUP_FILE:-}" ] || [ -n "${SYSCTL_LEGACY_BACKUP_FILE:-}" ]; then
    restore_zram_config >/dev/null 2>&1 || true
    restore_sysctl_conf >/dev/null 2>&1 || true
    apply_managed_sysctl >/dev/null 2>&1 || true
  fi
}

if [ "${VPS_TOOL_LIBRARY_ONLY:-0}" != "1" ]; then
  if [ "$EUID" -ne 0 ]; then
    err "请使用 root 用户运行此脚本。"
    exit 1
  fi
  if [ ! -t 0 ]; then
    err "请勿通过管道直接执行，请使用 bash <(curl -fsSL ...) 运行。"
    exit 1
  fi
  HOME=/root
  export HOME
  umask 077
  trap 'cleanup_runtime' EXIT
  trap 'exit 130' INT TERM

  if command -v flock &>/dev/null; then
    if [ "$VPS_RUNTIME_DIR" = "/tmp" ]; then
      LOCK_FILE="/tmp/.vps.sh.${EUID}.lock"
    else
      LOCK_FILE="${VPS_RUNTIME_DIR}/lock/vps.sh.lock"
      mkdir -p "${VPS_RUNTIME_DIR}/lock" 2>/dev/null || true
    fi
    if [ -L "$LOCK_FILE" ]; then
      err "检测到异常锁文件软链接：$LOCK_FILE"
      exit 1
    fi
    exec 9>"$LOCK_FILE" || {
      err "无法创建运行锁：$LOCK_FILE"
      exit 1
    }
    if ! flock -n 9; then
      err "已有另一个 vps.sh 实例正在运行。"
      exit 1
    fi
  fi
fi

#------------------------------------------------------------------------------
# 第 2 层：系统能力探测（只读取系统状态，不执行安装或配置变更）
#------------------------------------------------------------------------------
# ============ 能力检测 ============
detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="${NAME:-Unknown}"
    OS_ID="${ID:-unknown}"
    OS_VER="${VERSION_ID:-}"
  else
    OS_NAME=$(uname -s)
    OS_VER=$(uname -r)
    OS_ID="unknown"
  fi
  case "$OS_ID" in
    debian) OS_SHORT="Debian" ;;
    ubuntu) OS_SHORT="Ubuntu" ;;
    alpine) OS_SHORT="Alpine" ;;
    *) OS_SHORT="$OS_NAME" ;;
  esac
}

detect_pkg_mgr() {
  case "$OS_ID" in
    debian | ubuntu) command -v apt-get &>/dev/null && PKG_MGR="apt" ;;
    alpine) command -v apk &>/dev/null && PKG_MGR="apk" ;;
  esac
  [ -n "$PKG_MGR" ] || PKG_MGR="unknown"
}

detect_init() {
  if command -v systemctl &>/dev/null && { [ -d /run/systemd/system ] || systemctl show-environment >/dev/null 2>&1; }; then
    INIT_SYS="systemd"
  elif command -v rc-service &>/dev/null || [ -d /run/openrc ] || [ -d /etc/init.d ]; then
    if command -v rc-service &>/dev/null || [ -d /run/openrc ]; then
      INIT_SYS="openrc"
    elif command -v service &>/dev/null; then
      INIT_SYS="sysvinit"
    else INIT_SYS="unknown"; fi
  elif command -v service &>/dev/null || [ -x /sbin/init ]; then
    INIT_SYS="sysvinit"
  else INIT_SYS="unknown"; fi
}

detect_ssh_log() {
  case "$OS_ID" in
    debian | ubuntu) SSH_LOG="/var/log/auth.log" ;;
    alpine) SSH_LOG="/var/log/messages" ;;
  esac
}

#------------------------------------------------------------------------------
# 第 3 层：平台适配器——服务管理
# 调用方使用统一的 svc_* 接口，不直接依赖 systemd/OpenRC/SysVinit。
#------------------------------------------------------------------------------
# ============ 服务管理抽象 ============
svc_action() {
  local action="$1" service="$2"
  case "$INIT_SYS" in
    systemd) command -v systemctl &>/dev/null && systemctl "$action" "$service" 9>&- 2>/dev/null ;;
    openrc) command -v rc-service &>/dev/null && rc-service "$service" "$action" 9>&- 2>/dev/null ;;
    sysvinit) command -v service &>/dev/null && service "$service" "$action" 9>&- 2>/dev/null ;;
    *) return 1 ;;
  esac
}
svc_start() { svc_action start "$1"; }
svc_stop() { svc_action stop "$1"; }
svc_restart() { svc_action restart "$1"; }
svc_enable() {
  case "$INIT_SYS" in
    systemd) systemctl enable "$1" 9>&- 2>/dev/null ;;
    openrc) rc-update add "$1" default 9>&- 2>/dev/null ;;
    sysvinit) update-rc.d "$1" defaults 9>&- 2>/dev/null || chkconfig "$1" on 9>&- 2>/dev/null ;;
    *) return 1 ;;
  esac
}
svc_disable() {
  case "$INIT_SYS" in
    systemd) systemctl disable "$1" 9>&- 2>/dev/null ;;
    openrc) rc-update del "$1" default 9>&- 2>/dev/null ;;
    sysvinit) update-rc.d -f "$1" remove 9>&- 2>/dev/null || chkconfig "$1" off 9>&- 2>/dev/null ;;
    *) return 1 ;;
  esac
}

#------------------------------------------------------------------------------
# 第 3 层：平台适配器——包管理
# 包索引刷新状态只在一次包操作事务内有效，任何安装/卸载后都失效。
#------------------------------------------------------------------------------
# ============ 包管理抽象 ============
run_with_progress() {
  local label="$1"
  shift
  local log_file pid rc width=28 pos=0 direction=1 j bar
  log_file=$(mktemp "$VPS_RUNTIME_DIR/vps-progress.XXXXXX") || {
    "$@" 9>&-
    return $?
  }
  ACTIVE_PROGRESS_LOG="$log_file"

  "$@" 9>&- </dev/null >"$log_file" 2>&1 &
  pid=$!
  ACTIVE_PROGRESS_PID="$pid"
  while kill -0 "$pid" 2>/dev/null; do
    bar=""
    for ((j = 0; j < width; j++)); do
      if [ "$j" -eq "$pos" ]; then bar+='>'; else bar+='-'; fi
    done
    printf '\r\033[2K%s [%s]' "$label" "$bar"
    if [ "$pos" -ge $((width - 1)) ]; then direction=-1; elif [ "$pos" -le 0 ]; then direction=1; fi
    pos=$((pos + direction))
    sleep_frac 0.15
  done
  wait "$pid"
  rc=$?
  ACTIVE_PROGRESS_PID=""
  if [ "$rc" -eq 0 ]; then
    printf '\r\033[2K%s [%s] 完成\n' "$label" "$(printf '%*s' "$width" '' | tr ' ' '=')"
  else
    printf '\r\033[2K%s 失败\n' "$label" >&2
    cat "$log_file" >&2
  fi
  rm -f "$log_file"
  ACTIVE_PROGRESS_LOG=""
  return "$rc"
}

package_index_invalidate() {
  PKG_INDEX_REFRESHED=0
}

refresh_package_index() {
  # A failed refresh must not leave the previous index state marked as fresh.
  package_index_invalidate
  case "$PKG_MGR" in
    apt) run_with_progress "刷新 Debian 软件索引" apt-get update -qq || return 1 ;;
    apk) run_with_progress "刷新 Alpine 软件索引" apk update || return 1 ;;
    *) return 1 ;;
  esac
  PKG_INDEX_REFRESHED=1
}

apt_install_transaction() {
  local label="$1"
  shift
  if [ "${PKG_INDEX_REFRESHED:-0}" -eq 1 ]; then
    run_with_progress "$label" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  else
    run_with_progress "$label" env DEBIAN_FRONTEND=noninteractive sh -c \
      'apt-get update -qq && apt-get install -y -qq "$@"' sh "$@"
  fi
  local rc=$?
  package_index_invalidate
  return "$rc"
}

apt_remove_transaction() {
  local label="$1"
  shift
  run_with_progress "$label" env DEBIAN_FRONTEND=noninteractive \
    apt-get remove --purge -y -qq "$@"
  local rc=$?
  package_index_invalidate
  return "$rc"
}

pkg_install() {
  case "$PKG_MGR" in
    apt) apt_install_transaction "安装软件包: $*" "$@" ;;
    apk)
      if [ "${PKG_INDEX_REFRESHED:-0}" -eq 1 ]; then
        run_with_progress "安装软件包: $*" apk add "$@"
      else
        # --no-cache 在单个命令内原子拉取并丢弃索引，无需重复执行 apk update
        run_with_progress "安装软件包: $*" apk add --no-cache "$@"
      fi
      local rc=$?
      package_index_invalidate
      return "$rc"
      ;;
    *)
      err "未知包管理器"
      return 1
      ;;
  esac
}
pkg_remove() {
  case "$PKG_MGR" in
    apt) apt_remove_transaction "卸载软件包: $*" "$@" ;;
    apk)
      run_with_progress "卸载软件包: $*" apk del "$@"
      local rc=$?
      package_index_invalidate
      return "$rc"
      ;;
    *) return 1 ;;
  esac
}

pkg_autoremove() {
  case "$PKG_MGR" in
    apt)
      run_with_progress "清理无用依赖" env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq
      local rc=$?
      package_index_invalidate
      return "$rc"
      ;;
    *) return 0 ;;
  esac
}

pkg_is_installed() {
  case "$PKG_MGR" in
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    apk) apk info -e "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

pkg_reinstall() {
  case "$PKG_MGR" in
    apt)
      run_with_progress "重新安装软件包: $*" env DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y -qq "$@"
      local rc=$?
      package_index_invalidate
      return "$rc"
      ;;
    apk)
      run_with_progress "重新安装软件包: $*" apk fix "$@"
      local rc=$?
      package_index_invalidate
      return "$rc"
      ;;
    *) return 1 ;;
  esac
}

# 检测 EOL 系统（仅用于提示，不自动修改配置）
check_eol_system() {
  case "$OS_ID" in
    debian)
      case "$OS_VER" in
        8 | 9 | 10)
          warn "检测到 Debian ${OS_VER}，该系统已停止官方支持。"
          echo -e "${Y}apt 源可能已失效，导致无法正常安装软件。${N}"
          echo -e "${Y}如果安装失败，可将 /etc/apt/sources.list 改为 archive 源：${N}"
          local codename=""
          case "$OS_VER" in
            8) codename="jessie" ;;
            9) codename="stretch" ;;
            10) codename="buster" ;;
          esac
          if [ -n "$codename" ]; then
            echo -e "${C}示例：${N}"
            echo -e "deb http://archive.debian.org/debian ${codename} main contrib non-free"
            echo -e "deb http://archive.debian.org/debian ${codename}-updates main contrib non-free"
            echo -e "${C}修改后执行：apt update${N}"
          fi
          ;;
      esac
      ;;
  esac
}

#------------------------------------------------------------------------------
# 第 4 层：配置事务原语
# 各功能显式执行 backup -> 修改/校验 -> commit 或 restore，不绕过事务接口。
#------------------------------------------------------------------------------
atomic_write_file() {
  local file="$1" default_mode="${2:-}" mode="" owner=""
  local dir tmp
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || return 1
  [ -L "$file" ] && {
    err "拒绝原子替换软链接配置文件：$file"
    return 1
  }
  if [ -f "$file" ]; then
    mode=$(stat -c '%a' "$file" 2>/dev/null || true)
    owner=$(stat -c '%u:%g' "$file" 2>/dev/null || true)
  elif [ -n "$default_mode" ]; then
    mode="$default_mode"
  fi
  tmp=$(mktemp "${file}.tmp.XXXXXX") || return 1
  if ! cat >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  [ -z "$mode" ] || chmod "$mode" "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  [ -z "$owner" ] || chown "$owner" "$tmp" 2>/dev/null || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$file" || {
    rm -f "$tmp"
    return 1
  }
}

_tx_backup_file() {
  local target="$1" prefix="$2" backup_file
  backup_file=$(mktemp "$VPS_RUNTIME_DIR/${prefix}.XXXXXX") || return 1
  REPLY="$backup_file"
  REPLY_MISSING=0
  if [ -f "$target" ]; then
    cp -a "$target" "$backup_file" || {
      rm -f "$backup_file"
      REPLY=""
      return 1
    }
  else
    REPLY_MISSING=1
  fi
}

_tx_restore_file() {
  local target="$1" backup_file="$2" missing="$3" tmp
  [ -n "$backup_file" ] || return 0
  if [ "${missing:-0}" -eq 1 ]; then
    rm -f "$target" || return 1
  else
    [ -L "$target" ] && {
      err "拒绝自动恢复软链接文件：$target"
      return 1
    }
    mkdir -p "$(dirname "$target")" 2>/dev/null || return 1
    tmp=$(mktemp "${target}.restore.XXXXXX") || return 1
    if ! cp -a "$backup_file" "$tmp" || ! mv -f "$tmp" "$target"; then
      rm -f "$tmp"
      return 1
    fi
  fi
}

_tx_backup_dir() {
  local src_dir="$1" backup_dir="$2" name="$3"
  if [ -d "$src_dir" ]; then
    touch "$backup_dir/${name}-existed" || return 1
    stat -c '%a' "$src_dir" 2>/dev/null >"$backup_dir/${name}-mode" || true
    cp -a "$src_dir" "$backup_dir/${name}" || return 1
  fi
  return 0
}

_tx_restore_dir() {
  local dst_dir="$1" backup_dir="$2" name="$3"
  local tmp_dir old_dir dir_mode
  if [ -f "$backup_dir/${name}-existed" ]; then
    mkdir -p "$(dirname "$dst_dir")" 2>/dev/null || return 1
    tmp_dir=$(mktemp -d "${dst_dir}.restore.XXXXXX") || return 1
    if ! cp -a "$backup_dir/${name}/." "$tmp_dir/"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    dir_mode=$(cat "$backup_dir/${name}-mode" 2>/dev/null || true)
    chmod "${dir_mode:-755}" "$tmp_dir" 2>/dev/null || true
    old_dir="${dst_dir}.failed-restore.$$"
    if [ -e "$dst_dir" ] && ! mv "$dst_dir" "$old_dir"; then
      rm -rf "$tmp_dir"
      return 1
    fi
    if ! mv "$tmp_dir" "$dst_dir"; then
      [ -e "$old_dir" ] && mv "$old_dir" "$dst_dir"
      rm -rf "$tmp_dir"
      return 1
    fi
    rm -rf "$old_dir"
  else
    rm -rf "$dst_dir" || return 1
  fi
  return 0
}

# ============ SSH 配置管理 ============
backup_ssh_config() {
  [ -z "$SSH_BACKUP_DIR" ] || return 0
  SSH_BACKUP_DIR=$(mktemp -d "$VPS_RUNTIME_DIR/vps-ssh-backup-$(date +%Y%m%d%H%M%S)-XXXXXX") || return 1
  if [ -f "$SSHD_MAIN" ] && ! cp -a "$SSHD_MAIN" "$SSH_BACKUP_DIR/sshd_config"; then
    rm -rf "$SSH_BACKUP_DIR"
    SSH_BACKUP_DIR=""
    return 1
  elif [ ! -f "$SSHD_MAIN" ]; then
    touch "$SSH_BACKUP_DIR/sshd_config-absent" || {
      rm -rf "$SSH_BACKUP_DIR"
      SSH_BACKUP_DIR=""
      return 1
    }
  fi
  if ! _tx_backup_dir "$SSHD_CONF_DIR" "$SSH_BACKUP_DIR" "sshd_config.d"; then
    rm -rf "$SSH_BACKUP_DIR"
    SSH_BACKUP_DIR=""
    return 1
  fi
  if [ -d "$SSH_SOCKET_DROPIN_DIR" ]; then
    if ! _tx_backup_dir "$SSH_SOCKET_DROPIN_DIR" "$SSH_BACKUP_DIR" "ssh_socket_d"; then
      rm -rf "$SSH_BACKUP_DIR"
      SSH_BACKUP_DIR=""
      return 1
    fi
  fi
  return 0
}

restore_ssh_config() {
  [ -n "$SSH_BACKUP_DIR" ] || return 0
  if [ -f "$SSH_BACKUP_DIR/sshd_config" ]; then
    _tx_restore_file "$SSHD_MAIN" "$SSH_BACKUP_DIR/sshd_config" 0 || return 1
  elif [ -f "$SSH_BACKUP_DIR/sshd_config-absent" ]; then
    _tx_restore_file "$SSHD_MAIN" "$SSH_BACKUP_DIR/sshd_config-absent" 1 || return 1
  fi

  _tx_restore_dir "$SSHD_CONF_DIR" "$SSH_BACKUP_DIR" "sshd_config.d" || return 1
  if [ -f "$SSH_BACKUP_DIR/ssh_socket_d-existed" ]; then
    _tx_restore_dir "$SSH_SOCKET_DROPIN_DIR" "$SSH_BACKUP_DIR" "ssh_socket_d" || return 1
  else
    rm -f "$SSH_SOCKET_DROPIN_FILE" 2>/dev/null || true
    rmdir "$SSH_SOCKET_DROPIN_DIR" 2>/dev/null || true
  fi
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl daemon-reload &>/dev/null || true
  fi
  return 0
}

commit_ssh_config() {
  [ -n "$SSH_BACKUP_DIR" ] && rm -rf "$SSH_BACKUP_DIR"
  SSH_BACKUP_DIR=""
}

rollback_ssh_config() {
  if restore_ssh_config && restart_sshd >/dev/null 2>&1; then
    rm -rf "$SSH_BACKUP_DIR"
    SSH_BACKUP_DIR=""
  else
    err "SSH 配置恢复或重启失败，备份仍保留在：${SSH_BACKUP_DIR}"
  fi
}

backup_authorized_keys() {
  local auth_file="${HOME}/.ssh/authorized_keys"
  [ -n "$AUTH_BACKUP_FILE" ] && rm -f "$AUTH_BACKUP_FILE"
  AUTH_BACKUP_FILE=""
  AUTH_BACKUP_MISSING=0
  AUTH_RESTORE_FAILED=0
  _tx_backup_file "$auth_file" "vps-authorized-keys" || return 1
  AUTH_BACKUP_FILE="$REPLY"
  AUTH_BACKUP_MISSING="$REPLY_MISSING"
}

restore_authorized_keys() {
  local auth_file="${HOME}/.ssh/authorized_keys"
  [ -n "$AUTH_BACKUP_FILE" ] || return 0
  if ! _tx_restore_file "$auth_file" "$AUTH_BACKUP_FILE" "$AUTH_BACKUP_MISSING"; then
    AUTH_RESTORE_FAILED=1
    return 1
  fi
  if [ "$AUTH_BACKUP_MISSING" -eq 0 ]; then
    chmod 600 "$auth_file" || {
      AUTH_RESTORE_FAILED=1
      return 1
    }
  fi
  rm -f "$AUTH_BACKUP_FILE" || {
    AUTH_RESTORE_FAILED=1
    return 1
  }
  AUTH_BACKUP_FILE=""
  AUTH_BACKUP_MISSING=0
  AUTH_RESTORE_FAILED=0
}

commit_authorized_keys() {
  if [ "$AUTH_RESTORE_FAILED" -eq 1 ]; then
    err "authorized_keys 恢复失败，备份仍保留在：${AUTH_BACKUP_FILE}"
    return 1
  fi
  [ -n "$AUTH_BACKUP_FILE" ] && rm -f "$AUTH_BACKUP_FILE"
  AUTH_BACKUP_FILE=""
  AUTH_BACKUP_MISSING=0
}

backup_f2b_config() {
  [ -z "$F2B_BACKUP_DIR" ] || return 0
  F2B_BACKUP_DIR=$(mktemp -d "$VPS_RUNTIME_DIR/vps-f2b-config-$(date +%Y%m%d%H%M%S)-XXXXXX") || return 1
  F2B_RESTORE_FAILED=0
  if command -v fail2ban-client &>/dev/null && fail2ban-client ping >/dev/null 2>&1; then
    touch "$F2B_BACKUP_DIR/was-running" || true
  fi
  if [ -f "$JAIL_CONF" ]; then
    cp -a "$JAIL_CONF" "$F2B_BACKUP_DIR/jail.local" || {
      rm -rf "$F2B_BACKUP_DIR"
      F2B_BACKUP_DIR=""
      return 1
    }
  else
    touch "$F2B_BACKUP_DIR/jail.local-absent" || {
      rm -rf "$F2B_BACKUP_DIR"
      F2B_BACKUP_DIR=""
      return 1
    }
  fi
}

restore_f2b_config() {
  [ -n "$F2B_BACKUP_DIR" ] || return 0
  if [ -f "$F2B_BACKUP_DIR/jail.local" ]; then
    if ! _tx_restore_file "$JAIL_CONF" "$F2B_BACKUP_DIR/jail.local" 0; then
      F2B_RESTORE_FAILED=1
      return 1
    fi
  elif [ -f "$F2B_BACKUP_DIR/jail.local-absent" ]; then
    if ! _tx_restore_file "$JAIL_CONF" "$F2B_BACKUP_DIR/jail.local-absent" 1; then
      F2B_RESTORE_FAILED=1
      return 1
    fi
  fi
  F2B_RESTORE_FAILED=0
  return 0
}

commit_f2b_config() {
  if [ "$F2B_RESTORE_FAILED" -eq 1 ]; then
    err "Fail2Ban 配置恢复失败，备份仍保留在：${F2B_BACKUP_DIR}"
    return 1
  fi
  [ -n "$F2B_BACKUP_DIR" ] && rm -rf "$F2B_BACKUP_DIR"
  F2B_BACKUP_DIR=""
}

# 使用 OpenSSH 自身解析最终生效配置，避免手工模拟 Include/Match/First Match 规则。
# 若存在条件 Match 块导致裸 sshd -T 失败，则回退默认连接上下文 -C；仍失败时显式报错。
_sshd_dump_config() {
  command -v sshd &>/dev/null || return 1
  local parsed
  if parsed=$(sshd -T 2>/dev/null) && [ -n "$parsed" ]; then
    printf '%s\n' "$parsed"
    return 0
  fi
  if parsed=$(sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null) && [ -n "$parsed" ]; then
    printf '%s\n' "$parsed"
    return 0
  fi
  return 1
}

_sshd_val_from_dump() {
  local dump="$1" key="$2"
  printf '%s\n' "$dump" | awk -v key="${key,,}" 'tolower($1) == key {print $2; exit}'
}

_sshd_vals_from_dump() {
  local dump="$1" key="$2"
  printf '%s\n' "$dump" | awk -v key="${key,,}" 'tolower($1) == key {print $2}'
}

sshd_supports_opt() {
  local key="${1,,}" parsed
  parsed=$(_sshd_dump_config) || return 1
  printf '%s\n' "$parsed" | grep -qi "^${key}[[:space:]]"
}

get_sshd_config_val() {
  local key="$1" val="" parsed
  parsed=$(_sshd_dump_config) || return 1
  val=$(_sshd_val_from_dump "$parsed" "$key")
  [ -n "$val" ] || return 1
  printf '%s\n' "$val"
}

get_sshd_config_vals() {
  local key="$1" vals="" parsed
  parsed=$(_sshd_dump_config) || return 1
  vals=$(_sshd_vals_from_dump "$parsed" "$key")
  [ -n "$vals" ] || return 1
  printf '%s\n' "$vals"
}

read_sshd_config_val() {
  local key="$1" value
  if ! value=$(get_sshd_config_val "$key"); then
    err "无法解析当前 SSH 配置（sshd -T 失败），已取消相关操作。"
    return 1
  fi
  printf '%s\n' "$value"
}

is_ssh_socket_managed() {
  [ "$INIT_SYS" = "systemd" ] && {
    systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null
  }
}

set_ssh_socket_port() {
  local port="$1"
  printf '[Socket]\nListenStream=\nListenStream=%s\n' "$port" \
    | atomic_write_file "$SSH_SOCKET_DROPIN_FILE" 644 || return 1
  systemctl daemon-reload >/dev/null 2>&1 || return 1
}

# 只修改主配置文件，并放在 Include/Match 之前，避免改写发行版或云厂商的 .d 文件。
set_sshd_config() {
  local param="$1" value="$2" src="$SSHD_MAIN" tmpf
  [ -L "$SSHD_MAIN" ] && {
    err "拒绝修改软链接 SSH 主配置文件：$SSHD_MAIN"
    return 1
  }
  [ -f "$src" ] || src=/dev/null
  tmpf=$(mktemp "$VPS_RUNTIME_DIR/sshd-config.XXXXXX") || return 1
  if ! awk -v p="$param" -v v="$value" '
        BEGIN { target=tolower(p); inserted=0; in_match=0 }
        {
            if (tolower($0) ~ /^[[:space:]]*match[[:space:]]/) in_match=1
            raw=$0
            sub(/^[[:space:]]*/, "", raw)
            # 仅移除顶层有效配置或默认被注释掉的配置指令（如 #Port 22），保留 Match 块内的局部规则与说明性注释
            if (!in_match) {
                if (raw !~ /^#/) {
                    n = split(raw, arr, /[[:space:]=]+/)
                    if (n > 0 && tolower(arr[1]) == target) next
                } else {
                    comment_body = raw
                    sub(/^#[[:space:]]*/, "", comment_body)
                    n = split(comment_body, arr, /[[:space:]=]+/)
                    if (n == 2 && tolower(arr[1]) == target) next
                }
            }
            if (!inserted && tolower($0) ~ /^[[:space:]]*(include|match)[[:space:]]/) {
                print p " " v
                inserted=1
            }
            print
        }
        END { if (!inserted) print p " " v }
    ' "$src" >"$tmpf"; then
    rm -f "$tmpf"
    return 1
  fi
  if ! atomic_write_file "$SSHD_MAIN" 644 <"$tmpf"; then
    rm -f "$tmpf"
    return 1
  fi
  rm -f "$tmpf"
}

# 批量设置 sshd 参数：$@ 为 key=value
set_sshd_multi() {
  local kv
  for kv in "$@"; do
    set_sshd_config "${kv%%=*}" "${kv#*=}" || return 1
  done
}

# SSH 配置事务：备份 → 应用 → 重启；任一失败则回滚
ssh_config_apply() {
  if ! backup_ssh_config; then
    err "无法备份 SSH 配置，操作已取消"
    return 1
  fi
  if ! set_sshd_multi "$@" || ! restart_sshd; then
    err "SSH 重启失败，正在恢复原配置"
    rollback_ssh_config
    return 1
  fi
  commit_ssh_config
  return 0
}

restart_sshd() {
  ok "正在检测 SSH 配置文件语法..."
  if command -v sshd &>/dev/null; then
    if ! sshd -t; then
      err "SSH 配置文件测试失败！检测到语法错误，已取消重启以防止断连锁死！"
      return 1
    fi
  fi

  ok "正在重启 SSH 服务..."
  local restart_ok=1
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl daemon-reload &>/dev/null || true
    local ssh_unit="" socket_active=0
    is_ssh_socket_managed && socket_active=1
    if systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service'; then
      ssh_unit="ssh.service"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^sshd\.service'; then
      ssh_unit="sshd.service"
    elif systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.socket'; then
      ssh_unit="ssh.socket"
    fi
    if [ "$socket_active" -eq 1 ]; then
      if svc_restart ssh.socket && systemctl is-active --quiet ssh.socket 2>/dev/null; then
        [ -n "$ssh_unit" ] && [ "$ssh_unit" != "ssh.socket" ] && svc_restart "$ssh_unit" >/dev/null 2>&1 || true
        restart_ok=0
      fi
    elif [ -n "$ssh_unit" ]; then
      if svc_restart "$ssh_unit" && systemctl is-active --quiet "$ssh_unit" 2>/dev/null; then
        restart_ok=0
      fi
    else
      err "未找到 ssh.service 或 sshd.service！"
    fi
  elif [ "$INIT_SYS" = "openrc" ]; then
    svc_restart sshd && restart_ok=0
  else
    svc_restart sshd 2>/dev/null && restart_ok=0
    if [ "$restart_ok" -ne 0 ]; then
      svc_restart ssh 2>/dev/null && restart_ok=0
    fi
  fi

  if [ "$restart_ok" -eq 0 ]; then
    ok "SSH 服务重启成功！"
    return 0
  else
    err "SSH 服务重启失败，请检查配置文件！"
    return 1
  fi
}

#------------------------------------------------------------------------------
# 第 5 层：业务功能——SSH、密钥与 Fail2Ban
# 此层编排配置事务和平台适配器，并负责输入校验及用户提示。
#------------------------------------------------------------------------------
# ============ 依赖安装 ============
check_dependencies() {
  local pkgs=() install_confirm=""
  command -v curl &>/dev/null || pkgs+=(curl)
  if ! command -v ssh-keygen &>/dev/null; then
    if [ "$OS_ID" = "alpine" ]; then
      pkgs+=(openssh-keygen)
    else
      pkgs+=(openssh-client)
    fi
  fi
  if [ "${#pkgs[@]}" -gt 0 ]; then
    warn "需要安装依赖: ${pkgs[*]}"
    read -rp "${C}[注意]${N} 现在安装这些依赖吗？(Y/n，q=取消): " install_confirm
    if [[ -n "$install_confirm" && ! "$install_confirm" =~ ^[Yy]$ ]]; then
      err "未安装依赖，退出管理工具。"
      return 1
    fi
    if ! pkg_install "${pkgs[@]}"; then
      err "依赖安装失败，无法启动管理菜单。"
      return 1
    fi
  fi
  if ! command -v curl &>/dev/null || ! command -v ssh-keygen &>/dev/null; then
    err "缺少必要依赖 curl 或 ssh-keygen。"
    return 1
  fi
  return 0
}

init_ssh_dir() {
  mkdir -p "${HOME}/.ssh" || return 1
  touch "${HOME}/.ssh/authorized_keys" || return 1
  chmod 700 "${HOME}/.ssh" || return 1
  chmod 600 "${HOME}/.ssh/authorized_keys" || return 1
  chown root:root "${HOME}/.ssh" "${HOME}/.ssh/authorized_keys" 2>/dev/null || true
}

_split_auth_line_awk() {
  local mode="$1"
  awk -v mode="$mode" '
        {
            line = $0
            len = length(line)
            n = 0
            i = 1
            while (i <= len) {
                while (i <= len && substr(line, i, 1) ~ /[ \t\r]/) i++
                if (i > len) break
                start = i
                in_q = 0
                while (i <= len) {
                    c = substr(line, i, 1)
                    if (in_q) {
                        if (c == "\\" && i < len) { i += 2; continue }
                        if (c == "\"") in_q = 0
                    } else {
                        if (c == "\"") in_q = 1
                        else if (c ~ /[ \t\r]/) break
                    }
                    i++
                }
                n++
                tok[n] = substr(line, start, i - start)
            }
            for (k = 1; k <= n; k++) {
                if (tok[k] ~ /^(ssh-|ecdsa-|sk-)/ && k < n) {
                    if (mode == "core") {
                        print tok[k] " " tok[k + 1]
                    } else if (mode == "opts" && k > 1) {
                        out = ""
                        for (j = 1; j < k; j++) out = out (j > 1 ? " " : "") tok[j]
                        print out
                    }
                    exit
                }
            }
        }
    '
}

extract_core_key() {
  _split_auth_line_awk core
}

extract_key_options() {
  _split_auth_line_awk opts
}

is_valid_core_key() {
  local core_key="$1" key_type key_blob extra
  [ -n "$core_key" ] || return 1
  read -r key_type key_blob extra <<<"$core_key"
  [ -n "$key_type" ] && [ -n "$key_blob" ] && [ -z "$extra" ] || return 1
  ssh-keygen -lf <(printf '%s %s\n' "$key_type" "$key_blob") >/dev/null 2>&1
}

_auth_file_has_key() {
  local auth_file="$1" target_type="$2" target_blob="$3"
  [ -f "$auth_file" ] || return 1
  awk -v kt="$target_type" -v kb="$target_blob" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            line = $0
            len = length(line)
            n = 0
            i = 1
            while (i <= len) {
                while (i <= len && substr(line, i, 1) ~ /[ \t\r]/) i++
                if (i > len) break
                start = i
                in_q = 0
                while (i <= len) {
                    c = substr(line, i, 1)
                    if (in_q) {
                        if (c == "\\" && i < len) { i += 2; continue }
                        if (c == "\"") in_q = 0
                    } else {
                        if (c == "\"") in_q = 1
                        else if (c ~ /[ \t\r]/) break
                    }
                    i++
                }
                n++
                tok[n] = substr(line, start, i - start)
            }
            for (k = 1; k < n; k++) {
                if (tok[k] == kt && tok[k + 1] == kb) {
                    found = 1
                    exit
                }
            }
        }
        END { exit !found }
    ' "$auth_file"
}

# 追加公钥
# - 保留选项前缀（如 from="1.2.3.4",command="..."）
# - 丢弃尾部注释（避免污染元数据标签）
# - 用完整「密钥类型 + Base64 主体」做去重
append_key_with_meta() {
  local pub_content="$1" source_tag="$2" auth_file="${HOME}/.ssh/authorized_keys"
  local ts line core_key key_type key_base64 key_options auth_entry
  ts=$(date "+%Y-%m-%d %H:%M:%S")
  local added=0 skipped=0 invalid=0
  init_ssh_dir || return 1
  while IFS= read -r line; do
    line=$(printf '%s\n' "$line" | sed -e 's/[[:space:]]*$//')
    [ -z "$line" ] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    core_key=$(printf '%s\n' "$line" | extract_core_key)
    if ! is_valid_core_key "$core_key"; then
      invalid=$((invalid + 1))
      continue
    fi
    read -r key_type key_base64 <<<"$core_key"
    if _auth_file_has_key "$auth_file" "$key_type" "$key_base64"; then
      warn "该公钥已经存在于 authorized_keys 中，已跳过重复追加。"
      skipped=$((skipped + 1))
      continue
    fi
    key_options=$(printf '%s\n' "$line" | extract_key_options)
    if [ -n "$key_options" ]; then
      auth_entry="${key_options} ${core_key}"
    else
      auth_entry="$core_key"
    fi
    if ! printf '%s\n' "${auth_entry} [${ts}|${source_tag}]" >>"$auth_file"; then
      err "无法写入 authorized_keys。"
      return 1
    fi
    ok "已成功追加公钥 (${source_tag})"
    added=$((added + 1))
  done <<<"$pub_content"
  if ! chmod 600 "$auth_file"; then
    err "无法设置 authorized_keys 权限。"
    return 1
  fi
  if [ "$added" -eq 0 ] && [ "$skipped" -eq 0 ]; then
    [ "$invalid" -gt 0 ] && err "未找到有效 SSH 公钥，未写入任何内容。"
    return 1
  fi
  if [ "$added" -eq 0 ] && [ "$skipped" -gt 0 ]; then
    note "所导入的公钥均已存在于 authorized_keys 中。"
  fi
  return 0
}

# 统计 authorized_keys 中有效公钥数量
count_authorized_keys() {
  local auth_file="${HOME}/.ssh/authorized_keys" count=0 line core_key
  [ -s "$auth_file" ] || {
    echo 0
    return
  }
  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    core_key=$(printf '%s\n' "$line" | extract_core_key)
    is_valid_core_key "$core_key" && count=$((count + 1))
  done <"$auth_file"
  echo "$count"
}

# 判断 authorized_keys 是否有有效公钥
has_valid_pubkey() {
  [ "$(count_authorized_keys)" -gt 0 ]
}

# ============ Fail2Ban ============
# 读指定段的 key 值（段内最后一次出现者为准）
_f2b_read_kv() {
  awk -v t="$1" -v k="$2" '
        BEGIN { in_block=0; result="" }
        $0 ~ "^[[:space:]]*\\[" t "\\][[:space:]]*([#;].*)?$" { in_block=1; next }
        /^[[:space:]]*\[/ { in_block=0 }
        in_block && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
            value=$0
            sub(/^[[:space:]]*[^=]+=[[:space:]]*/, "", value)
            sub(/[[:space:]]+$/, "", value)
            result = value
        }
        END { if (result != "") print result }
    ' "$JAIL_CONF"
}

# 参数读取：优先 [sshd] 段 → 读不到再读 [DEFAULT] 段
# 递增参数（bantime.increment/factor/maxtime）只应在 [DEFAULT] 段生效
get_f2b_conf() {
  local key=$1 result
  [ -f "$JAIL_CONF" ] || return
  result=$(_f2b_read_kv "$TARGET_JAIL" "$key")
  [ -z "$result" ] && result=$(_f2b_read_kv DEFAULT "$key")
  printf '%s\n' "$result"
}

# 参数写入：
# - bantime.increment / bantime.factor / bantime.maxtime / dbfile / dbpurgeage 属于 [DEFAULT] 段
# - 其余参数写入 [sshd] 段
# 写入失败时的统一清理：删临时文件，若本次新建了备份则还原并回收
_f2b_write_abort() {
  [ -n "${1:-}" ] && rm -f "$1"
  [ "${2:-0}" -eq 1 ] && {
    restore_f2b_config
    commit_f2b_config
  }
  return 1
}

set_f2b_conf() {
  local key="$1" val="$2" target_section="$TARGET_JAIL"
  local tmpf input_file backup_created=0
  case "$key" in
    bantime.increment | bantime.factor | bantime.maxtime | dbfile | dbpurgeage)
      target_section="DEFAULT"
      ;;
  esac

  if [ -z "$F2B_BACKUP_DIR" ]; then
    backup_f2b_config || return 1
    backup_created=1
  fi
  tmpf=$(mktemp "$VPS_RUNTIME_DIR/f2b-config.XXXXXX") || {
    _f2b_write_abort "" "$backup_created"
    return 1
  }
  input_file="$JAIL_CONF"
  [ -f "$input_file" ] || input_file=/dev/null
  # 一次 awk 完成 section/key 的插入或替换，再通过原子写入替换配置；
  # 不再把用户输入拼接进 sed 表达式，也不会留下半写入的 jail.local。
  awk -v t="$target_section" -v k="$key" -v v="$val" '
        BEGIN { in_target=0; section_seen=0; key_written=0 }
        /^[[:space:]]*\[/ {
            if (in_target && !key_written) print k " = " v
            in_target=0
            header=$0
            sub(/^[[:space:]]*/, "", header)
            sub(/[[:space:]]*([#;].*)?$/, "", header)
            if (header == "[" t "]") {
                in_target=1
                section_seen=1
                key_written=0
            }
            print
            next
        }
        in_target {
            line=$0
            sub(/^[[:space:]]*/, "", line)
            current_key=line
            sub(/[[:space:]=].*$/, "", current_key)
            if (current_key == k) {
                if (!key_written) print k " = " v
                key_written=1
                next
            }
        }
        { print }
        END {
            if (in_target && !key_written) print k " = " v
            if (!section_seen) print "\n[" t "]\n" k " = " v
        }
    ' "$input_file" 2>/dev/null >"$tmpf" || {
    _f2b_write_abort "$tmpf" "$backup_created"
    return 1
  }
  atomic_write_file "$JAIL_CONF" 644 <"$tmpf" || {
    _f2b_write_abort "$tmpf" "$backup_created"
    return 1
  }
  rm -f "$tmpf"

  if command -v fail2ban-client &>/dev/null && ! fail2ban-client -t >/dev/null 2>&1; then
    err "Fail2Ban 配置测试失败，已恢复原配置。"
    if [ "$backup_created" -eq 1 ]; then
      restore_f2b_config
      commit_f2b_config
    fi
    return 1
  fi
  [ "$backup_created" -eq 1 ] && commit_f2b_config
  return 0
}

# 轮询等待 Fail2Ban 就绪（首次启动可能稍慢）
wait_f2b_ready() {
  local i=0
  while [ "$i" -lt 5 ]; do
    fail2ban-client ping >/dev/null 2>&1 && return 0
    i=$((i + 1))
    [ "$i" -lt 5 ] && sleep 1
  done
  return 1
}

restart_f2b() {
  ok "正在重载 Fail2Ban 配置..."
  if command -v fail2ban-client &>/dev/null && ! fail2ban-client -t >/dev/null 2>&1; then
    err "Fail2Ban 配置测试失败。"
    return 1
  fi
  if ! svc_restart fail2ban; then
    err "Fail2Ban 服务重启命令失败。"
    return 1
  fi
  if wait_f2b_ready; then
    ok "成功！配置已加载。"
    return 0
  fi
  err "Fail2Ban 重启超时或失败。"
  if [ "$INIT_SYS" = "systemd" ]; then
    echo -e "${Y}请手动运行 'journalctl -u fail2ban -n 50' 排查错误。${N}"
  else
    echo -e "${Y}请手动检查 '${LOG_FILE}' 排查错误。${N}"
  fi
  return 1
}

get_fail2ban_status() {
  # 清命令缓存，否则 bash 会记住已被卸载的旧路径，
  # 导致 apt remove 后 command -v 仍返回旧路径、状态显示"已安装"。
  hash -r 2>/dev/null
  if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
    local count
    count=$(fail2ban-client status "$TARGET_JAIL" 2>/dev/null | grep -i "Currently banned" | awk '{print $NF}')
    echo -e "${G}防护中 (已封禁${count:-0} IP)${N}"
  elif command -v fail2ban-client >/dev/null 2>&1; then
    echo -e "${Y}已安装 / 已停止${N}"
  else
    echo -e "${Y}未安装${N}"
  fi
}

fmt_f2b_unit() {
  local val=$1 type=$2
  [ -z "$val" ] && {
    echo "未设置"
    return
  }
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    if [ "$type" = "time" ]; then
      echo "${val}秒"
    elif [ "$type" = "factor" ]; then
      echo "${val}倍"
    else
      echo "$val"
    fi
  else
    echo "$val"
  fi
}

validate_time() { [[ "$1" =~ ^[1-9][0-9]*[smhdw]?$ ]]; }
validate_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
validate_float() { [[ "$1" =~ ^[1-9][0-9]*(\.[0-9]+)?$ ]]; }

f2b_ssh_filter() {
  if [ "$OS_ID" = "alpine" ] && [ -f /etc/fail2ban/filter.d/alpine-sshd.conf ]; then
    printf '%s\n' alpine-sshd
  else
    printf '%s\n' sshd
  fi
}

# systemd 环境默认走 journal，不写死 logpath（避免 WARN）
# port 动态读取当前 SSH 端口，避免装 F2B 前已改端口时防护失效
# 递增参数 + 数据库配置写入 [DEFAULT] 段（Fail2Ban 官方要求）
generate_default_jail_conf() {
  local backend="auto"
  local logpath_line="logpath = ${SSH_LOG}"
  if [ "$INIT_SYS" = "systemd" ]; then
    backend="systemd"
    logpath_line=""
  fi
  local ssh_filter
  ssh_filter=$(f2b_ssh_filter)
  local banaction="iptables-multiport"
  if ! command -v iptables &>/dev/null && command -v nft &>/dev/null; then
    banaction="nftables-multiport"
  fi
  local current_port
  if ! current_port=$(get_sshd_config_vals "Port" | paste -sd ',' -) || [ -z "$current_port" ]; then
    err "无法解析当前 SSH 配置（sshd -T 失败），已取消生成 Fail2Ban 配置。"
    return 1
  fi
  cat <<EOF2
[DEFAULT]
backend = ${backend}
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
dbpurgeage = 648000
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 7d

[${TARGET_JAIL}]
enabled = true
port = ${current_port}
filter = ${ssh_filter}
EOF2
  [ -n "$logpath_line" ] && printf '%s\n' "$logpath_line"
  cat <<EOF2
maxretry = 5
bantime = 600
findtime = 3600
banaction = ${banaction}
ignoreip = 127.0.0.1/8
EOF2
}

# 迁移：老配置里 [sshd] 段的递增参数挪到 [DEFAULT] 段
# 确保 dbfile 和 dbpurgeage 存在（递增功能必需数据库支持）
migrate_f2b_increment() {
  [ -f "$JAIL_CONF" ] || return 0
  [ -d "/var/lib/fail2ban" ] || {
    mkdir -p /var/lib/fail2ban
    chmod 755 /var/lib/fail2ban 2>/dev/null || true
  }

  # 1. 移除 [sshd] 段内误放的递增参数
  local tmpf
  tmpf=$(mktemp "$VPS_RUNTIME_DIR/f2b-migrate.XXXXXX") || return 1
  if ! awk -v t="$TARGET_JAIL" '
        BEGIN { in_target=0 }
        /^[[:space:]]*\[/ {
            header=$0; sub(/^[[:space:]]*/, "", header); sub(/[[:space:]]*([#;].*)?$/, "", header)
            in_target = (header == "[" t "]")
            print; next
        }
        in_target && /^[[:space:]]*(bantime\.(increment|factor|maxtime))[[:space:]=]/ { next }
        { print }
    ' "$JAIL_CONF" >"$tmpf" || ! atomic_write_file "$JAIL_CONF" 644 <"$tmpf"; then
    rm -f "$tmpf"
    return 1
  fi
  rm -f "$tmpf"

  # 2. 补齐 [DEFAULT] 段的递增与数据库参数
  local item k v
  local defaults=(
    "dbfile=/var/lib/fail2ban/fail2ban.sqlite3"
    "dbpurgeage=648000"
    "bantime.increment=true"
    "bantime.factor=2"
    "bantime.maxtime=7d"
  )
  for item in "${defaults[@]}"; do
    k="${item%%=*}"
    v="${item#*=}"
    if [ -z "$(get_f2b_conf "$k")" ]; then
      set_f2b_conf "$k" "$v" || return 1
    fi
  done
}

# Fail2Ban 依赖包：非 systemd 环境需要 rsyslog 提供日志
f2b_packages() {
  case "$PKG_MGR" in
    apt)
      printf '%s\n' fail2ban
      [ "$INIT_SYS" = "systemd" ] && printf '%s\n' python3-systemd
      [ "$INIT_SYS" != "systemd" ] && printf '%s\n' rsyslog
      ;;
    apk) printf '%s\n' fail2ban ;;
  esac
}

_ensure_f2b_log_ready() {
  [ "$INIT_SYS" = "systemd" ] && return 0
  if [ "$OS_ID" = "alpine" ]; then
    svc_enable syslog >/dev/null 2>&1 || true
    svc_start syslog >/dev/null 2>&1 || true
  else
    svc_enable rsyslog >/dev/null 2>&1 || true
    svc_start rsyslog >/dev/null 2>&1 || true
  fi
  if [ -n "${SSH_LOG:-}" ] && [ ! -f "$SSH_LOG" ]; then
    mkdir -p "$(dirname "$SSH_LOG")" 2>/dev/null || true
    touch "$SSH_LOG" 2>/dev/null && chmod 640 "$SSH_LOG" 2>/dev/null || true
  fi
}

check_f2b_install() {
  local install_confirm="" f2b_fix_opt="" item=""
  hash -r 2>/dev/null
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    warn "未检测到 Fail2Ban 服务。"
    read -rp "${C}[注意]${N} 是否立即安装 Fail2Ban？(y/N，q=取消): " install_confirm
    [[ ! "$install_confirm" =~ ^[Yy]$ ]] && {
      warn "已取消安装。"
      return 1
    }

    ok "正在安装 Fail2Ban 及相关依赖..."
    local -a f2b_pkgs
    mapfile -t f2b_pkgs < <(f2b_packages)

    if ! pkg_install "${f2b_pkgs[@]}"; then
      err "Fail2Ban 及其依赖安装失败。"
      return 1
    fi

    if ! command -v fail2ban-client >/dev/null 2>&1; then
      err "Fail2Ban 安装失败"
      check_eol_system
      echo -e "${Y}请先解决软件源问题，然后重新运行本脚本。${N}"
      sleep 1
      return 1
    fi

    if [ ! -d "/etc/fail2ban" ]; then
      err "/etc/fail2ban 目录不存在，安装可能不完整"
      echo -e "${Y}请检查 Fail2Ban 是否安装成功：dpkg -l | grep fail2ban${N}"
      sleep 1
      return 1
    fi

    if ! command -v iptables &>/dev/null && ! command -v nft &>/dev/null; then
      warn "未检测到 iptables 或 nftables，Fail2Ban 可能无法执行封禁规则。"
    fi

    _ensure_f2b_log_ready

    # 先生成配置文件（含递增参数 + 数据库配置），保证后续 restart 能读到完整配置
    if [ ! -f "$JAIL_CONF" ]; then
      local init_jail
      if init_jail=$(generate_default_jail_conf); then
        printf '%s\n' "$init_jail" | atomic_write_file "$JAIL_CONF" 644 || warn "无法写入 ${JAIL_CONF}"
      else
        warn "无法解析 SSH 端口，跳过自动生成 ${JAIL_CONF}"
      fi
    fi

    # 确保数据库目录存在（指数递增依赖数据库持久化 IP 历史封禁次数）
    [ ! -d "/var/lib/fail2ban" ] && {
      mkdir -p /var/lib/fail2ban
      chmod 755 /var/lib/fail2ban
    }

    svc_enable fail2ban
    # 关键修复：包管理器安装时可能已经自动启动 fail2ban（读的是默认 jail.conf），
    # 此时若用 svc_start 就是空操作，导致刚写入的 jail.local 不被加载。
    # 必须用 svc_restart 强制重读配置，否则指数递增不生效，直到 reboot 才行。
    if ! svc_restart fail2ban; then
      err "Fail2Ban 服务启动失败，请检查服务日志。"
      return 1
    fi

    # 轮询确认服务真正就绪（首次启动可能稍慢）
    if wait_f2b_ready; then
      ok "Fail2Ban 安装并启动完成！"
    else
      warn "Fail2Ban 已安装，但服务尚未就绪，请稍后手动检查。"
    fi
    sleep 1
    return 0
  fi

  # 已安装 fail2ban-client，但 /etc/fail2ban 目录缺失 = 残缺安装
  if [ ! -d "/etc/fail2ban" ]; then
    err "Fail2Ban 处于残缺状态：命令存在但 /etc/fail2ban 目录缺失"
    echo -e "${Y}可能是之前的卸载操作没有清理干净。${N}"
    printf "${C}1${N}  尝试修复（重新安装 Fail2Ban 以重建配置目录）\n"
    printf "${C}2${N}  强制卸载 Fail2Ban 残留\n"
    printf "${C}0${N}  返回\n"
    read_menu_choice "> " '^(0|1|2|[qQ])$' || return 1
    f2b_fix_opt="$REPLY"
    if is_q "$f2b_fix_opt" || [ "$f2b_fix_opt" = "0" ]; then return 1; fi
    case "$f2b_fix_opt" in
      1)
        ok "正在重新安装 Fail2Ban..."
        local -a f2b_pkgs
        mapfile -t f2b_pkgs < <(f2b_packages)
        if ! pkg_reinstall "${f2b_pkgs[@]}"; then
          err "Fail2Ban 修复安装失败。"
          return 1
        fi
        if [ -d "/etc/fail2ban" ]; then
          ok "修复成功！"
          sleep 1
        else
          err "修复失败，请手动处理：dpkg -l | grep fail2ban"
          sleep 1
          return 1
        fi
        ;;
      2)
        warn "正在强制卸载 Fail2Ban..."
        svc_stop fail2ban 2>/dev/null
        svc_disable fail2ban 2>/dev/null
        pkg_remove fail2ban
        # 兜底：apt 失败时直接用 dpkg 清（dpkg 数据库损坏场景）
        hash -r 2>/dev/null
        if command -v fail2ban-client &>/dev/null; then
          if [ "$PKG_MGR" = "apt" ]; then
            warn "检测到残留，尝试 dpkg 强制清除..."
            dpkg --purge --force-all fail2ban 2>/dev/null || true
          fi
          remove_fail2ban_fallback_files
          hash -r 2>/dev/null
        fi
        rm -rf /etc/fail2ban
        remove_fail2ban_fallback_files
        ok "Fail2Ban 已强制卸载。"
        sleep 1
        return 1
        ;;
      *)
        return 1
        ;;
    esac
  fi

  # Debian/Ubuntu systemd 环境补齐可能缺失的 python3-systemd（提前手动装过 fail2ban 的场景）
  if [ "$PKG_MGR" = "apt" ] && [ "$INIT_SYS" = "systemd" ] && ! pkg_is_installed python3-systemd; then
    warn "检测到 systemd 环境缺少 python3-systemd，正在补装..."
    if ! pkg_install python3-systemd; then
      err "python3-systemd 安装失败，systemd 后端可能无法工作。"
      return 1
    fi
  fi

  if ! command -v iptables &>/dev/null && ! command -v nft &>/dev/null; then
    warn "未检测到 iptables 或 nftables，Fail2Ban 可能无法执行封禁规则。"
  fi
  _ensure_f2b_log_ready

  if ! backup_f2b_config; then
    err "无法备份 Fail2Ban 配置，操作已取消。"
    return 1
  fi
  local was_running=0
  [ -f "$F2B_BACKUP_DIR/was-running" ] && was_running=1

  # 记录配置修改前的哈希（md5sum 更高效，避免大文件全文对比）
  local conf_hash_before=""
  [ -f "$JAIL_CONF" ] && conf_hash_before=$(md5sum "$JAIL_CONF" 2>/dev/null | awk '{print $1}')

  if [ ! -f "$JAIL_CONF" ]; then
    local generated_jail
    if ! generated_jail=$(generate_default_jail_conf); then
      err "无法解析 SSH 配置，未生成 Fail2Ban 配置。"
      restore_f2b_config
      commit_f2b_config
      return 1
    fi
    if ! printf '%s\n' "$generated_jail" | atomic_write_file "$JAIL_CONF" 644; then
      err "无法写入 Fail2Ban 配置。"
      restore_f2b_config
      commit_f2b_config
      return 1
    fi
  else
    if ! grep -Eq "^[[:space:]]*\[DEFAULT\]" "$JAIL_CONF"; then
      local be="auto"
      [ "$INIT_SYS" = "systemd" ] && be="systemd"
      local tmp_d
      if ! tmp_d=$(mktemp "$VPS_RUNTIME_DIR/f2b-default.XXXXXX") \
        || ! printf '[DEFAULT]\nbackend = %s\n\n' "$be" | cat - "$JAIL_CONF" >"$tmp_d" \
        || ! atomic_write_file "$JAIL_CONF" 644 <"$tmp_d"; then
        [ -n "${tmp_d:-}" ] && rm -f "$tmp_d"
        err "无法写入 Fail2Ban [DEFAULT] 配置。"
        restore_f2b_config
        commit_f2b_config
        return 1
      fi
      rm -f "$tmp_d"
    fi
    # 迁移老配置：把 [sshd] 段错放的递增参数挪到 [DEFAULT] + 确保数据库配置存在
    if ! migrate_f2b_increment; then
      err "Fail2Ban 递增配置迁移失败，已恢复原配置。"
      restore_f2b_config
      commit_f2b_config
      return 1
    fi
    if ! grep -Eq "^[[:space:]]*\[${TARGET_JAIL}\]" "$JAIL_CONF"; then
      local generated_jail tmp_add
      if ! generated_jail=$(generate_default_jail_conf); then
        err "无法解析 SSH 配置，未补全 Fail2Ban 配置。"
        restore_f2b_config
        commit_f2b_config
        return 1
      fi
      if ! tmp_add=$(mktemp "$VPS_RUNTIME_DIR/f2b-append.XXXXXX") \
        || ! {
          cat "$JAIL_CONF"
          printf '\n'
          printf '%s\n' "$generated_jail" | awk -v t="$TARGET_JAIL" '$0 ~ "^\\[" t "\\]"{f=1} f{print}'
        } >"$tmp_add" \
        || ! atomic_write_file "$JAIL_CONF" 644 <"$tmp_add"; then
        [ -n "${tmp_add:-}" ] && rm -f "$tmp_add"
        err "无法补全 Fail2Ban 配置。"
        restore_f2b_config
        commit_f2b_config
        return 1
      fi
      rm -f "$tmp_add"
    else
      # 保证 [sshd] 段基本参数齐全（不含递增参数，那些归 [DEFAULT]）
      local current_port
      if ! current_port=$(get_sshd_config_vals "Port" | paste -sd ',' -) || [ -z "$current_port" ]; then
        err "无法解析 SSH 端口，已恢复 Fail2Ban 原配置。"
        restore_f2b_config
        commit_f2b_config
        return 1
      fi
      local defaults=(
        "enabled=true" "port=${current_port}" "filter=$(f2b_ssh_filter)" "maxretry=5"
        "bantime=600" "findtime=3600"
      )
      for item in "${defaults[@]}"; do
        local k="${item%%=*}" v="${item#*=}"
        if [ -z "$(get_f2b_conf "$k")" ]; then
          if ! set_f2b_conf "$k" "$v"; then
            err "补全 Fail2Ban 参数 ${k} 失败，已恢复原配置。"
            restore_f2b_config
            commit_f2b_config
            return 1
          fi
        fi
      done
    fi
  fi

  # 关键修复：上面可能有迁移/补全动作改动了 jail.local，
  # 用哈希对比判断配置是否真变化，避免每次进菜单都触发 Restore Ban 刷屏。
  local conf_hash_after=""
  [ -f "$JAIL_CONF" ] && conf_hash_after=$(md5sum "$JAIL_CONF" 2>/dev/null | awk '{print $1}')

  local f2b_apply_ok=1
  if [ "$conf_hash_before" != "$conf_hash_after" ]; then
    # 配置有变化：重载或启动服务让新配置生效
    if fail2ban-client ping >/dev/null 2>&1; then
      restart_f2b || f2b_apply_ok=0
    else
      ok "检测到配置变更，正在启动 Fail2Ban..."
      if svc_start fail2ban && wait_f2b_ready; then
        ok "Fail2Ban 已启动并加载新配置。"
      else
        err "Fail2Ban 启动超时或失败。"
        [ "$INIT_SYS" = "systemd" ] && echo -e "${Y}请手动运行 'journalctl -u fail2ban -n 50' 排查错误。${N}" || echo -e "${Y}请手动检查 '${LOG_FILE}' 排查错误。${N}"
        f2b_apply_ok=0
      fi
    fi
  else
    # 配置未变化：仅做服务状态兜底，避免每次进菜单重启导致 Restore Ban 刷屏
    if ! fail2ban-client ping >/dev/null 2>&1; then
      warn "Fail2Ban 服务未运行，正在尝试启动..."
      svc_start fail2ban
      if wait_f2b_ready; then
        ok "Fail2Ban 已启动。"
      else
        err "Fail2Ban 启动超时或失败。"
        [ "$INIT_SYS" = "systemd" ] && echo -e "${Y}请手动运行 'journalctl -u fail2ban -n 50' 排查错误。${N}" || echo -e "${Y}请手动检查 '${LOG_FILE}' 排查错误。${N}"
      fi
    fi
  fi

  if [ "$f2b_apply_ok" -eq 0 ] || { command -v fail2ban-client &>/dev/null && ! fail2ban-client -t >/dev/null 2>&1; }; then
    err "Fail2Ban 配置校验或服务应用失败，正在恢复原配置。"
    restore_f2b_config
    [ "$was_running" -eq 1 ] && svc_restart fail2ban >/dev/null 2>&1 || true
    commit_f2b_config
    return 1
  fi
  commit_f2b_config
  return 0
}

remove_fail2ban_fallback_files() {
  # 仅清理 Fail2Ban 的已知文件名，绝不使用宽泛的 fail2ban-* 通配符。
  local f
  for f in \
    /usr/bin/fail2ban-client /usr/bin/fail2ban-server \
    /usr/local/bin/fail2ban-client /usr/local/bin/fail2ban-server \
    /var/lib/dpkg/info/fail2ban.list /var/lib/dpkg/info/fail2ban.md5sums \
    /var/lib/dpkg/info/fail2ban.conffiles /var/lib/dpkg/info/fail2ban.config \
    /var/lib/dpkg/info/fail2ban.postinst /var/lib/dpkg/info/fail2ban.prerm \
    /var/lib/dpkg/info/fail2ban.postrm /var/lib/dpkg/info/fail2ban.triggers; do
    [ -e "$f" ] && rm -f "$f"
  done
}

uninstall_f2b() {
  local confirm="" del_conf=""
  warn "即将卸载 Fail2Ban 及其配置！"
  read -rp "${C}[注意]${N} 确认卸载吗？(y/N，q=取消): " confirm
  [[ ! "$confirm" =~ ^[Yy]$ ]] && {
    ok "已取消卸载。"
    sleep 1
    return 1
  }
  svc_stop fail2ban
  svc_disable fail2ban
  pkg_remove fail2ban
  # 清 bash 命令缓存：否则 command -v 仍返回已删除的旧路径，
  # 导致卸载后状态仍显示"已安装 / 已停止"。
  hash -r 2>/dev/null
  # 兜底：apt 卸载失败时用 dpkg 强制清除（dpkg 数据库损坏 / 静默失败场景）
  if [ "$PKG_MGR" = "apt" ] && { command -v fail2ban-client &>/dev/null || dpkg-query -W fail2ban >/dev/null 2>&1; }; then
    warn "检测到 Fail2Ban 残留，尝试 dpkg 强制清除..."
    dpkg --purge --force-all fail2ban 2>/dev/null || true
  fi
  # 再兜底：仅删除已知的 Fail2Ban 二进制文件名。
  remove_fail2ban_fallback_files
  hash -r 2>/dev/null
  read -rp "${C}[注意]${N} 是否同时删除配置目录 /etc/fail2ban？(y/N，q=取消): " del_conf
  [[ "$del_conf" =~ ^[Yy]$ ]] && {
    rm -rf /etc/fail2ban
    ok "已删除 /etc/fail2ban"
  }
  ok "Fail2Ban 卸载完成。"
  sleep 1
  return 0
}

change_f2b_param() {
  local name=$1 key=$2 type=$3
  local current new_val=""
  current=$(get_f2b_conf "$key")
  info "正在修改: ${C}${name}${N}"
  echo -e "当前值: ${G}$(fmt_f2b_unit "$current" "$type")${N}"
  [ "$type" == "time" ] && echo -e "${D}(支持后缀: s=秒, m=分, h=小时, d=天)${N}"
  while true; do
    read -rp "${C}[注意]${N} 请输入新值（留空或输入 q 取消）： " new_val || return
    is_q "$new_val" && return
    [ -z "$new_val" ] && return
    if [ "$type" == "time" ] && validate_time "$new_val"; then break; fi
    if [ "$type" == "int" ] && validate_int "$new_val"; then break; fi
    if [ "$type" == "factor" ] && validate_float "$new_val"; then break; fi
    printf '\033[1A\r\033[2K'
    transient_error "格式错误，请重试。"
  done
  if ! backup_f2b_config; then
    err "无法备份 Fail2Ban 配置，操作已取消。"
    sleep 1
    return 1
  fi
  if ! set_f2b_conf "$key" "$new_val"; then
    err "Fail2Ban 配置未修改。"
    restore_f2b_config
    commit_f2b_config
    sleep 1
    return 1
  fi
  if ! restart_f2b; then
    err "Fail2Ban 重启失败，正在恢复原配置。"
    restore_f2b_config
    restart_f2b >/dev/null 2>&1 || true
    commit_f2b_config
    sleep 1
    return 1
  fi
  commit_f2b_config
}

toggle_f2b_service() {
  local confirm=""
  printf "${C}▸${N} ${B}服务开关${N}\n"
  if fail2ban-client ping >/dev/null 2>&1; then
    read -rp "${C}[注意]${N} 是否停止并禁用 Fail2Ban？(y/N，q=取消): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] && {
      svc_stop fail2ban
      svc_disable fail2ban
      warn "服务已停止。"
    }
  else
    read -rp "${C}[注意]${N} 是否启用并启动 Fail2Ban？(y/N，q=取消): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      svc_enable fail2ban
      svc_start fail2ban
      if wait_f2b_ready; then
        ok "服务已成功启动。"
        sleep 1
        return
      fi
      err "启动失败或超时。"
    fi
  fi
  sleep 1
}

unban_f2b_ip() {
  printf "${C}▸${N} ${B}手动解封 IP${N}\n"
  local banned_list target_ip=""
  banned_list=$(fail2ban-client status "$TARGET_JAIL" 2>/dev/null | grep "Banned IP list" | awk -F':' '{print $2}' | sed 's/^[ \t]*//')
  [ -z "$banned_list" ] && banned_list="无"
  echo -e "当前被封禁列表: ${Y}${banned_list}${N}"
  while true; do
    read -rp "${C}[注意]${N} 输入要解封的 IP（留空或输入 q 取消）： " target_ip || return 1
    [ -z "$target_ip" ] && return
    is_q "$target_ip" && return
    if validate_ip_or_cidr "$target_ip"; then
      break
    fi
    printf '\033[1A\r\033[2K'
    transient_error "IP 或 CIDR 格式不正确，请重试。"
  done
  if fail2ban-client set "$TARGET_JAIL" unbanip "$target_ip"; then
    ok "解封成功: $target_ip"
  else
    err "操作失败。"
  fi
  sleep 1
}

validate_ip_or_cidr() {
  local value="$1" address prefix octet left right after_slash
  [[ "$value" != *[!0-9A-Fa-f:./]* ]] || return 1
  address="$value"
  prefix=""
  if [[ "$value" == */* ]]; then
    after_slash="${value#*/}"
    [[ "$after_slash" != */* ]] || return 1
    address="${value%%/*}"
    prefix="${value##*/}"
    [[ "$prefix" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  fi
  [ -n "$address" ] || return 1
  if [[ "$address" == *:* ]]; then
    local groups=() group_count=0
    if [[ "$address" == *::* ]]; then
      # IPv6 compression may occur exactly once and must replace at least one group.
      local remainder="${address/::/}"
      [[ "$remainder" != *::* ]] || return 1
      left="${address%%::*}"
      right="${address#*::}"
      [ -z "$left" ] || {
        [[ "$left" != :* && "$left" != *: ]] || return 1
        IFS=: read -r -a groups <<<"$left"
        group_count=$((group_count + ${#groups[@]}))
        for octet in "${groups[@]}"; do [[ "$octet" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; done
      }
      groups=()
      [ -z "$right" ] || {
        [[ "$right" != :* && "$right" != *: ]] || return 1
        IFS=: read -r -a groups <<<"$right"
        group_count=$((group_count + ${#groups[@]}))
        for octet in "${groups[@]}"; do [[ "$octet" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; done
      }
      [ "$group_count" -lt 8 ] || return 1
    else
      [[ "$address" != :* && "$address" != *: ]] || return 1
      IFS=: read -r -a groups <<<"$address"
      [ "${#groups[@]}" -eq 8 ] || return 1
    fi
    for octet in "${groups[@]}"; do
      [[ -n "$octet" && "$octet" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
    [ -z "$prefix" ] || [ "$prefix" -le 128 ]
    return
  fi
  [[ "$address" != .* && "$address" != *. && "$address" != *..* ]] || return 1
  IFS=. read -r -a groups <<<"$address"
  [ "${#groups[@]}" -eq 4 ] || return 1
  for octet in "${groups[@]}"; do
    [[ "$octet" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    [ "$octet" -le 255 ] || return 1
  done
  [ -z "$prefix" ] || [ "$prefix" -le 32 ]
}

add_f2b_whitelist() {
  printf "${C}▸${N} ${B}白名单管理${N}\n"
  local current_list current_ip input_ip="" op="add" target_ip="" new_list=""
  current_list=$(get_f2b_conf "ignoreip")
  echo -e "当前白名单: ${Y}${current_list:-继承全局或无}${N}"
  current_ip=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
  while true; do
    read -rp "${C}[注意]${N} 输入放行 IP（回车默认当前连接 IP，输入 -IP 移除，q=取消）： " input_ip || return
    is_q "$input_ip" && return
    if [[ "$input_ip" == -* ]]; then
      op="del"
      target_ip="${input_ip#-}"
    else
      op="add"
      target_ip="$input_ip"
      [ -z "$target_ip" ] && target_ip="$current_ip"
    fi
    if [ -z "$target_ip" ]; then
      err "无法获取 IP。"
      sleep 1
      return
    fi
    if validate_ip_or_cidr "$target_ip"; then
      break
    fi
    printf '\033[1A\r\033[2K'
    transient_error "IP 或 CIDR 格式不正确，请重试。"
  done

  if [ "$op" = "del" ]; then
    if ! printf '%s\n' "$current_list" | awk -v ip="$target_ip" '{gsub(/,/, " "); for (i = 1; i <= NF; i++) if ($i == ip) found=1} END {exit !found}'; then
      warn "该 IP 不在当前白名单中。"
      sleep 1
      return
    fi
    new_list=$(printf '%s\n' "$current_list" | awk -v ip="$target_ip" '{gsub(/,/, " "); out=""; for (i = 1; i <= NF; i++) if ($i != ip) out = out (out == "" ? "" : " ") $i; print out}')
  else
    if printf '%s\n' "$current_list" | awk -v ip="$target_ip" '{gsub(/,/, " "); for (i = 1; i <= NF; i++) if ($i == ip) found=1} END {exit !found}'; then
      warn "该 IP 已在白名单中。"
      sleep 1
      return
    fi
    if [ -z "$current_list" ]; then
      new_list="$target_ip"
    else
      new_list="$current_list $target_ip"
    fi
  fi

  if ! backup_f2b_config; then
    err "无法备份 Fail2Ban 配置，操作已取消。"
  elif set_f2b_conf "ignoreip" "$new_list"; then
    if restart_f2b; then
      commit_f2b_config
    else
      err "Fail2Ban 重启失败，正在恢复白名单配置。"
      restore_f2b_config
      restart_f2b >/dev/null 2>&1 || true
      commit_f2b_config
    fi
  else
    err "Fail2Ban 配置未修改。"
    restore_f2b_config
    commit_f2b_config
  fi
  sleep 1
}

view_f2b_logs() {
  title "Fail2Ban 审计日志 (最近 20 条)"
  local out=""
  if [ "$INIT_SYS" = "systemd" ] && command -v journalctl &>/dev/null; then
    out=$(journalctl -u fail2ban --no-pager -n 200 2>/dev/null | grep -E '(^|[^[:alnum:]_])(Ban|Unban)([^[:alnum:]_]|$)' | tail -n 20)
  elif [ -f "$LOG_FILE" ]; then
    out=$(grep -E '(^|[^[:alnum:]_])(Ban|Unban)([^[:alnum:]_]|$)' "$LOG_FILE" 2>/dev/null | tail -n 20)
  elif [ "$OS_ID" = "alpine" ] && [ -f /var/log/messages ]; then
    out=$(grep -E 'fail2ban\.' /var/log/messages 2>/dev/null | grep -E '(^|[^[:alnum:]_])(Ban|Unban)([^[:alnum:]_]|$)' | tail -n 20)
  else
    warn "日志文件不存在: $LOG_FILE"
  fi
  if [ -z "$out" ]; then
    warn "暂无封禁/解封记录"
  else
    printf '%s\n' "$out" | awk '{
            gsub(/Unban /, "\033[32mUnban\033[0m ");
            gsub(/Ban /, "\033[31mBan\033[0m ");
            print
        }'
  fi
  pause
}

menu_f2b_exponential() {
  local sc=""
  while true; do
    local inc fac max
    inc=$(get_f2b_conf "bantime.increment")
    fac=$(get_f2b_conf "bantime.factor")
    max=$(get_f2b_conf "bantime.maxtime")
    local S_INC
    [ "$inc" == "true" ] && S_INC="${G}启用${N}" || S_INC="${Y}禁用${N}"
    title "指数封禁设置（针对 sshd）"
    printf "${D}对重复犯错的恶意 IP，封禁时间按设定系数成倍递增${N}\n"
    printf "${C}1${N}  递增模式开关   [%b]\n" "$S_INC"
    printf "${C}2${N}  增长系数       [${Y}%s${N}]\n" "$(fmt_f2b_unit "$fac" "factor")"
    printf "${C}3${N}  封禁上限       [${Y}%s${N}]\n" "$(fmt_f2b_unit "$max" "time")"
    printf "${C}0${N}  返回\n"
    read_menu_choice "> " '^(0|1|2|3|[qQ])$' || return
    sc="$REPLY"
    if is_q "$sc" || [ "$sc" = "0" ]; then return; fi
    case "$sc" in
      1)
        local ns
        [ "$inc" == "true" ] && ns="false" || ns="true"
        if ! backup_f2b_config; then
          err "无法备份 Fail2Ban 配置。"
        elif ! set_f2b_conf "bantime.increment" "$ns"; then
          err "Fail2Ban 配置未修改。"
          restore_f2b_config
          commit_f2b_config
        elif restart_f2b; then
          commit_f2b_config
        else
          err "Fail2Ban 重启失败，正在恢复原配置。"
          restore_f2b_config
          restart_f2b >/dev/null 2>&1 || true
          commit_f2b_config
        fi
        ;;
      2) change_f2b_param "增长系数 (倍数)" "bantime.factor" "factor" ;;
      3) change_f2b_param "封禁上限 (时间)" "bantime.maxtime" "time" ;;
    esac
  done
}

manage_fail2ban_menu() {
  if ! check_f2b_install; then
    sleep 1
    return
  fi
  local VAL_MAX="" VAL_BAN="" VAL_FIND="" choice=""
  while true; do
    VAL_MAX=$(get_f2b_conf "maxretry")
    VAL_BAN=$(get_f2b_conf "bantime")
    VAL_FIND=$(get_f2b_conf "findtime")
    title "Fail2Ban 防护管理 · $(get_fail2ban_status)"
    printf "${C}1${N}  最大重试次数   [${Y}%s${N}]\n" "${VAL_MAX:-默认}"
    printf "${C}2${N}  初始封禁时间   [${Y}%s${N}]\n" "$(fmt_f2b_unit "${VAL_BAN:-默认}" "time")"
    printf "${C}3${N}  检测时间窗口   [${Y}%s${N}]\n" "$(fmt_f2b_unit "${VAL_FIND:-默认}" "time")"
    printf "${C}4${N}  手动解封 IP\n"
    printf "${C}5${N}  IP 白名单管理\n"
    printf "${C}6${N}  查看封禁日志\n"
    printf "${C}7${N}  指数递增封禁设置\n"
    printf "${C}8${N}  启用 / 停止 服务\n"
    printf "${C}9${N}  ${R}卸载 Fail2Ban${N}\n"
    printf "${C}0${N}  返回\n"
    read_menu_choice "> " '^([0-9]|[qQ])$' || return
    choice="$REPLY"
    if is_q "$choice" || [ "$choice" = "0" ]; then return; fi
    case "$choice" in
      1) change_f2b_param "最大重试次数" "maxretry" "int" ;;
      2) change_f2b_param "初始封禁时长" "bantime" "time" ;;
      3) change_f2b_param "监测时间窗口" "findtime" "time" ;;
      4) unban_f2b_ip ;;
      5) add_f2b_whitelist ;;
      6) view_f2b_logs ;;
      7) menu_f2b_exponential ;;
      8) toggle_f2b_service ;;
      9) # 卸载后根据返回值决定是否返回主菜单：
        #   uninstall_f2b 返回 0 = 卸载完成 → 返回主菜单
        #   uninstall_f2b 返回 1 = 用户取消 → 留在本菜单
        if uninstall_f2b; then
          return
        fi
        ;;
    esac
  done
}

# ============ 状态面板 ============
show_status() {
  local dump port ports pwd_auth kbd_auth pubkey_auth root_login
  if ! dump=$(_sshd_dump_config); then
    err "无法读取 SSH 有效配置（sshd -T 失败），状态面板已取消。"
    return 1
  fi
  ports=$(_sshd_vals_from_dump "$dump" "port" | paste -sd ',' -)
  port="${ports:-未知}"
  pwd_auth=$(_sshd_val_from_dump "$dump" "passwordauthentication")
  kbd_auth=$(_sshd_val_from_dump "$dump" "kbdinteractiveauthentication")
  pubkey_auth=$(_sshd_val_from_dump "$dump" "pubkeyauthentication")
  root_login=$(_sshd_val_from_dump "$dump" "permitrootlogin")
  if [ -z "$ports" ] || [ -z "$pwd_auth" ] || [ -z "$pubkey_auth" ]; then
    err "SSH 有效配置缺失关键字段，状态面板已取消。"
    return 1
  fi
  local f2b_stat key_count
  f2b_stat=$(get_fail2ban_status)
  key_count=$(count_authorized_keys)

  printf "${B}SSH 安全配置状态${N}\n"
  echo -e "系统架构 : ${G}${OS_SHORT} ${OS_VER}${N}"
  if [[ "${pubkey_auth,,}" == "yes" ]]; then
    if [ "$key_count" -gt 0 ]; then
      echo -e "密钥登录 : ${G}已启用 (${key_count} 把公钥)${N}"
    else
      echo -e "密钥登录 : ${Y}已启用 (但无公钥，无法密钥登录)${N}"
    fi
  else
    echo -e "密钥登录 : ${Y}已禁用${N}"
  fi
  if [[ "${pwd_auth,,}" == "no" ]]; then
    if [[ "${kbd_auth,,}" == "yes" ]]; then
      echo -e "密码登录 : ${Y}常规密码已禁用，但 KbdInteractiveAuthentication=yes 仍允许交互认证${N}"
    else
      echo -e "密码登录 : ${G}已禁用 (PasswordAuthentication no)${N}"
    fi
  elif [[ "${root_login,,}" =~ ^(no|prohibit-password|without-password)$ ]]; then
    echo -e "密码登录 : ${Y}已启用 (但 PermitRootLogin=${root_login}，root 无法密码登录)${N}"
  else
    echo -e "密码登录 : ${Y}已启用 (推荐配置密钥后禁用)${N}"
  fi
  if [[ "${root_login,,}" == "no" ]]; then
    echo -e "Root 登录: ${Y}已禁止 (PermitRootLogin no，root 无法直接登录)${N}"
  fi
  echo -e "Fail2Ban : ${f2b_stat}"
  echo -e "SSH 端口 : ${C}${port}${N}"
}

# ============ 密钥生成 ============
generate_vps_keypair() {
  info "准备在 VPS 上生成新的 ED25519 密钥..."
  local key_file="${HOME}/.ssh/PrivateKey.pem"
  local pub_file="${HOME}/.ssh/PublicKey.pub"
  local work_dir backup_dir="" overwrite_confirm="" rm_confirm=""

  if [ -f "$key_file" ] || [ -f "$pub_file" ] || [ -f "${key_file}.pub" ]; then
    warn "检测到已有同名密钥。覆盖前请确认旧私钥已备份。"
    read -rp "${C}[注意]${N} 确认覆盖现有 VPS 密钥文件吗？(y/N，q=取消): " overwrite_confirm
    [[ "$overwrite_confirm" =~ ^[Yy]$ ]] || return 1
  fi
  init_ssh_dir || {
    err "无法初始化 SSH 目录。"
    return 1
  }
  work_dir=$(mktemp -d "${HOME}/.ssh/.vps-key.XXXXXX") || {
    err "无法创建临时密钥目录。"
    return 1
  }
  chmod 700 "$work_dir"

  # 先在临时目录生成，成功后再替换旧文件，避免生成失败导致旧私钥丢失。
  if ! ssh-keygen -t ed25519 -C "" -f "$work_dir/PrivateKey.pem" -N "" -q; then
    rm -rf "$work_dir"
    err "密钥生成失败，旧密钥未被修改。"
    sleep 1
    return 1
  fi
  if [ ! -f "$work_dir/PrivateKey.pem.pub" ]; then
    rm -rf "$work_dir"
    err "密钥生成失败，旧密钥未被修改。"
    sleep 1
    return 1
  fi

  if [ -f "$key_file" ] || [ -f "$pub_file" ]; then
    backup_dir=$(mktemp -d "${HOME}/.ssh/.vps-key-backup.XXXXXX") || {
      rm -rf "$work_dir"
      return 1
    }
    if [ -f "$key_file" ] && ! cp -a "$key_file" "$backup_dir/PrivateKey.pem"; then
      rm -rf "$work_dir" "$backup_dir"
      err "无法备份旧私钥，操作已取消。"
      return 1
    fi
    if [ -f "$pub_file" ] && ! cp -a "$pub_file" "$backup_dir/PublicKey.pub"; then
      rm -rf "$work_dir" "$backup_dir"
      err "无法备份旧公钥，操作已取消。"
      return 1
    fi
  fi
  if ! mv "$work_dir/PrivateKey.pem" "$key_file" || ! mv "$work_dir/PrivateKey.pem.pub" "$pub_file"; then
    rm -f "$key_file" "$pub_file"
    [ -f "$backup_dir/PrivateKey.pem" ] && mv "$backup_dir/PrivateKey.pem" "$key_file"
    [ -f "$backup_dir/PublicKey.pub" ] && mv "$backup_dir/PublicKey.pub" "$pub_file"
    rm -rf "$work_dir" "$backup_dir"
    err "替换密钥文件失败，已尝试恢复旧密钥。"
    return 1
  fi
  rm -rf "$work_dir"
  if ! chmod 600 "$key_file" || ! chmod 644 "$pub_file"; then
    rm -f "$key_file" "$pub_file"
    [ -f "$backup_dir/PrivateKey.pem" ] && mv "$backup_dir/PrivateKey.pem" "$key_file"
    [ -f "$backup_dir/PublicKey.pub" ] && mv "$backup_dir/PublicKey.pub" "$pub_file"
    rm -rf "$backup_dir"
    err "新密钥权限设置失败，已尝试恢复旧密钥。"
    return 1
  fi

  local pub_content
  pub_content=$(cat "$pub_file")

  if ! append_key_with_meta "$pub_content" "VPS本地生成"; then
    rm -f "$key_file" "$pub_file"
    [ -f "$backup_dir/PrivateKey.pem" ] && mv "$backup_dir/PrivateKey.pem" "$key_file"
    [ -f "$backup_dir/PublicKey.pub" ] && mv "$backup_dir/PublicKey.pub" "$pub_file"
    rm -rf "$backup_dir"
    err "新公钥写入 authorized_keys 失败，已尝试恢复旧密钥。"
    return 1
  fi
  rm -rf "$backup_dir"

  ok "密钥生成成功"
  printf "VPS 私钥路径 : ${C}%s${N}\n" "$key_file"
  printf "VPS 公钥路径 : ${C}%s${N}\n" "$pub_file"
  printf "授权目标文件 : 已将公钥写入 ${C}%s/.ssh/authorized_keys${N}\n" "$HOME"
  note "密钥已生成，私钥不会显示在终端。请通过 SFTP 下载并保管：${C}${key_file}${N}"
  printf "${G}${B}公钥（可上传到 GitHub）：${N}\n"
  printf "${G}%s${N}\n" "$pub_content"

  read -rp "${C}[注意]${N} 确认已保存/下载密钥，是否立即删除 VPS 上的暂存密钥文件？(y/N，q=取消): " rm_confirm
  if [[ "$rm_confirm" =~ ^[Yy]$ ]]; then
    rm -f "$key_file" "$pub_file"
    ok "已成功删除 VPS 上的暂存密钥文件。"
  else
    warn "密钥文件仍保留在: ${key_file} 和 ${pub_file} (请务必防范私钥泄露)"
  fi
}

# ============ 密钥登录开关 ============
toggle_pubkey_login() {
  local current confirm="" confirm_risky=""
  if ! current=$(read_sshd_config_val "PubkeyAuthentication"); then
    sleep 1
    return 1
  fi

  if [[ "${current,,}" == "no" ]]; then
    echo -e "当前密钥登录已${G}禁用${N}。"
    local key_count
    key_count=$(count_authorized_keys)
    if [ "$key_count" -eq 0 ]; then
      note "当前 authorized_keys 中还没有公钥，启用后仍需先添加公钥才能通过密钥登录。"
    fi
    read -rp "${C}[注意]${N} 是否要启用密钥登录？(y/N，q=取消): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      ssh_config_apply "PubkeyAuthentication=yes" \
        && ok "密钥登录已成功启用"
    fi
  else
    warn "禁用密钥登录后，如果密码登录也已禁用，你将无法登录 VPS！"
    if [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
      note "检测到您正在使用 SSH 远程会话，修改后切勿关闭当前窗口！"
    fi

    local pwd_auth
    if ! pwd_auth=$(read_sshd_config_val "PasswordAuthentication"); then
      sleep 1
      return 1
    fi
    if [[ "${pwd_auth,,}" == "no" ]]; then
      warn "检测到密码登录已禁用，禁用密钥登录后你将无法登录此 VPS！"
      read -rp "${C}[注意]${N} 确认仍然要禁用密钥登录吗？(y/N，q=取消): " confirm_risky
      [[ ! "$confirm_risky" =~ ^[Yy]$ ]] && {
        ok "已取消操作。"
        sleep 1
        return
      }
    else
      read -rp "${C}[注意]${N} 确认禁用密钥登录吗？(y/N，q=取消): " confirm
      [[ ! "$confirm" =~ ^[Yy]$ ]] && {
        ok "已取消操作。"
        sleep 1
        return
      }
    fi

    ssh_config_apply "PubkeyAuthentication=no" \
      && ok "密钥登录已禁用，现在只能通过密码登录"
  fi
  sleep 1
}

validate_https_url() {
  local url="$1" authority port
  [[ "$url" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?([/?#][^[:space:]]*)?$ ]] || return 1
  authority="${url#https://}"
  authority="${authority%%[/?#]*}"
  if [[ "$authority" == *:* ]]; then
    port="${authority##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  fi
  return 0
}

install_key_menu() {
  local key_opt="" switch_opt2=""
  while true; do
    init_ssh_dir

    local key_count
    key_count=$(count_authorized_keys)
    local key_count_label
    if [ "$key_count" -gt 0 ]; then
      key_count_label=" (${G}${key_count} 把公钥${N})"
    else
      key_count_label=" (${Y}无公钥${N})"
    fi

    local pubkey_status root_login
    if ! pubkey_status=$(read_sshd_config_val "PubkeyAuthentication"); then
      sleep 1
      return 1
    fi
    root_login=$(get_sshd_config_val "PermitRootLogin" 2>/dev/null || true)
    local pubkey_label
    if [[ "${pubkey_status,,}" == "yes" ]]; then
      pubkey_label="[${G}已启用${N}]"
    else
      pubkey_label="[${Y}已禁用${N}]"
    fi

    title "SSH 密钥登录管理"
    if [[ "${root_login,,}" == "no" ]]; then
      warn "当前 PermitRootLogin=no，root 账户无法使用密钥登录（需先调整 SSH 配置或使用普通用户）。"
    fi
    printf "${C}1${N}  GitHub 公钥导入\n"
    printf "${C}2${N}  本地生成 ED25519 密钥\n"
    printf "${C}3${N}  HTTPS URL 公钥导入\n"
    printf "${C}4${N}  管理已存公钥%b\n" "$key_count_label"
    printf "${C}5${N}  密钥登录开关 %b\n" "$pubkey_label"
    printf "${C}0${N}  返回\n"
    read_menu_choice "> " '^([0-5]|[qQ])$' || return
    key_opt="$REPLY"
    if is_q "$key_opt" || [ "$key_opt" = "0" ]; then return; fi

    local test_hint=""
    local do_restart=0
    local need_pause=0

    case "$key_opt" in
      1)
        note "使用前提：需先将本地公钥上传至 GitHub: ${C}https://github.com/settings/keys${N}"
        local gh_user=""
        while true; do
          read -rp "${C}[注意]${N} 请输入您的 GitHub 用户名（q=取消）： " gh_user || {
            gh_user=""
            break
          }
          is_q "$gh_user" && {
            gh_user=""
            break
          }
          if [[ "$gh_user" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
            break
          fi
          printf '\033[1A\r\033[2K'
          transient_error "GitHub 用户名格式不正确，请重试。"
        done
        [ -z "$gh_user" ] && continue
        if ! backup_authorized_keys; then
          err "无法备份 authorized_keys，操作已取消。"
          sleep 1
          continue
        fi
        ok "正在从 GitHub 拉取公钥..."
        local pub_key="" curl_rc=0
        pub_key=$(curl --fail --silent --show-error --location \
          --connect-timeout 5 --max-time 20 --max-filesize 1048576 \
          --proto '=https' --tlsv1.2 \
          "https://github.com/${gh_user}.keys") || curl_rc=$?
        if [ "$curl_rc" -ne 0 ]; then
          err "GitHub 请求失败（网络异常或用户名不存在）。"
          restore_authorized_keys
          sleep 1
          continue
        fi
        if [ -z "$pub_key" ] || [[ "$pub_key" == "Not Found" ]]; then
          err "该 GitHub 账号尚未配置任何公钥。"
          read -rp "${C}[注意]${N} 是否要在 VPS 上全新生成密钥 (选项 2)？(y/N，q=取消): " switch_opt2
          if [[ "$switch_opt2" =~ ^[Yy]$ ]]; then
            if generate_vps_keypair; then
              test_hint="请将已保存的私钥导入本地 SSH 客户端，新建终端测试连接。"
              do_restart=1
              need_pause=1
            else
              err "密钥生成失败，操作已取消。"
              restore_authorized_keys
              sleep 1
              continue
            fi
          else
            restore_authorized_keys
            sleep 1
            continue
          fi
        else
          if append_key_with_meta "$pub_key" "GitHub: ${gh_user}"; then
            test_hint="请使用该 GitHub 公钥对应的本地私钥，新建终端测试连接。"
            do_restart=1
          else
            restore_authorized_keys
            sleep 1
            continue
          fi
        fi
        ;;
      2)
        if ! backup_authorized_keys; then
          err "无法备份 authorized_keys，操作已取消。"
          sleep 1
          continue
        fi
        if ! generate_vps_keypair; then
          restore_authorized_keys
          sleep 1
          continue
        fi
        test_hint="请将已保存的私钥导入本地 SSH 客户端，新建终端测试连接。"
        do_restart=1
        need_pause=1
        ;;
      3)
        local key_url=""
        while true; do
          read -rp "${C}[注意]${N} 请输入公钥 URL（q=取消）： " key_url || {
            key_url=""
            break
          }
          is_q "$key_url" && {
            key_url=""
            break
          }
          if validate_https_url "$key_url"; then
            break
          fi
          printf '\033[1A\r\033[2K'
          transient_error "URL 格式不正确（仅支持 https://），请重试。"
        done
        [ -z "$key_url" ] && continue
        local pub_key="" curl_rc=0
        pub_key=$(curl --fail --silent --show-error --location \
          --connect-timeout 5 --max-time 20 --max-filesize 1048576 \
          --proto '=https' --tlsv1.2 \
          "$key_url") || curl_rc=$?
        if [ "$curl_rc" -ne 0 ] || [ -z "$pub_key" ]; then
          err "从 URL 获取公钥失败！"
          sleep 1
          continue
        fi
        if ! backup_authorized_keys; then
          err "无法备份 authorized_keys，操作已取消。"
          sleep 1
          continue
        fi
        if append_key_with_meta "$pub_key" "自定义URL"; then
          test_hint="请使用该公钥对应的本地私钥，新建终端测试连接。"
          do_restart=1
        else
          restore_authorized_keys
          sleep 1
          continue
        fi
        ;;
      4)
        manage_keys_menu
        continue
        ;;
      5)
        toggle_pubkey_login
        continue
        ;;
    esac

    if [ "$do_restart" == "1" ]; then
      if ssh_config_apply "PubkeyAuthentication=yes"; then
        commit_authorized_keys
        note "重点测试：${test_hint}"
        info "测试成功后，再返回主菜单【禁用密码登录】"
      else
        restore_authorized_keys
      fi
      if [ "$need_pause" -eq 1 ]; then
        pause
      else
        sleep 1
      fi
    fi
  done
}

# ============ 已存公钥管理 ============
manage_keys_menu() {
  init_ssh_dir
  local auth_file="${HOME}/.ssh/authorized_keys"
  local key_action="" risky_all="" confirm_all="" risky_del="" confirm_del=""

  while true; do
    title "SSH 已存公钥管理"

    local key_lines=()
    local key_contents=()
    local key_types=()
    local line_num=0 core_key

    if [ -f "$auth_file" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
          continue
        fi
        core_key=$(printf '%s\n' "$line" | extract_core_key)
        is_valid_core_key "$core_key" || continue
        key_lines+=("$line_num")
        key_contents+=("$line")
        key_types+=("${core_key%% *}")
      done <"$auth_file"
    fi

    if [ ${#key_contents[@]} -eq 0 ]; then
      warn "当前 ${auth_file} 中没有找到任何有效公钥"
      sleep 1
      return
    fi

    printf "%-4s %-19s %-18s %s\n" "序号" "添加时间" "类型" "备注来源"

    local idx=1 i
    for ((i = 0; i < ${#key_contents[@]}; i++)); do
      local key="${key_contents[$i]}"
      local key_type="${key_types[$i]:-未知}"
      local add_time="历史存量/未标记"
      local key_tag="未知/手动导入"

      if [[ "$key" =~ \[([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\|([^\]]+)\] ]]; then
        add_time="${BASH_REMATCH[1]}"
        key_tag="${BASH_REMATCH[2]}"
      fi

      printf "${C}%-4s${N} %-19s %-18s %s\n" "$idx" "$add_time" "$key_type" "$key_tag"
      idx=$((idx + 1))
    done

    printf "${D}操作指令: [序号] 删除公钥 · [all] 清空公钥 · [q] 返回上级${N}\n"
    while true; do
      read -rp "${C}[注意]${N} 请输入指令（序号/all/q）： " key_action || return
      if is_q "$key_action" || [ "$key_action" = "all" ] \
        || { [[ "$key_action" =~ ^[0-9]+$ ]] && [ "$key_action" -ge 1 ] && [ "$key_action" -le "${#key_contents[@]}" ]; }; then
        break
      fi
      printf '\033[1A\r\033[2K'
      transient_error "输入无效，请重试。"
    done

    if is_q "$key_action"; then
      return
    elif [ "$key_action" == "all" ]; then
      # 危险检查：密码登录已禁用时清空全部公钥会锁死
      local password_auth
      if ! password_auth=$(read_sshd_config_val "PasswordAuthentication"); then
        sleep 1
        continue
      fi
      if [[ "${password_auth,,}" == "no" ]]; then
        warn "密码登录已禁用，清空全部公钥后将无法登录此 VPS"
        read -rp "${C}[注意]${N} 确认仍然要清空吗？(y/N，q=取消): " risky_all
        [[ ! "$risky_all" =~ ^[Yy]$ ]] && continue
      fi
      read -rp "${C}[注意]${N} 确认要清空所有公钥吗？(y/N，q=取消): " confirm_all
      if [[ "$confirm_all" =~ ^[Yy]$ ]]; then
        if ! backup_authorized_keys || ! printf '' | atomic_write_file "$auth_file" 600; then
          restore_authorized_keys
          err "清空公钥失败，已尝试恢复原文件。"
        else
          commit_authorized_keys
          chmod 600 "$auth_file"
          ok "已清空所有公钥！"
        fi
        sleep 1
        continue
      fi
    elif [[ "$key_action" =~ ^[0-9]+$ ]] && [ "$key_action" -ge 1 ] && [ "$key_action" -le "${#key_contents[@]}" ]; then
      local target_idx=$((key_action - 1))
      local target_line_num="${key_lines[$target_idx]}"

      # 危险检查：密码登录已禁用 + 只剩最后一个公钥时删除会锁死
      local password_auth
      if ! password_auth=$(read_sshd_config_val "PasswordAuthentication"); then
        sleep 1
        continue
      fi
      if [[ "${password_auth,,}" == "no" ]] && [ "${#key_contents[@]}" -eq 1 ]; then
        warn "密码登录已禁用，删除最后一个公钥后将无法登录此 VPS"
        read -rp "${C}[注意]${N} 确认仍然要删除吗？(y/N，q=取消): " risky_del
        [[ ! "$risky_del" =~ ^[Yy]$ ]] && continue
      fi

      read -rp "${C}[注意]${N} 确认删除序号 [${key_action}] 的公钥吗？(y/N，q=取消): " confirm_del
      if [[ "$confirm_del" =~ ^[Yy]$ ]]; then
        local tmp_auth
        tmp_auth=$(mktemp "$VPS_RUNTIME_DIR/auth-keys.XXXXXX") || tmp_auth=""
        if ! backup_authorized_keys || [ -z "$tmp_auth" ] \
          || ! awk -v target="$target_line_num" 'NR != target' "$auth_file" >"$tmp_auth" \
          || ! atomic_write_file "$auth_file" 600 <"$tmp_auth"; then
          rm -f "$tmp_auth"
          restore_authorized_keys
          err "删除公钥失败，已尝试恢复原文件。"
        else
          rm -f "$tmp_auth"
          commit_authorized_keys
          chmod 600 "$auth_file"
          ok "序号 [${key_action}] 的公钥已成功删除！"
        fi
        sleep 1
        continue
      fi
    fi
  done
}

# ============ 密码登录开关 ============
toggle_password_login() {
  local current confirm="" root_confirm="" pwd_confirm="" risky_confirm=""
  if ! current=$(read_sshd_config_val "PasswordAuthentication"); then
    sleep 1
    return 1
  fi

  if [[ "${current,,}" == "no" ]]; then
    echo -e "当前密码登录已${G}禁用${N}。"
    read -rp "${C}[注意]${N} 是否要启用密码登录？(y/N，q=取消): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      if ssh_config_apply "PasswordAuthentication=yes"; then
        local root_login kbd_auth
        root_login=$(get_sshd_config_val "PermitRootLogin" 2>/dev/null || true)
        kbd_auth=$(get_sshd_config_val "KbdInteractiveAuthentication" 2>/dev/null || true)
        if [[ "${kbd_auth,,}" == "no" ]]; then
          note "当前 KbdInteractiveAuthentication=no（仅允许常规 password 认证；若使用 PAM 交互登录可按需开启）。"
        fi
        if [[ "${root_login,,}" =~ ^(no|prohibit-password|without-password)$ ]]; then
          warn "检测到当前 PermitRootLogin 为 ${root_login}，root 仍无法通过密码登录！"
          read -rp "${C}[注意]${N} 是否将 PermitRootLogin 设置为 yes 以允许 root 密码登录？(Y/n，q=取消): " root_confirm
          if [[ -z "$root_confirm" || "$root_confirm" =~ ^[Yy]$ ]]; then
            ssh_config_apply "PermitRootLogin=yes"
          fi
        fi
        ok "已成功启用密码登录"

        read -rp "${C}[注意]${N} 是否需要为当前用户 ($(whoami)) 设置新密码？(y/N，q=取消): " pwd_confirm
        if [[ "$pwd_confirm" =~ ^[Yy]$ ]]; then
          passwd "$(whoami)"
        fi
      fi
    fi
  else
    warn "禁用密码登录前，请务必确认密钥登录能够成功！"
    # 危险检查：密钥登录不可用时禁用密码登录会锁死
    local pubkey_auth
    if ! pubkey_auth=$(read_sshd_config_val "PubkeyAuthentication"); then
      sleep 1
      return 1
    fi
    local pubkey_ok=0
    if [[ "${pubkey_auth,,}" == "yes" ]] && has_valid_pubkey; then
      pubkey_ok=1
    fi
    if [ "$pubkey_ok" -eq 0 ]; then
      if [[ "${pubkey_auth,,}" != "yes" ]]; then
        warn "密钥登录已禁用，禁用密码登录后你将无法登录此 VPS！"
      else
        warn "authorized_keys 中没有任何公钥，禁用密码登录后你将无法登录此 VPS！"
      fi
      read -rp "${C}[注意]${N} 确认仍然要禁用吗？(y/N，q=取消): " risky_confirm
      [[ ! "$risky_confirm" =~ ^[Yy]$ ]] && {
        ok "已取消操作。"
        sleep 1
        return
      }
    fi
    if [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
      note "检测到您正在使用 SSH 远程会话，修改后切勿关闭当前窗口，请先新建终端测试连接！"
    fi
    read -rp "${C}[注意]${N} 确认彻底禁用密码登录吗？(y/N，q=取消): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      local -a pwd_off_opts=("PasswordAuthentication=no")
      if sshd_supports_opt "KbdInteractiveAuthentication"; then
        pwd_off_opts+=("KbdInteractiveAuthentication=no")
      elif sshd_supports_opt "ChallengeResponseAuthentication"; then
        pwd_off_opts+=("ChallengeResponseAuthentication=no")
      fi
      ssh_config_apply "${pwd_off_opts[@]}" \
        && ok "密码登录已成功禁用，现在只能通过密钥登录"
    fi
  fi
  sleep 1
}

selinux_prepare_ssh_port() {
  local new_port="$1" allowed_ports
  SELINUX_SSH_PORT=""
  SELINUX_SSH_PORT_ADDED=0
  if ! command -v getenforce &>/dev/null || [ "$(getenforce 2>/dev/null)" != "Enforcing" ]; then
    return 0
  fi
  if ! command -v semanage &>/dev/null; then
    err "SELinux 处于 Enforcing 状态，但未找到 semanage，无法安全放行 SSH 端口。"
    return 1
  fi
  allowed_ports=$(semanage port -l 2>/dev/null | awk '$1 == "ssh_port_t" && $2 == "tcp" {print $3}' | tr ',' ' ')
  if printf '%s\n' "$allowed_ports" | grep -Eq "(^|[[:space:]])${new_port}([[:space:]]|$)"; then
    return 0
  fi
  if ! semanage port -a -t ssh_port_t -p tcp "$new_port" >/dev/null 2>&1; then
    err "SELinux 无法将 ${new_port}/tcp 标记为 ssh_port_t。"
    return 1
  fi
  SELINUX_SSH_PORT="$new_port"
  SELINUX_SSH_PORT_ADDED=1
}

selinux_commit_ssh_port() {
  SELINUX_SSH_PORT=""
  SELINUX_SSH_PORT_ADDED=0
}

selinux_rollback_ssh_port() {
  if [ "${SELINUX_SSH_PORT_ADDED:-0}" -eq 1 ] && command -v semanage &>/dev/null; then
    semanage port -d -t ssh_port_t -p tcp "$SELINUX_SSH_PORT" >/dev/null 2>&1 || true
  fi
  SELINUX_SSH_PORT=""
  SELINUX_SSH_PORT_ADDED=0
}

ssh_port_listening() {
  local port="$1"
  if command -v ss &>/dev/null; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"
  elif command -v netstat &>/dev/null; then
    netstat -ltn 2>/dev/null | awk 'NR > 2 {print $4}' | grep -Eq "(^|:)${port}$"
  else
    local port_hex
    printf -v port_hex '%04X' "$port"
    awk -v p=":${port_hex}" '$2 ~ p "$" && $4 == "0A" {found=1} END {exit !found}' /proc/net/tcp /proc/net/tcp6 2>/dev/null
  fi
}

ufw_rule_exists() {
  local port="$1"
  command -v ufw &>/dev/null && {
    LC_ALL=C ufw status 2>/dev/null | awk -v p="${port}/tcp" '$1 == p {found=1} END {exit !found}' \
      || ufw show added 2>/dev/null | grep -Eq "[[:space:]]allow[[:space:]]+${port}/tcp([[:space:]]|$)"
  }
}

firewalld_port_exists() {
  command -v firewall-cmd &>/dev/null && firewall-cmd --permanent --query-port="$1/tcp" >/dev/null 2>&1
}

rollback_firewall_rule() {
  local backend="$1" port="$2"
  [ "${FIREWALL_RULE_ADDED:-0}" -eq 1 ] || return 0
  if [ "$backend" = "ufw" ]; then
    ufw delete allow "$port/tcp" >/dev/null 2>&1 || true
  elif [ "$backend" = "firewalld" ]; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  FIREWALL_RULE_ADDED=0
  FIREWALL_BACKEND=""
  FIREWALL_PORT=""
}

commit_firewall_rule() {
  FIREWALL_RULE_ADDED=0
  FIREWALL_BACKEND=""
  FIREWALL_PORT=""
}

rollback_ssh_port_change() {
  local new_port="$1" firewall_backend="$2"
  rollback_ssh_config
  if [ "${FIREWALL_RULE_ADDED:-0}" -eq 1 ]; then
    rollback_firewall_rule "$firewall_backend" "$new_port"
  fi
  selinux_rollback_ssh_port
}

# ============ 修改 SSH 端口 ============
change_ssh_port() {
  local current_port firewall_backend="" firewall_rule_existed=0 dropin_confirm=""
  FIREWALL_BACKEND=""
  FIREWALL_RULE_ADDED=0
  FIREWALL_PORT=""
  if ! current_port=$(read_sshd_config_val "Port"); then
    sleep 1
    return 1
  fi
  local all_ports
  all_ports=$(get_sshd_config_vals "Port" 2>/dev/null | paste -sd ',' - || echo "$current_port")
  echo -e "当前 SSH 端口为: ${C}${all_ports}${N}"
  if [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    note "检测到您正在使用 SSH 远程会话，修改端口后请勿关闭当前窗口，请先新建终端验证！"
  fi
  local new_port=""
  while true; do
    read -rp "${C}[注意]${N} 请输入新的 SSH 端口（1-65535，q=取消）： " new_port || return
    is_q "$new_port" && {
      ok "已取消端口修改。"
      sleep 1
      return
    }
    if [[ "$new_port" =~ ^[1-9][0-9]*$ ]] && [ "$new_port" -le 65535 ]; then
      break
    fi
    printf '\033[1A\r\033[2K'
    transient_error "端口格式不正确，范围为 1-65535。"
  done
  if [ "$new_port" = "$current_port" ] && [ "$all_ports" = "$current_port" ]; then
    if ! is_ssh_socket_managed || ssh_port_listening "$new_port"; then
      ok "新端口与当前端口相同，无需修改。"
      sleep 1
      return
    fi
  fi
  if [ "$new_port" != "$current_port" ] && ssh_port_listening "$new_port"; then
    err "端口 ${new_port} 已被其他进程监听占用，请更换端口。"
    sleep 1
    return 1
  fi
  if ! backup_ssh_config; then
    err "无法备份 SSH 配置，操作已取消。"
    sleep 1
    return 1
  fi

  if ! selinux_prepare_ssh_port "$new_port"; then
    rollback_ssh_config
    sleep 1
    return 1
  fi

  if command -v ufw &>/dev/null && LC_ALL=C ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active([[:space:]]|$)'; then
    ok "正在向 ufw 防火墙放行端口 ${new_port}/tcp..."
    if ufw_rule_exists "$new_port"; then
      firewall_rule_existed=1
    fi
    if ufw allow "$new_port/tcp" >/dev/null; then
      firewall_backend="ufw"
      if [ "$firewall_rule_existed" -eq 0 ]; then
        FIREWALL_RULE_ADDED=1
        FIREWALL_BACKEND="ufw"
        FIREWALL_PORT="$new_port"
      fi
    else
      err "ufw 放行端口失败，已取消 SSH 端口切换。"
      rollback_ssh_port_change "$new_port" "$firewall_backend"
      sleep 1
      return 1
    fi
  elif command -v firewall-cmd &>/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    ok "正在向 firewalld 防火墙放行端口 ${new_port}/tcp..."
    if firewalld_port_exists "$new_port"; then
      firewall_rule_existed=1
    fi
    if firewall-cmd --permanent --add-port="${new_port}/tcp" >/dev/null; then
      firewall_backend="firewalld"
      if [ "$firewall_rule_existed" -eq 0 ]; then
        FIREWALL_RULE_ADDED=1
        FIREWALL_BACKEND="firewalld"
        FIREWALL_PORT="$new_port"
      fi
      if ! firewall-cmd --reload >/dev/null; then
        err "firewalld 重载失败，已取消 SSH 端口切换。"
        rollback_ssh_port_change "$new_port" "$firewall_backend"
        sleep 1
        return 1
      fi
    else
      err "firewalld 放行端口失败，已取消 SSH 端口切换。"
      rollback_ssh_port_change "$new_port" "$firewall_backend"
      sleep 1
      return 1
    fi
  fi

  # OpenSSH Port 为多值累加指令；若 drop-in 文件中存在额外 Port，提醒并允许在本事务内注释
  if [ -d "$SSHD_CONF_DIR" ]; then
    local extra_port_files
    extra_port_files=$(grep -lriE '^[[:space:]]*Port[[:space:]]+' "$SSHD_CONF_DIR"/*.conf 2>/dev/null || true)
    if [ -n "$extra_port_files" ]; then
      warn "检测到 ${SSHD_CONF_DIR} 中存在额外的 Port 指令（OpenSSH 会同时监听所有 Port）："
      printf '%s\n' "$extra_port_files"
      read -rp "${C}[注意]${N} 是否注释上述文件中的 Port 指令，仅保留新端口 ${new_port}？(Y/n，q=取消): " dropin_confirm
      if is_q "$dropin_confirm"; then
        rollback_ssh_port_change "$new_port" "$firewall_backend"
        sleep 1
        return 1
      elif [[ -z "$dropin_confirm" || "$dropin_confirm" =~ ^[Yy]$ ]]; then
        local pf tmp_pf
        while IFS= read -r pf; do
          [ -f "$pf" ] || continue
          tmp_pf=$(mktemp "$VPS_RUNTIME_DIR/sshd-dropin.XXXXXX") || {
            rollback_ssh_port_change "$new_port" "$firewall_backend"
            sleep 1
            return 1
          }
          if ! awk '/^[[:space:]]*[Pp][Oo][Rr][Tt][[:space:]]+/{print "# " $0; next} {print}' "$pf" >"$tmp_pf" \
            || ! atomic_write_file "$pf" <"$tmp_pf"; then
            rm -f "$tmp_pf"
            rollback_ssh_port_change "$new_port" "$firewall_backend"
            sleep 1
            return 1
          fi
          rm -f "$tmp_pf"
        done <<<"$extra_port_files"
      fi
    fi
  fi

  if ! set_sshd_config "Port" "$new_port"; then
    err "SSH 端口配置写入失败，正在恢复原配置。"
    rollback_ssh_port_change "$new_port" "$firewall_backend"
    sleep 1
    return 1
  fi
  if is_ssh_socket_managed && ! set_ssh_socket_port "$new_port"; then
    err "ssh.socket 端口配置写入失败，正在恢复原配置。"
    rollback_ssh_port_change "$new_port" "$firewall_backend"
    sleep 1
    return 1
  fi
  if ! restart_sshd; then
    err "SSH 端口修改失败，正在恢复原配置。"
    rollback_ssh_port_change "$new_port" "$firewall_backend"
    sleep 1
    return 1
  fi
  sleep 1
  if ! ssh_port_listening "$new_port"; then
    err "SSH 服务未监听新端口 ${new_port}，正在恢复原配置。"
    rollback_ssh_port_change "$new_port" "$firewall_backend"
    sleep 1
    return 1
  fi
  selinux_commit_ssh_port
  commit_firewall_rule
  commit_ssh_config
  ok "SSH 端口已顺利修改为 ${new_port}"

  if [ -f "$JAIL_CONF" ] && grep -Eq "^[[:space:]]*\[${TARGET_JAIL}\]" "$JAIL_CONF"; then
    ok "正在同步更新 Fail2Ban 防护端口..."
    if ! backup_f2b_config; then
      warn "无法备份 Fail2Ban 配置，端口同步已跳过。"
    elif ! set_f2b_conf "port" "$new_port"; then
      warn "Fail2Ban 端口配置未修改。"
      restore_f2b_config
      commit_f2b_config
    elif command -v fail2ban-client &>/dev/null && fail2ban-client ping >/dev/null 2>&1; then
      if restart_f2b; then
        commit_f2b_config
      else
        warn "Fail2Ban 重启失败，正在恢复原端口配置。"
        restore_f2b_config
        restart_f2b >/dev/null 2>&1 || true
        commit_f2b_config
      fi
    else
      commit_f2b_config
    fi
  elif command -v fail2ban-client &>/dev/null && fail2ban-client ping >/dev/null 2>&1; then
    warn "Fail2Ban 正在运行但 ${JAIL_CONF} 尚未定义 [${TARGET_JAIL}]，建议进入 Fail2Ban 菜单同步端口。"
  fi

  if command -v ss &>/dev/null; then
    ok "系统实际监听服务端口状态："
    ss -ltnp 2>/dev/null | grep -E "(:${new_port}[[:space:]]|ssh|sshd)" || true
  fi
  warn "注意：如使用的是云服务器，请务必在安全组中开放 TCP ${new_port} 端口。"
  pause
}

#------------------------------------------------------------------------------
# 第 5 层：业务功能——系统优化、Docker 与状态展示
# Docker 包名/候选版本来自发行版仓库；包操作经统一进度适配器。
#------------------------------------------------------------------------------
# ============ 系统优化模块 ============
backup_sysctl_conf() {
  if [ -z "$SYSCTL_BACKUP_FILE" ]; then
    _tx_backup_file "$SYSCTL_CONF_FILE" "vps-sysctl" || return 1
    SYSCTL_BACKUP_FILE="$REPLY"
    SYSCTL_BACKUP_MISSING="$REPLY_MISSING"
  fi
  if [ -z "$SYSCTL_LEGACY_BACKUP_FILE" ] && [ -f "$SYSCTL_LEGACY_FILE" ]; then
    _tx_backup_file "$SYSCTL_LEGACY_FILE" "vps-sysctl-legacy" || return 1
    SYSCTL_LEGACY_BACKUP_FILE="$REPLY"
    SYSCTL_LEGACY_BACKUP_MISSING="$REPLY_MISSING"
  fi
}

restore_sysctl_conf() {
  local rc=0
  if [ -n "$SYSCTL_BACKUP_FILE" ]; then
    if _tx_restore_file "$SYSCTL_CONF_FILE" "$SYSCTL_BACKUP_FILE" "$SYSCTL_BACKUP_MISSING"; then
      rm -f "$SYSCTL_BACKUP_FILE"
      SYSCTL_BACKUP_FILE=""
      SYSCTL_BACKUP_MISSING=0
    else
      rc=1
    fi
  fi
  if [ -n "$SYSCTL_LEGACY_BACKUP_FILE" ]; then
    if _tx_restore_file "$SYSCTL_LEGACY_FILE" "$SYSCTL_LEGACY_BACKUP_FILE" "$SYSCTL_LEGACY_BACKUP_MISSING"; then
      rm -f "$SYSCTL_LEGACY_BACKUP_FILE"
      SYSCTL_LEGACY_BACKUP_FILE=""
      SYSCTL_LEGACY_BACKUP_MISSING=0
    else
      rc=1
    fi
  fi
  return "$rc"
}

commit_sysctl_conf() {
  [ -z "$SYSCTL_BACKUP_FILE" ] || rm -f "$SYSCTL_BACKUP_FILE"
  SYSCTL_BACKUP_FILE=""
  SYSCTL_BACKUP_MISSING=0
  [ -z "$SYSCTL_LEGACY_BACKUP_FILE" ] || rm -f "$SYSCTL_LEGACY_BACKUP_FILE"
  SYSCTL_LEGACY_BACKUP_FILE=""
  SYSCTL_LEGACY_BACKUP_MISSING=0
}

backup_zram_config() {
  local file="$1"
  [ -n "$ZRAM_CONFIG_BACKUP" ] && return 0
  ZRAM_CONFIG_FILE="$file"
  _tx_backup_file "$file" "vps-zram-config" || {
    ZRAM_CONFIG_FILE=""
    return 1
  }
  ZRAM_CONFIG_BACKUP="$REPLY"
  ZRAM_CONFIG_MISSING="$REPLY_MISSING"
}

restore_zram_config() {
  [ -n "$ZRAM_CONFIG_BACKUP" ] || return 0
  _tx_restore_file "$ZRAM_CONFIG_FILE" "$ZRAM_CONFIG_BACKUP" "$ZRAM_CONFIG_MISSING" || return 1
  rm -f "$ZRAM_CONFIG_BACKUP"
  ZRAM_CONFIG_FILE=""
  ZRAM_CONFIG_BACKUP=""
  ZRAM_CONFIG_MISSING=0
}

commit_zram_config() {
  [ -z "$ZRAM_CONFIG_BACKUP" ] || rm -f "$ZRAM_CONFIG_BACKUP"
  ZRAM_CONFIG_FILE=""
  ZRAM_CONFIG_BACKUP=""
  ZRAM_CONFIG_MISSING=0
}

_sysctl_write_kv_file() {
  local target_file="$1" key="$2" value="$3" tmp
  [ -L "$target_file" ] && {
    err "拒绝修改软链接 sysctl 文件：$target_file"
    return 1
  }
  tmp=$(mktemp "$VPS_RUNTIME_DIR/vps-sysctl-kv.XXXXXX") || return 1
  if [ -f "$target_file" ]; then
    if ! awk -v k="$key" -v v="$value" '
          BEGIN { found=0 }
          {
              line=$0
              sub(/^[[:space:]]*/, "", line)
              if (line !~ /^#/ && index(line, "=") > 0) {
                  cur=substr(line, 1, index(line, "=") - 1)
                  sub(/[[:space:]]+$/, "", cur)
                  if (cur == k) {
                      if (!found) { print k "=" v; found=1 }
                      next
                  }
              }
              print
          }
          END { if (!found) print k "=" v }
      ' "$target_file" >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
  else
    printf '%s=%s\n' "$key" "$value" >"$tmp" || {
      rm -f "$tmp"
      return 1
    }
  fi
  if ! atomic_write_file "$target_file" 644 <"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

sysctl_set() {
  local key="$1" value="$2"
  backup_sysctl_conf || return 1
  _sysctl_write_kv_file "$SYSCTL_CONF_FILE" "$key" "$value" || return 1
  # 若传统 /etc/sysctl.conf 已有同名生效键，同步更新以防非 systemd 启动顺序覆盖
  if [ -f "$SYSCTL_LEGACY_FILE" ] && awk -v k="$key" '
      {
          line=$0; sub(/^[[:space:]]*/, "", line)
          if (line !~ /^#/ && index(line, "=") > 0) {
              cur=substr(line, 1, index(line, "=") - 1)
              sub(/[[:space:]]+$/, "", cur)
              if (cur == k) found=1
          }
      }
      END { exit !found }
  ' "$SYSCTL_LEGACY_FILE"; then
    _sysctl_write_kv_file "$SYSCTL_LEGACY_FILE" "$key" "$value" || return 1
  fi
}

apply_managed_sysctl() {
  local err_out
  if [ -f "$SYSCTL_CONF_FILE" ]; then
    if ! err_out=$(sysctl -p "$SYSCTL_CONF_FILE" 2>&1); then
      [ -n "$err_out" ] && err "sysctl 应用失败：$err_out"
      return 1
    fi
  elif [ -f "$SYSCTL_LEGACY_FILE" ]; then
    sysctl -p "$SYSCTL_LEGACY_FILE" >/dev/null 2>&1 || return 1
  fi
  return 0
}

fix_dpkg() {
  local proc
  if command -v pgrep &>/dev/null; then
    for proc in apt apt-get dpkg unattended-upgrade; do
      if pgrep -x "$proc" >/dev/null 2>&1; then
        err "检测到正在运行的 ${proc}，为避免损坏包管理数据库，已取消清理。"
        return 1
      fi
    done
  fi
  DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold
}

run_system_cleanup() {
  local docker_cleanup_confirm=""
  ok "正在执行系统清理..."
  if [ "$PKG_MGR" = "apt" ]; then
    if ! run_with_progress "修复 Debian 软件包状态" fix_dpkg; then
      return 1
    fi
    if ! run_with_progress "清理 Debian 软件包缓存" env DEBIAN_FRONTEND=noninteractive sh -c \
      'apt-get autoremove --purge -y && apt-get clean && apt-get autoclean'; then
      package_index_invalidate
      err "apt 清理失败。"
      return 1
    fi
    package_index_invalidate
    if command -v journalctl &>/dev/null; then
      journalctl --rotate >/dev/null 2>&1 || true
      journalctl --vacuum-time=30d --vacuum-size=200M >/dev/null 2>&1 || true
    fi
  elif [ "$PKG_MGR" = "apk" ]; then
    find /var/log -mindepth 1 \
      -path "/var/log/cdt" -prune -o \
      -type f -name '*.gz' -mtime +30 -exec rm -f {} + 2>/dev/null || true
    if [ -d /etc/apk/cache ]; then
      run_with_progress "清理 Alpine 软件包缓存" apk cache clean || return 1
    fi
  fi
  # 只清理超过 7 天的临时文件，避免递归删除仍在使用的目录。
  find /tmp -xdev -mindepth 1 -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true
  find /tmp -xdev -mindepth 1 -maxdepth 1 -type l -mtime +7 -delete 2>/dev/null || true
  if command -v docker &>/dev/null; then
    echo -e "${Y}Docker 清理将删除所有未使用镜像（含旧版本），并清空所有容器日志文件（*.log）。${N}"
    read_menu_choice "Docker 清理 [1=清理，2=跳过，q=返回]：" '^(1|2|[qQ])$' || return 1
    case "$REPLY" in
      1)
        read -rp "${C}[注意]${N} 请输入 DELETE 确认删除未使用镜像并清空容器日志： " docker_cleanup_confirm
        if [ "$docker_cleanup_confirm" = "DELETE" ]; then
          if ! docker image prune -a -f >/dev/null 2>&1; then
            warn "Docker 镜像清理失败或 daemon 未运行。"
          fi
          find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
        else
          ok "已取消 Docker 清理。"
        fi
        ;;
      2 | [qQ]) ok "已跳过 Docker 清理。" ;;
    esac
  fi
  ok "系统清理完成。"
}

current_timezone() {
  local tz=""
  command -v timedatectl &>/dev/null && tz=$(timedatectl show -p Timezone --value 2>/dev/null)
  [ -z "$tz" ] && tz=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
  [ -z "$tz" ] && [ -f /etc/timezone ] && tz=$(cat /etc/timezone 2>/dev/null)
  [ -z "$tz" ] && tz="未知"
  printf '%s\n' "$tz"
}

show_vps_status() {
  local bbr_status fq_status tz docker_status zram_status
  bbr_status=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
  fq_status=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
  tz=$(current_timezone)

  if [ "$bbr_status" = "bbr" ] && [ "$fq_status" = "fq" ]; then
    bbr_status="${G}BBR + FQ 已启用${N}"
  elif [ "$bbr_status" = "bbr" ]; then
    bbr_status="${Y}BBR 已启用，FQ=${fq_status:-未知}${N}"
  else
    bbr_status="${Y}未启用${N}"
  fi

  if grep -q '^/dev/zram' /proc/swaps 2>/dev/null; then
    zram_status="${G}已启用${N}"
  else
    zram_status="${Y}未启用${N}"
  fi

  if command -v docker &>/dev/null; then
    if docker info >/dev/null 2>&1; then
      docker_status="${G}$(docker -v 2>/dev/null | awk '{print $3}' | tr -d ',')，daemon 运行中${N}"
    else
      docker_status="${Y}已安装，daemon 未运行${N}"
    fi
  else
    docker_status="${Y}未安装${N}"
  fi

  printf "${B}系统综合状态${N}\n"
  echo -e "系统环境 : ${G}${OS_SHORT} ${OS_VER}${N}"
  echo -e "网络算法 : ${bbr_status}"
  echo -e "zRAM     : ${zram_status}"
  echo -e "Docker   : ${docker_status}"
  echo -e "系统时区 : ${tz}"
}

manage_bbr() {
  local current_cc current_qdisc confirm=""
  current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
  current_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
  echo -e "当前状态：拥塞控制=${current_cc:-未知}，队列调度=${current_qdisc:-未知}"
  read -rp "${C}[注意]${N} 是否配置 BBR + FQ？(y/N，q=取消): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    if ! backup_sysctl_conf || ! sysctl_set "net.core.default_qdisc" "fq" \
      || ! sysctl_set "net.ipv4.tcp_congestion_control" "bbr" || ! apply_managed_sysctl; then
      restore_sysctl_conf
      apply_managed_sysctl >/dev/null 2>&1 || true
      err "BBR 配置失败，已恢复原 sysctl 配置。"
      sleep 1
      return 1
    fi
    current_cc=$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true)
    current_qdisc=$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || true)
    if [ "$current_cc" = "bbr" ] && [ "$current_qdisc" = "fq" ]; then
      ok "BBR + FQ 已配置并生效。"
    else
      warn "配置已写入，当前未完全生效，可能需要重启。"
    fi
    commit_sysctl_conf
  fi
  sleep 1
}

manage_zram() {
  local total_mem zram_size phys_swap swap_p install_rc=0 confirm=""
  if grep -q '^/dev/zram' /proc/swaps 2>/dev/null; then
    echo -e "${G}检测到 zRAM swap 已启用。${N}"
  fi
  read -rp "${C}[注意]${N} 是否部署或覆盖 zRAM？(y/N，q=取消): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    sleep 1
    return
  }

  if ! command -v free &>/dev/null; then
    err "未找到 free，无法读取内存大小。"
    sleep 1
    return 1
  fi
  total_mem=$(free -m | awk '/^Mem:/{print $2}')
  if ! [[ "$total_mem" =~ ^[0-9]+$ ]] || [ "$total_mem" -le 0 ]; then
    err "无法读取有效的内存大小。"
    sleep 1
    return 1
  fi
  if [ "$total_mem" -le 1024 ]; then zram_size="$total_mem"; else zram_size=$((total_mem * 60 / 100)); fi

  phys_swap=$(awk 'NR>1 && $1 !~ /^\/dev\/zram/ {s+=$3} END{printf "%d", s/1024}' /proc/swaps 2>/dev/null)
  phys_swap=${phys_swap:-0}
  if [ "$phys_swap" -gt 0 ]; then swap_p=60; elif [ "$total_mem" -le 1024 ]; then swap_p=80; else swap_p=60; fi

  local zram_config zram_was_missing=0
  if [ "$OS_ID" = "alpine" ]; then zram_config=/etc/conf.d/zram-init; else zram_config=/etc/default/zramswap; fi
  if ! backup_sysctl_conf || ! backup_zram_config "$zram_config"; then
    err "无法备份 zRAM/sysctl 配置，操作已取消。"
    sleep 1
    return 1
  fi
  zram_was_missing="$ZRAM_CONFIG_MISSING"

  if [ "$OS_ID" = "alpine" ]; then
    if ! pkg_install zram-init; then
      install_rc=1
    elif ! printf 'load_modules="yes"\nnum_devices="1"\ntype0="swap"\nsize0="%s"\nalgo0="lz4"\n' "$zram_size" | atomic_write_file "$zram_config" 644; then
      install_rc=1
    else
      svc_enable zram-init || true
      svc_restart zram-init || svc_start zram-init || install_rc=1
    fi
  else
    if ! pkg_install zram-tools; then
      install_rc=1
    elif ! printf 'ALGO=lz4\nSIZE=%s\nPRIORITY=100\n' "$zram_size" | atomic_write_file "$zram_config" 644; then
      install_rc=1
    else
      svc_enable zramswap || true
      svc_restart zramswap || svc_start zramswap || install_rc=1
    fi
  fi

  if [ "$install_rc" -eq 0 ] && grep -q '^/dev/zram' /proc/swaps 2>/dev/null \
    && sysctl_set "vm.swappiness" "$swap_p" && apply_managed_sysctl; then
    ok "zRAM 已配置 (${zram_size}MB，swappiness=${swap_p})。"
  else
    restore_zram_config
    restore_sysctl_conf
    apply_managed_sysctl >/dev/null 2>&1 || true
    if [ "$OS_ID" = "alpine" ]; then
      if [ "$zram_was_missing" -eq 1 ]; then
        svc_stop zram-init >/dev/null 2>&1 || true
      else
        svc_restart zram-init >/dev/null 2>&1 || true
      fi
    else
      if [ "$zram_was_missing" -eq 1 ]; then
        svc_stop zramswap >/dev/null 2>&1 || true
      else
        svc_restart zramswap >/dev/null 2>&1 || true
      fi
    fi
    err "zRAM 或 swappiness 配置失败，已恢复原配置，请检查内核模块和服务日志。"
    sleep 1
    return 1
  fi
  commit_zram_config
  commit_sysctl_conf
  sleep 1
}

package_candidate_version() {
  local package="$1"
  case "$PKG_MGR" in
    apt)
      apt-cache policy "$package" 2>/dev/null \
        | awk '/Candidate:/{print $2; exit}'
      ;;
    apk)
      apk policy "$package" 2>/dev/null \
        | awk '/^[[:space:]]*[0-9]/{gsub(/:$/, "", $1); print $1; exit}'
      ;;
    *) return 1 ;;
  esac
}

package_candidate_available() {
  local candidate
  candidate=$(package_candidate_version "$1")
  [ -n "$candidate" ] && [ "$candidate" != "(none)" ]
}

apt_package_available() {
  [ "$PKG_MGR" = "apt" ] && package_candidate_available "$1"
}

compose_version() {
  local version
  if command -v docker >/dev/null 2>&1; then
    version=$(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null || true)
    version=$(printf '%s\n' "$version" | grep -Eo 'v?[0-9]+(\.[0-9]+)+' | head -n1 || true)
    if [ -n "$version" ]; then
      printf '%s\n' "${version#v}"
      return 0
    fi
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    version=$(docker-compose version --short 2>/dev/null || docker-compose version 2>/dev/null || true)
    version=$(printf '%s\n' "$version" | grep -Eo 'v?[0-9]+(\.[0-9]+)+' | head -n1 || true)
    if [ -n "$version" ]; then
      printf '%s\n' "${version#v}"
      return 0
    fi
  fi
  return 1
}

compose_available() {
  compose_version >/dev/null 2>&1
}

docker_install_flavor() {
  if [ "$OS_ID" = "alpine" ]; then
    echo "alpine"
  elif pkg_is_installed docker-ce; then
    echo "ce"
  else
    echo "distro"
  fi
}

check_docker_latest() {
  local compose_pkg docker_pkg flavor
  LATEST_DOCKER=""
  LATEST_COMPOSE=""
  flavor=$(docker_install_flavor)
  case "$flavor" in
    ce)
      docker_pkg=docker-ce
      compose_pkg=docker-compose-plugin
      ;;
    distro)
      docker_pkg=docker.io
      compose_pkg=$(docker_compose_package) || return 1
      ;;
    alpine)
      docker_pkg=docker
      compose_pkg=$(docker_compose_package) || return 1
      ;;
    *) return 1 ;;
  esac
  package_candidate_available "$docker_pkg" || return 1
  LATEST_DOCKER=$(package_candidate_version "$docker_pkg")
  package_candidate_available "$compose_pkg" || return 1
  LATEST_COMPOSE=$(package_candidate_version "$compose_pkg")
  return 0
}

docker_compose_package() {
  case "$OS_ID" in
    debian | ubuntu)
      if apt_package_available docker-compose-v2; then
        printf '%s\n' docker-compose-v2
      elif apt_package_available docker-compose; then
        printf '%s\n' docker-compose
      else
        return 1
      fi
      ;;
    alpine)
      package_candidate_available docker-cli-compose || return 1
      printf '%s\n' docker-cli-compose
      ;;
    *) return 1 ;;
  esac
}

detect_containerd_use() {
  CONTAINERD_SHARED_USE=0
  if command -v nerdctl &>/dev/null || command -v crictl &>/dev/null \
    || pgrep -x kubelet >/dev/null 2>&1 || pgrep -x k3s >/dev/null 2>&1 \
    || pgrep -x k3s-server >/dev/null 2>&1 || pgrep -x k3s-agent >/dev/null 2>&1 \
    || pgrep -x buildkitd >/dev/null 2>&1 \
    || [ -d /var/lib/kubelet ] || [ -d /var/lib/rancher/k3s ]; then
    CONTAINERD_SHARED_USE=1
  fi
}

remove_docker() {
  local rc=0 packages=() pkg=""
  detect_containerd_use
  if [ "$OS_ID" = "alpine" ]; then
    svc_stop docker || true
    svc_disable docker || true
    if apk info -e docker >/dev/null 2>&1; then packages+=(docker); fi
    if apk info -e docker-cli-compose >/dev/null 2>&1; then packages+=(docker-cli-compose); fi
    if [ "${CONTAINERD_SHARED_USE:-0}" -eq 1 ]; then
      warn "检测到可能由其他运行时使用 containerd，将保留其相关软件包和数据。"
      if pkg_is_installed containerd && ! run_with_progress "保护 Alpine containerd 依赖" apk add --no-cache containerd; then
        rc=1
      fi
    fi
    if [ "$rc" -eq 0 ] && [ "${#packages[@]}" -gt 0 ] && ! pkg_remove "${packages[@]}"; then
      rc=1
    fi
  else
    svc_stop docker || true
    svc_disable docker 2>/dev/null || true
    for pkg in docker-ce docker-ce-cli containerd.io containerd docker-compose-plugin docker-buildx-plugin docker.io docker-compose docker-compose-v2; do
      if [ "${CONTAINERD_SHARED_USE:-0}" -eq 1 ] \
        && { [ "$pkg" = "containerd.io" ] || [ "$pkg" = "containerd" ]; }; then
        continue
      fi
      if pkg_is_installed "$pkg"; then
        packages+=("$pkg")
      fi
    done
    if [ "${CONTAINERD_SHARED_USE:-0}" -eq 1 ]; then
      warn "检测到可能由其他运行时使用 containerd，已跳过 containerd/containerd.io 软件包及自动依赖清理。"
    fi
    if [ "${#packages[@]}" -gt 0 ] && ! pkg_remove "${packages[@]}"; then
      rc=1
    fi
    if [ "$rc" -eq 0 ] && [ "${CONTAINERD_SHARED_USE:-0}" -eq 0 ] \
      && [ "${#packages[@]}" -gt 0 ] && ! pkg_autoremove; then
      rc=1
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    err "Docker 软件包卸载失败，未删除 Docker 数据。"
    return 1
  fi
  return 0
}

remove_docker_data() {
  rm -rf /var/lib/docker
  if [ "${CONTAINERD_SHARED_USE:-0}" -eq 1 ]; then
    warn "已保留 /var/lib/containerd（可能被非 Docker 运行时使用）。"
  else
    rm -rf /var/lib/containerd
  fi
}

manage_docker() {
  local action="" confirm="" install_rc=0 compose_pkg="" data_confirm="" containerd_confirm="" flavor=""
  if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker -v 2>/dev/null | awk '{print $3}' | tr -d ',')
    COMPOSE_VER=$(compose_version 2>/dev/null || true)
    echo -e "当前 Docker：${G}${DOCKER_VER:-未知}${N}，Compose：${G}${COMPOSE_VER:-未安装}${N}"
    if check_docker_latest; then
      echo -e "可用仓库版本：Docker ${LATEST_DOCKER:-未知}，Compose ${LATEST_COMPOSE:-未找到}"
    else
      warn "无法读取系统软件仓库中的 Docker 版本。"
    fi
    printf "${C}1${N}  更新 Docker/Compose\n"
    printf "${C}2${N}  卸载 Docker/Compose\n"
    printf "${C}0${N}  返回\n"
    read_menu_choice "> " '^(0|1|2|[qQ])$' || return
    action="$REPLY"
    if is_q "$action" || [ "$action" = "0" ]; then return; fi
    case "$action" in 1) action=update ;; 2) action=remove ;; *) return ;; esac
  else
    echo -e "${Y}当前未安装 Docker。${N}"
    read -rp "${C}[注意]${N} 是否安装 Docker/Compose？(y/N，q=取消): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return
    action=install
  fi

  if [ "$action" = "remove" ]; then
    detect_containerd_use
    warn "此操作将卸载 Docker 软件包，但不会自动删除容器、镜像、卷或运行时数据。"
    if [ "${CONTAINERD_SHARED_USE:-0}" -eq 1 ]; then
      warn "检测到可能存在非 Docker 的 containerd 使用者（nerdctl/crictl/kubelet/k3s 等）。"
    fi
    read -rp "${C}[注意]${N} 请输入 DELETE 确认卸载 Docker 软件包（不删除数据）: " confirm
    [ "$confirm" = "DELETE" ] || {
      ok "已取消。"
      sleep 1
      return
    }
    remove_docker
    install_rc=$?
    hash -r 2>/dev/null
    if [ "$install_rc" -ne 0 ] || command -v docker &>/dev/null; then
      err "Docker 软件包卸载未完整成功，未删除任何数据。"
    else
      read -rp "${C}[注意]${N} 如需删除 /var/lib/docker（容器、镜像、卷），请输入 DELETE-DATA；其他输入保留数据： " data_confirm
      if [ "$data_confirm" = "DELETE-DATA" ]; then
        remove_docker_data
        if [ "${CONTAINERD_SHARED_USE:-0}" -eq 1 ]; then
          read -rp "${C}[注意]${N} 检测到可能共享 containerd，确认删除 /var/lib/containerd 请输入 DELETE-CONTAINERD-DATA（否则保留）： " containerd_confirm
          if [ "$containerd_confirm" = "DELETE-CONTAINERD-DATA" ]; then
            rm -rf /var/lib/containerd
          fi
        fi
        ok "Docker 软件包及确认的数据已处理。"
      else
        ok "Docker 数据已保留。"
      fi
    fi
    pause
    return
  fi

  echo -e "${Y}Docker 安装/更新将使用系统软件包管理器，不执行远程 root 安装脚本。${N}"
  read -rp "${C}[注意]${N} 确认继续？(y/N，q=取消): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    ok "已取消 Docker 安装/更新。"
    sleep 1
    return
  }
  ok "正在安装/更新 Docker & Compose，请稍候..."
  flavor=$(docker_install_flavor)
  if [ "$flavor" = "alpine" ]; then
    if ! pkg_install docker docker-cli-compose; then
      install_rc=1
    else
      svc_enable docker || true
      svc_start docker || true
    fi
  elif [ "$flavor" = "ce" ]; then
    local -a ce_pkgs=(docker-ce docker-ce-cli containerd.io docker-compose-plugin)
    pkg_is_installed docker-buildx-plugin && ce_pkgs+=(docker-buildx-plugin)
    if ! refresh_package_index || ! pkg_install "${ce_pkgs[@]}"; then
      install_rc=1
    else
      svc_enable docker || true
      svc_start docker || true
    fi
  else
    if ! refresh_package_index; then
      install_rc=1
    else
      compose_pkg=$(docker_compose_package) || {
        err "当前 ${OS_SHORT} 官方软件仓库没有可用的 Compose 包。"
        install_rc=1
      }
      if [ "$install_rc" -eq 0 ] && ! pkg_install docker.io "$compose_pkg"; then
        install_rc=1
      fi
    fi
    if [ "$install_rc" -eq 0 ]; then
      svc_enable docker || true
      svc_start docker || true
    fi
  fi
  hash -r 2>/dev/null
  if [ "$install_rc" -eq 0 ] && command -v docker &>/dev/null && docker info >/dev/null 2>&1 && compose_available; then
    DOCKER_VER=$(docker -v 2>/dev/null | awk '{print $3}' | tr -d ',')
    COMPOSE_VER=$(compose_version 2>/dev/null || true)
    ok "Docker ${DOCKER_VER:-未知} / Compose ${COMPOSE_VER:-未知} 已就绪。"
  else
    err "Docker 或 Compose 安装失败，或 Docker daemon 未运行。"
  fi
  pause
}

manage_timezone() {
  local tz confirm=""
  tz=$(current_timezone)
  echo -e "当前时区：${C}${tz}${N}"
  read -rp "${C}[注意]${N} 是否设置为 Asia/Shanghai？(y/N，q=取消): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || {
    sleep 1
    return
  }
  if command -v timedatectl &>/dev/null && [ "$INIT_SYS" = "systemd" ]; then
    if timedatectl set-timezone Asia/Shanghai 2>/dev/null; then
      ok "时区已设置为 Asia/Shanghai。"
      sleep 1
      return 0
    fi
  fi
  local zoneinfo="/usr/share/zoneinfo/Asia/Shanghai"
  if [ "$OS_ID" = "alpine" ] && [ ! -f "$zoneinfo" ]; then
    if ! pkg_install tzdata; then
      err "tzdata 安装失败。"
      sleep 1
      return 1
    fi
  fi
  if [ ! -f "$zoneinfo" ] && [ "$PKG_MGR" = "apt" ]; then
    if ! pkg_install tzdata; then
      err "时区数据安装失败。"
      sleep 1
      return 1
    fi
  fi
  if [ ! -f "$zoneinfo" ]; then
    err "未找到 Asia/Shanghai 时区数据。"
    sleep 1
    return 1
  fi
  if ! ln -sf "$zoneinfo" /etc/localtime || ! printf 'Asia/Shanghai\n' | atomic_write_file /etc/timezone 644; then
    err "时区写入失败。"
    sleep 1
    return 1
  fi
  if [ "$(current_timezone)" != "Asia/Shanghai" ]; then
    err "时区设置后验证失败。"
    sleep 1
    return 1
  fi
  ok "时区已设置为 Asia/Shanghai。"
  sleep 1
}

show_combined_status() {
  show_status
  show_vps_status
}

header() {
  cls
  local dump="" port="未知" pwd_auth="" kbd_auth="" pubkey_auth="" root_login="" key_count=0
  local ssh_ok=0 status_badge="${G}● 正常${N}"
  if dump=$(_sshd_dump_config); then
    ssh_ok=1
    port=$(_sshd_vals_from_dump "$dump" "port" | paste -sd ',' -)
    [ -n "$port" ] || port="未知"
    pwd_auth=$(_sshd_val_from_dump "$dump" "passwordauthentication")
    kbd_auth=$(_sshd_val_from_dump "$dump" "kbdinteractiveauthentication")
    pubkey_auth=$(_sshd_val_from_dump "$dump" "pubkeyauthentication")
    root_login=$(_sshd_val_from_dump "$dump" "permitrootlogin")
  else
    status_badge="${Y}● SSH异常${N}"
  fi
  key_count=$(count_authorized_keys 2>/dev/null || echo 0)

  local f2b_status="${D}关${N}"
  if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
    f2b_status="${G}开${N}"
  fi

  local bbr_status="${D}关${N}"
  if [ "$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
    bbr_status="${G}开${N}"
  fi

  local pwd_str="${D}密码 未知${N}"
  if [ "$ssh_ok" -eq 1 ]; then
    pwd_str="${Y}密码 开${N}"
    if [[ "${pwd_auth,,}" == "no" ]]; then
      if [[ "${kbd_auth,,}" == "yes" ]]; then
        pwd_str="${Y}密码 交互开${N}"
      else
        pwd_str="${G}密码 关${N}"
      fi
    elif [[ "${root_login,,}" =~ ^(no|prohibit-password|without-password)$ ]]; then
      pwd_str="${Y}密码 免密root${N}"
    fi
  fi

  local key_str="${D}密钥 未知${N}"
  if [ "$ssh_ok" -eq 1 ]; then
    key_str="${D}密钥 关${N}"
    if [[ "${pubkey_auth,,}" == "yes" ]]; then
      key_str="${G}密钥 开(${key_count})${N}"
    fi
  fi

  printf "${B}VPS TOOL${N}  %b  ${D}vps${N}\n" "$status_badge"
  printf "${D}%s %s · SSH:%s (%b · %b) · F2B:%b · BBR:%b${N}\n" \
    "${OS_SHORT:-Linux}" "${OS_VER:-}" "$port" \
    "$key_str" "$pwd_str" "$f2b_status" "$bbr_status"
}

#------------------------------------------------------------------------------
# 第 6 层：交互与应用入口
# 菜单负责路由到业务函数；检测和依赖准备在主循环前完成。
#------------------------------------------------------------------------------
# 在测试或其他脚本中只复用纯函数/适配器时，跳过主循环；不会执行任何系统变更。
if [ "${VPS_TOOL_LIBRARY_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

# ============ 主逻辑 ============
detect_os
detect_pkg_mgr
detect_init
detect_ssh_log

case "$OS_ID" in
  debian | ubuntu | alpine) ;;
  *)
    err "不支持的系统：${OS_NAME} (${OS_ID})"
    echo -e "${Y}当前脚本仅支持 Debian、Ubuntu 和 Alpine。${N}"
    exit 1
    ;;
esac

check_dependencies || exit 1
setup_shortcut

main_menu() {
  local choice="" cleanup_confirm="" exit_msg="已退出 VPS 管理面板"
  while true; do
    header
    printf "${C}1${N}  SSH 密钥       ${C}6${N}  zRAM 压缩\n"
    printf "${C}2${N}  密码登录       ${C}7${N}  Docker 管理\n"
    printf "${C}3${N}  SSH 端口       ${C}8${N}  系统清理\n"
    printf "${C}4${N}  Fail2Ban       ${C}9${N}  时区设置\n"
    printf "${C}5${N}  BBR 加速       ${C}10${N} 综合状态\n"
    printf "${C}0${N}  退出\n"

    read_menu_choice "> " '^([0-9]|10|[qQ])$' || bye "$exit_msg"
    choice="$REPLY"
    if is_q "$choice" || [ "$choice" = "0" ]; then
      [ -x "$SCRIPT_LINK" ] && exit_msg="已退出 VPS 管理面板（输入 vps 可再次打开）"
      bye "$exit_msg"
    fi
    case "$choice" in
      1) install_key_menu ;;
      2) toggle_password_login ;;
      3) change_ssh_port ;;
      4) manage_fail2ban_menu ;;
      5) manage_bbr ;;
      6) manage_zram ;;
      7) manage_docker ;;
      8)
        warn "系统清理将执行包缓存/临时文件/日志清理，并在确认后清理 Docker 未使用镜像与容器日志"
        read -rp "${C}[注意]${N} 确认继续？[y/N]: " cleanup_confirm
        if [[ "$cleanup_confirm" =~ ^[Yy]$ ]]; then
          run_system_cleanup || err "系统清理未完整成功"
        fi
        sleep 1
        ;;
      9) manage_timezone ;;
      10)
        title "综合状态"
        show_combined_status
        pause
        ;;
    esac
  done
}

main_menu
