#!/bin/bash

set -e

# 默认值设置
SOURCE_DIR=""
BACKUP_DIR="localbackup"
REMOTE_DIRS=""
EMAIL=""
LOG_TO_FILE=false
LOGFILE="$(dirname "$0")/backup.log"
RCLONE_CONFIG=""
RCLONE_COMMAND="rclone"
TOTAL=""

# 显示帮助信息函数
show_help() {
    echo "Usage: backup.sh [options]"
    echo
    echo "Options:"
    echo "  -s, --source-dir   指定 stalwart 数据目录"
    echo "  -b, --backup-dir   指定本地备份目录 (default: localbackup)"
    echo "  -r, --remote       指定 rclone 远程备份文件夹，用 | 分隔多个 (不指定 rclone 远程服务, 只压缩)"
    echo "  -e, --email        指定接收备份结果的邮箱地址"
    echo "  -l, --log          将日志输出到文件"
    echo "  -c, --config       指定 rclone 的配置文件路径 (default: ~/.config/rclone/rclone.conf)"
    echo "  -h, --help         显示此帮助信息"
}

# 错误处理函数
handle_error() {
    local error_message="$1"
    date_format "Error" "$error_message"
    show_help
    exit 1
}

# 日志记录函数
log_message() {
    local message="$1"
    date_format "Log" "$message"
}

date_format() {
    local message_type="$1"
    local message="$2"
    if [ "$LOG_TO_FILE" = true ]; then
        echo "$(date '+%Y-%m-%d %H:%M %Z'): $message_type: $message" >> "$LOGFILE"
    else
        echo "$(date '+%Y-%m-%d %H:%M %Z'): $message_type: $message"
    fi
}

# 检查和安装必要的命令
check_and_install() {
    local cmd=$1
    local install_cmd=$2
    if ! command -v $cmd &> /dev/null; then
        log_message  "$cmd 未安装，正在安装..."
        eval $install_cmd || handle_error "$cmd 安装失败"
    else
        log_message  "$cmd 已安装" 
    fi
}
params=("$@")
# 解析命令行参数
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--source-dir) SOURCE_DIR="$2"; shift ;;
        -b|--backup-dir) BACKUP_DIR="$2"; shift ;;
        -r|--remote) REMOTE_DIRS="$2"; shift ;;
        -e|--email) EMAIL="$2"; shift ;;
        -l|--log) LOG_TO_FILE=true;LOGFILE="$2"; shift ;;
	-c|--config) RCLONE_CONFIG="$2"; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) handle_error "未知参数: $1"; show_help; exit 1 ;;
    esac
    shift
done

# 检查必要参数是否提供
if [[ -z "$SOURCE_DIR" ]]; then
    handle_error "必填参数 -s/--source-dir 缺失"
    show_help
    exit 1
fi

# 设置 rclone 命令和配置文件路径
if [ -n "$RCLONE_CONFIG" ]; then
    RCLONE_COMMAND="rclone --config $RCLONE_CONFIG"
fi

if [ "$EUID" -ne 0 ]; then
  log_message "脚本运行需要root权限，尝试获取root权限..."
  # 尝试通过sudo获取root权限
  if sudo -v; then
    log_message "成功获取root权限。重新运行脚本..."
    # 恢复 $@ $# 的值
    set -- "${params[@]}"
    sudo "$0" "$@"
    exit
  else
    handle_error "获取root权限失败。请检查您的密码是否正确。"
    exit 1
  fi
fi

# 检查和安装所有必要命令
#check_and_install sqlite3 "sudo apt update && sudo apt install -y sqlite3"
check_and_install rclone "sudo curl https://rclone.org/install.sh | sudo bash"
check_and_install tar "sudo apt update && sudo apt install -y tar"
check_and_install diff "sudo apt update && sudo apt install -y diffutils"

