#!/usr/bin/env bash
set -e

#
# Readeck 安装/卸载脚本
#
# 功能：
#   * install   安装或升级 Readeck（默认命令）
#   * uninstall 卸载 Readeck（--purge 同时删除配置、数据目录和专用用户）
#   * 未指定版本时安装最新版，可用 --version=<版本号> 指定
#   * 非 root 执行时自动通过 sudo 提权重跑
#

# --- 脚本变量定义 ---
ERROR="\e[1;31m"
WARN="\e[93m"
INFO="\e[32m"
END="\e[0m"

# 脚本版本号（与 Readeck 版本无关）
SCRIPT_VERSION="1.2.0"
# 可选的脚本来源地址，默认为空；可用环境变量 READECK_INSTALL_URL 指定。
SCRIPT_INSTALL_URL="${READECK_INSTALL_URL:-}"

ACTION=
READECK_VERSION=
PURGE=false
ASSUME_YES=false
INSTALL_USER="readeck"
INSTALL_GROUP="readeck"

CONFIG_DIR="/etc/readeck"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
DATA_DIR="/var/lib/readeck"
SERVICE_FILE="/etc/systemd/system/readeck.service"
BINARY_PATH="/usr/local/bin/readeck"

# 安装函数回传的版本号
INSTALLED_VERSION=""

# 临时文件列表（提权成功后初始化）
NEED_REMOVE_TEMP=""
NEED_REMOVE=()

identify_the_operating_system_and_architecture() {
  if ! [[ "$(uname)" == 'Linux' ]]; then
    echo -e "${ERROR}错误:${END} 当前脚本仅支持 Linux 操作系统。"
    exit 1
  fi
  
  # 按 CPU 架构匹配发布包后缀
  case "$(uname -m)" in
    'i386' | 'i686') REPO_ARCH_SUFFIX='linux-386' ;;       # 对应 readeck-X.X.X-linux-386
    'amd64' | 'x86_64') REPO_ARCH_SUFFIX='linux-amd64' ;;   # 对应 readeck-X.X.X-linux-amd64
    'armv8' | 'aarch64') REPO_ARCH_SUFFIX='linux-arm64' ;; # 对应 readeck-X.X.X-linux-arm64
    'armv7' | 'armv7l') REPO_ARCH_SUFFIX='linux-arm-5' ;; # 对应 readeck-X.X.X-linux-arm-5
    'armv6l') REPO_ARCH_SUFFIX='linux-arm-5' ;;         # 对应 readeck-X.X.X-linux-arm-5
    *) echo -e "${ERROR}错误:${END} 不支持的硬件架构: $(uname -m)。"; exit 1 ;;
  esac

  if ! ( [[ -d /run/systemd/system ]] || grep -q systemd <(ls -l /sbin/init) ); then
      echo -e "${ERROR}错误:${END} 仅支持使用 systemd 的 Linux 发行版。"
      exit 1
  fi
}

