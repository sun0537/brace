#!/bin/bash

# ==============================================================================
#  Vaultwarden (SQLite) 安全热备份与同步脚本 (优化版)
#
#  功能:
#  1. 使用 inotifywait 监控 Vaultwarden 数据目录，但通过 --exclude 参数
#     精确排除掉非核心的缓存和临时文件 (如 icon_cache, tmp, *.sqlite3-wal)。
#  2. 引入防抖机制：检测到文件变化后，会等待一个“静默期”，只有当此期间内
#     没有新变化时，才执行备份，避免在频繁写入时重复备份。
#  3. 备份流程分为两步，确保数据一致性：
#     a. 使用 SQLite 在线备份 API 创建一个安全的数据库快照。
#     b. 使用 rsync 同步包括附件、配置和密钥在内的所有其他关键文件。
#
#  优点:
#  - 完整备份：覆盖所有重要数据，不仅仅是数据库。
#  - 智能高效：通过排除非关键文件，避免了不必要的备份触发。
#  - 无需停止主 Vaultwarden 服务，实现零停机备份。
#  - 数据一致性有保障。
#
#  使用前置条件:
#  - 系统已安装 inotify-tools (e.g., sudo apt-get install inotify-tools)
#  - 系统已安装 sqlite3
#  - (如果需要远程同步) 配置好到备份服务器的 SSH 免密登录。
# ==============================================================================

# --- 用户配置 ---

# Vaultwarden 的完整数据目录
VAULT_DATA_DIR="/home/ubuntu/vaultwarden/backup"

# 临时备份目录 (用于存放安全的数据库快照和所有其他文件)
BACKUP_TEMP_DIR="/home/ubuntu/vaultwarden/vw-data"

# 备份延迟（秒）：检测到文件变化后，需要等待多少秒的“静默期”才开始备份。
BACKUP_DELAY=60

# --- (可选) 远程服务器配置 ---
ENABLE_REMOTE_SYNC=false # 设置为 false 则只在本地创建备份
REMOTE_USER="oracle2"
PARAM="ssh -F /home/ubuntu/.ssh/config"
# 远程路径应该是存放整个 data 目录的父目录
REMOTE_PATH="vaultwarden/backup"

# --- 脚本核心逻辑 ---

# 从主目录派生出数据库路径和临时快照路径
SOURCE_DB="${VAULT_DATA_DIR}/db.sqlite3"
BACKUP_DB_FILE="${BACKUP_TEMP_DIR}/db.sqlite3"

# 确保临时备份目录存在
mkdir -p "$BACKUP_TEMP_DIR"

# 定义要监控的事件
EVENTS="close_write,create,delete,move"

# 定义要排除的文件/目录的正则表达式。
# 这会忽略所有以 -wal 或 -shm 结尾的文件，以及 icon_cache 和 tmp 目录下的所有内容。
EXCLUDE_REGEX='(db\.sqlite3-wal|db\.sqlite3-shm|icon_cache/|tmp/|log/)'

echo "🔔 [$(date '+%Y-%m-%d %H:%M:%S')] 🚀 监控启动: 正在监视 '$VAULT_DATA_DIR' 目录及其子目录..."
echo "   - 备份延迟设置为: ${BACKUP_DELAY} 秒"
echo "   - 将排除匹配 '${EXCLUDE_REGEX}' 的文件事件"
echo "----------------------------------------------------"

