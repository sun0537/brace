# dufs-install

[Filesystem Hierarchy Standard (FHS)](https://en.wikipedia.org/wiki/Filesystem_Hierarchy_Standard) 

Upstream URL: 
[dufs](https://github.com/sigoden/dufs) 

```
Installed: /usr/local/bin/dufs
```
```ini
...
# Working Directory
WorkingDirectory=/var/lib/dufs
##
...
# /etc/systemd/system/dufs.service
ExecStart=/usr/local/bin/dufs run -c /usr/local/etc/dufs/config.json
##
# /etc/systemd/system/dufs@.service
ExecStart=/usr/local/bin/dufs run -c /usr/local/etc/dufs/%i.json
...
```

## Usage

```
bash -c "$(curl -L dufs.vercel.app)" @ [ACTION] [OPTION]
```

```
dufs 安装与管理脚本
用法: ./install.sh [操作] [选项]...
操作:
  install                  安装或更新 dufs
  remove                   卸载 dufs (保留配置文件和数据目录)
  help                     显示此帮助信息
选项:
  --version=<版本号>       安装指定的 dufs 版本 (例如: --version=0.45.0)
  remove --purge           彻底卸载 dufs, 包括配置、数据目录和专用用户

```

