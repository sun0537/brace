#!/bin/bash

set -o pipefail

# --- 用户配置 ---

# 1. 源目录: 监控此目录。
SOURCE_DIR="/home/ubuntu/certs"

# 2. 目标目录: Nginx 读取证书的目录。
TARGET_DIR="/usr/local/nginx/certs"

# 3. 证书文件名: 脚本将等待这两个文件同时出现在 SOURCE_DIR 中。
CERT_FILE="cert.pem"
KEY_FILE="key.pem"

# --- 脚本核心逻辑 (一般无需修改) ---

# 确保源目录存在
mkdir -p "$SOURCE_DIR"

# 检查是否我们需要的两个文件都已存在
if [ -f "$SOURCE_DIR/$CERT_FILE" ] && [ -f "$SOURCE_DIR/$KEY_FILE" ]; then
    echo "目标文件 '$CERT_FILE' 和 '$KEY_FILE' 均已存在。开始执行更新..."

    # --- 开始更新流程 ---

    # 1. 停止 Nginx
    echo "[1/5] 正在停止 Nginx..."
    if ! systemctl stop nginx; then
        echo "❌ 错误: 停止 Nginx 失败。请使用 'systemctl status nginx' 查看详情。"
        echo "中止本次更新，将继续监控。"
        continue # 跳过本次循环的剩余部分，继续监控
    fi
    echo "✅ Nginx 已停止。"

    # 2. 复制证书文件
    echo "[2/5] 正在复制新证书..."
    if ! rsync -av "$SOURCE_DIR/$CERT_FILE" "$SOURCE_DIR/$KEY_FILE" "$TARGET_DIR/"; then
        echo "❌ 错误: 复制文件失败。请检查目录权限和路径。"
        echo "尝试重启 Nginx 以恢复服务..."
        systemctl start nginx
        continue
    fi
    echo "✅ 证书已复制到 $TARGET_DIR"

    echo "修改证书所有者root"
    chown root:root -R "$TARGET_DIR/"
    # 3. 启动 Nginx
    echo "[3/5] 正在启动 Nginx..."
    if ! systemctl start nginx; then
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "❌ 严重错误: Nginx 启动失败！"
        echo "   这很可能是因为新的证书文件有问题 (格式错误、不匹配等)。"
        echo "   请立即检查 Nginx 错误日志:"
        echo "   - journalctl -u nginx --since '2 minutes ago'"
        echo "   - tail -n 50 /var/log/nginx/error.log"
        echo "   为了方便排查，源文件 '$SOURCE_DIR/$CERT_FILE' 和 '$SOURCE_DIR/$KEY_FILE' 已被保留。"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        exit 1 # 发生严重错误，退出脚本
    fi

    # 4. 验证 Nginx 状态
    echo "[4/5] 正在验证 Nginx 服务状态..."
    if systemctl is-active --quiet nginx; then
        echo "✅ Nginx 启动成功并处于活动状态。"

        # 5. 清理源文件
        echo "[5/5] 正在清理源文件..."
        rm -f "$SOURCE_DIR/$CERT_FILE" "$SOURCE_DIR/$KEY_FILE"
        echo "✅ 源文件已删除。"
        echo "🎉🎉🎉 本次证书更新成功完成！🎉🎉🎉"
    else
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        echo "⚠️ 警告: Nginx 进程已启动，但服务状态不是 'active'。"
        echo "   请使用 'systemctl status nginx' 检查服务详情。"
        echo "   为了安全，源文件 '$SOURCE_DIR/$CERT_FILE' 和 '$SOURCE_DIR/$KEY_FILE' 已被保留。"
        echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
        exit 1 # 状态异常，退出脚本
    fi

    echo "----------------------------------------------------"
fi

