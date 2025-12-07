#!/usr/bin/env bash
set -e

# --- 脚本变量定义 ---
ERROR="\e[1;31m"
WARN="\e[93m"
INFO="\e[32m"
END="\e[0m"

ACTION=
READECK_VERSION=
PURGE=false
INSTALL_USER="readeck"
INSTALL_GROUP="readeck"

CONFIG_DIR="/etc/readeck"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
DATA_DIR="/var/lib/readeck"
SERVICE_FILE="/etc/systemd/system/readeck.service"
BINARY_PATH="/usr/local/bin/readeck"

# 用于 install_binary 函数回传版本号
INSTALLED_VERSION=""

# 临时文件列表
NEED_REMOVE_TEMP="$(mktemp)"
NEED_REMOVE=( "$NEED_REMOVE_TEMP" )

identify_the_operating_system_and_architecture() {
  if ! [[ "$(uname)" == 'Linux' ]]; then
    echo -e "${ERROR}错误:${END} 当前脚本仅支持 Linux 操作系统。"
    exit 1
  fi
  
  # 优化：根据您提供的包列表 (v0.20.4) 调整后缀
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

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${ERROR}错误:${END} 请使用 root 权限运行此脚本 (例如: sudo ./install.sh install)。"
    exit 1
  fi
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

  # 按照文档设置数据目录权限
  install_directory "$DATA_DIR" "755" "$INSTALL_USER" "$INSTALL_GROUP"
  # 按照文档设置配置目录权限 (readeck:root 750)
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
    # 优化：查询指定标签(tag)的 API，而不是猜测下载链接
    API_URL="${REPO_API_BASE_URL}/tags/${READECK_VERSION}"
  fi

  # 尝试从 Codeberg API 获取版本信息
  # 优化：使用 grep -o 和 cut 来稳健地处理 Codeberg 返回的单行(minified) JSON
  local API_JSON
  if ! API_JSON=$(curl_wrapper -s "$API_URL"); then
      echo -e "${ERROR}错误:${END} 无法从 Codeberg API 获取版本信息: $API_URL"; exit 1
  fi

  # 解析 tag_name (版本号)
  # grep -o '"tag_name":"[^"]*"' 提取 "tag_name":"0.20.4"
  # cut -d '"' -f 4            提取 0.20.4
  INSTALLED_VERSION=$(echo "$API_JSON" | grep -o '"tag_name":"[^"]*"' | cut -d '"' -f 4)
  if [[ -z "$INSTALLED_VERSION" ]]; then
      echo -e "${ERROR}错误:${END} 无法解析版本号。API 返回内容可能无效或版本不存在。"
      echo -e "      API URL: $API_URL"; exit 1
  fi

  # 解析下载链接
  # grep -o '"browser_download_url":"[^"]*"'  提取所有URL
  # grep -- "${REPO_ARCH_SUFFIX}\""           过滤出以 <ARCH>" 结尾的 URL (排除 .sha256)
  # cut -d '"' -f 4                           提取 URL
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
  # 按照文档设置 a+x (755) 权限
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
    
    # 使用文档中提供的推荐配置
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
  
  # 使用文档中提供的完整 .service 文件内容
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
    
    read -p "您确定要继续吗？请输入 'yes' 以确认: " CONFIRMATION
    
    if [[ "$CONFIRMATION" != "yes" ]]; then
      echo -e "${INFO}信息:${END} 操作已取消。"
      exit 0
    fi
    
    echo -e "${INFO}信息:${END} 确认成功，继续执行彻底清除..."
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
      echo -e "如需彻底清除，请使用 'remove --purge' 选项。"
  fi
}


help() {
  echo "Readeck 安装与管理脚本"
  echo "用法: ./install.sh [操作] [选项]..."
  echo "操作:"
  echo "  install                  安装或更新 Readeck"
  echo "  remove                   卸载 Readeck (保留配置文件和数据目录)"
  echo "  help                     显示此帮助信息"
  echo "选项:"
  echo "  --version=<版本号>       安装指定的 Readeck 版本 (例如: --version=0.20.4)"
  echo "  remove --purge           彻底卸载 Readeck, 包括配置、数据目录和专用用户"
  exit 0
}

parse_args() {
    for arg in "$@"; do
    case $arg in
        install) ACTION="install"; shift ;;
        remove) ACTION="uninstall"; shift ;;
        help) ACTION="help"; shift ;;
        --version=*) READECK_VERSION="${arg#*=}"; shift ;;
        --purge) PURGE=true; shift ;;
        *) ;;
    esac
    done
}

main() {
  parse_args "$@"
 
  if [[ -z $ACTION ]] || [[ "$ACTION" == "help" ]]; then
    help
  fi

  trap remove_temp_files EXIT
  check_root
  
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
