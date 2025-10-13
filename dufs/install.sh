#!/usr/bin/env bash
set -e

# --- 脚本变量定义 ---
ERROR="\e[1;31m"
WARN="\e[93m"
INFO="\e[32m"
END="\e[0m"

ACTION=
DUFS_VERSION=
PURGE=false
INSTALL_USER="dufs"

CONFIG_DIR="/usr/local/etc/dufs"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
DATA_DIR="/var/lib/dufs"
LOG_DIR="/var/log/dufs"
SERVICE_FILE="/etc/systemd/system/dufs.service"

SERVICE_FILE_TEMPLATE="/etc/systemd/system/dufs@.service"
CONFIG_FILE_EXAMPLE="${CONFIG_DIR}/config.yaml.example"

NEED_REMOVE_TEMP="$(mktemp)"
NEED_REMOVE=( "$NEED_REMOVE_TEMP" )


identify_the_operating_system_and_architecture() {
  if ! [[ "$(uname)" == 'Linux' ]]; then
    echo -e "${ERROR}错误:${END} 当前脚本仅支持 Linux 操作系统。"
    exit 1
  fi
  
  case "$(uname -m)" in
    'i386' | 'i686') MACHINE='x86' ;;
    'amd64' | 'x86_64') MACHINE='x86_64' ;;
    'armv7' | 'armv7l') MACHINE='armv7' ;;
    'armv8' | 'aarch64') MACHINE='aarch64' ;;
    *) echo -e "${ERROR}错误:${END} 不支持的硬件架构: $(uname -m)。"; exit 1 ;;
  esac
  
  case "$(uname -m)" in
    'i386' | 'i686') MACHINE='i686' ;; # dufs 使用 i686
    'amd64' | 'x86_64') MACHINE='x86_64' ;;
    'armv6l') MACHINE='arm' ;; # 明确区分 arm
    'armv7' | 'armv7l') MACHINE='armv7' ;; # 明确区分 armv7
    'armv8' | 'aarch64') MACHINE='aarch64' ;;
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
    echo -e "${INFO}已安装:${END} \"$DEST\""
  else
    echo -e "${ERROR}错误:${END} 安装 \"$DEST\" 失败。"
    exit 1
  fi
}

install_directory() {
  local DIR=$1 PERMS=$2 OWNER=$3 GROUP=$4
  if install -d -m "$PERMS" -o "$OWNER" -g "$GROUP" "$DIR"; then
    echo -e "${INFO}已创建目录:${END} \"$DIR\""
  else
    echo -e "${ERROR}错误:${END} 创建目录 \"$DIR\" 失败。"
    exit 1
  fi
}

remove_temp_files() {
    if [[ -f "$NEED_REMOVE_TEMP" ]]; then
        while IFS= read -r file; do NEED_REMOVE+=( "$file" ); done < "$NEED_REMOVE_TEMP"
    fi
    echo -e "${INFO}INFO:${END} 正在清理临时文件..."
    for file in "${NEED_REMOVE[@]}"; do
        if [[ -e $file ]]; then rm -rf "$file"; fi
    done
}


setup_user_and_dirs() {
  if ! id "$INSTALL_USER" &>/dev/null; then
    echo -e "${INFO}INFO:${END} 正在创建用于 dufs 服务的用户 '$INSTALL_USER'..."
    useradd --system --user-group --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$INSTALL_USER"
  fi
  install_directory "$CONFIG_DIR" "750" "root" "$INSTALL_USER"
  install_directory "$DATA_DIR" "770" "$INSTALL_USER" "$INSTALL_USER"

  install_directory "$LOG_DIR" "770" "$INSTALL_USER" "$INSTALL_USER"
}

install_dufs_binary() {
  echo -e "${INFO}INFO:${END} 正在获取 dufs 最新版本信息..."
  
  local suffix
  case "$MACHINE" in
      "arm" | "armv7")
          suffix="-unknown-linux-musleabihf.tar.gz"
          ;;
      *)
          suffix="-unknown-linux-musl.tar.gz"
          ;;
  esac

  if [[ -z $DUFS_VERSION ]]; then
    LATEST_URL="https://api.github.com/repos/sigoden/dufs/releases/latest"
    DOWNLOAD_URL=$(curl_wrapper -s "$LATEST_URL" | grep "browser_download_url" | grep -- "-${MACHINE}${suffix}" | cut -d '"' -f 4 | head -n 1)
  else
    DOWNLOAD_URL="https://github.com/sigoden/dufs/releases/download/v${DUFS_VERSION}/dufs-v${DUFS_VERSION}-${MACHINE}${suffix}"
  fi
  if [[ -z "$DOWNLOAD_URL" ]]; then
      echo -e "${ERROR}错误:${END} 未能找到适用于 ${MACHINE} 架构的版本。请检查 https://github.com/sigoden/dufs/releases"; exit 1
  fi
  
  TEMP_TAR="/tmp/dufs.tar.gz"; echo "$TEMP_TAR" >> "$NEED_REMOVE_TEMP"
  TEMP_DIR=$(mktemp -d); echo "$TEMP_DIR" >> "$NEED_REMOVE_TEMP"
  
  echo -e "${INFO}INFO:${END} 正在下载 dufs..."
  curl_wrapper -o "$TEMP_TAR" "$DOWNLOAD_URL"
  
  echo -e "${INFO}INFO:${END} 正在解压并安装..."
  tar -xzf "$TEMP_TAR" -C "$TEMP_DIR"
  install_file "$TEMP_DIR/dufs" "/usr/local/bin/dufs" "755" "root" "root"
}

