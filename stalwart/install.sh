#!/usr/bin/env sh

set -e
set -u

readonly BASE_URL="https://github.com/stalwartlabs/stalwart/releases/latest/download"
readonly VERSION="2.1.0"

show_help() {
    cat <<EOF
Stalwart 安装/卸载脚本 v${VERSION}

用法: $0 [命令] [选项] [PREFIX]

命令:
  install         安装或更新 Stalwart
  uninstall       完全卸载 Stalwart
  help, --help    显示帮助信息

选项:
  --fdb           安装 FoundationDB 版本
  --force-init    强制覆盖环境配置文件

参数:
  PREFIX          自定义安装路径。如果不提供：
                  - 若 /opt/stalwart 已存在，则默认使用该路径。
                  - 否则，将遵循 FHS 标准安装到系统目录 (/usr/local/bin, /etc/stalwart 等)。

示例:
  $0 install /opt/stalwart       
  $0 install                     
  $0 install --fdb               
EOF
    exit 0
}

main() {
    if [ $# -eq 0 ]; then
        show_help
    fi

    local _command="install"
    case "$1" in
        install)
            _command="install"
            shift
            ;;
        uninstall)
            _command="uninstall"
            shift
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            _command="install"
            ;;
    esac

    case "$_command" in
        install) do_install "$@" ;;
        uninstall) do_uninstall "$@" ;;
    esac
}

do_install() {
    downloader --check
    need_cmd uname
    need_cmd mktemp
    need_cmd chmod
    need_cmd chown
    need_cmd mkdir
    need_cmd rm
    need_cmd tar
    need_cmd cp
    need_cmd hostname

    if [ "$(id -u)" -ne 0 ]; then
        err "❌ 安装失败：此程序需要以 root 权限运行。"
    fi

    local _os="unknown"
    local _uname="$(uname)"
    local _account="stalwart"
    case "$_uname" in
        Linux)  _os="linux" ;;
        Darwin) _os="macos"; _account="_stalwart" ;;
        *)      err "❌ 不支持的 OS: $_uname" ;;
    esac

    local _component="stalwart"
    local _prefix=""
    local _force_init=0
    
    while [ $# -gt 0 ]; do
        case "$1" in
            --fdb) _component="stalwart-foundationdb" ;;
            --force-init) _force_init=1 ;;
            -*) err "未知选项: $1" ;;
            *) _prefix="$1" ;;
        esac
        shift
    done

    local _bin_dir _conf_dir _log_dir _data_dir _is_fhs=0
    
    if [ -z "$_prefix" ]; then
        if [ -d "/opt/stalwart" ]; then
            _prefix="/opt/stalwart"
        else
            _is_fhs=1
        fi
    fi

    if [ "$_is_fhs" -eq 1 ]; then
        _bin_dir="/usr/local/bin"
        _conf_dir="/etc/stalwart"
        _log_dir="/var/log/stalwart"
        _data_dir="/var/lib/stalwart"
    else
        _bin_dir="${_prefix}/bin"
        _conf_dir="${_prefix}/etc"
        _log_dir="${_prefix}/logs"
        _data_dir="${_prefix}/data"
    fi

    local _bin_file="${_bin_dir}/stalwart"
    local _config_file="${_conf_dir}/config.json"
    local _env_file="${_conf_dir}/stalwart.env"

    get_architecture || return 1
    local _arch="$RETVAL"

    if [ -f "$_bin_file" ]; then
        say "📦 检测到已安装，正在执行更新 (目录: ${_prefix:-FHS Standard})..."
        if [ "${_os}" = "linux" ]; then
            check_cmd systemctl && systemctl stop stalwart.service 2>/dev/null || true
        elif [ "${_os}" = "macos" ]; then
            launchctl bootout system /Library/LaunchDaemons/stalwart.plist 2>/dev/null || true
        fi
    fi

    ensure mkdir -p "$_bin_dir" "$_conf_dir" "$_log_dir" "$_data_dir"

    say "⏳ 正在下载 ${_component} (${_arch})..."
    local _tmp="$(mktemp -d)"
    local _tar="${_tmp}/stalwart.tar.gz"
    ensure downloader "${BASE_URL}/${_component}-${_arch}.tar.gz" "$_tar" "$_arch"
    ensure tar zxf "$_tar" -C "$_tmp"
    local _src_name="stalwart"
    [ "$_component" = "stalwart-foundationdb" ] && _src_name="stalwart-foundationdb"
    ensure cp "${_tmp}/${_src_name}" "$_bin_file"
    ensure chmod 0755 "$_bin_file"
    ensure rm -rf "$_tmp"

    create_account "$_os" "$_account"

    if [ ! -e "$_env_file" ] || [ $_force_init -eq 1 ]; then
        write_env_file "$_env_file"
    fi

    say "🔐 设置权限..."
    ensure chown "${_account}:${_account}" "$_conf_dir" "$_log_dir" "$_data_dir"
    ensure chmod 0750 "$_conf_dir" "$_log_dir" "$_data_dir"
    ensure chown "root:${_account}" "$_env_file"
    ensure chmod 0640 "$_env_file"

    say "🚀 启动服务..."
    if [ "${_os}" = "linux" ]; then
        create_service_linux_systemd "$_bin_file" "$_config_file" "$_env_file" "$_account"
    elif [ "${_os}" = "macos" ]; then
        create_service_macos "$_bin_file" "$_config_file" "$_env_file" "$_account"
    fi

    local _host="$(hostname -f 2>/dev/null || hostname)"
    say "🎉 安装完成! 请在浏览器中继续设置: http://${_host}:8080/admin"
}

