#!/usr/bin/env sh
# shellcheck shell=dash

#
# Stalwart 安装/卸载脚本
#
# 功能：
#   * install   安装或升级 Stalwart（默认命令）
#   * uninstall 卸载 Stalwart（可用 --yes 跳过交互确认）
#   * 未指定 PREFIX 时优先复用 /opt/stalwart 下已有的安装，否则按 FHS 布局安装
#   * --force-init 强制重写 stalwart.env
#   * 安装/升级后修复目录属主与权限
#   * 非 root 执行时自动通过 sudo 提权重跑
#

set -e
set -u

readonly BASE_URL="https://github.com/stalwartlabs/stalwart/releases/latest/download"
readonly SCRIPT_VERSION="2.4.0"

# 可选的脚本来源地址，默认为空（不绑定任何域名）。
# 仅在无法从磁盘文件或当前进程取回脚本正文时使用。
readonly SCRIPT_INSTALL_URL="${STALWART_INSTALL_URL:-}"

# 脚本自身的显示名
script_name() {
    if [ -n "$0" ] && [ -f "$0" ]; then
        basename "$0"
    else
        echo "install.sh"
    fi
}

show_help() {
    local _me
    _me="$(script_name)"
    cat <<EOF
Stalwart 安装/卸载脚本（脚本版本 v${SCRIPT_VERSION}）

用法: ${_me} [命令] [选项] [PREFIX]

命令:
  install         安装或更新 Stalwart（默认，省略命令时即执行此动作）
  uninstall       卸载 Stalwart（自动识别 /opt/stalwart 或 FHS 布局）
  help, --help    显示帮助信息

选项:
  --force-init    强制覆盖 stalwart.env 环境配置文件
  --fdb           已废弃，保留参数以兼容旧脚本（标准版已内置 FoundationDB 客户端）
  --yes, -y       仅用于 uninstall：跳过交互确认（非交互环境建议显式指定）

参数:
  PREFIX          自定义安装路径。如果不提供：
                  - 若 /opt/stalwart 下存在已有安装（bin/stalwart 或 etc/config.json），
                    则默认使用该路径。
                  - 否则，将遵循 FHS 标准安装到系统目录：
                      Linux:   /usr/local/bin, /etc/stalwart, /var/log/stalwart, /var/lib/stalwart
                      FreeBSD: /usr/local/bin, /usr/local/etc/stalwart, /var/log/stalwart, /var/db/stalwart

权限:
  脚本需要 root 权限。以普通用户直接执行时会自动调用 sudo 重新执行，
  无需手动加 sudo；若系统没有 sudo，请先切换到 root 用户。
  以 bash -c "\$(curl ...)" 方式执行时，脚本会从当前进程取回自身正文后再提权，无需联网。

示例:
  ${_me} install /opt/stalwart
  ${_me} install
  ${_me} install --force-init
  ${_me} uninstall
  ${_me} uninstall --yes /opt/stalwart
EOF
    exit 0
}