create_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${INFO}INFO:${END} 配置文件 $CONFIG_FILE 已存在，跳过创建。"
        return
    fi

    echo -e "${INFO}INFO:${END} 正在创建 YAML 格式的默认配置文件..."
    cat <<EOF > "$CONFIG_FILE"
# dufs 服务配置文件 (YAML 格式)
# ======================================================
#
# 使用方法:
# 1. 根据您的需求，选择下面的一个功能区块。
# 2. 去掉该区块内所有行开头的 '#' 注释符。
# 3. 根据注释说明修改参数值。
# 4. 保存文件后，运行 'sudo systemctl restart dufs' 来应用配置。
#
# 注意: 请不要同时启用多个功能区块！
#
# ======================================================

# --- 功能一：作为静态网站/博客服务器 ---
# 描述: 适用于托管静态站点。它会自动渲染目录下的 index.html 文件。
# 准备: 请先创建 serve-path 指定的目录 (例如 mkdir -p /var/lib/dufs/my-blog)，
#      然后将您的网站文件放入其中，并确保 dufs 用户有读取权限。
#
# serve-path: ./my-blog  # 相对于工作目录 (/var/lib/dufs) 的路径
# bind: 0.0.0.0
# port: 5000
# render-index: true     # 启用索引页渲染
# log-format: '\$remote_addr "\$request" \$status \$http_user_agent' # 日志格式
# log-file: ${LOG_DIR}/dufs.log

# --- 功能二：作为文件上传/下载服务器 ---
# 描述: 快速搭建一个私人的、支持上传下载的文件分享服务。
# 准备: 请先创建 serve-path 指定的目录 (例如 mkdir -p /var/lib/dufs/shared-files)，
#      并确保 dufs 用户有读写权限 (例如 sudo chown -R dufs:dufs /var/lib/dufs/shared-files)。
#
# 建议的文件服务器配置 (dufs.yaml)

# 1. 安全设置：将文件服务的根目录指向一个专门的文件夹，例如 'data'
#    避免暴露配置文件等敏感信息。
serve-path: .

# 2. 网络设置：监听所有网络接口的 5000 端口
bind: 0.0.0.0
port: 5000

# (可选) 如果在 Nginx 等反代后使用，这个前缀很有用
# path-prefix: /dufs

# 3. 认证与权限：移除匿名访问，只允许授权用户登录
#    这是最重要的安全修改！
auth:
  # 管理员: 密码为'admin'，对所有目录有读写权限
  - admin:admin@/:rw
  # 普通用户: 密码为'pass'，对/src目录读写，对/share目录只读
  - user:pass@/src:rw,/share

# 4. 核心功能开关：开启上传、删除、搜索和打包下载功能
allow-upload: true
allow-delete: true
allow-search: true
allow-archive: true

# 5. 日志记录：保留日志以供审计
log-format: '\$remote_addr "\$request" \$status \$http_user_agent'
log-file: ${LOG_DIR}/dufs.log

# 6. 性能：开启压缩以提升传输速度
compress: low
EOF
    chown root:"$INSTALL_USER" "$CONFIG_FILE"
    chmod 640 "$CONFIG_FILE"
    echo -e "${INFO}已创建:${END} \"$CONFIG_FILE\""

    if [ ! -f "$CONFIG_FILE_EXAMPLE" ]; then
        echo -e "${INFO}INFO:${END} 正在创建多实例模板配置文件..."
        cp "$CONFIG_FILE" "$CONFIG_FILE_EXAMPLE"
        # 在模板文件顶部添加说明
        sed -i '1s/^/# 这是一个用于多实例服务 (dufs@.service) 的模板文件。\n# 请复制此文件并以您的实例名重命名 (例如: blog.yaml)。\n/' "$CONFIG_FILE_EXAMPLE"
        echo -e "${INFO}已创建:${END} \"$CONFIG_FILE_EXAMPLE\""
    fi
}