# 非 root 时通过 sudo 重新执行自身。
# 脚本正文来源依次为：磁盘文件、BASH_EXECUTION_STRING、READECK_INSTALL_URL。
ensure_root() {
  if [[ $EUID -eq 0 ]]; then
    return 0
  fi

  # 已提权过仍非 root 时退出，避免重复执行
  if [[ "${READECK_SUDO_REEXEC:-0}" == "1" ]]; then
    echo -e "${ERROR}错误:${END} 已尝试通过 sudo 提权，但当前仍不是 root，已停止以避免递归。"
    exit 1
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    echo -e "${ERROR}错误:${END} 需要 root 权限，但系统中没有 sudo。"
    echo -e "      请先切换到 root 用户再执行本脚本。"
    exit 1
  fi

  local _bash _src _self="" _dir="" _tmp=""

  _bash="$(command -v bash || true)"
  [[ -n "$_bash" ]] || _bash="/bin/bash"

  # 1) 磁盘上的脚本文件
  _src="${BASH_SOURCE[0]:-}"
  if [[ -n "$_src" && -f "$_src" ]]; then
    _dir="$(cd "$(dirname "$_src")" >/dev/null 2>&1 && pwd)" || _dir=""
    [[ -n "$_dir" ]] && _self="${_dir}/$(basename "$_src")"
  fi
  if [[ -z "$_self" && -n "${0:-}" && -f "$0" ]]; then
    _dir="$(cd "$(dirname "$0")" >/dev/null 2>&1 && pwd)" || _dir=""
    [[ -n "$_dir" ]] && _self="${_dir}/$(basename "$0")"
  fi

  # 保留代理与下载地址相关环境变量（sudo 默认会重置）
  local _name _val _preserve=()
  for _name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
               http_proxy https_proxy all_proxy no_proxy \
               READECK_INSTALL_URL; do
    _val="${!_name:-}"
    [[ -n "$_val" ]] && _preserve+=( "${_name}=${_val}" )
  done

  echo -e "${INFO}信息:${END} 当前用户不是 root，正在通过 sudo 重新执行（如提示密码，请输入当前用户密码）..."

  if [[ -n "$_self" ]]; then
    exec sudo env "${_preserve[@]}" READECK_SUDO_REEXEC=1 "$_bash" "$_self" "$@"
  fi

  # 2) bash -c "$(curl ...)"：从 BASH_EXECUTION_STRING 取出脚本正文
  if [[ -n "${BASH_EXECUTION_STRING:-}" ]]; then
    _tmp="$(mktemp)"
    printf '%s\n' "$BASH_EXECUTION_STRING" > "$_tmp"
    # 校验取到的内容是本脚本
    if grep -q 'SCRIPT_VERSION=' "$_tmp"; then
      chmod 700 "$_tmp"
      echo -e "${INFO}信息:${END} 已从当前进程取回脚本正文，无需联网。"
    else
      rm -f "$_tmp"; _tmp=""
    fi
  fi

  # 3) 从 READECK_INSTALL_URL 下载脚本
  if [[ -z "$_tmp" && -n "${SCRIPT_INSTALL_URL:-}" ]]; then
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
      echo -e "${ERROR}错误:${END} 需要 curl 或 wget 才能从 ${SCRIPT_INSTALL_URL} 获取脚本。"
      exit 1
    fi
    echo -e "${INFO}信息:${END} 正在从 ${SCRIPT_INSTALL_URL} 获取脚本..."
    local _dl _ok=0
    _dl="$(mktemp)"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --retry 3 --retry-delay 2 --max-time 60 "$SCRIPT_INSTALL_URL" -o "$_dl" && _ok=1 || _ok=0
    else
      wget -q -T 60 -O "$_dl" "$SCRIPT_INSTALL_URL" && _ok=1 || _ok=0
    fi
    # 校验下载内容是有效脚本
    if [[ $_ok -eq 1 ]] && [[ -s "$_dl" ]] && head -n 1 "$_dl" | grep -q '^#!'; then
      chmod 700 "$_dl"; _tmp="$_dl"
    else
      rm -f "$_dl"
      echo -e "${ERROR}错误:${END} 无法从 ${SCRIPT_INSTALL_URL} 获取有效脚本（可能返回了错误页）。"
      exit 1
    fi
  fi

  if [[ -z "$_tmp" ]]; then
    echo -e "${ERROR}错误:${END} 无法定位脚本文件，无法自动提权。"
    echo -e "      请改用以下任一方式："
    echo -e "        bash -c \"\$(curl -L <脚本地址>)\" @ $*"
    echo -e "        curl -fsSL <脚本地址> | sudo bash -s -- $*"
    echo -e "        curl -fsSL <脚本地址> -o install.sh && bash install.sh $*"
    echo -e "      或指定脚本地址后重试：READECK_INSTALL_URL=<脚本地址> bash ..."
    exit 1
  fi

  local _rc=0
  sudo env "${_preserve[@]}" READECK_SUDO_REEXEC=1 "$_bash" "$_tmp" "$@" || _rc=$?
  rm -f "$_tmp" 2>/dev/null || true
  exit $_rc
}