main() {
    # 帮助信息无需 root，先处理 -h/--help/help
    local _scan
    for _scan in "$@"; do
        case "$_scan" in
            -h|--help|help) show_help ;;
        esac
    done

    # 校验命令是否合法（在提权之前）
    if [ $# -gt 0 ]; then
        case "$1" in
            install|uninstall|/*|-*) ;;
            *) err "❌ 未知命令: $1 (可用: install / uninstall / help)" ;;
        esac
    fi

    # 非 root 时自动通过 sudo 重新执行自身（此处 "$@" 尚未被 shift）
    ensure_root "$@"

    # 无参数时执行安装（install 为默认命令）
    local _command="install"

    if [ $# -gt 0 ]; then
        case "$1" in
            install)
                _command="install"
                shift
                ;;
            uninstall)
                _command="uninstall"
                shift
                ;;
            /*)
                # 直接给了绝对路径，按默认命令 install 处理
                ;;
            -*)
                # 直接给了选项（如 --force-init），交给 do_install 解析
                ;;
        esac
    fi

    case "$_command" in
        install) do_install "$@" ;;
        uninstall) do_uninstall "$@" ;;
    esac
}

# 非 root 时通过 sudo 重新执行自身。
# 脚本正文来源依次为：磁盘文件、BASH_EXECUTION_STRING、STALWART_INSTALL_URL。
# 参数与代理变量原样传递。
ensure_root() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi

    # 已提权过仍非 root 时退出，避免重复执行
    if [ "${STALWART_SUDO_REEXEC:-0}" = "1" ]; then
        err "❌ 已尝试通过 sudo 提权，但当前仍不是 root，已停止以避免递归。"
    fi

    if ! check_cmd sudo; then
        say "❌ 需要 root 权限，但系统中没有 sudo。"
        say "   请先切换到 root 用户再执行本脚本。"
        exit 1
    fi

    local _self="" _dir="" _tmp=""

    # 1) 磁盘上的脚本文件（$0 是真实文件时）
    if [ -n "$0" ] && [ -f "$0" ]; then
        case "$0" in
            /*)
                _self="$0"
                ;;
            *)
                _dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _dir=""
                if [ -n "$_dir" ]; then
                    _self="${_dir}/$(basename "$0")"
                fi
                ;;
        esac
    fi

    # 2) bash -c "$(curl ...)"：从 BASH_EXECUTION_STRING 取出脚本正文
    if [ -z "$_self" ] && [ -n "${BASH_EXECUTION_STRING:-}" ]; then
        _tmp="$(mktemp)" || err "❌ 无法创建临时文件。"
        printf '%s\n' "$BASH_EXECUTION_STRING" > "$_tmp"
        # 校验取到的内容是本脚本
        if grep -q 'SCRIPT_VERSION=' "$_tmp" 2>/dev/null; then
            chmod 700 "$_tmp"
            _self="$_tmp"
            say "📄 已从当前进程取回脚本正文，无需联网。"
        else
            rm -f "$_tmp"
            _tmp=""
        fi
    fi

    # 3) 从 STALWART_INSTALL_URL 下载脚本
    if [ -z "$_self" ] && [ -n "$SCRIPT_INSTALL_URL" ]; then
        say "📥 未找到本地脚本文件，正在从 ${SCRIPT_INSTALL_URL} 获取..."
        _tmp="$(mktemp)" || err "❌ 无法创建临时文件。"
        if check_cmd curl; then
            curl -fsSL "$SCRIPT_INSTALL_URL" -o "$_tmp" \
                || { rm -f "$_tmp"; err "❌ 获取脚本失败: ${SCRIPT_INSTALL_URL}"; }
        elif check_cmd wget; then
            wget -q "$SCRIPT_INSTALL_URL" -O "$_tmp" \
                || { rm -f "$_tmp"; err "❌ 获取脚本失败: ${SCRIPT_INSTALL_URL}"; }
        else
            rm -f "$_tmp"
            err "❌ 需要 curl 或 wget 才能从 ${SCRIPT_INSTALL_URL} 获取脚本。"
        fi
        # 校验下载内容是有效脚本
        if head -n 1 "$_tmp" 2>/dev/null | grep -q '^#!'; then
            chmod 700 "$_tmp"
            _self="$_tmp"
        else
            rm -f "$_tmp"
            _tmp=""
            err "❌ 获取到的内容不是有效脚本，请检查 ${SCRIPT_INSTALL_URL}"
        fi
    fi

    if [ -z "$_self" ]; then
        say "❌ 无法定位脚本文件，无法自动提权。"
        say "   请改用以下任一方式："
        say "     bash -c \"\$(curl -L <脚本地址>)\" @ $*"
        say "     curl -fsSL <脚本地址> | sudo sh -s -- $*"
        say "     curl -fsSL <脚本地址> -o install.sh && sh install.sh $*"
        say "   或指定脚本地址后重试：STALWART_INSTALL_URL=<脚本地址>"
        exit 1
    fi

    # 保留代理与 TLS 相关环境变量（sudo 默认会重置）
    local _name _val _preserve=""
    for _name in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
                 http_proxy https_proxy all_proxy no_proxy \
                 RUSTUP_TLS_CIPHERSUITES STALWART_INSTALL_URL; do
        eval "_val=\${${_name}:-}"
        if [ -n "$_val" ]; then
            _preserve="${_preserve} ${_name}=${_val}"
        fi
    done

    say "🔑 当前用户不是 root，正在通过 sudo 重新执行（如提示密码，请输入当前用户密码）..."

    # 使用临时文件时需要清理，故不使用 exec
    if [ -n "$_tmp" ]; then
        local _rc=0
        # shellcheck disable=SC2086
        sudo env ${_preserve} STALWART_SUDO_REEXEC=1 sh "$_self" "$@" || _rc=$?
        rm -f "$_tmp" 2>/dev/null || true
        exit $_rc
    fi

    # shellcheck disable=SC2086
    exec sudo env ${_preserve} STALWART_SUDO_REEXEC=1 sh "$_self" "$@"
}

do_install() {
    # 任何位置出现 -h/--help 都显示帮助（无需 root）
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
            -h|--help) show_help ;;
        esac
    done

    downloader --check
    need_cmd uname
    need_cmd mktemp
    need_cmd chmod
    need_cmd chown
    need_cmd mkdir
    need_cmd rm
    need_cmd tar
    need_cmd cp
    need_cmd mv
    need_cmd hostname

    if [ "$(id -u)" -ne 0 ]; then
        err "❌ 安装失败：需要 root 权限（自动提权未生效，请手动以 root 执行）。"
    fi

    # 检测操作系统
    local _os="" _uname="" _account="stalwart"
    _uname="$(uname)"
    case "$_uname" in
        Linux)   _os="linux" ;;
        Darwin)  _os="macos"; _account="_stalwart" ;;
        FreeBSD) _os="freebsd" ;;
        *)       err "❌ 不支持的 OS: $_uname" ;;
    esac

    # 解析参数
    local _prefix="" _force_init=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            --force-init)
                _force_init=1
                ;;
            --fdb)
                say "⚠️  --fdb 已废弃：自 v1.2.0 起官方不再单独发布 stalwart-foundationdb，"
                say "    标准版已内置 FoundationDB 原生客户端，本次继续安装标准版本。"
                ;;
            --*|-*)
                err "❌ 未知选项: $1 (使用 --help 查看帮助)"
                ;;
            *)
                if [ -n "$_prefix" ]; then
                    err "❌ 只允许一个安装路径参数，收到: $_prefix $1"
                fi
                _prefix="$1"
                ;;
        esac
        shift
    done

    # 未显式指定 PREFIX 时，优先复用 /opt/stalwart 下已有的安装
    if [ -z "$_prefix" ] && is_opt_install; then
        _prefix="/opt/stalwart"
    fi

    if [ -n "$_prefix" ]; then
        _prefix="$(normalize_prefix "$_prefix")"
        validate_prefix "$_prefix"
    fi

    # 计算安装路径
    local _bin_dir _conf_dir _log_dir _data_dir
    if [ -n "$_prefix" ]; then
        _bin_dir="${_prefix}/bin"
        _conf_dir="${_prefix}/etc"
        _log_dir="${_prefix}/logs"
        _data_dir="${_prefix}/data"
    elif [ "$_os" = "freebsd" ]; then
        _bin_dir="/usr/local/bin"
        _conf_dir="/usr/local/etc/stalwart"
        _log_dir="/var/log/stalwart"
        _data_dir="/var/db/stalwart"
    else
        _bin_dir="/usr/local/bin"
        _conf_dir="/etc/stalwart"
        _log_dir="/var/log/stalwart"
        _data_dir="/var/lib/stalwart"
    fi

    local _bin_file="${_bin_dir}/stalwart"
    local _config_file="${_conf_dir}/config.json"
    local _env_file="${_conf_dir}/stalwart.env"
    local _is_update=0 _has_config=0

    # 判断是否为升级（兼容只有二进制、没有 config.json 的旧安装）
    if [ -e "$_config_file" ]; then
        _has_config=1
        _is_update=1
    elif [ -f "$_bin_file" ]; then
        _is_update=1
    fi

    local _arch="" _local_version="" _remote_version=""
    get_architecture || return 1
    _arch="$RETVAL"
    assert_nz "$_arch" "arch"

    if [ "$_is_update" -eq 1 ]; then
        say "📦 检测到已安装的 Stalwart (目录: ${_prefix:-FHS 标准布局})..."

        if [ -x "$_bin_file" ]; then
            _local_version="$("$_bin_file" --version 2>/dev/null | head -n 1 | awk '{print $NF}' | sed 's/^v//')"
        fi

        # 通过 GitHub latest 重定向获取最新版本号
        if check_cmd curl; then
            _remote_version=$(curl -sLI -o /dev/null -w '%{url_effective}' "https://github.com/stalwartlabs/stalwart/releases/latest" | awk -F'/' '{print $NF}' | sed 's/^v//' | head -n 1)
        elif check_cmd wget; then
            _remote_version=$(wget --server-response --max-redirect=0 "https://github.com/stalwartlabs/stalwart/releases/latest" 2>&1 | grep -i -m 1 "Location:" | awk -F'/' '{print $NF}' | tr -d '\r' | sed 's/^v//' | head -n 1)
        fi

        if [ -n "$_local_version" ] && [ -n "$_remote_version" ] && [ "$_local_version" = "$_remote_version" ]; then
            say "✅ 当前已是最新版本 (v${_local_version})"
            # 配置完整且未指定 --force-init 时提前退出
            if [ "$_has_config" -eq 1 ] && [ -e "$_env_file" ] && [ "$_force_init" -eq 0 ] && service_installed "$_os"; then
                say "🔐 检查并修复目录权限..."
                fix_permissions "$_account" "$_conf_dir" "$_log_dir" "$_data_dir" "$_env_file"
                ensure_service_running "$_os"
                say "✅ 无需更新，流程结束。"
                return 0
            fi
            say "⚠️  安装不完整或指定了 --force-init，继续执行完整安装流程..."
        elif [ -n "$_local_version" ] && [ -n "$_remote_version" ]; then
            say "⬆️  准备更新: v${_local_version} ➔ v${_remote_version} ..."
        else
            say "⚠️  无法准确获取版本信息对比，将执行覆盖更新..."
        fi
    fi

    # 先创建服务账号，再创建目录
    create_account "$_os" "$_account"

    ensure mkdir -p "$_bin_dir" "$_conf_dir" "$_log_dir" "$_data_dir"

    # 下载并安装二进制（先写 .new 再原子替换）
    say "⏳ 正在下载 stalwart (${_arch})..."
    local _tmp _tar
    _tmp="$(mktemp -d)"
    _tar="${_tmp}/stalwart.tar.gz"
    ensure downloader "${BASE_URL}/stalwart-${_arch}.tar.gz" "$_tar" "$_arch"
    ensure tar zxf "$_tar" -C "$_tmp"
    ensure cp "${_tmp}/stalwart" "${_bin_file}.new"
    ensure chmod 0755 "${_bin_file}.new"

    # 二进制就绪后停止服务
    if [ "$_is_update" -eq 1 ]; then
        stop_service "$_os"
    fi

    ensure mv -f "${_bin_file}.new" "$_bin_file"
    ensure rm -rf "$_tmp"

    # 仅在文件不存在或指定 --force-init 时写入环境文件
    if [ ! -e "$_env_file" ] || [ "$_force_init" -eq 1 ]; then
        say "📝 正在写入环境文件 ${_env_file}..."
        write_env_file "$_env_file"
    fi

    # 每次安装/升级都检查并修复属主与权限
    say "🔐 检查并修复目录权限..."
    fix_permissions "$_account" "$_conf_dir" "$_log_dir" "$_data_dir" "$_env_file"

    # 安装并启动服务
    say "🚀 启动服务..."
    local _service_type=""
    case "$_os" in
        linux)
            if check_cmd systemctl; then
                create_service_linux_systemd "$_bin_file" "$_config_file" "$_env_file" "$_account"
                _service_type="systemd"
            else
                create_service_linux_initd "$_bin_file" "$_config_file" "$_env_file" "$_account" "$_log_dir"
                _service_type="initd"
            fi
            ;;
        macos)
            create_service_macos "$_bin_file" "$_config_file" "$_env_file" "$_account"
            _service_type="launchd"
            ;;
        freebsd)
            create_service_freebsd "$_bin_file" "$_config_file" "$_env_file" "$_account" "$_log_dir"
            _service_type="rcd"
            ;;
    esac

    # 完成提示
    # 已有 config.json：服务以正常模式启动
    if [ "$_has_config" -eq 1 ]; then
        say "✅ 更新完成！Stalwart 服务已使用旧配置重启。"
        say "🌐 请访问管理后台: $(admin_url "$_env_file" https)"
        return 0
    fi

    say "🎉 安装完成!"
    say ""
    say "Stalwart 正在以 bootstrap 模式运行，启动时会生成临时管理员密码并写入服务日志。"
    say ""
    say "👉 查看密码："
    case "$_service_type" in
        systemd)
            say "     journalctl -u stalwart -n 200 | grep -A8 'bootstrap mode'"
            ;;
        initd)
            say "     grep -A8 'bootstrap mode' ${_log_dir}/stalwart.log"
            ;;
        launchd)
            say "     sudo log show --predicate 'process == \"stalwart\"' --last 5m"
            ;;
        rcd)
            say "     grep -A8 'bootstrap mode' ${_log_dir}/stalwart.log"
            ;;
    esac
    say ""
    say "   或者在 ${_env_file} 中设置 STALWART_RECOVERY_ADMIN=admin:<password> 后重启服务。"
    say ""
    say "   请访问以下地址继续设置: $(admin_url "$_env_file" http)"
}

do_uninstall() {
    # 解析参数（uninstall 只接受一个可选的 PREFIX）
    local _prefix="" _assume_yes=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            --yes|-y)
                _assume_yes=1
                ;;
            --force-init|--fdb)
                # 卸载时无意义，忽略以兼容旧用法
                ;;
            --*|-*)
                err "❌ 未知选项: $1 (使用 --help 查看帮助)"
                ;;
            *)
                if [ -n "$_prefix" ]; then
                    err "❌ 只允许一个安装路径参数，收到: $_prefix $1"
                fi
                _prefix="$1"
                ;;
        esac
        shift
    done

    # 卸载需要 root 权限
    if [ "$(id -u)" -ne 0 ]; then
        err "❌ 卸载失败：需要 root 权限（自动提权未生效，请手动以 root 执行）。"
    fi

    local _os="" _uname="" _fhs=0 _account="stalwart"
    _uname="$(uname)"
    case "$_uname" in
        Linux)   _os="linux" ;;
        Darwin)  _os="macos"; _account="_stalwart" ;;
        FreeBSD) _os="freebsd" ;;
        *)       _os="linux" ;;
    esac

    # 自动识别安装布局
    if [ -z "$_prefix" ]; then
        local _has_opt=0 _has_fhs=0
        if is_opt_install; then
            _has_opt=1
        fi
        if [ -d "/etc/stalwart" ] || [ -d "/usr/local/etc/stalwart" ] || [ -f "/usr/local/bin/stalwart" ]; then
            _has_fhs=1
        fi
        if [ "$_has_opt" -eq 1 ] && [ "$_has_fhs" -eq 1 ]; then
            err "❌ 同时检测到 /opt/stalwart 与 FHS 两套安装，请显式指定要卸载的路径，例如: $0 uninstall /opt/stalwart"
        fi
        if [ "$_has_opt" -eq 1 ]; then
            _prefix="/opt/stalwart"
        elif [ "$_has_fhs" -eq 1 ]; then
            _fhs=1
        else
            say "ℹ️  未检测到 Stalwart 安装（/opt/stalwart 与 FHS 路径下均无安装痕迹），无需卸载。"
            return 0
        fi
    fi

    if [ "$_fhs" -eq 0 ] && [ -n "$_prefix" ]; then
        _prefix="$(normalize_prefix "$_prefix")"
        validate_prefix "$_prefix"
    fi

    local _bin_dir _bin_file _conf_dir _log_dir _data_dir
    if [ "$_fhs" -eq 1 ]; then
        _bin_dir="/usr/local/bin"
        if [ "$_os" = "freebsd" ]; then
            _conf_dir="/usr/local/etc/stalwart"
            _data_dir="/var/db/stalwart"
        else
            _conf_dir="/etc/stalwart"
            _data_dir="/var/lib/stalwart"
        fi
        _log_dir="/var/log/stalwart"
    else
        _bin_dir="${_prefix}/bin"
        _conf_dir="${_prefix}/etc"
        _log_dir="${_prefix}/logs"
        _data_dir="${_prefix}/data"
    fi
    _bin_file="${_bin_dir}/stalwart"

    # 确认：卸载会删除配置与数据目录（不可恢复）
    if [ "$_assume_yes" -eq 0 ]; then
        if [ -t 0 ]; then
            printf '即将删除 %s 下的程序、配置与数据（不可恢复），确认继续？[y/N] ' "${_prefix:-FHS 标准布局}"
            local _ans=""
            read -r _ans || _ans=""
            case "$_ans" in
                y|Y|yes|YES) ;;
                *)
                    say "已取消。"
                    return 0
                    ;;
            esac
        else
            say "⚠️  非交互环境且未指定 --yes，仍继续执行卸载。"
        fi
    fi

    say "🗑️  正在停止并移除服务..."

    if [ -f /etc/systemd/system/stalwart.service ] && check_cmd systemctl; then
        systemctl stop stalwart.service 2>/dev/null || true
        systemctl disable stalwart.service 2>/dev/null || true
        rm -f /etc/systemd/system/stalwart.service
        systemctl daemon-reload 2>/dev/null || true
    fi

    if [ -f /etc/init.d/stalwart ]; then
        service stalwart stop 2>/dev/null || true
        if check_cmd update-rc.d; then
            update-rc.d stalwart remove 2>/dev/null || true
        fi
        if check_cmd chkconfig; then
            chkconfig --del stalwart 2>/dev/null || true
        fi
        rm -f /etc/init.d/stalwart
    fi
    rm -f /etc/logrotate.d/stalwart

    if [ -f /Library/LaunchDaemons/stalwart.plist ]; then
        launchctl bootout system/ /Library/LaunchDaemons/stalwart.plist 2>/dev/null || true
        rm -f /Library/LaunchDaemons/stalwart.plist
    fi

    if [ -f /usr/local/etc/rc.d/stalwart ]; then
        service stalwart stop 2>/dev/null || true
        if check_cmd sysrc; then
            sysrc stalwart_enable=NO 2>/dev/null || true
        fi
        rm -f /usr/local/etc/rc.d/stalwart
    fi
    rm -f /usr/local/etc/newsyslog.conf.d/stalwart.conf

    say "🗑️  正在删除程序与数据..."
    rm -f "$_bin_file"
    rm -f /var/run/stalwart.pid /var/run/stalwart_daemon.pid
    rm -rf "$_conf_dir" "$_log_dir" "$_data_dir"
    if [ "$_fhs" -eq 0 ]; then
        rm -rf "$_prefix"
    fi

    say "✅ 卸载完成（服务账号 ${_account} 未删除，如不再需要可手动删除）"
}

write_env_file() {
    cat > "$1" <<'EOF'
# Environment variables for the Stalwart service.
# Uncomment and edit an entry to override its default.

# Override the hostname used in HTTP responses
#STALWART_HOSTNAME=mail.example.com

# Override the public base URL published in OAuth, OIDC, and JMAP discovery
# documents. Accepts scheme, host and optional port; serving Stalwart under a
# path prefix is not supported.
#STALWART_PUBLIC_URL=https://mail.example.com

# Enable bootstrap / recovery mode on startup. Accepted: 1, true. Default: false.
#STALWART_RECOVERY_MODE=true

# Log level while in recovery mode. Default: info.
#STALWART_RECOVERY_MODE_LOG_LEVEL=debug

# HTTP port used in recovery mode. Default: 8080.
#STALWART_RECOVERY_MODE_PORT=9090

# Fixed administrator credentials — format: username:password
# Default: a temporary random password is generated and printed to the logs.
#STALWART_RECOVERY_ADMIN=admin:changeme

# Cluster role assigned to this node. Must match a role name defined in the
# cluster registry. Leave unset for a standalone (non-clustered) deployment.
#STALWART_ROLE=primary

# Push-notification shard this node is responsible for, when running in a
# cluster.
#STALWART_PUSH_SHARD=1
EOF
}

create_account() {
    local _os="$1"
    local _account="$2"
    if id -u "$_account" > /dev/null 2>&1; then
        return 0
    fi
    say "🖥️  正在创建 '${_account}' 服务账号..."
    if [ "$_os" = "macos" ]; then
        local _last_uid _last_gid _uid _gid
        _last_uid="$(dscacheutil -q user | grep uid | awk '{print $2}' | sort -n | tail -n 1)"
        _last_gid="$(dscacheutil -q group | grep gid | awk '{print $2}' | sort -n | tail -n 1)"
        _uid="$((_last_uid+1))"
        _gid="$((_last_gid+1))"

        ensure dscl /Local/Default -create Groups/_stalwart
        ensure dscl /Local/Default -create Groups/_stalwart Password \*
        ensure dscl /Local/Default -create Groups/_stalwart PrimaryGroupID $_gid
        ensure dscl /Local/Default -create Groups/_stalwart RealName "Stalwart service"
        ensure dscl /Local/Default -create Groups/_stalwart RecordName _stalwart stalwart

        ensure dscl /Local/Default -create Users/_stalwart
        ensure dscl /Local/Default -create Users/_stalwart NFSHomeDirectory /var/empty
        ensure dscl /Local/Default -create Users/_stalwart Password \*
        ensure dscl /Local/Default -create Users/_stalwart PrimaryGroupID $_gid
        ensure dscl /Local/Default -create Users/_stalwart RealName "Stalwart service"
        ensure dscl /Local/Default -create Users/_stalwart RecordName _stalwart stalwart
        ensure dscl /Local/Default -create Users/_stalwart UniqueID $_uid
        ensure dscl /Local/Default -create Users/_stalwart UserShell /usr/bin/false

        ensure dscl /Local/Default -delete /Users/_stalwart AuthenticationAuthority
        ensure dscl /Local/Default -delete /Users/_stalwart PasswordPolicyOptions
    elif [ "$_os" = "freebsd" ]; then
        ensure pw useradd -n "$_account" -c "Stalwart service" -d /nonexistent -s /usr/sbin/nologin -w no
    else
        ensure useradd "$_account" -s /usr/sbin/nologin -M -r -U
    fi
}

create_service_linux_systemd() {
    local _bin="$1" _config="$2" _env="$3" _user="$4"
    cat > /etc/systemd/system/stalwart.service <<EOF
[Unit]
Description=Stalwart
Conflicts=postfix.service sendmail.service exim4.service
After=network-online.target

[Service]
Type=notify
LimitNOFILE=65536
KillMode=process
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
EnvironmentFile=-${_env}
ExecStart=${_bin} --config=${_config}
SyslogIdentifier=stalwart
User=${_user}
Group=${_user}
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable stalwart.service
    systemctl restart stalwart.service
}

create_service_linux_initd() {
    local _bin="$1" _config="$2" _env="$3" _user="$4" _log_dir="$5"
    local _start_opts _start_env=""
    if check_cmd setcap && setcap cap_net_bind_service=+ep "$_bin"; then
        _start_opts="--chuid ${_user}:${_user}"
    else
        _start_opts=""
        _start_env="export RUN_AS_USER=${_user} RUN_AS_GROUP=${_user}"
    fi
    local _output_opts _daemon_args
    if start-stop-daemon --help 2>&1 | grep -q -- '--output'; then
        _output_opts='--output $LOGFILE'
        _daemon_args='$DAEMON_ARGS'
    else
        _output_opts='--startas /bin/sh'
        _daemon_args='-c "exec $DAEMON $DAEMON_ARGS >> $LOGFILE 2>&1"'
    fi
    cat > /etc/init.d/stalwart <<EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          stalwart
# Required-Start:    \$network
# Required-Stop:     \$network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Stalwart Server
# Description:       Starts and stops the Stalwart Server
# Conflicts:         postfix sendmail exim4
### END INIT INFO

PATH=/sbin:/usr/sbin:/bin:/usr/bin

. /lib/init/vars.sh
. /lib/lsb/init-functions

DAEMON=${_bin}
DAEMON_ARGS="--config=${_config}"
ENV_FILE=${_env}
PIDFILE=/var/run/stalwart.pid
ULIMIT_NOFILE=65536
LOGFILE=${_log_dir}/stalwart.log

[ -x "\$DAEMON" ] || exit 0

if [ -r "\$ENV_FILE" ]; then
    set -a
    . "\$ENV_FILE"
    set +a
fi

ulimit -n \$ULIMIT_NOFILE
${_start_env}

do_start()
{
    start-stop-daemon --start --quiet --pidfile \$PIDFILE --exec \$DAEMON --test > /dev/null \\
        || return 1
    start-stop-daemon --start --quiet --pidfile \$PIDFILE --exec \$DAEMON \\
        --background --make-pidfile ${_output_opts} ${_start_opts} \\
        -- ${_daemon_args} \\
        || return 2
}

do_stop()
{
    start-stop-daemon --stop --quiet --retry=INT/30/KILL/5 --pidfile \$PIDFILE --name stalwart
    RETVAL="\$?"
    [ "\$RETVAL" = 2 ] && return 2
    start-stop-daemon --stop --quiet --oknodo --retry=0/30/KILL/5 --exec \$DAEMON
    [ "\$?" = 2 ] && return 2
    rm -f \$PIDFILE
    return "\$RETVAL"
}

case "\$1" in
  start)
    [ "\$VERBOSE" != no ] && log_daemon_msg "Starting Stalwart Server" "stalwart"
    do_start
    case "\$?" in
        0|1) [ "\$VERBOSE" != no ] && log_end_msg 0 ;;
        2)   [ "\$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    ;;
  stop)
    [ "\$VERBOSE" != no ] && log_daemon_msg "Stopping Stalwart Server" "stalwart"
    do_stop
    case "\$?" in
        0|1) [ "\$VERBOSE" != no ] && log_end_msg 0 ;;
        2)   [ "\$VERBOSE" != no ] && log_end_msg 1 ;;
    esac
    ;;
  status)
    status_of_proc "\$DAEMON" "stalwart" && exit 0 || exit \$?
    ;;
  restart)
    log_daemon_msg "Restarting Stalwart Server" "stalwart"
    do_stop
    case "\$?" in
      0|1)
        do_start
        case "\$?" in
            0) log_end_msg 0 ;;
            *) log_end_msg 1 ;;
        esac
        ;;
      *)
        log_end_msg 1
        ;;
    esac
    ;;
  *)
    echo "Usage: /etc/init.d/stalwart {start|stop|status|restart}" >&2
    exit 3
    ;;
esac

exit 0
EOF
    chmod +x /etc/init.d/stalwart
    if [ -d /etc/logrotate.d ]; then
        cat > /etc/logrotate.d/stalwart <<EOF
${_log_dir}/stalwart.log {
    su ${_user} ${_user}
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    fi
    update-rc.d stalwart defaults
    service stalwart restart
}

create_service_macos() {
    local _bin="$1" _config="$2" _env="$3" _user="$4"
    local _plist="/Library/LaunchDaemons/stalwart.plist"

    # 移除旧安装遗留的 LaunchDaemon
    if [ -f "$_plist" ]; then
        launchctl bootout system/ "$_plist" 2>/dev/null || true
        rm -f "$_plist"
    fi

    # launchd 没有 EnvironmentFile，用 sh 包装以便加载 env 文件
    cat > "$_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>Label</key>
        <string>stalwart</string>
        <key>ServiceDescription</key>
        <string>Stalwart</string>
        <key>UserName</key>
        <string>${_user}</string>
        <key>GroupName</key>
        <string>${_user}</string>
        <key>ProgramArguments</key>
        <array>
            <string>/bin/sh</string>
            <string>-c</string>
            <string>set -a; if [ -r "${_env}" ]; then . "${_env}"; fi; set +a; exec "${_bin}" --config="${_config}"</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
    </dict>
</plist>
EOF
    chmod 0644 "$_plist"
    chown root:wheel "$_plist"
    launchctl bootout system/ "$_plist" 2>/dev/null || true
    launchctl bootstrap system/ "$_plist"
}

create_service_freebsd() {
    local _bin="$1" _config="$2" _env="$3" _user="$4" _log_dir="$5"
    ensure mkdir -p /usr/local/etc/rc.d
    cat > /usr/local/etc/rc.d/stalwart <<EOF
#!/bin/sh

# PROVIDE: stalwart
# REQUIRE: NETWORKING LOGIN
# KEYWORD: shutdown

. /etc/rc.subr

name="stalwart"
rcvar="stalwart_enable"
desc="Stalwart Server"

load_rc_config \$name

: \${stalwart_enable:="NO"}
: \${stalwart_runas_user:="${_user}"}
: \${stalwart_runas_group:="${_user}"}
: \${stalwart_config:="${_config}"}
: \${stalwart_envfile:="${_env}"}
: \${stalwart_logfile:="${_log_dir}/stalwart.log"}
: \${stalwart_fdlimit:="65536"}

pidfile="/var/run/stalwart.pid"
supervisor_pidfile="/var/run/stalwart_daemon.pid"
procname="${_bin}"
command="/usr/sbin/daemon"
command_args="-f -H -o \${stalwart_logfile} -p \${pidfile} -P \${supervisor_pidfile} ${_bin} --config=\${stalwart_config}"
sig_stop="INT"
start_precmd="stalwart_precmd"

stalwart_precmd()
{
    # daemon(8) passes its environment through to the service
    if [ -r "\${stalwart_envfile}" ]; then
        set -a
        . "\${stalwart_envfile}"
        set +a
    fi

    # Stalwart binds its listeners as root, then setuid()s to this account
    export RUN_AS_USER="\${stalwart_runas_user}"
    export RUN_AS_GROUP="\${stalwart_runas_group}"

    ulimit -n "\${stalwart_fdlimit}"
}

run_rc_command "\$1"
EOF
    chmod +x /usr/local/etc/rc.d/stalwart
    ensure mkdir -p /usr/local/etc/newsyslog.conf.d
    cat > /usr/local/etc/newsyslog.conf.d/stalwart.conf <<EOF
${_log_dir}/stalwart.log ${_user}:${_user} 640 4 * \$W0D0 JC /var/run/stalwart_daemon.pid 1
EOF
    sysrc stalwart_enable=YES
    service stalwart stop > /dev/null 2>&1 || true
    service stalwart start
}

get_architecture() {
    local _ostype _cputype _bitness _arch _clibtype
    _ostype="$(uname -s)"
    _cputype="$(uname -m)"
    _clibtype="gnu"

    if [ "$_ostype" = Linux ]; then
        if [ "$(uname -o)" = Android ]; then
            _ostype=Android
        fi
        if ldd --version 2>&1 | grep -q 'musl'; then
            _clibtype="musl"
        fi
    fi

    if [ "$_ostype" = Darwin ] && [ "$_cputype" = i386 ]; then
        # Darwin `uname -m` lies
        if sysctl hw.optional.x86_64 | grep -q ': 1'; then
            _cputype=x86_64
        fi
    fi

    if [ "$_ostype" = SunOS ]; then
        # Both Solaris and illumos presently announce as "SunOS" in "uname -s"
        # so use "uname -o" to disambiguate.  We use the full path to the
        # system uname in case the user has coreutils uname first in PATH,
        # which has historically sometimes printed the wrong value here.
        if [ "$(/usr/bin/uname -o)" = illumos ]; then
            _ostype=illumos
        fi

        # illumos systems have multi-arch userlands, and "uname -m" reports the
        # machine hardware name; e.g., "i86pc" on both 32- and 64-bit x86
        # systems.  Check for the native (widest) instruction set on the
        # running kernel:
        if [ "$_cputype" = i86pc ]; then
            _cputype="$(isainfo -n)"
        fi
    fi

    case "$_ostype" in

        Android)
            _ostype=linux-android
            ;;

        Linux)
            check_proc
            _ostype=unknown-linux-$_clibtype
            _bitness=$(get_bitness)
            ;;

        FreeBSD)
            _ostype=unknown-freebsd
            ;;

        NetBSD)
            _ostype=unknown-netbsd
            ;;

        DragonFly)
            _ostype=unknown-dragonfly
            ;;

        Darwin)
            _ostype=apple-darwin
            ;;

        illumos)
            _ostype=unknown-illumos
            ;;

        MINGW* | MSYS* | CYGWIN* | Windows_NT)
            _ostype=pc-windows-gnu
            ;;

        *)
            err "unrecognized OS type: $_ostype"
            ;;

    esac

    case "$_cputype" in

        i386 | i486 | i686 | i786 | x86)
            _cputype=i686
            ;;

        xscale | arm)
            _cputype=arm
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            fi
            ;;

        armv6l)
            _cputype=arm
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            else
                _ostype="${_ostype}eabihf"
            fi
            ;;

        armv7l | armv8l)
            _cputype=armv7
            if [ "$_ostype" = "linux-android" ]; then
                _ostype=linux-androideabi
            else
                _ostype="${_ostype}eabihf"
            fi
            ;;

        aarch64 | arm64)
            _cputype=aarch64
            ;;

        x86_64 | x86-64 | x64 | amd64)
            _cputype=x86_64
            ;;

        mips)
            _cputype=$(get_endianness mips '' el)
            ;;

        mips64)
            if [ "$_bitness" -eq 64 ]; then
                # only n64 ABI is supported for now
                _ostype="${_ostype}abi64"
                _cputype=$(get_endianness mips64 '' el)
            fi
            ;;

        ppc)
            _cputype=powerpc
            ;;

        ppc64)
            _cputype=powerpc64
            ;;

        ppc64le)
            _cputype=powerpc64le
            ;;

        s390x)
            _cputype=s390x
            ;;
        riscv64)
            _cputype=riscv64gc
            ;;
        *)
            err "unknown CPU type: $_cputype"

    esac

    # Detect 64-bit linux with 32-bit userland
    if [ "${_ostype}" = unknown-linux-gnu ] && [ "${_bitness}" -eq 32 ]; then
        case $_cputype in
            x86_64)
                if [ -n "${RUSTUP_CPUTYPE:-}" ]; then
                    _cputype="$RUSTUP_CPUTYPE"
                else {
                    # 32-bit executable for amd64 = x32
                    if is_host_amd64_elf; then {
                         echo "This host is running an x32 userland; as it stands, x32 support is poor," 1>&2
                         echo "and there isn't a native toolchain -- you will have to install" 1>&2
                         echo "multiarch compatibility with i686 and/or amd64, then select one" 1>&2
                         echo "by re-running this script with the RUSTUP_CPUTYPE environment variable" 1>&2
                         echo "set to i686 or x86_64, respectively." 1>&2
                         echo 1>&2
                         echo "You will be able to add an x32 target after installation by running" 1>&2
                         echo "  rustup target add x86_64-unknown-linux-gnux32" 1>&2
                         exit 1
                    }; else
                        _cputype=i686
                    fi
                }; fi
                ;;
            mips64)
                _cputype=$(get_endianness mips '' el)
                ;;
            powerpc64)
                _cputype=powerpc
                ;;
            aarch64)
                _cputype=armv7
                if [ "$_ostype" = "linux-android" ]; then
                    _ostype=linux-androideabi
                else
                    _ostype="${_ostype}eabihf"
                fi
                ;;
            riscv64gc)
                err "riscv64 with 32-bit userland unsupported"
                ;;
        esac
    fi

    # Detect armv7 but without the CPU features Rust needs in that build,
    # and fall back to arm.
    # See https://github.com/rust-lang/rustup.rs/issues/587.
    if [ "$_ostype" = "unknown-linux-gnueabihf" ] && [ "$_cputype" = armv7 ]; then
        if ensure grep '^Features' /proc/cpuinfo | grep -q -v neon; then
            # At least one processor does not have NEON.
            _cputype=arm
        fi
    fi

    _arch="${_cputype}-${_ostype}"

    RETVAL="$_arch"
}

check_proc() {
    # Check for /proc by looking for the /proc/self/exe link
    # This is only run on Linux
    if ! test -L /proc/self/exe ; then
        err "fatal: Unable to find /proc/self/exe.  Is /proc mounted?  Installation cannot proceed without /proc."
    fi
}

get_bitness() {
    need_cmd head
    # Architecture detection without dependencies beyond coreutils.
    # ELF files start out "\x7fELF", and the following byte is
    #   0x01 for 32-bit and
    #   0x02 for 64-bit.
    # The printf builtin on some shells like dash only supports octal
    # escape sequences, so we use those.
    local _current_exe_head
    _current_exe_head=$(head -c 5 /proc/self/exe )
    if [ "$_current_exe_head" = "$(printf '\177ELF\001')" ]; then
        echo 32
    elif [ "$_current_exe_head" = "$(printf '\177ELF\002')" ]; then
        echo 64
    else
        err "unknown platform bitness"
    fi
}

is_host_amd64_elf() {
    need_cmd head
    need_cmd tail
    # ELF e_machine detection without dependencies beyond coreutils.
    # Two-byte field at offset 0x12 indicates the CPU,
    # but we're interested in it being 0x3E to indicate amd64, or not that.
    local _current_exe_machine
    _current_exe_machine=$(head -c 19 /proc/self/exe | tail -c 1)
    [ "$_current_exe_machine" = "$(printf '\076')" ]
}

get_endianness() {
    local cputype=$1
    local suffix_eb=$2
    local suffix_el=$3

    # detect endianness without od/hexdump, like get_bitness() does.
    need_cmd head
    need_cmd tail

    local _current_exe_endianness
    _current_exe_endianness="$(head -c 6 /proc/self/exe | tail -c 1)"
    if [ "$_current_exe_endianness" = "$(printf '\001')" ]; then
        echo "${cputype}${suffix_el}"
    elif [ "$_current_exe_endianness" = "$(printf '\002')" ]; then
        echo "${cputype}${suffix_eb}"
    else
        err "unknown platform endianness"
    fi
}

say() {
    printf '%s\n' "$1"
}

err() {
    say "$1" >&2
    exit 1
}

need_cmd() {
    if ! check_cmd "$1"; then
        err "need '$1' (command not found)"
    fi
}

check_cmd() {
    command -v "$1" > /dev/null 2>&1
}

assert_nz() {
    if [ -z "$1" ]; then err "assert_nz $2"; fi
}

# 判断 /opt/stalwart 下是否存在真实的安装
is_opt_install() {
    [ -f "/opt/stalwart/bin/stalwart" ] || [ -f "/opt/stalwart/etc/config.json" ]
}

# 规范化安装路径：合并重复斜杠、去掉结尾斜杠
normalize_prefix() {
    printf '%s' "$1" | sed -e 's#//*#/#g' -e 's#/*$##'
}

# 修复目录属主与权限
fix_permissions() {
    local _account="$1" _conf_dir="$2" _log_dir="$3" _data_dir="$4" _env_file="$5"
    ensure chown "${_account}:${_account}" "$_conf_dir" "$_log_dir" "$_data_dir"
    ensure chmod 0750 "$_conf_dir" "$_log_dir" "$_data_dir"
    ensure chown "root:${_account}" "$_env_file"
    ensure chmod 0640 "$_env_file"
}

# 停止服务
stop_service() {
    local _os="$1"
    case "$_os" in
        linux)
            if check_cmd systemctl && [ -f /etc/systemd/system/stalwart.service ]; then
                systemctl stop stalwart.service 2>/dev/null || true
            elif [ -x /etc/init.d/stalwart ]; then
                service stalwart stop 2>/dev/null || true
            fi
            ;;
        macos)
            launchctl bootout system/ /Library/LaunchDaemons/stalwart.plist 2>/dev/null || true
            ;;
        freebsd)
            service stalwart stop 2>/dev/null || true
            ;;
    esac
}

# 判断服务单元是否已注册
service_installed() {
    case "$1" in
        linux)
            [ -f /etc/systemd/system/stalwart.service ] || [ -x /etc/init.d/stalwart ]
            ;;
        macos)
            [ -f /Library/LaunchDaemons/stalwart.plist ]
            ;;
        freebsd)
            [ -f /usr/local/etc/rc.d/stalwart ]
            ;;
        *)
            return 1
            ;;
    esac
}

# 服务未运行时拉起
ensure_service_running() {
    local _os="$1"
    case "$_os" in
        linux)
            if check_cmd systemctl && [ -f /etc/systemd/system/stalwart.service ]; then
                if ! systemctl is-active --quiet stalwart.service 2>/dev/null; then
                    say "🔄 服务当前未运行，正在启动..."
                    systemctl restart stalwart.service 2>/dev/null || true
                fi
            elif [ -x /etc/init.d/stalwart ]; then
                service stalwart status >/dev/null 2>&1 || service stalwart restart >/dev/null 2>&1 || true
            fi
            ;;
        macos)
            launchctl print system/stalwart >/dev/null 2>&1 \
                || launchctl bootstrap system/ /Library/LaunchDaemons/stalwart.plist 2>/dev/null \
                || true
            ;;
        freebsd)
            service stalwart status >/dev/null 2>&1 || service stalwart start >/dev/null 2>&1 || true
            ;;
    esac
}

# 输出管理后台地址。
# 优先级：STALWART_PUBLIC_URL > STALWART_HOSTNAME（https）> 主机名
# 参数：$1 环境文件路径；$2 回退方案
#   https —— https://主机名/admin
#   http  —— http://主机名:端口/admin
admin_url() {
    local _env="$1" _fallback="$2" _url _name _host _port

    if [ -f "$_env" ]; then
        _url="$(sed -n 's/^STALWART_PUBLIC_URL=//p' "$_env" | tail -n 1 | tr -d "\"'")"
        if [ -n "$_url" ]; then
            printf '%s/admin\n' "${_url%/}"
            return 0
        fi
        _name="$(sed -n 's/^STALWART_HOSTNAME=//p' "$_env" | tail -n 1 | tr -d "\"'")"
        if [ -n "$_name" ]; then
            printf 'https://%s/admin\n' "$_name"
            return 0
        fi
    fi

    _host="$(hostname -f 2>/dev/null || hostname)"
    if [ "$_fallback" = "http" ]; then
        _port="$(sed -n 's/^STALWART_RECOVERY_MODE_PORT=\([0-9][0-9]*\).*/\1/p' "$_env" 2>/dev/null | tail -n 1)"
        printf 'http://%s:%s/admin\n' "$_host" "${_port:-8080}"
    else
        printf 'https://%s/admin\n' "$_host"
    fi
}

