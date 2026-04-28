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
bash -c "$(curl -L stalwart-one.vercel.app)" @ [ACTION] [OPTION]
```

脚本基于[官方脚本](https://stalw.art/docs/install/platform/linux/#:~:text=https%3A//get.stalw.art/install.sh)修改，执行脚本默认安装，增加更新删除选项
**命令 `help` 显示**: 
```
Stalwart 安装/卸载脚本 v2.1.0

用法: ./install.sh [命令] [选项] [PREFIX]

命令:
  install         安装或更新 Stalwart
  uninstall       完全卸载 Stalwart
  help, --help    显示帮助信息

选项:
  --fdb           安装 FoundationDB 版本
  --force-init    强制覆盖环境配置文件

参数:
  PREFIX          自定义安装路径。如果不提供：
                  - 若 /opt/stalwart 已存在，则默认使用该路径。
                  - 否则，将遵循 FHS 标准安装到系统目录 (/usr/local/bin, /etc/stalwart 等)。

示例:
  ./install.sh install /opt/stalwart
  ./install.sh install
  ./install.sh install --fdb

```

**使用示例**
```bash
# 安装到默认目录
sudo ./install.sh

# 更新已安装的版本（保留配置）
sudo ./install.sh install

# 强制重置配置（会备份）
sudo ./install.sh install --force-init

# 完全卸载
sudo ./install.sh uninstall

# 显示帮助
./install.sh --help
```
