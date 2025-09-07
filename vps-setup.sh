#!/bin/bash
# VPS 初始化极简版
# 版本: v3.12 (Ubuntu/Debian通用精简版, 增加无Nginx选项)
# 适用系统: Ubuntu / Debian

# 颜色
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
PLAIN="\033[0m"

# 检查 root
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 检测系统
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        CODENAME=$VERSION_CODENAME
    else
        echo -e "${RED}无法检测系统类型！${PLAIN}"
        exit 1
    fi
}

# 安装常用工具
install_base() {
    echo -e "${YELLOW}正在安装常用工具...${PLAIN}"
    apt update -y
    apt install -y curl wget vim fail2ban iperf3 lsb-release gnupg2
}

# 配置 Swap（自动判断并设置两倍RAM大小）
setup_swap() {
    MEM_TOTAL_MB=$(free -m | awk '/^Mem:/ {print $2}')
    SWAP_DESIRED_MB=$((MEM_TOTAL_MB * 2))
    SWAP_DESIRED_G=$(( (SWAP_DESIRED_MB + 1023) / 1024 ))

    echo -e "${YELLOW}正在检查 Swap 交换分区...${PLAIN}"
    SWAP_CURRENT_MB=$(free -m | awk '/^Swap:/ {print $2}')

    if [[ $SWAP_CURRENT_MB -eq 0 ]]; then
        echo -e "${YELLOW}未检测到 Swap，将创建 ${SWAP_DESIRED_G}G...${PLAIN}"
    else
        if [[ $SWAP_CURRENT_MB -ge $SWAP_DESIRED_MB ]]; then
            echo -e "${GREEN}当前 Swap (${SWAP_CURRENT_MB}MB) 已满足要求，跳过。${PLAIN}"
            return 0
        else
            echo -e "${YELLOW}当前 Swap (${SWAP_CURRENT_MB}MB) 不足，将重新创建。${PLAIN}"
            swapoff -a
            SWAP_FILE_PATH=$(grep -w swap /etc/fstab | awk '{print $1}')
            if [[ -f $SWAP_FILE_PATH ]]; then
                sed -i "/swap/d" /etc/fstab
                rm -f $SWAP_FILE_PATH
            fi
        fi
    fi

    fallocate -l ${SWAP_DESIRED_G}G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
    sysctl -p
    echo -e "${GREEN}Swap 配置完成 (${SWAP_DESIRED_G}G)。${PLAIN}"
}

# SSH 安全端口配置
setup_ssh() {
    read -p "请输入新的 SSH 端口（建议 1024-65535）: " sshport
    sed -i "s/^#Port.*/Port $sshport/" /etc/ssh/sshd_config
    sed -i "s/^Port.*/Port $sshport/" /etc/ssh/sshd_config
    systemctl restart sshd
    echo -e "${GREEN}SSH 端口已修改为 $sshport。${PLAIN}"
}

# 配置时区为上海
setup_timezone() {
    echo -e "${YELLOW}正在设置时区为亚洲/上海...${PLAIN}"
    timedatectl set-timezone Asia/Shanghai
    echo -e "${GREEN}时区已成功设置为 Asia/Shanghai。${PLAIN}"
}

# Nginx 目录配置
setup_nginx_config() {
    echo -e "${YELLOW}正在配置Nginx站点目录结构...${PLAIN}"
    mkdir -p /etc/nginx/sites-available
    mkdir -p /etc/nginx/sites-enabled
    NGINX_CONF="/etc/nginx/nginx.conf"
    if ! grep -q "include /etc/nginx/sites-enabled/\*;" "$NGINX_CONF"; then
        sed -i '/http {/a \\tinclude /etc/nginx/sites-enabled/\*;' "$NGINX_CONF"
    fi
    echo -e "${GREEN}Nginx站点目录配置完成。${PLAIN}"
}

# 安装最新版 Nginx (Ubuntu / Debian 自动适配)
install_nginx() {
    echo -e "${YELLOW}正在安装最新版 Nginx...${PLAIN}"
    rm -f /etc/apt/sources.list.d/nginx.list
    curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null

    if [[ $OS == "ubuntu" ]]; then
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu ${CODENAME} nginx" | tee /etc/apt/sources.list.d/nginx.list
    elif [[ $OS == "debian" ]]; then
        echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/debian ${CODENAME} nginx" | tee /etc/apt/sources.list.d/nginx.list
    else
        echo -e "${RED}不支持的系统: $OS${PLAIN}"
        exit 1
    fi

    apt update -y
    apt install -y nginx
    if command -v nginx >/dev/null 2>&1; then
        setup_nginx_config
        systemctl enable --now nginx
        echo -e "${GREEN}Nginx 安装完成！${PLAIN}"
    else
        echo -e "${RED}Nginx 安装失败！${PLAIN}"
    fi
}

# 一键完整配置（含Nginx）
full_setup() {
    install_base
    setup_timezone
    setup_swap
    setup_ssh
    install_nginx
    systemctl enable fail2ban --now
    echo -e "${GREEN}一键配置完成（含Nginx）！${PLAIN}"
}

# 一键完整配置（不安装Nginx）
full_setup_without_nginx() {
    install_base
    setup_timezone
    setup_swap
    setup_ssh
    systemctl enable fail2ban --now
    echo -e "${GREEN}一键配置完成（不含Nginx）！${PLAIN}"
}

# 主菜单
check_os
while true; do
    clear
    echo -e "${GREEN}====== VPS 初始化精简版 v3.12 (${OS^}) ======${PLAIN}"
    echo "1. 一键完整配置（含Nginx，推荐）"
    echo "2. 配置 Swap 交换分区"
    echo "3. SSH 安全端口配置"
    echo "4. 一键完整配置（不含Nginx）"
    echo "0. 退出"
    echo -n "请输入选项: "
    read choice
    case $choice in
        1) full_setup ;;
        2) setup_swap ;;
        3) setup_ssh ;;
        4) full_setup_without_nginx ;;
        0) exit ;;
        *) echo -e "${RED}无效选项！${PLAIN}" ;;
    esac
    read -n 1 -s -r -p "按任意键返回菜单..."
done
