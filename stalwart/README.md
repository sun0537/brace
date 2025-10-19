# stalwart-install


Upstream URL: 
[stalwart](https://stalw.art/docs/install/get-started) 

```
Installed: /opt/stalwart/bin/stalwart
```
```ini
...
# /etc/systemd/system/stalwart.service
ExecStart=/opt/stalwart/bin/stalwart --config=/opt/stalwart/etc/config.toml
##
...
```

## Usage

```
bash -c "$(curl -L stalwart.vercel.app)" @ [ACTION] [OPTION]
```

脚本基于[官方脚本](https://stalw.art/docs/install/platform/linux/#:~:text=https%3A//get.stalw.art/install.sh)修改，执行脚本默认安装，增加更新删除选项
**命令 `help` 显示**: 
```
Stalwart 安装/卸载脚本 v2.0.0

用法: ./install.sh [命令] [选项] [安装目录]

命令:
  install         安装 Stalwart (默认命令)
                  - 如果未安装：执行全新安装
                  - 如果已安装：更新到最新版本（保留配置）
  uninstall       完全卸载 Stalwart
  help, --help    显示此帮助信息

选项:
  --fdb           安装 FoundationDB 版本
  --force-init    强制重新初始化配置（会备份旧配置）

示例:
  ./install.sh                          # 安装到默认目录 /opt/stalwart
  ./install.sh install /usr/local/stalwart  # 安装到指定目录
  ./install.sh install --force-init     # 重新安装并重置配置
  ./install.sh uninstall                # 完全卸载

```

**使用示例**
```bash
# 安装到默认目录
sudo ./install.sh

# 更新已安装的版本（保留配置）
sudo ./install.sh install

# 强制重置配置（会备份）
sudo ./install.sh install --force-init

# 安装到自定义目录
sudo ./install.sh install /usr/local/stalwart

# 完全卸载
sudo ./install.sh uninstall

# 显示帮助
./install.sh --help
```
