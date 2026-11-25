# vps-setup

用于 Debian 12 / 13 新 VPS。以 root 运行，日志保存在 `/data_back/scripts/`。

```bash
curl -fsSLo vps-setup.sh https://raw.githubusercontent.com/wio-ki/vps-setup/main/vps-setup.sh && bash vps-setup.sh
```

脚本更新系统、配置 SSH 端口 `61692`、设置上海时区、安装 Docker Compose 和 Nginx、准备 sing-box 配置目录，并设置 Swap 与 BBR。sing-box 配置需要自行填写。再次运行会保留已有的 sing-box 和 Nginx 配置。

默认由你安排重启。请先在服务商防火墙放行 TCP 61692。需要在初始化结束后自动重启时，运行 `AUTO_REBOOT=1 bash vps-setup.sh`。