curl_wrapper() {
  if ! curl -# -L -q --retry 5 --retry-delay 5 --retry-max-time 60 "$@"; then
    echo -e "${ERROR}错误:${END} Curl 下载失败，请检查您的网络连接。"
    exit 1
  fi
}

install_file() {
  local SOURCE=$1 DEST=$2 PERMS=$3 OWNER=$4 GROUP=$5
  if install -m "$PERMS" -o "$OWNER" -g "$GROUP" "$SOURCE" "$DEST"; then
    echo -e "${INFO}信息:${END} 已安装 \"$DEST\""
  else
    echo -e "${ERROR}错误:${END} 安装 \"$DEST\" 失败。"
    exit 1
  fi
}

install_directory() {
  local DIR=$1 PERMS=$2 OWNER=$3 GROUP=$4
  # -p 确保父目录存在
  if install -d -m "$PERMS" -o "$OWNER" -g "$GROUP" "$DIR"; then
    echo -e "${INFO}信息:${END} 已创建目录 \"$DIR\""
  else
    echo -e "${ERROR}错误:${END} 创建目录 \"$DIR\" 失败。"
    exit 1
  fi
}

remove_temp_files() {
    if [[ -f "$NEED_REMOVE_TEMP" ]]; then
        while IFS= read -r file; do NEED_REMOVE+=( "$file" ); done < "$NEED_REMOVE_TEMP"
    fi
    echo -e "${INFO}信息:${END} 正在清理临时文件..."
    for file in "${NEED_REMOVE[@]}"; do
        if [[ -e $file ]]; then rm -rf "$file"; fi
    done
}


setup_user_and_dirs() {
  if ! getent group "$INSTALL_GROUP" &>/dev/null; then
    echo -e "${INFO}信息:${END} 正在创建用于 readeck 服务的用户组 '$INSTALL_GROUP'..."
    groupadd --system "$INSTALL_GROUP"
  fi

  if ! id "$INSTALL_USER" &>/dev/null; then
    echo -e "${INFO}信息:${END} 正在创建用于 readeck 服务的用户 '$INSTALL_USER'..."
    useradd --system -d "$DATA_DIR" -M -s /bin/false -g "$INSTALL_GROUP" "$INSTALL_USER"
  fi

  # 设置数据目录权限
  install_directory "$DATA_DIR" "755" "$INSTALL_USER" "$INSTALL_GROUP"
  # 设置配置目录权限 (readeck:root 750)
  install_directory "$CONFIG_DIR" "750" "$INSTALL_USER" "root"
}

install_readeck_binary() {
  echo -e "${INFO}信息:${END} 正在获取 readeck 版本信息..."
  
  local REPO_API_BASE_URL="https://codeberg.org/api/v1/repos/readeck/readeck/releases"
  local API_URL

  if [[ -z $READECK_VERSION ]]; then
    echo -e "${INFO}信息:${END} 未指定版本，正在获取最新版本..."
    API_URL="${REPO_API_BASE_URL}/latest"
  else
    echo -e "${INFO}信息:${END} 正在获取指定版本: $READECK_VERSION"
    # 查询指定标签的版本信息
    API_URL="${REPO_API_BASE_URL}/tags/${READECK_VERSION}"
  fi

  # 从 Codeberg API 获取版本信息
  local API_JSON
  if ! API_JSON=$(curl_wrapper -s "$API_URL"); then
      echo -e "${ERROR}错误:${END} 无法从 Codeberg API 获取版本信息: $API_URL"; exit 1
  fi

  # 解析版本号
  INSTALLED_VERSION=$(echo "$API_JSON" | grep -o '"tag_name":"[^"]*"' | cut -d '"' -f 4)
  if [[ -z "$INSTALLED_VERSION" ]]; then
      echo -e "${ERROR}错误:${END} 无法解析版本号。API 返回内容可能无效或版本不存在。"
      echo -e "      API URL: $API_URL"; exit 1
  fi

  # 解析下载链接
  DOWNLOAD_URL=$(echo "$API_JSON" | grep -o '"browser_download_url":"[^"]*"' | grep -- "${REPO_ARCH_SUFFIX}\"" | cut -d '"' -f 4 | head -n 1)
  
  if [[ -z "$DOWNLOAD_URL" ]]; then
      echo -e "${ERROR}错误:${END} 未能找到适用于 ${REPO_ARCH_SUFFIX} 架构的版本 (${INSTALLED_VERSION})。"
      echo -e "      请检查 https://codeberg.org/readeck/readeck/releases"; exit 1
  fi
  
  TEMP_BIN=$(mktemp); echo "$TEMP_BIN" >> "$NEED_REMOVE_TEMP"
  
  echo -e "${INFO}信息:${END} 正在下载 Readeck ${INSTALLED_VERSION}..."
  echo -e "      ${DOWNLOAD_URL}"
  curl_wrapper -o "$TEMP_BIN" "$DOWNLOAD_URL"
  
  echo -e "${INFO}信息:${END} 正在安装二进制文件..."
  # 设置 755 权限
  install_file "$TEMP_BIN" "$BINARY_PATH" "755" "root" "root"
}

