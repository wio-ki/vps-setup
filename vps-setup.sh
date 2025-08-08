#!/bin/bash

# ===============================================
# VPS 一键配置和调优脚本
# 作者：改进版
# 版本：2.0
# ===============================================

# 步骤 1: 检查是否以 root 用户运行，如果不是则切换
check_and_switch_to_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "当前用户不是 root，正在切换到 root 用户..."
        exec sudo su - root -c "bash $0"
        exit
    fi
}

# 检查并切换到 root
check_and_switch_to_root

echo "---"
echo "欢迎使用 VPS 自动配置脚本 v2.0，我们将按步骤进行设置。"
echo "---"

# 步骤 2: 更新软件包列表并更新已安装软件
echo ">> [1/8] 正在更新软件包列表并更新已安装软件..."
apt update -y > /dev/null 2>&1
apt upgrade -y > /dev/null 2>&1
echo "✓ 系统更新完成。"

# 步骤 3: 安装常用软件
echo "---"
echo ">> [2/8] 正在安装常用软件..."
apt install -y sudo curl wget nano vim > /dev/null 2>&1
echo "✓ 常用软件安装完成。"

# 步骤 4: 设置时区
echo "---"
echo ">> [3/8] 正在设置系统时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai
echo "✓ 时区设置完成。当前时区为：$(timedatectl | grep "Time zone" | awk '{print $3}')"

# 步骤 5: 系统调优 (BBR, FQ, TCP 缓冲区)
echo "---"
echo ">> [4/8] 正在进行系统调优（开启BBR、FQ、动态调节TCP缓冲区）..."

# 检查内核版本是否支持BBR
kernel_version=$(uname -r | cut -d. -f1-2)
echo "当前内核版本：$(uname -r)"

# 获取VPS配置信息
total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
total_ram_mb=$((total_ram_kb / 1024))
total_ram_gb=$((total_ram_mb / 1024))

# 获取CPU核心数
cpu_cores=$(nproc)

# 尝试获取网络带宽信息（通过网卡速度）
network_speed=""
for interface in $(ls /sys/class/net/ | grep -E '^(eth|ens|enp)'); do
    if [ -f "/sys/class/net/$interface/speed" ]; then
        speed=$(cat /sys/class/net/$interface/speed 2>/dev/null)
        if [ "$speed" != "-1" ] && [ ! -z "$speed" ]; then
            network_speed="${speed}Mbps"
            break
        fi
    fi
done

echo "VPS配置信息："
echo "  - 内存：${total_ram_mb} MB (${total_ram_gb} GB)"
echo "  - CPU核心：${cpu_cores} 核"
echo "  - 网卡速度：${network_speed:-"未检测到"}"

# 根据内存大小动态计算TCP缓冲区
# 基础算法：内存越大，缓冲区越大，但有合理上限
if [ $total_ram_mb -le 512 ]; then
    # 小内存VPS (≤512MB)
    tcp_rmem_max=16777216      # 16MB
    tcp_wmem_max=16777216      # 16MB
    tcp_rmem_default=65536     # 64KB
    tcp_wmem_default=32768     # 32KB
    netdev_backlog=2500
    syn_backlog=2048
elif [ $total_ram_mb -le 1024 ]; then
    # 1GB内存VPS
    tcp_rmem_max=33554432      # 32MB
    tcp_wmem_max=33554432      # 32MB
    tcp_rmem_default=87380     # 85KB
    tcp_wmem_default=65536     # 64KB
    netdev_backlog=3000
    syn_backlog=4096
elif [ $total_ram_mb -le 2048 ]; then
    # 2GB内存VPS
    tcp_rmem_max=67108864      # 64MB
    tcp_wmem_max=67108864      # 64MB
    tcp_rmem_default=131072    # 128KB
    tcp_wmem_default=65536     # 64KB
    netdev_backlog=4000
    syn_backlog=8192
elif [ $total_ram_mb -le 4096 ]; then
    # 4GB内存VPS
    tcp_rmem_max=134217728     # 128MB
    tcp_wmem_max=134217728     # 128MB
    tcp_rmem_default=174760    # 170KB
    tcp_wmem_default=131072    # 128KB
    netdev_backlog=5000
    syn_backlog=16384