# 主循环
while true; do
    # 步骤 1: 等待第一次文件变化事件，同时排除非关键文件。
    inotifywait -r -q -e ${EVENTS} --exclude "${EXCLUDE_REGEX}" "${VAULT_DATA_DIR}"

    # 步骤 2: 防抖机制。
    while true; do
        echo "🔔 [$(date '+%Y-%m-%d %H:%M:%S')] 检测到关键文件变化。等待 ${BACKUP_DELAY} 秒的静默期..."
        
        # 使用 read -t 设置超时。如果在 BACKUP_DELAY 秒内检测到新事件，循环继续。
        # 如果超时，说明静默期已过，可以安全地开始备份了。
        if ! read -t ${BACKUP_DELAY} < <(inotifywait -r -q -e ${EVENTS} --exclude "${EXCLUDE_REGEX}" "${VAULT_DATA_DIR}"); then
            break
        fi
    done

    # 步骤 3: 执行备份
    echo "✅ [$(date '+%Y-%m-%d %H:%M:%S')] 静默期结束。开始执行安全备份..."

    # 3a. 创建数据库安全快照
    echo "   -> 正在创建数据库安全快照..."
    sqlite3 "$SOURCE_DB" ".backup '$BACKUP_DB_FILE'"
    
    if [ $? -ne 0 ]; then
        echo "❌ 严重错误: 创建数据库快照失败！跳过本次备份。"
        continue
    fi
    echo "   -> 数据库快照创建成功。"

    # 3b. 同步所有其他文件（附件、配置、密钥等）
    if [ "$ENABLE_REMOTE_SYNC" = true ]; then
        echo " 🔔 [$(date '+%Y-%m-%d %H:%M:%S')]   -> 正在同步所有文件到远程服务器: $REMOTE_HOST..."
        
        # 同步除数据库和临时文件外的所有内容到远程服务器
        echo " 🔔 [$(date '+%Y-%m-%d %H:%M:%S')]      - 同步附件、配置及其他文件..."
        rsync -avz -e "$PARAM" --delete --exclude 'db.sqlite3*' --exclude 'icon_cache/' --exclude 'tmp/' --exclude 'log/' "${VAULT_DATA_DIR}/" "${REMOTE_USER}:${REMOTE_PATH}"
        # 单独同步安全的数据库快照到远程服务器
        echo " 🔔 [$(date '+%Y-%m-%d %H:%M:%S')]     - 同步数据库快照..."
        rsync -avz -e "$PARAM" "$BACKUP_DB_FILE" "${REMOTE_USER}:${REMOTE_PATH}/db.sqlite3"

        if [ $? -eq 0 ]; then
            echo "✅ [$(date '+%Y-%m-%d %H:%M:%S')] 远程同步成功。"
        else
            echo "❌ [$(date '+%Y-%m-%d %H:%M:%S')] 错误: 远程同步失败！"
        fi
    else
	echo " 正在停止 vaultwarden..."
        if ! systemctl stop vaultwarden; then
            echo "❌ 错误: 停止 Vaultwarden 失败。请使用 'systemctl status vaultwarden' 查看详情。"
            echo "中止本次更新，将继续监控。"
            continue # 跳过本次循环的剩余部分，继续监控
	fi
        echo "✅ [$(date '+%Y-%m-%d %H:%M:%S')]  Vaultwarden 已停止。"
        # 如果禁用远程同步，则将所有其他文件也复制到本地备份目录
	
	rm "${BACKUP_TEMP_DIR}/db.*"
          	
        echo "   -> 正在将其他关键文件复制到本地备份目录..."
        rsync -av  "${VAULT_DATA_DIR}/" "${BACKUP_TEMP_DIR}/"
        echo "✅ [$(date '+%Y-%m-%d %H:%M:%S')]  本地完整备份已在 '$BACKUP_TEMP_DIR' 目录中更新。远程同步已禁用。"

	echo " 正在启动 vaultwarden..."
        if ! systemctl start vaultwarden; then
            echo "❌ 错误: 启动 Vaultwarden 失败。请使用 'systemctl status vaultwarden' 查看详情。"
            echo "中止本次更新，将继续监控。"
            continue # 跳过本次循环的剩余部分，继续监控
	fi
        echo "✅ [$(date '+%Y-%m-%d %H:%M:%S')]  Vaultwarden 已启动。"
    fi

    echo "✅ [$(date '+%Y-%m-%d %H:%M:%S')] 🎉 本次备份流程完成。"
    echo "----------------------------------------------------"
    echo "🔔 [$(date '+%Y-%m-%d %H:%M:%S')] 🚀 继续监控..."
done
