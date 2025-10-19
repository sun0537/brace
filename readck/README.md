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

```
Readeck 安装与管理脚本
用法: ./install.sh [操作] [选项]...
操作:
  install                  安装或更新 Readeck
  remove                   卸载 Readeck (保留配置文件和数据目录)
  help                     显示此帮助信息
选项:
  --version=<版本号>       安装指定的 Readeck 版本 (例如: --version=0.20.4)
  remove --purge           彻底卸载 Readeck, 包括配置、数据目录和专用用户

```