elif [ $total_ram_mb -le 8192 ]; then
    # 8GB内存VPS
    tcp_rmem_max=268435456     # 256MB
    tcp_wmem_max=268435456     # 256MB
    tcp_rmem_default=262144    # 256KB
    tcp_wmem_default=262144    # 256KB
    netdev_backlog=8000
    syn_backlog=32768
else
    # 大内存VPS (>8GB)
    tcp_rmem_max=536870912     # 512MB
    tcp_wmem_max=536870912     # 512MB
    tcp_rmem_default=524288    # 512KB
    tcp_wmem_default=524288    # 512KB
    netdev_backlog=10000
    syn_backlog=65536
fi

echo ">> 根据VPS配置计算的优化参数："
echo "  - TCP接收缓冲区最大值：$((tcp_rmem_max / 1024 / 1024)) MB"
echo "  - TCP发送缓冲区最大值：$((tcp_wmem_max / 1024 / 1024)) MB"
echo "  - TCP接收缓冲区默认值：$((tcp_rmem_default / 1024)) KB"
echo "  - TCP发送缓冲区默认值：$((tcp_wmem_default / 1024)) KB"

# 写入动态计算的 sysctl 配置文件
cat <<EOF > /etc/sysctl.d/99-vps-tuning.conf
# 开启 BBR 拥塞控制算法和 FQ 队列调度
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr

# 根据VPS配置动态调整的TCP缓冲区 (最小值/默认值/最大值)
net.ipv4.tcp_rmem = 4096 $tcp_rmem_default $tcp_rmem_max
net.ipv4.tcp_wmem = 4096 $tcp_wmem_default $tcp_wmem_max

# 网络核心缓冲区配置
net.core.rmem_max = $tcp_rmem_max
net.core.wmem_max = $tcp_wmem_max

# TCP性能优化
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 1024 65535

# 根据VPS性能调整的其他参数
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_max_syn_backlog = $syn_backlog
net.core.netdev_max_backlog = $netdev_backlog

# 内存相关优化
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_rfc1337 = 1
EOF

# 应用 sysctl 配置
sysctl --system > /dev/null 2>&1
echo "✓ 系统调优参数已应用。"
echo "当前拥塞控制算法：$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
echo "当前队列调度算法：$(sysctl net.core.default_qdisc | awk '{print $3}')"

# 步骤 6: 添加 Swap
echo "---"
echo ">> [5/8] 准备创建 Swap 交换分区..."

# 检查是否已有swap
existing_swap=$(free -m | grep "Swap:" | awk '{print $2}')
if [ "$existing_swap" -gt 0 ]; then
    echo "检测到系统已有 ${existing_swap} MB 的 Swap，跳过创建。"
else
    total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_ram_mb=$((total_ram_kb / 1024))
    recommended_swap=$((total_ram_mb * 2))
    
    echo "当前 VPS 的物理内存 (RAM) 为：${total_ram_mb} MB"
    echo "建议创建 Swap 大小：${recommended_swap} MB (RAM 的 2 倍)"
    echo ""
    echo "请选择："
    echo "1. 创建推荐大小的 Swap (${recommended_swap} MB) [默认]"
    echo "2. 自定义 Swap 大小"
    echo ""
    read -p "请输入选择 [1/2] (回车默认选择1): " swap_choice
    
    swap_size_mb=0
    if [[ "$swap_choice" == "2" ]]; then
        while true; do
            read -p "请输入自定义的 Swap 大小 (单位：MB): " custom_size
            if [[ "$custom_size" =~ ^[0-9]+$ ]] && [ "$custom_size" -gt 0 ]; then
                swap_size_mb=$custom_size
                break
            else
                echo "输入无效，请输入一个大于 0 的整数。"
            fi
        done
    else
        swap_size_mb=$recommended_swap
    fi
    
    echo ">> 正在创建 ${swap_size_mb} MB 的 Swap 文件..."
    swap_file_path="/swapfile"
    
    # 创建swap文件
    fallocate -l ${swap_size_mb}M $swap_file_path
    chmod 600 $swap_file_path
    mkswap $swap_file_path > /dev/null
    swapon $swap_file_path
    
    # 添加到fstab使其永久生效
    if ! grep -q "$swap_file_path" /etc/fstab; then
        echo "$swap_file_path none swap sw 0 0" >> /etc/fstab
    fi
    
    # 设置swappiness
    sysctl vm.swappiness=10 > /dev/null
    if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi
    
    echo "✓ Swap 交换分区创建完成。"
    echo "当前 Swap 大小：$(free -m | grep "Swap:" | awk '{print $2}') MB"
