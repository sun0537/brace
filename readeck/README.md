# readeck-install

[Filesystem Hierarchy Standard (FHS)](https://en.wikipedia.org/wiki/Filesystem_Hierarchy_Standard)

Upstream URL:
[readeck](https://readeck.org/en/start)

```
Installed: /usr/local/bin/readeck
```
```ini
...
# Working Directory
WorkingDirectory=/var/lib/readeck
##
...
# /etc/systemd/system/readeck.service
ExecStart=/usr/local/bin/readeck serve -config /etc/readeck/config.toml
##
...
```

## Usage

```
bash -c "$(curl -L readeck.vercel.app)" @ [ACTION] [OPTION]
```

普通用户直接执行即可，脚本会自动调用 sudo 重新执行，无需手动加 `sudo`。

**命令 `help` 显示**:
```
Readeck 安装与管理脚本（脚本版本 v1.2.0）

用法: bash -c "$(curl -L <脚本地址>)" @ [操作] [选项]...
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
  bash -c "$(curl -L <脚本地址>)" @ install
  bash -c "$(curl -L <脚本地址>)" @ install --version=0.20.4
  bash -c "$(curl -L <脚本地址>)" @ uninstall
  bash -c "$(curl -L <脚本地址>)" @ uninstall --purge --yes
```
