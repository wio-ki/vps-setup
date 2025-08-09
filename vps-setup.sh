#!/bin/bash
# VPS 初始化极简版
# 版本: v3.6-lite
# 适用系统: Debian / Ubuntu / CentOS

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 检查 root
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 安装常用工具
install_base() {
    echo -e "${YELLOW}正在安装常用工具...${PLAIN}"
    if [[ -f /etc/debian_version ]]; then
        apt update -y && apt install -y curl wget vim ufw fail2ban
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y epel-release
        yum install -y curl wget vim ufw fail2ban
    fi
}

# TCP 调优（只保留 BBR + FQ）
enable_bbr_fq() {
    echo -e "${YELLOW}开启 BBR + FQ...${PLAIN}"
    modprobe tcp_bbr
    echo "tcp_bbr" >> /etc/modules-load.d/modules.conf
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p
}

# 配置 Swap
setup_swap() {
    read -p "请输入 swap 大小（例如 1G）: " swapsize
    fallocate -l $swapsize /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    echo -e "${GREEN}Swap 配置完成！${PLAIN}"
}

# SSH 安全端口配置
setup_ssh() {
    read -p "请输入新的 SSH 端口（建议 1024-65535）: " sshport
    sed -i "s/^#Port.*/Port $sshport/" /etc/ssh/sshd_config
    sed -i "s/^Port.*/Port $sshport/" /etc/ssh/sshd_config
    systemctl restart sshd
    ufw allow $sshport/tcp
    echo -e "${GREEN}SSH 端口已修改为 $sshport 并放行防火墙！${PLAIN}"
}

# 一键完整配置
full_setup() {
    install_base
    enable_bbr_fq
    setup_swap
    setup_ssh
    systemctl enable fail2ban --now
    echo -e "${GREEN}一键配置完成！${PLAIN}"
}

# 菜单
while true; do
    clear
    echo -e "${GREEN}====== VPS 初始化极简版 ======${PLAIN}"
    echo "1. 一键完整配置（推荐）"
    echo "2. 配置 Swap 交换分区"
    echo "3. SSH 安全端口配置"
    echo "0. 退出"
    echo -n "请输入选项: "
    read choice
    case $choice in
        1) full_setup ;;
        2) setup_swap ;;
        3) setup_ssh ;;
        0) exit ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
    read -n 1 -s -r -p "按任意键返回菜单..."
done
