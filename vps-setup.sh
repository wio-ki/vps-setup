#!/bin/bash
# VPS 初始化极简版
# 版本: v3.10 (Ubuntu专用精简版, 修复Nginx安装)
# 适用系统: Ubuntu

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
    apt update -y
    apt install -y curl wget vim fail2ban iperf3 lsb-release gnupg2
}

# 配置 Swap（自动判断并设置两倍RAM大小）
setup_swap() {
    # 获取内存大小（MB）
    MEM_TOTAL_MB=$(free -m | awk '/^Mem:/ {print $2}')
    # 计算期望的Swap大小（两倍内存），以MB为单位
    SWAP_DESIRED_MB=$((MEM_TOTAL_MB * 2))
    # 将MB转换为G，并向上取整，如果不足1G则按1G计算
    SWAP_DESIRED_G=$(( (SWAP_DESIRED_MB + 1023) / 1024 ))
    
    echo -e "${YELLOW}正在检查 Swap 交换分区...${PLAIN}"

    # 获取当前Swap大小（MB）
    SWAP_CURRENT_MB=$(free -m | awk '/^Swap:/ {print $2}')
    
    # 检查是否存在Swap分区
    if [[ $SWAP_CURRENT_MB -eq 0 ]]; then
        echo -e "${YELLOW}未检测到 Swap 分区，将自动创建 ${SWAP_DESIRED_G}G Swap...${PLAIN}"
    else
        echo -e "${YELLOW}已检测到 Swap 分区，大小为 ${SWAP_CURRENT_MB}MB...${PLAIN}"
        
        if [[ $SWAP_CURRENT_MB -eq $SWAP_DESIRED_MB || $SWAP_CURRENT_MB -gt $SWAP_DESIRED_MB ]]; then
            echo -e "${GREEN}Swap 大小 (${SWAP_CURRENT_MB}MB) 满足或大于期望值 (${SWAP_DESIRED_MB}MB)，跳过配置。${PLAIN}"
            return 0
        else
            echo -e "${YELLOW}当前 Swap 大小 (${SWAP_CURRENT_MB}MB) 不满足期望值 (${SWAP_DESIRED_MB}MB)，将删除旧 Swap 并重新创建。${PLAIN}"
            
            # 删除旧的Swap
            swapoff -a
            # 找到 /etc/fstab 中配置的swapfile并删除
            SWAP_FILE_PATH=$(grep -w swap /etc/fstab | awk '{print $1}')
            if [[ -f $SWAP_FILE_PATH ]]; then
                sed -i "/swap/d" /etc/fstab
                rm -f $SWAP_FILE_PATH
                echo -e "${YELLOW}旧的 Swap 文件 (${SWAP_FILE_PATH}) 已删除。${PLAIN}"
            fi
        fi
    fi

    # 创建新的Swap文件
    echo -e "${YELLOW}正在创建新的 ${SWAP_DESIRED_G}G Swap 文件...${PLAIN}"
    fallocate -l ${SWAP_DESIRED_G}G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    
    # 加入开机自启
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
    
    # 调整 swappiness 和 vfs_cache_pressure
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    echo "vm.vfs_cache_pressure=50" >> /etc/sysctl.conf
    sysctl -p
    
    echo -e "${GREEN}Swap 配置完成！大小为 ${SWAP_DESIRED_G}G。${PLAIN}"
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

# 安装最新版 Nginx
install_nginx() {
    echo -e "${YELLOW}正在通过官方源安装最新版 Nginx...${PLAIN}"
    
    # 移除旧的Nginx APT源配置文件，防止格式错误
    rm -f /etc/apt/sources.list.d/nginx.list
    
    # 下载并添加 Nginx 签名密钥
    curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor | tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
    
    # 获取系统代号
    UBUNTU_CODENAME=$(lsb_release -cs)
    
    # 添加 Nginx APT 源，使用正确的格式
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/mainline/ubuntu ${UBUNTU_CODENAME} nginx" | tee /etc/apt/sources.list.d/nginx.list
    
    # 更新并安装 Nginx
    apt update -y
    apt install -y nginx
    
    # 检查 Nginx 是否成功安装，如果成功则启动服务
    if command -v nginx >/dev/null 2>&1; then
        # 启动 Nginx
        systemctl start nginx
        systemctl enable nginx
        echo -e "${GREEN}Nginx 安装和启动已完成！${PLAIN}"
    else
        echo -e "${RED}Nginx 安装失败，请手动检查。${PLAIN}"
    fi
}


# 一键完整配置
full_setup() {
    install_base
    setup_timezone
    setup_swap
    setup_ssh
    install_nginx
    systemctl enable fail2ban --now
    echo -e "${GREEN}一键配置完成！${PLAIN}"
}

# 菜单
while true; do
    clear
    echo -e "${GREEN}====== VPS 初始化精简版 v3.10 (Ubuntu) ======${PLAIN}"
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
