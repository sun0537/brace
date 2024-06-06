#!/bin/bash

# 检查参数是否正确
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <directory_to_watch> <script_to_execute>"
    exit 1
fi

directory_to_watch="$1"
script_to_execute="$2"

# 监听文件的变更事件
inotifywait -m -e modify,create,delete "$directory_to_watch" |
while read path action file; do
    # 当文件发生变更时，执行指定的脚本或命令
    echo "File '$file' $action"
    # 运行指定的脚本或命令
    "$script_to_execute"
done