create_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${INFO}信息:${END} 配置文件 $CONFIG_FILE 已存在，跳过创建以保留用户设置。"
        return
    fi

    echo -e "${INFO}信息:${END} 正在创建默认 $CONFIG_FILE ..."
    echo -e "${WARN}警告:${END} 默认配置仅监听 '127.0.0.1' (本地)。"
    echo -e "      如需从其他计算机访问，请将 'host' 修改为 '0.0.0.0' 并设置 'allowed_hosts'。"
    
    # 写入默认配置
    cat <<EOF > "$CONFIG_FILE"
# Readeck 默认配置文件
# 更多选项请参考: https://codeberg.org/readeck/readeck/src/branch/main/config.example.toml

[server]
# 监听地址
# 0.0.0.0 - 监听所有网络接口
# 127.0.0.1 - 仅监听本地 (推荐用于反向代理后)
host = "127.0.0.1"

# 监听端口
port = 8000

# 允许访问的主机名列表 (安全设置)
# 例如: allowed_hosts = ["read.example.net"]
allowed_hosts = []

# 信任的代理IP (如果使用反向代理，请设置为代理服务器的IP)
# 例如: trusted_proxies = ["127.0.0.1", "192.168.1.1"]
trusted_proxies = []

EOF
    chown "$INSTALL_USER":"root" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    echo -e "${INFO}信息:${END} 已创建 \"$CONFIG_FILE\""
}

setup_service() {
  echo -e "${INFO}信息:${END} 正在创建 systemd 服务文件..."
  
  # 写入 systemd 服务文件
  cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Readeck - Open Source bookmark manager
After=network.target

[Service]
User=${INSTALL_USER}
Group=${INSTALL_GROUP}
WorkingDirectory=${DATA_DIR}
ExecStart=${BINARY_PATH} serve -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5

# Optional sandboxing options
ProtectSystem=full
ReadWritePaths=${CONFIG_DIR} ${DATA_DIR}
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=yes
RestrictRealtime=yes
DevicePolicy=closed
ProtectClock=yes
ProtectHostname=yes
ProtectProc=invisible
ProtectSystem=full
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=~@clock @debug @module @mount @obsolete @reboot @setuid @swap @cpu-emulation @privileged
CapabilityBoundingSet=~CAP_RAWIO CAP_MKNOD
CapabilityBoundingSet=~CAP_AUDIT_CONTROL CAP_AUDIT_READ CAP_AUDIT_WRITE
CapabilityBoundingSet=~CAP_SYS_BOOT CAP_SYS_TIME CAP_SYS_MODULE CAP_SYS_PACCT
CapabilityBoundingSet=~CAP_LEASE CAP_LINUX_IMMUTABLE CAP_IPC_LOCK
CapabilityBoundingSet=~CAP_BLOCK_SUSPEND CAP_WAKE_ALARM
CapabilityBoundingSet=~CAP_SYS_TTY_CONFIG
CapabilityBoundingSet=~CAP_MAC_ADMIN CAP_MAC_OVERRIDE
CapabilityBoundingSet=~CAP_NET_ADMIN CAP_NET_BROADCAST CAP_NET_RAW
CapabilityBoundingSet=~CAP_SYS_ADMIN CAP_SYS_PTRACE CAP_SYSLOG

[Install]
WantedBy=multi-user.target
EOF
  echo -e "${INFO}信息:${END} 已创建 \"$SERVICE_FILE\""
  
  systemctl daemon-reload
  systemctl enable readeck.service
  echo -e "${INFO}信息:${END} 已设置 readeck 服务开机自启。"
}

