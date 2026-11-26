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

以普通用户执行即可，脚本会自动通过 `sudo` 提权重跑（会提示输入当前用户密码），不需要手动加 `sudo`。
通过 `bash -c "$(curl ...)"` 或管道方式执行时，提权前会先从 `stalwart-one.vercel.app` 重新获取脚本本体；
如需指向镜像，可设置环境变量 `STALWART_INSTALL_URL`。

**命令 `help` 显示**: 
```
Stalwart 安装/卸载脚本（脚本版本 v2.3.1）

用法: install.sh [命令] [选项] [PREFIX]

命令:
  install         安装或更新 Stalwart（默认，省略命令时即执行此动作）
  uninstall       卸载 Stalwart（自动识别 /opt/stalwart 或 FHS 布局）
  help, --help    显示帮助信息

选项:
  --force-init    强制覆盖 stalwart.env 环境配置文件
  --fdb           已废弃，保留参数以兼容旧脚本（标准版已内置 FoundationDB 客户端）
  --yes, -y       仅用于 uninstall：跳过交互确认（非交互环境建议显式指定）

参数:
  PREFIX          自定义安装路径。如果不提供：
                  - 若 /opt/stalwart 下存在已有安装（bin/stalwart 或 etc/config.json），
                    则默认使用该路径。
                  - 否则，将遵循 FHS 标准安装到系统目录：
                      Linux:   /usr/local/bin, /etc/stalwart, /var/log/stalwart, /var/lib/stalwart
                      FreeBSD: /usr/local/bin, /usr/local/etc/stalwart, /var/log/stalwart, /var/db/stalwart

权限:
  脚本需要 root 权限。以普通用户直接执行时会自动调用 sudo 重新执行，
  无需手动加 sudo；若系统没有 sudo，请先切换到 root 用户。
  通过管道或 bash -c "$(curl ...)" 执行时，提权前会自动重新获取脚本本体。

示例:
  install.sh install /opt/stalwart
  install.sh install
  install.sh install --force-init
  install.sh uninstall
  install.sh uninstall --yes /opt/stalwart

```