# 检查备份目录是否存在，不存在则创建
if [ ! -d "$BACKUP_DIR" ]; then
    log_message "备份目录 $BACKUP_DIR 不存在，正在创建..." 
    mkdir -p "$BACKUP_DIR" || handle_error "创建备份目录失败"
else
    log_message "备份目录 $BACKUP_DIR 已存在" 
fi

# 检查文件夹和文件是否变更
backup_successful=false

# 删除旧文件只保留最新文件
del_db_file() {
        local files=$1

        # 保留最新的备份文件
        DB_COUNT=$(find "$BACKUP_DIR" -type f -name "$files"| wc -l)
        if [ "$DB_COUNT" -gt 1 ]; then
            FILES_TO_DELETE=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$files" -printf "%T@ %p\n" | sort -nr | cut -d' ' -f2- | tail -n +2)
            for file in $FILES_TO_DELETE; do
	#	file=$(basename "$file")
                log_message " 删除旧文件 $file"
                rm "$file" || handle_error "删除旧的备份文件失败"
            done
        fi
}


# 检查文件夹变更函数
check_and_backup_dir() {
    local dir_names=("$@")
    # 遍历要备份的目录
    for dir_name in "$SOURCE_DIR/${dir_names[@]}"; do
       dir_name=$(basename "$dir_name")
       if [ -d "$SOURCE_DIR/$dir_name" ]; then
	    # 如果备份目录中没有该目录，直接备份
	    if [ ! -d "$BACKUP_DIR/$dir_name" ]; then
		log_message "$dir_name 目录在备份目标中不存在，进行初始备份..."
		cp -r "$SOURCE_DIR/$dir_name" "$BACKUP_DIR/" || handle_error "$dir_name 目录备份失败"
		backup_successful=true
            else
		if [ -z "$(find "$SOURCE_DIR/$dir_name" -type f -newer "$BACKUP_DIR/$dir_name" 2>/dev/null)" ]; then
		    log_message " $dir_name 目录未变更"
		else
		    log_message " $dir_name 目录有变更，进行备份..." 
		    rm -rf "$BACKUP_DIR/$dir_name"
		    cp -r "$SOURCE_DIR/$dir_name" "$BACKUP_DIR/" || handle_error "$dir_name 目录备份失败"
		    backup_successful=true
		fi
	   fi
       fi
    done  
}


# 检查配置文件和密钥文件变更函数
check_and_backup_files() {
    local files=("$@")
    
    for file_pattern in "${files[@]}"; do
        # 使用通配符匹配文件
        for file in "$SOURCE_DIR"/$file_pattern; do
            # 确保文件存在
            if [ -f "$file" ]; then
                local filename=$(basename "$file")
                # 如果文件在源目录有更新，或者备份文件不存在
                if [ "$file" -nt "$BACKUP_DIR/$filename" ]; then
                    log_message " $filename 文件有变更，进行备份..."
                    cp "$file" "$BACKUP_DIR/$filename" || handle_error "$filename 文件备份失败"
                    backup_successful=true
                else
                    log_message " $filename 文件未变更"
                fi
            fi
        done
    done
}

# 检查并备份目录
check_and_backup_dir "etc" "data" 

# 检查并备份文件
#check_and_backup_files "config.json" "rsa_key.*"