# 校验安装路径：拒绝系统目录与非绝对路径（入参需先经 normalize_prefix 处理）
validate_prefix() {
    local _p="$1"
    [ -n "$_p" ] || err "❌ 非法的安装路径（为空）"
    case "$_p" in
        /*) ;;
        *) err "❌ 安装路径必须是绝对路径: $_p" ;;
    esac
    # 拒绝包含 '.' 或 '..' 的路径段
    case "/${_p}/" in
        */../*|*/./*) err "❌ 安装路径不能包含 '.' 或 '..' 路径段: $_p" ;;
    esac
    case "$_p" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/usr/bin|/usr/local|/usr/local/bin|/usr/local/etc|/var|/var/db|/var/lib|/var/log)
            err "❌ 拒绝使用系统目录作为安装路径: $_p"
            ;;
    esac
}

# Run a command that should never fail. If the command fails execution
# will immediately terminate with an error showing the failing
# command.
ensure() {
    if ! "$@"; then err "command failed: $*"; fi
}

# This wraps curl or wget. Try curl first, if not installed,
# use wget instead.
downloader() {
    local _dld
    local _ciphersuites
    local _err
    local _status
    local _retry
    if check_cmd curl; then
        _dld=curl
    elif check_cmd wget; then
        _dld=wget
    else
        _dld='curl or wget' # to be used in error message of need_cmd
    fi

    if [ "$1" = --check ]; then
        need_cmd "$_dld"
    elif [ "$_dld" = curl ]; then
        check_curl_for_retry_support
        _retry="$RETVAL"
        get_ciphersuites_for_curl
        _ciphersuites="$RETVAL"
        if [ -n "$_ciphersuites" ]; then
            _err=$(curl $_retry --proto '=https' --tlsv1.2 --ciphers "$_ciphersuites" --silent --show-error --fail --location "$1" --output "$2" 2>&1)
            _status=$?
        else
            echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
            if ! check_help_for "$3" curl --proto --tlsv1.2; then
                echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                _err=$(curl $_retry --silent --show-error --fail --location "$1" --output "$2" 2>&1)
                _status=$?
            else
                _err=$(curl $_retry --proto '=https' --tlsv1.2 --silent --show-error --fail --location "$1" --output "$2" 2>&1)
                _status=$?
            fi
        fi
        if [ -n "$_err" ]; then
            if echo "$_err" | grep -q 404; then
                err "❌  未找到平台 '$3' 的二进制包，该平台可能不受支持。"
            else
                echo "$_err" >&2
            fi
        fi
        return $_status
    elif [ "$_dld" = wget ]; then
        if [ "$(wget -V 2>&1|head -2|tail -1|cut -f1 -d" ")" = "BusyBox" ]; then
            echo "Warning: using the BusyBox version of wget.  Not enforcing strong cipher suites for TLS or TLS v1.2, this is potentially less secure"
            _err=$(wget "$1" -O "$2" 2>&1)
            _status=$?
        else
            get_ciphersuites_for_wget
            _ciphersuites="$RETVAL"
            if [ -n "$_ciphersuites" ]; then
                _err=$(wget --https-only --secure-protocol=TLSv1_2 --ciphers "$_ciphersuites" "$1" -O "$2" 2>&1)
                _status=$?
            else
                echo "Warning: Not enforcing strong cipher suites for TLS, this is potentially less secure"
                if ! check_help_for "$3" wget --https-only --secure-protocol; then
                    echo "Warning: Not enforcing TLS v1.2, this is potentially less secure"
                    _err=$(wget "$1" -O "$2" 2>&1)
                    _status=$?
                else
                    _err=$(wget --https-only --secure-protocol=TLSv1_2 "$1" -O "$2" 2>&1)
                    _status=$?
                fi
            fi
        fi
        if [ -n "$_err" ]; then
            if echo "$_err" | grep -q ' 404 Not Found'; then
                err "❌  未找到平台 '$3' 的二进制包，该平台可能不受支持。"
            else
                echo "$_err" >&2
            fi
        fi
        return $_status
    else
        err "Unknown downloader"   # should not reach here
    fi
}

# Check if curl supports the --retry flag, then pass it to the curl invocation.
check_curl_for_retry_support() {
  local _retry_supported=""
  # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
  if check_help_for "notspecified" "curl" "--retry"; then
    _retry_supported="--retry 3"
  fi

  RETVAL="$_retry_supported"

}

check_help_for() {
    local _arch
    local _cmd
    local _arg
    _arch="$1"
    shift
    _cmd="$1"
    shift

    local _category
    if "$_cmd" --help | grep -q 'For all options use the manual or "--help all".'; then
      _category="all"
    else
      _category=""
    fi

    case "$_arch" in

        *darwin*)
        if check_cmd sw_vers; then
            case $(sw_vers -productVersion) in
                10.*)
                    # If we're running on macOS, older than 10.13, then we always
                    # fail to find these options to force fallback
                    if [ "$(sw_vers -productVersion | cut -d. -f2)" -lt 13 ]; then
                        # Older than 10.13
                        echo "Warning: Detected macOS platform older than 10.13"
                        return 1
                    fi
                    ;;
                11.*)
                    # We assume Big Sur will be OK for now
                    ;;
                *)
                    # Unknown product version, warn and continue
                    echo "Warning: Detected unknown macOS major version: $(sw_vers -productVersion)"
                    echo "Warning TLS capabilities detection may fail"
                    ;;
            esac
        fi
        ;;

    esac

    for _arg in "$@"; do
        if ! "$_cmd" --help $_category | grep -q -- "$_arg"; then
            return 1
        fi
    done

    true # not strictly needed
}

# Return cipher suite string specified by user, otherwise return strong TLS 1.2-1.3 cipher suites
# if support by local tools is detected. Detection currently supports these curl backends:
# GnuTLS and OpenSSL (possibly also LibreSSL and BoringSSL). Return value can be empty.
get_ciphersuites_for_curl() {
    if [ -n "${RUSTUP_TLS_CIPHERSUITES-}" ]; then
        # user specified custom cipher suites, assume they know what they're doing
        RETVAL="$RUSTUP_TLS_CIPHERSUITES"
        return
    fi

    local _openssl_syntax="no"
    local _gnutls_syntax="no"
    local _backend_supported="yes"
    if curl -V | grep -q ' OpenSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' LibreSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' BoringSSL/'; then
        _openssl_syntax="yes"
    elif curl -V | grep -iq ' GnuTLS/'; then
        _gnutls_syntax="yes"
    else
        _backend_supported="no"
    fi

    local _args_supported="no"
    if [ "$_backend_supported" = "yes" ]; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "curl" "--tlsv1.2" "--ciphers" "--proto"; then
            _args_supported="yes"
        fi
    fi

    local _cs=""
    if [ "$_args_supported" = "yes" ]; then
        if [ "$_openssl_syntax" = "yes" ]; then
            _cs=$(get_strong_ciphersuites_for "openssl")
        elif [ "$_gnutls_syntax" = "yes" ]; then
            _cs=$(get_strong_ciphersuites_for "gnutls")
        fi
    fi

    RETVAL="$_cs"
}

# Return cipher suite string specified by user, otherwise return strong TLS 1.2-1.3 cipher suites
# if support by local tools is detected. Detection currently supports these wget backends:
# GnuTLS and OpenSSL (possibly also LibreSSL and BoringSSL). Return value can be empty.
get_ciphersuites_for_wget() {
    if [ -n "${RUSTUP_TLS_CIPHERSUITES-}" ]; then
        # user specified custom cipher suites, assume they know what they're doing
        RETVAL="$RUSTUP_TLS_CIPHERSUITES"
        return
    fi

    local _cs=""
    if wget -V | grep -q '\-DHAVE_LIBSSL'; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "wget" "TLSv1_2" "--ciphers" "--https-only" "--secure-protocol"; then
            _cs=$(get_strong_ciphersuites_for "openssl")
        fi
    elif wget -V | grep -q '\-DHAVE_LIBGNUTLS'; then
        # "unspecified" is for arch, allows for possibility old OS using macports, homebrew, etc.
        if check_help_for "notspecified" "wget" "TLSv1_2" "--ciphers" "--https-only" "--secure-protocol"; then
            _cs=$(get_strong_ciphersuites_for "gnutls")
        fi
    fi

    RETVAL="$_cs"
}

# Return strong TLS 1.2-1.3 cipher suites in OpenSSL or GnuTLS syntax. TLS 1.2
# excludes non-ECDHE and non-AEAD cipher suites. DHE is excluded due to bad
# DH params often found on servers (see RFC 7919). Sequence matches or is
# similar to Firefox 68 ESR with weak cipher suites disabled via about:config.
# $1 must be openssl or gnutls.
get_strong_ciphersuites_for() {
    if [ "$1" = "openssl" ]; then
        # OpenSSL is forgiving of unknown values, no problems with TLS 1.3 values on versions that don't support it yet.
        echo "TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384"
    elif [ "$1" = "gnutls" ]; then
        # GnuTLS isn't forgiving of unknown values, so this may require a GnuTLS version that supports TLS 1.3 even if wget doesn't.
        # Begin with SECURE128 (and higher) then remove/add to build cipher suites. Produces same 9 cipher suites as OpenSSL but in slightly different order.
        echo "SECURE128:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1:-VERS-DTLS-ALL:-CIPHER-ALL:-MAC-ALL:-KX-ALL:+AEAD:+ECDHE-ECDSA:+ECDHE-RSA:+AES-128-GCM:+CHACHA20-POLY1305:+AES-256-GCM"
    fi
}

# This is just for indicating that commands' results are being
# intentionally ignored. Usually, because it's being executed
# as part of error handling.
ignore() {
    "$@"
}

main "$@" || exit 1