do_uninstall() {
    local _dir="${1:-/opt/stalwart}"
    say "🗑️  正在卸载..."
    if [ -f /etc/systemd/system/stalwart.service ]; then
        systemctl stop stalwart.service 2>/dev/null || true
        systemctl disable stalwart.service 2>/dev/null || true
        rm -f /etc/systemd/system/stalwart.service
        systemctl daemon-reload
    fi
    [ -d "$_dir" ] && rm -rf "$_dir"
    say "✅ 卸载完成"
}

write_env_file() {
    cat > "$1" <<'EOF'
#STALWART_RECOVERY_MODE=true
#STALWART_RECOVERY_ADMIN=admin:changeme
EOF
}

create_account() {
    local _os="$1" _account="$2"
    id -u "$_account" >/dev/null 2>&1 && return 0
    if [ "$_os" = "macos" ]; then
        local _uid="$(dscacheutil -q user | grep uid | awk '{print $2}' | sort -n | tail -n 1)"
        local _gid="$(dscacheutil -q group | grep gid | awk '{print $2}' | sort -n | tail -n 1)"
        _uid=$((_uid+1)); _gid=$((_gid+1))
        dscl /Local/Default -create Groups/_stalwart
        dscl /Local/Default -create Groups/_stalwart PrimaryGroupID $_gid
        dscl /Local/Default -create Users/_stalwart
        dscl /Local/Default -create Users/_stalwart PrimaryGroupID $_gid
        dscl /Local/Default -create Users/_stalwart UniqueID $_uid
        dscl /Local/Default -create Users/_stalwart UserShell /usr/bin/false
    else
        useradd "$_account" -s /usr/sbin/nologin -M -r -U
    fi
}

create_service_linux_systemd() {
    cat > /etc/systemd/system/stalwart.service <<EOF
[Unit]
Description=Stalwart Mail Server
After=network-online.target
[Service]
Type=simple
EnvironmentFile=-$3
ExecStart=$1 --config=$2
User=$4
Group=$4
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable stalwart.service
    systemctl restart stalwart.service
}

create_service_macos() {
    local _plist="/Library/LaunchDaemons/stalwart.plist"
    cat > "$_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>stalwart</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string><string>-c</string>
        <string>set -a; [ -r "$3" ] && . "$3"; exec "$1" --config="$2"</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
    launchctl bootstrap system "$_plist" 2>/dev/null || true
    launchctl enable system/stalwart
}

get_architecture() {
    local _ostype="$(uname -s)" _cputype="$(uname -m)" _arch=""
    case "$_ostype" in
        Linux) _ostype="unknown-linux-gnu" ;;
        Darwin) _ostype="apple-darwin" ;;
    esac
    case "$_cputype" in
        x86_64|amd64) _cputype="x86_64" ;;
        aarch64|arm64) _cputype="aarch64" ;;
    esac
    _arch="${_cputype}-${_ostype}"
    RETVAL="$_arch"
}

downloader() {
    local _dld="curl"; check_cmd wget && _dld="wget"
    [ "$1" = "--check" ] && return 0
    if [ "$_dld" = "curl" ]; then
        curl -sSL "$1" -o "$2"
    else
        wget -q "$1" -O "$2"
    fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || exit 1; }
check_cmd() { command -v "$1" >/dev/null 2>&1; }
ensure() { "$@" || exit 1; }
say() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; exit 1; }

main "$@" || exit 1