fi

# 步骤 7: 修改 SSH 端口
echo "---"
echo ">> [6/8] SSH 端口配置..."

# 获取当前SSH端口
current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null)
if [ -z "$current_port" ]; then
    current_port="22"
fi

echo "当前 SSH 端口：$current_port"
echo ""
read -p "是否要修改 SSH 端口？[y/N] " modify_ssh

if [[ "$modify_ssh" == "y" || "$modify_ssh" == "Y" ]]; then
    while true; do
        read -p "请输入新的 SSH 端口号 (1024-65535): " new_port
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ "$new_port" -ge 1024 ] && [ "$new_port" -le 65535 ]; then
            break
        else
            echo "输入无效，请输入 1024-65535 范围内的端口号。"
        fi
    done
    
    echo ">> 正在修改 SSH 配置..."
    
    # 备份配置文件
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)
    
    # 修改端口配置
    if grep -q "^Port" /etc/ssh/sshd_config; then
        sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
    elif grep -q "^#Port 22" /etc/ssh/sshd_config; then
        sed -i "s/^#Port 22/Port $new_port/" /etc/ssh/sshd_config
    else
        echo "Port $new_port" >> /etc/ssh/sshd_config
    fi
    
    # 测试SSH配置
    if sshd -t; then
        echo "✓ SSH 配置测试通过。"
        echo ">> 重启 SSH 服务..."
        systemctl restart sshd
        echo "✓ SSH 端口已修改为 $new_port"
        echo ""
        echo "======================================================"
        echo "!!! 重要提醒：请不要关闭当前终端 !!!"
        echo "请另开一个终端，使用以下命令测试新端口："
        echo "ssh -p $new_port 用户名@服务器IP"
        echo "确认能正常登录后，再关闭此终端。"
        echo "======================================================"
        echo ""
    else
        echo "✗ SSH 配置有误，恢复备份..."
        cp /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S) /etc/ssh/sshd_config
        echo "SSH 配置已恢复，端口保持为 $current_port"
    fi
else
    echo "✓ SSH 端口保持为 $current_port"
fi

# 步骤 8: 安装和配置 Fail2ban
echo "---"
echo ">> [7/8] 正在安装和配置 Fail2ban..."

# 安装 fail2ban
if ! command -v fail2ban-server >/dev/null 2>&1; then
    apt install -y fail2ban > /dev/null 2>&1
    echo "✓ Fail2ban 安装完成。"
else
    echo "✓ Fail2ban 已安装。"
fi

# 获取SSH端口用于fail2ban配置
ssh_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null)
if [ -z "$ssh_port" ]; then
    ssh_port="ssh"
else
    ssh_port="$ssh_port"
fi

# 创建 jail.local 配置文件
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
# 封禁时间：1天
bantime = 1d

# 监控时间窗口：10分钟
findtime = 10m

# 最大尝试次数
maxretry = 5

# 忽略IP列表（可以添加自己的IP）
ignoreip = 127.0.0.1/8 ::1

# 封禁动作
banaction = iptables-multiport

# 邮件动作（如果配置了邮件）
mta = sendmail

[sshd]
enabled = true
port = $ssh_port
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
EOF

echo "✓ Fail2ban 配置文件创建完成。"

# 启动并启用 fail2ban 服务
systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban

# 等待服务启动
sleep 2

echo "✓ Fail2ban 服务已启动。"
echo ">> Fail2ban 状态检查："
systemctl status fail2ban --no-pager -l

echo ""
echo ">> Fail2ban 活动监狱："
fail2ban-client status

# 步骤 9: 完成总结
echo ""
echo "---"
echo ">> [8/8] 配置完成！"
echo "---"
echo "✅ 配置总结："
echo "   - 系统已更新并安装常用软件"
echo "   - 时区已设置为 Asia/Shanghai"
echo "   - 系统已启用 BBR 拥塞控制和性能优化"
echo "   - Swap 交换分区已配置"
if [[ "$modify_ssh" == "y" || "$modify_ssh" == "Y" ]]; then
    echo "   - SSH 端口已修改为 $new_port"
else
    echo "   - SSH 端口保持为 $current_port"
fi
echo "   - Fail2ban 已安装并配置完成"
echo ""
echo "🎉 VPS 配置完成！建议重启系统以确保所有设置生效。"
echo "---"