setup_service() {
  cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Dufs - A file server
Documentation=https://github.com/sigoden/dufs
After=network.target

[Service]
User=${INSTALL_USER}
Group=${INSTALL_USER}
Type=simple
WorkingDirectory=${DATA_DIR}
ExecStart=/usr/local/bin/dufs -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5
LimitNPROC=512
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  echo -e "${INFO}已创建:${END} \"$SERVICE_FILE\""

  cat <<EOF > "$SERVICE_FILE_TEMPLATE"
[Unit]
Description=Dufs - A file server for instance %i
Documentation=https://github.com/sigoden/dufs
After=network.target

[Service]
User=${INSTALL_USER}
Group=${INSTALL_USER}
Type=simple
WorkingDirectory=${DATA_DIR}
ExecStart=/usr/local/bin/dufs run -c ${CONFIG_DIR}/%i.yaml
Restart=on-failure
RestartSec=5
LimitNPROC=512
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  echo -e "${INFO}已创建:${END} \"$SERVICE_FILE_TEMPLATE\""

  install_directory "${SERVICE_FILE}.d" "755" "root" "root"
  install_directory "${SERVICE_FILE_TEMPLATE}.d" "755" "root" "root"  

  systemctl daemon-reload
  systemctl enable dufs.service
  
  echo -e "\n${INFO}------------------------------------------------------${END}"
  echo -e "${INFO}dufs 安装成功!${END}"
  echo -e "${WARN}重要操作: 服务尚未启动！${END}"
  echo -e "请编辑配置文件 ${INFO}${CONFIG_FILE}${END} 来选择并启用一种服务模式。"
  echo -e "配置完成后，请运行 ${INFO}sudo systemctl start dufs${END} 来启动服务。"
  echo -e "你可以使用 ${INFO}sudo systemctl status dufs${END} 来检查服务状态。"
  echo -e "${INFO}------------------------------------------------------${END}"
}

uninstall() {
  echo -e "${INFO}INFO:${END} 正在卸载 dufs..."
  if systemctl list-units --type=service --all | grep -q "dufs"; then
    systemctl stop dufs.service dufs@*.service || true
    systemctl disable dufs.service dufs@*.service || true
    echo -e "${INFO}INFO:${END} 已停止并禁用 dufs 服务。"
  fi

  FILES_TO_REMOVE=( "/usr/local/bin/dufs" "$SERVICE_FILE" "$SERVICE_FILE_TEMPLATE" "${SERVICE_FILE}.d" "${SERVICE_FILE_TEMPLATE}.d" )

  if [[ $PURGE == true ]]; then
    echo -e "${WARN}警告: --purge 选项是毁灭性操作！${END}"
    echo -e "它将永久删除以下系统目录及其所有内容："
    echo -e "  - 配置文件: ${INFO}${CONFIG_DIR}${END}"
    echo -e "  - 默认数据目录: ${INFO}${DATA_DIR}${END}"
    echo -e "  - 日志目录: ${INFO}${LOG_DIR}${END}"
    echo -e "${ERROR}注意: 如果您在配置文件中使用了自定义的数据路径，该路径不会被此脚本删除，但与 dufs 相关的所有用户和组将被移除。${END}"
    
    read -p "您确定要继续吗？请输入 'yes' 以确认: " CONFIRMATION
    
    if [[ "$CONFIRMATION" != "yes" ]]; then
      echo -e "${INFO}操作已取消。${END}"
      exit 0
    fi
    
    echo -e "${INFO}确认成功，继续执行彻底清除...${END}"
    FILES_TO_REMOVE+=( "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR" )
  fi

  for file in "${FILES_TO_REMOVE[@]}"; do
    if [[ -e "$file" ]]; then rm -rf "$file"; echo -e "${INFO}已删除:${END} $file"; fi
  done
  
  if [[ $PURGE == true ]]; then

      if id "$INSTALL_USER" &>/dev/null; then
         userdel "$INSTALL_USER"
         echo -e "${INFO}已删除用户:${END} $INSTALL_USER"
      fi

      if getent group "$INSTALL_USER" &>/dev/null; then
        groupdel "$INSTALL_USER" 2>/dev/null || true
        echo -e "${INFO}已删除用户组:${END} $INSTALL_USER"
      fi

  fi

  systemctl daemon-reload
  echo -e "${INFO}dufs 卸载完成。${END}"
  if [[ $PURGE == false ]]; then
      echo -e "${WARN}注意:${END} 配置文件目录 $CONFIG_DIR 和数据目录 $DATA_DIR 未被删除。"
      echo -e "如需彻底清除，请使用 'remove --purge' 选项。"
  fi
}


help() {
  echo "dufs 安装与管理脚本 "
  echo "用法: ./install.sh [操作] [选项]..."
  echo "操作:"
  echo "  install                  安装或更新 dufs"
  echo "  remove                   卸载 dufs (保留配置文件和数据目录)"
  echo "  help                     显示此帮助信息"
  echo "选项:"
  echo "  --version=<版本号>       安装指定的 dufs 版本 (例如: --version=0.45.0)"
  echo "  remove --purge           彻底卸载 dufs, 包括配置、数据目录和专用用户"
  exit 0
}

parse_args() {
    for arg in "$@"; do
    case $arg in
        install) ACTION="install"; shift ;;
        remove) ACTION="uninstall"; shift ;;
        help) ACTION="help"; shift ;;
        --version=*) DUFS_VERSION="${arg#*=}"; shift ;;
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
    identify_the_operating_system_and_architecture
    setup_user_and_dirs
    create_config_file
    install_dufs_binary
    setup_service
  elif [[ "$ACTION" == "uninstall" ]]; then
    uninstall
  fi
}

main "$@"