uninstall() {
  echo -e "${INFO}信息:${END} 正在卸载 Readeck..."
  if systemctl list-units --type=service --all | grep -q "readeck.service"; then
    systemctl stop readeck.service || true
    systemctl disable readeck.service || true
    echo -e "${INFO}信息:${END} 已停止并禁用 readeck 服务。"
  fi

  FILES_TO_REMOVE=( "$BINARY_PATH" "$SERVICE_FILE" )

  if [[ $PURGE == true ]]; then
    echo -e "${WARN}警告: --purge 选项是毁灭性操作！${END}"
    echo -e "它将永久删除以下系统目录及其所有内容："
    echo -e "  - 配置文件: ${INFO}${CONFIG_DIR}${END}"
    echo -e "  - 数据目录: ${INFO}${DATA_DIR}${END}"

    if [[ $ASSUME_YES == true ]]; then
      echo -e "${INFO}信息:${END} 已指定 --yes，跳过交互确认。"
    elif [[ -t 0 ]]; then
      read -r -p "您确定要继续吗？请输入 'yes' 以确认: " CONFIRMATION || CONFIRMATION=""
      if [[ "$CONFIRMATION" != "yes" ]]; then
        echo -e "${INFO}信息:${END} 操作已取消。"
        exit 0
      fi
      echo -e "${INFO}信息:${END} 确认成功，继续执行彻底清除..."
    else
      echo -e "${ERROR}错误:${END} 非交互环境下执行 --purge 必须显式加 --yes 以确认。"
      exit 1
    fi

    FILES_TO_REMOVE+=( "$CONFIG_DIR" "$DATA_DIR" )
  fi

  for file in "${FILES_TO_REMOVE[@]}"; do
    if [[ -e "$file" ]]; then rm -rf "$file"; echo -e "${INFO}信息:${END} 已删除: $file"; fi
  done
  
  if [[ $PURGE == true ]]; then
      if id "$INSTALL_USER" &>/dev/null; then
         userdel "$INSTALL_USER"
         echo -e "${INFO}信息:${END} 已删除用户: $INSTALL_USER"
      fi

      if getent group "$INSTALL_GROUP" &>/dev/null; then
        groupdel "$INSTALL_GROUP" 2>/dev/null || true
        echo -e "${INFO}信息:${END} 已删除用户组: $INSTALL_GROUP"
      fi
  fi

  systemctl daemon-reload
  echo -e "${INFO}信息:${END} Readeck 卸载完成。${END}"
  if [[ $PURGE == false ]]; then
      echo -e "${WARN}注意:${END} 配置文件目录 $CONFIG_DIR 和数据目录 $DATA_DIR 未被删除。"
      echo -e "如需彻底清除，请使用 'uninstall --purge' 选项。"
  fi
}


