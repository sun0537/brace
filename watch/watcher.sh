#!/bin/bash
: '
该Shell脚本函数用于监视指定目录下的文件变更，并在发生变更时执行指定的脚本或命令。具体功能如下：

1.检查参数是否正确：通过$#获取传入的参数个数，如果不等于2，则输出用法提示并退出脚本。

2.设置变量：将传入的两个参数分别赋值给directory_to_watch和script_to_execute变量。

3.监听文件变更事件：使用inotifywait命令以监控模式（-m）监听指定目录（$directory_to_watch）下的文件变更事件（-e modify,create,delete）。当发生变更时，会输出相关信息并触发后续操作。

4.处理变更事件：通过read命令读取inotifywait输出的路径（path）、动作（action）和文件名（file），并输出相关信息。然后执行指定的脚本或命令（$script_to_execute）。

该函数适用于自动化任务，如编译、测试、部署等，以便在文件变更时自动触发相应操作。
'

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
