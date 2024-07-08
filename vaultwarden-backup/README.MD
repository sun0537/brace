## backup.sh
The purpose of this script is to backup vaultwarden data files using rclone.

Use systemd-timer to execute the script at 2 am.

Before executing the script, you need to configure rclone and mail.
```
Usage: backup.sh [options]

Options:
  -s, --source-dir   指定 Vaultwarden 数据目录
  -b, --backup-dir   指定本地备份目录 (default: localbackup)
  -r, --remote       指定 rclone 远程备份文件夹，用 | 分隔多个 (default: remotebackup)
  -e, --email        指定接收备份结果的邮箱地址
  -l, --log          将日志输出到文件
  -c, --config       指定 rclone 的配置文件路径 (default: ~/.config/rclone/rclone.conf)
  -h, --help         显示此帮助信息
```
## example
```bash
/bin/bash /home/user/vaultwarden/backup.sh -s /home/user/vaultwarden/vw-data/ -b /home/user/vaultwarden/localbuckup/ -c /home/user/.config/rclone/rclone.conf -r "remote:vaultwarden/|remote2:vaultwarden/|remote3:vaultwarden/" -e user@email.com -l /home/user/vaultwarden/log/vault.log
```

[rclone 配置甲骨文对象存储](https://docs.oracle.com/zh-cn/solutions/move-data-to-cloud-storage-using-rclone/index.html#GUID-8CF47E2F-5F0E-466F-8A1B-DF61B751102E)  
[rclone 配置cloudflare对象存储](https://developers.cloudflare.com/r2/examples/rclone/)   
[rclone crypt 中间层加密](https://cloud.tencent.com/developer/article/2345878)  
[using-docker-secrets-with-a-vaultwarden-mysql-setup](https://anujnair.com/blog/19-using-docker-secrets-with-a-vaultwarden-mysql-setup)  
[配置mail，使用命令行发送邮件：Setting up email with SMTP on Ubuntu/Debian Servers](https://gist.github.com/movd/7a9e3db63d076f85d16c7dcde62fe401)