help() {
  cat <<EOF
Readeck 安装与管理脚本（脚本版本 v${SCRIPT_VERSION}）

用法: bash -c "\$(curl -L <脚本地址>)" @ [操作] [选项]...
      bash <脚本文件> [操作] [选项]...

操作:
  install                  安装或更新 Readeck（默认）
  uninstall                卸载 Readeck（保留配置文件和数据目录）
  help                     显示此帮助信息

选项:
  --version=<版本号>       安装指定的 Readeck 版本 (例如: --version=0.20.4)
  --purge                  仅用于 uninstall：同时删除配置、数据目录和专用用户
  --yes, -y                仅用于 uninstall --purge：跳过交互确认

权限:
  脚本需要 root 权限。以普通用户直接执行时会自动调用 sudo 重新执行，
  无需手动加 sudo；若系统没有 sudo，请先切换到 root 用户。

示例:
  bash -c "\$(curl -L <脚本地址>)" @ install
  bash -c "\$(curl -L <脚本地址>)" @ install --version=0.20.4
  bash -c "\$(curl -L <脚本地址>)" @ uninstall
  bash -c "\$(curl -L <脚本地址>)" @ uninstall --purge --yes
EOF
  exit 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install)          ACTION="install" ;;
      uninstall|remove) ACTION="uninstall" ;;   # remove 为旧名，保留兼容
      help|-h|--help)   ACTION="help" ;;
      --version=*)      READECK_VERSION="${1#*=}" ;;
      --purge)          PURGE=true ;;
      --yes|-y)         ASSUME_YES=true ;;
      *)
        echo -e "${ERROR}错误:${END} 未知参数: $1"
        echo -e "      使用 'help' 查看帮助。"
        exit 1
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  if [[ -z $ACTION ]] || [[ "$ACTION" == "help" ]]; then
    help
  fi

  # 非 root 时自动通过 sudo 重新执行自身（参数原样传递）
  ensure_root "$@"

  NEED_REMOVE_TEMP="$(mktemp)"
  NEED_REMOVE=( "$NEED_REMOVE_TEMP" )
  trap remove_temp_files EXIT
  
  if [[ "$ACTION" == "install" ]]; then
    
    IS_UPDATE=false
    if [ -f "$BINARY_PATH" ]; then
        echo -e "${INFO}信息:${END} 检测到 Readeck 已安装。正在准备更新..."
        IS_UPDATE=true
        if systemctl is-active --quiet readeck.service; then
            echo -e "${INFO}信息:${END} 正在停止 readeck 服务..."
            systemctl stop readeck.service || true
        fi
    fi

    identify_the_operating_system_and_architecture
    setup_user_and_dirs
    create_config_file
    install_readeck_binary
    setup_service # 覆盖 service 文件以确保更新, 并重载 daemon

    if [[ "$IS_UPDATE" == true ]]; then
        echo -e "${INFO}信息:${END} 正在重启 readeck 服务..."
        systemctl start readeck.service
        
        echo -e "\n${INFO}------------------------------------------------------${END}"
        echo -e "${INFO}Readeck 更新成功!${END}"
        echo -e "已更新至版本: ${INFO}${INSTALLED_VERSION}${END}"
        echo -e "配置文件 ${INFO}${CONFIG_FILE}${END} 和数据目录 ${INFO}${DATA_DIR}${END} 已保留。"
        echo -e "你可以使用 ${INFO}sudo systemctl status readeck${END} 来检查服务状态。"
        echo -e "${INFO}------------------------------------------------------${END}"
    else
        echo -e "\n${INFO}------------------------------------------------------${END}"
        echo -e "${INFO}Readeck 安装成功!${END}"
        echo -e "安装版本: ${INFO}${INSTALLED_VERSION}${END}"
        echo -e "${WARN}重要操作: 服务尚未启动！${END}"
        echo -e "请根据需要编辑配置文件 ${INFO}${CONFIG_FILE}${END} (例如设置 'allowed_hosts')。"
        echo -e "配置完成后，请运行 ${INFO}sudo systemctl start readeck${END} 来启动服务。"
        echo -e "你可以使用 ${INFO}sudo systemctl status readeck${END} 来检查服务状态。"
        echo -e "${INFO}------------------------------------------------------${END}"
    fi

  elif [[ "$ACTION" == "uninstall" ]]; then
    uninstall
  fi
}

main "$@"