backup_and_rclone(){
	# 如果有备份操作成功，使用 rclone 传输备份
	if [ "$backup_successful" = true ]; then
	    log_message "======================备份开始====================="
	    systemctl stop stalwart
            log_message " 停止 stalwart 服务"
	    # 压缩备份的文件
	    cd "$BACKUP_DIR" || handle_error "切换到备份目录失败"

	    EXPORT_FILE="$BACKUP_DIR/export"
            mkdir -p "$EXPORT_FILE"
            log_message " 导出 stalwart 数据库文件"
            /opt/stalwart/bin/stalwart -c /opt/stalwart/etc/config.toml -e "$EXPORT_FILE"

	    BACKUP_DIR=$(pwd)
	    BACKUP_ARCHIVE="stalwart-backup-$(date '+%Y%m%d-%H%M').tar.gz"
	    log_message "删除旧备份压缩文件：$(find $BACKUP_DIR -maxdepth 1 -name '*.tar.gz' -printf '%P\n')"
	    find . -maxdepth 1 -name "*.tar.gz" -exec rm -f {} \;
	    log_message "$(find $BACKUP_DIR -mindepth 1 -printf '%P\n')生成压缩文件: $BACKUP_ARCHIVE"
	    tar -czf "$BACKUP_ARCHIVE" * || handle_error "压缩备份文件失败"
	    systemctl start stalwart
            log_message " 重启 stalwart 服务"
	    # 压缩备份的文件
	    TOTAL=$(ls -lah $BACKUP_ARCHIVE | awk '{print $5}')
	    if [ -n "$REMOTE_DIRS" ]; then
		    IFS='|' read -ra REMOTES <<< "$REMOTE_DIRS"
		    for remote in "${REMOTES[@]}"; do
		       log_message "$RCLONE_COMMAND copy $BACKUP_ARCHIVE $remote"       
		       $RCLONE_COMMAND copy "$BACKUP_ARCHIVE" "$remote" || handle_error "rclone 传输到 $remote 失败"
		#: <<'notes'  
			# 检查远程目录中的备份文件数量，保留最新的五个
			BACKUP_FILES=$($RCLONE_COMMAND ls "$remote" | sort -rk2 | awk '{print $2}')
			BACKUP_COUNT=$(echo "$BACKUP_FILES" | wc -l)
			if [ "$BACKUP_COUNT" -gt 5 ]; then
			    FILES_TO_DELETE=$(echo "$BACKUP_FILES" | tail -n +6)
			    for file in $FILES_TO_DELETE; do
				$RCLONE_COMMAND delete "$remote/$file" || handle_error "删除 $remote 的旧备份文件失败"
			    done
			fi
		#notes
		    done
	    fi
	    # 发送邮件通知
	    if [ -n "$EMAIL" ]; then
		check_and_install mail "sudo apt install -y mailutils"
		check_and_install msmtp "sudo apt install -y msmtp"
		check_and_install msmtp-mta "sudo apt install -y msmtp-mta"
		check_and_install bsd-mailx "sudo apt install -y bsd-mailx"
		# 1. 先将中文主题进行Base64编码
		#    注意：echo -n 可以防止在字符串末尾添加换行符
		SUBJECT_ENCODED=$(echo -n "stalwart 备份结果" | base64)
                CONTENT_ENCODED=$(echo "$(date '+%Y-%m-%d %H:%M %Z'): stalwart 备份已完成并同步至远程存储。文件大小：$TOTAL" | base64)
		# 2. 构建邮件内容
		(
		#echo "From: sender@yourdomain.com"
		#echo "To: recipient@example.com"
		# 3. 使用特殊格式来格式化主题
		#    格式为：=?字符集?编码方式?Base64编码后的内容?=
		echo "Subject: =?UTF-8?B?${SUBJECT_ENCODED}?="

		# ---其他MIME头和正文部分与方案一相同---
		echo "MIME-Version: 1.0"
		echo "Content-Type: text/plain; charset=UTF-8"
		echo "Content-Transfer-Encoding: base64"
		echo ""
#		echo "你好，"
#		echo "这封邮件的正文和主题现在都应该能正确显示了。"
		echo "${CONTENT_ENCODED}"

		) |runuser -u admin -- msmtp -C /home/admin/.msmtprc "$EMAIL"
		if [ $? -eq 0 ]; then
		    log_message "备份结果已发送到邮箱 $EMAIL"
		else
		    log_message "发送备份结果到邮箱 $EMAIL 失败"
		fi
	    fi
	    log_message "======================备份结束====================="
	    
	    # 删除本地备份压缩包只保留最新
	    del_db_file "*.tar.gz"
	else
	    log_message " 未发现需要备份的变更，跳过备份" 
	fi
}

backup_and_rclone
