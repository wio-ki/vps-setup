#!/bin/bash

# ===============================================
# VPS 一键配置和调优脚本 - 优化版
# 版本：3.3
# 主要改进：智能TCP调优算法、错误处理、性能检测
# ===============================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# 错误处理：在非交互式模式下，如果命令失败，脚本立即退出
# set -euo pipefail
# trap 'log_error "脚本执行失败，行号: $LINENO"' ERR

# 步骤 1: 检查是否以 root 用户运行
check_and_switch_to_root() {
    if [ "$EUID" -ne 0 ]; then
        log_info "当前用户不是 root，正在切换到 root 用户..."
        # 传递所有参数给新的bash实例
        exec sudo su - root -c "bash $0 $*"
        exit 1
    fi
}

check_and_switch_to_root "$@"

# 检测系统信息
detect_system() {
    # 检测操作系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "无法检测操作系统类型"
        exit 1
    fi
    
    # 检测包管理器
    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    else
        log_error "不支持的包管理器"
        exit 1
    fi
    
    log_info "检测到系统: $OS $OS_VERSION，包管理器: $PKG_MANAGER"
}

# 模块 1: 更新系统软件包
update_system() {
    log_info "正在更新软件包列表并更新已安装软件..."
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt update -y
        apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
        
        if [ -f /var/run/reboot-required ]; then
            log_warn "检测到系统更新需要重启才能完全生效"
            log_warn "建议在脚本执行完成后重启系统"
        fi
        
        apt autoremove -y > /dev/null 2>&1
        apt autoclean > /dev/null 2>&1
        unset DEBIAN_FRONTEND
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum update -y
        yum autoremove -y
    fi
    
    log_info "系统更新完成"
}

# 模块 2: 安装常用工具
install_common_tools() {
    log_info "正在安装常用软件..."
    
    local tools="curl wget nano vim bc iproute2 htop iotop nethogs"
    
    if [ "$PKG_MANAGER" = "apt" ]; then
        apt install -y sudo $tools > /dev/null 2>&1
    elif [ "$PKG_MANAGER" = "yum" ]; then
        yum install -y sudo $tools > /dev/null 2>&1
    fi
    
    log_info "常用软件安装完成"
}

# 模块 3: 设置系统时区
set_timezone() {
    log_info "正在设置系统时区为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai
    log_info "时区设置完成。当前时区为：$(timedatectl | grep "Time zone" | awk '{print $3}')"
}

# 网络性能检测函数
detect_network_performance() {
    log_info "正在进行网络性能检测..."
    
    local detected_bandwidth=0
    local avg_rtt=50
    local network_interface=""
    
    # 1. 检测网卡速度
    for interface in $(ls /sys/class/net/ | grep -E '^(eth|ens|enp|venet)'); do
        if [ -f "/sys/class/net/$interface/speed" ]; then
            local speed=$(cat "/sys/class/net/$interface/speed" 2>/dev/null || echo "0")
            if [ "$speed" != "-1" ] && [ "$speed" -gt 0 ]; then
                detected_bandwidth=$speed
                network_interface=$interface
                break
            fi
        fi
    done
    
    # 2. RTT检测 - 改进版本，更准确
    log_debug "正在检测网络延迟..."
    local rtt_sum=0
    local rtt_count=0
    local test_targets=("8.8.8.8" "1.1.1.1" "223.5.5.5" "119.29.29.29")
    
    for target in "${test_targets[@]}"; do
        local rtt=$(ping -c 3 -W 3 "$target" 2>/dev/null | grep "avg" | awk -F'/' '{print $5}' | cut -d'.' -f1 2>/dev/null || echo "")
        if [ -n "$rtt" ] && [ "$rtt" -gt 0 ] && [ "$rtt" -lt 1000 ]; then
            rtt_sum=$((rtt_sum + rtt))
            rtt_count=$((rtt_count + 1))
        fi
    done
    
    if [ $rtt_count -gt 0 ]; then
        avg_rtt=$((rtt_sum / rtt_count))
    fi
    
    # 3. 如果无法检测网卡速度，智能估算
    if [ $detected_bandwidth -eq 0 ]; then
        local total_ram_mb=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
        local cpu_cores=$(nproc)
        
        # 根据VPS配置估算带宽
        if [ $total_ram_mb -le 512 ] && [ $cpu_cores -le 1 ]; then
            detected_bandwidth=100  # 小型VPS
        elif [ $total_ram_mb -le 1024 ] && [ $cpu_cores -le 2 ]; then
            detected_bandwidth=200  # 中小型VPS
        elif [ $total_ram_mb -le 2048 ] && [ $cpu_cores -le 4 ]; then
            detected_bandwidth=500  # 中型VPS
        elif [ $total_ram_mb -le 8192 ] && [ $cpu_cores -le 8 ]; then
            detected_bandwidth=1000 # 大型VPS
        else
            detected_bandwidth=2000 # 超大型VPS
        fi
        
        log_warn "无法检测网卡速度，基于配置估算: ${detected_bandwidth}Mbps"
    fi
    
    echo "$detected_bandwidth $avg_rtt $network_interface"
}

# 智能计算TCP缓冲区
calculate_tcp_buffers() {
    local bandwidth_mbps=$1
    local rtt_ms=$2
    local total_ram_mb=$3
    local cpu_cores=$4
    
    # BDP计算 (Bandwidth-Delay Product)
    local bandwidth_bps=$((bandwidth_mbps * 1000 * 1000))
    local rtt_seconds=$(echo "scale=6; $rtt_ms / 1000" | bc -l)
    local bdp_bytes=$(echo "scale=0; ($bandwidth_bps * $rtt_seconds) / 8" | bc -l)
    
    # 确保BDP合理
    if [ -z "$bdp_bytes" ] || [ "$bdp_bytes" -le 0 ]; then
        bdp_bytes=1048576  # 默认1MB
    fi
    
    log_debug "BDP计算: ${bandwidth_mbps}Mbps x ${rtt_ms}ms = $(echo "scale=2; $bdp_bytes/1024/1024" | bc)MB"
    
    # 内存限制 (TCP缓冲区不超过总内存的15%)
    local max_buffer_bytes=$((total_ram_mb * 1024 * 1024 * 15 / 100))
    
    # 接收缓冲区 = BDP x 倍数（根据网络类型调整）
    local rmem_multiplier=4
    if [ $bandwidth_mbps -ge 1000 ]; then
        rmem_multiplier=6  # 高带宽网络需要更大缓冲区
    elif [ $bandwidth_mbps -le 100 ]; then
        rmem_multiplier=2  # 低带宽网络缓冲区可以小一些
    fi
    
    local tcp_rmem_max=$((bdp_bytes * rmem_multiplier))
    
    # 发送缓冲区稍小于接收缓冲区
    local tcp_wmem_max=$((bdp_bytes * rmem_multiplier * 3 / 4))
    
    # 应用内存限制
    if [ $tcp_rmem_max -gt $max_buffer_bytes ]; then
        tcp_rmem_max=$max_buffer_bytes
    fi
    if [ $tcp_wmem_max -gt $max_buffer_bytes ]; then
        tcp_wmem_max=$max_buffer_bytes
    fi
    
    # 设置合理的最小值
    local min_rmem=$((16 * 1024 * 1024))  # 16MB
    local min_wmem=$((8 * 1024 * 1024))    # 8MB
    
    if [ $tcp_rmem_max -lt $min_rmem ]; then tcp_rmem_max=$min_rmem; fi
    if [ $tcp_wmem_max -lt $min_wmem ]; then tcp_wmem_max=$min_wmem; fi
    
    # 默认缓冲区大小（连接建立时的初始值）
    local tcp_rmem_default=$((tcp_rmem_max / 4))
    local tcp_wmem_default=$((tcp_wmem_max / 4))
    
    # 确保默认值在合理范围内
    if [ $tcp_rmem_default -lt 87380 ]; then tcp_rmem_default=87380; fi
    if [ $tcp_wmem_default -lt 65536 ]; then tcp_wmem_default=65536; fi
    if [ $tcp_rmem_default -gt 1048576 ]; then tcp_rmem_default=1048576; fi
    if [ $tcp_wmem_default -gt 524288 ]; then tcp_wmem_default=524288; fi
    
    # 网络队列参数
    local netdev_backlog=$((2048 * cpu_cores))
    if [ $netdev_backlog -lt 4096 ]; then netdev_backlog=4096; fi
    if [ $netdev_backlog -gt 30000 ]; then netdev_backlog=30000; fi
    
    local syn_backlog=$((netdev_backlog / 2))
    if [ $syn_backlog -lt 1024 ]; then syn_backlog=1024; fi
    
    echo "$tcp_rmem_max $tcp_wmem_max $tcp_rmem_default $tcp_wmem_default $netdev_backlog $syn_backlog"
}

# 模块 4: 智能TCP调优
intelligent_tcp_tuning() {
    log_info "正在进行智能TCP调优..."
    
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_mb=$((total_ram_kb / 1024))
    local cpu_cores=$(nproc)
    local cpu_freq=$(lscpu | grep "CPU MHz" | awk '{print int($3)}' 2>/dev/null || echo "未知")
    
    log_info "VPS配置: ${total_ram_mb}MB内存, ${cpu_cores}核CPU @ ${cpu_freq}MHz"
    
    read bandwidth_mbps avg_rtt network_interface <<< $(detect_network_performance)
    
    if [ $bandwidth_mbps -eq 0 ] || [ $bandwidth_mbps -gt 10000 ]; then
        log_warn "网络带宽检测异常，当前值: ${bandwidth_mbps}Mbps"
        echo ""
        echo "请选择获取带宽的方式："
        echo "1. 手动输入带宽值（推荐先用 speedtest-cli 或 iperf3 测速）"
        echo "2. 使用保守估算值 (500Mbps)"
        echo ""
        read -p "请输入选择 [1/2] (默认1): " bandwidth_choice
        
        if [[ "$bandwidth_choice" == "2" ]]; then
            bandwidth_mbps=500
            log_info "使用保守估算带宽: ${bandwidth_mbps}Mbps"
        else
            while true; do
                read -p "请输入实际带宽值 (Mbps, 建议先测速): " user_bandwidth
                if [[ "$user_bandwidth" =~ ^[0-9]+$ ]] && [ "$user_bandwidth" -gt 0 ] && [ "$user_bandwidth" -le 10000 ]; then
                    bandwidth_mbps=$user_bandwidth
                    break
                else
                    log_error "请输入1-10000之间的整数"
                fi
            done
            log_info "使用手动输入带宽: ${bandwidth_mbps}Mbps"
        fi
    fi
    
    log_info "网络参数: 带宽=${bandwidth_mbps}Mbps, 延迟=${avg_rtt}ms, 网卡=${network_interface:-auto}"
    
    read tcp_rmem_max tcp_wmem_max tcp_rmem_default tcp_wmem_default netdev_backlog syn_backlog <<< \
        $(calculate_tcp_buffers $bandwidth_mbps $avg_rtt $total_ram_mb $cpu_cores)
    
    log_info "智能计算的TCP参数:"
    log_info "├─ 接收缓冲区: 4KB / $(echo "scale=0; $tcp_rmem_default/1024" | bc)KB / $(echo "scale=1; $tcp_rmem_max/1024/1024" | bc)MB"
    log_info "├─ 发送缓冲区: 4KB / $(echo "scale=0; $tcp_wmem_default/1024" | bc)KB / $(echo "scale=1; $tcp_wmem_max/1024/1024" | bc)MB"
    log_info "├─ 网络队列: $netdev_backlog"
    log_info "└─ SYN队列: $syn_backlog"
    
    cat <<EOF > /etc/sysctl.d/99-intelligent-tcp-tuning.conf
# ===============================================
# 智能TCP调优配置
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# VPS配置: ${total_ram_mb}MB RAM, ${cpu_cores}核CPU
# 网络参数: ${bandwidth_mbps}Mbps带宽, ${avg_rtt}ms延迟
# ===============================================

# ============= 核心算法配置 =============
# BBR拥塞控制 + FQ公平队列
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ============= 智能缓冲区配置 =============
# 基于BDP(带宽×延迟)动态计算
# 格式: 最小值 默认值 最大值
net.ipv4.tcp_rmem = 4096 $tcp_rmem_default $tcp_rmem_max
net.ipv4.tcp_wmem = 4096 $tcp_wmem_default $tcp_wmem_max

# 核心网络缓冲区
net.core.rmem_max = $tcp_rmem_max
net.core.wmem_max = $tcp_wmem_max
net.core.rmem_default = $tcp_rmem_default
net.core.wmem_default = $tcp_wmem_default

# ============= 网络队列优化 =============
net.core.netdev_max_backlog = $netdev_backlog
net.ipv4.tcp_max_syn_backlog = $syn_backlog

# ============= TCP功能优化 =============
# 高性能特性
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1

# 超时优化
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_keepalive_probes = 9
net.ipv4.tcp_keepalive_intvl = 75

# 重传优化
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_orphan_retries = 3

# ============= 端口和内存管理 =============
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_orphans = $((total_ram_mb * 1024 / 2))
net.ipv4.tcp_mem = $((total_ram_kb/16)) $((total_ram_kb/8)) $((total_ram_kb/4))

# ============= 高级优化 =============
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_slow_start_after_idle = 0

# 拥塞窗口优化
net.ipv4.tcp_notsent_lowat = 16384

# ============= 安全优化 =============
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
EOF

    if sysctl --system > /dev/null 2>&1; then
        log_info "TCP优化配置已成功应用"
    else
        log_warn "配置应用时出现警告，但主要参数已生效"
    fi
    
    local current_bbr=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
    local current_fq=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
    
    if [ "$current_bbr" = "bbr" ] && [ "$current_fq" = "fq" ]; then
        log_info "✓ TCP优化验证成功: BBR + FQ 已启用"
    else
        log_warn "TCP优化可能未完全生效，请重启后检查"
    fi
    
    cat > /var/log/tcp-tuning.log <<EOF
TCP调优记录 - $(date)
========================================
系统信息:
- 内存: ${total_ram_mb}MB
- CPU: ${cpu_cores}核 @ ${cpu_freq}MHz
- 网络: ${bandwidth_mbps}Mbps, ${avg_rtt}ms延迟

缓冲区配置:
- 接收缓冲区最大: $(echo "scale=1; $tcp_rmem_max/1024/1024" | bc)MB
- 发送缓冲区最大: $(echo "scale=1; $tcp_wmem_max/1024/1024" | bc)MB
- 网络队列: $netdev_backlog
- SYN队列: $syn_backlog

配置文件: /etc/sysctl.d/99-intelligent-tcp-tuning.conf
EOF
    log_info "调优信息已保存到 /var/log/tcp-tuning.log"
}

# 模块 5: 配置 Swap
configure_swap() {
    log_info "正在配置 Swap 交换分区..."
    
    local total_ram_mb=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
    local recommended_swap=$((total_ram_mb > 4096 ? total_ram_mb : total_ram_mb * 2))
    local existing_swap=$(free -m | grep "Swap:" | awk '{print $2}')
    
    if [ "$existing_swap" -gt 0 ]; then
        log_info "检测到现有Swap: ${existing_swap}MB，推荐: ${recommended_swap}MB"
        
        # 即使现有Swap为推荐大小，也提供修改选项
        local default_action="保持现有Swap"
        if [ "$existing_swap" -eq "$recommended_swap" ]; then
            log_info "当前Swap大小已为推荐值。"
            read -p "是否重新配置Swap？[y/N] (默认N): " modify_swap
            if [[ "$modify_swap" != [yY] ]]; then
                log_info "保持现有Swap配置"
                return
            fi
        else
            log_info "当前Swap大小与推荐值不符。"
            read -p "是否重新配置Swap？[y/N] (默认y): " modify_swap
            if [[ "$modify_swap" != [yY] ]]; then
                log_info "保持现有Swap配置"
                return
            fi
        fi

        log_info "正在移除现有Swap..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        sed -i '/swapfile/d' /etc/fstab
    else
        log_info "当前无Swap，建议创建 ${recommended_swap}MB"
        read -p "是否创建Swap？[Y/n]: " create_swap
        if [[ "$create_swap" == [nN] ]]; then
            log_info "跳过Swap创建"
            return
        fi
    fi
    
    echo "推荐Swap大小: ${recommended_swap}MB"
    read -p "请输入Swap大小(MB) [默认${recommended_swap}]: " swap_size
    swap_size=${swap_size:-$recommended_swap}
    
    if ! [[ "$swap_size" =~ ^[0-9]+$ ]] || [ $swap_size -le 0 ]; then
        log_error "无效的Swap大小"
        return
    fi
    
    local available_space=$(df / | tail -1 | awk '{print int($4/1024)}')
    if [ $available_space -lt $swap_size ]; then
        log_error "磁盘空间不足，需要${swap_size}MB，可用${available_space}MB"
        return
    fi
    
    log_info "正在创建 ${swap_size}MB Swap文件..."
    fallocate -l ${swap_size}M /swapfile
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null
    swapon /swapfile
    
    if ! grep -q "/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    
    echo "vm.swappiness=10" > /etc/sysctl.d/99-swap.conf
    sysctl vm.swappiness=10
    
    log_info "Swap创建完成: $(free -m | grep Swap | awk '{print $2}')MB"
}

# 模块 6: SSH安全配置
configure_ssh_port() {
    log_info "正在配置SSH安全设置..."
    
    local current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null || echo "22")
    log_info "当前SSH端口: $current_port"
    
    read -p "是否修改SSH端口？[y/N]: " modify_ssh
    if [[ "$modify_ssh" != [yY] ]]; then
        log_info "保持SSH端口为 $current_port"
        return
    fi
    
    while true; do
        read -p "请输入新SSH端口 (1024-65535): " new_port
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [ $new_port -ge 1024 ] && [ $new_port -le 65535 ]; then
            break
        fi
        log_error "请输入1024-65535范围内的端口号"
    done
    
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
    
    if grep -q "^Port" /etc/ssh/sshd_config; then
        sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
    else
        echo "Port $new_port" >> /etc/ssh/sshd_config
    fi
    
    if sshd -t; then
        systemctl restart sshd
        log_info "SSH端口已修改为 $new_port"
        
        echo ""
        echo "=============================================="
        log_warn "重要提醒：请保持当前终端连接!"
        log_warn "请在新终端测试: ssh -p $new_port user@ip"
        log_warn "确认连接正常后再关闭此终端"
        echo "=============================================="
    else
        log_error "SSH配置测试失败，已恢复备份"
        cp "/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)" /etc/ssh/sshd_config
    fi
}

# 模块 7: 防火墙和安全配置
configure_security() {
    log_info "正在配置Fail2ban安全防护..."
    
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        if [ "$PKG_MANAGER" = "apt" ]; then
            apt install -y fail2ban iptables-persistent >/dev/null 2>&1
        elif [ "$PKG_MANAGER" = "yum" ]; then
            yum install -y epel-release >/dev/null 2>&1
            yum install -y fail2ban iptables-services >/dev/null 2>&1
        fi
        log_info "Fail2ban安装完成"
    else
        log_info "Fail2ban已安装"
    fi
    
    local ssh_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null || echo "22")
    
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
banaction = iptables-multiport
banaction_allports = iptables-allports

[sshd]
enabled = true
port = $ssh_port
filter = sshd
backend = auto
logpath = /var/log/auth.log
maxretry = 3
findtime = 600
bantime = 3600
EOF

    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban
    sleep 2
    
    log_info "Fail2ban配置完成"
    
    if systemctl is-active --quiet fail2ban; then
        log_info "Fail2ban状态: $(systemctl is-active fail2ban)"
        fail2ban-client status 2>/dev/null || true
    else
        log_warn "Fail2ban启动失败，请检查日志"
    fi
}

# 性能优化建议
show_optimization_tips() {
    log_info "性能优化建议:"
    echo ""
    echo "1. 网络测试命令:"
    echo "    # 带宽测试"
    echo "    wget -O /dev/null http://speedtest.tele2.net/100MB.zip"
    echo "    # iperf3测试"
    echo "    服务器端: iperf3 -s"
    echo "    客户端: iperf3 -c 服务器IP -t 30 -P 4"
    echo ""
    echo "2. TCP状态监控:"
    echo "    # 查看连接状态"
    echo "    ss -tuln"
    echo "    # 监控重传"
    echo "    watch -n 1 'cat /proc/net/netstat | grep TcpExt'"
    echo "    # 查看拥塞窗口"
    echo "    ss -i"
    echo ""
    echo "3. 系统性能监控:"
    echo "    # 实时监控"
    echo "    htop"
    echo "    # 网络IO监控"
    echo "    nethogs"
    echo "    # 磁盘IO监控"  
    echo "    iotop"
    echo ""
    echo "4. 配置文件位置:"
    echo "    - TCP优化: /etc/sysctl.d/99-intelligent-tcp-tuning.conf"
    echo "    - 调优日志: /var/log/tcp-tuning.log"
    echo "    - SSH配置: /etc/ssh/sshd_config"
    echo "    - Fail2ban: /etc/fail2ban/jail.local"
}

# 系统信息总结
print_system_summary() {
    log_info "系统配置总结:"
    echo ""
    echo "=========================================="
    echo "系统信息:"
    echo "  操作系统: $(lsb_release -d 2>/dev/null | cut -f2 || echo "$OS $OS_VERSION")"
    echo "  内核版本: $(uname -r)"
    echo "  内存大小: $(free -h | grep Mem | awk '{print $2}')"
    echo "  CPU信息: $(nproc)核心"
    echo "  磁盘空间: $(df -h / | tail -1 | awk '{print $4}') 可用"
    echo ""
    echo "网络优化:"
    local bbr_status=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "未知")
    local fq_status=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}' || echo "未知")
    echo "  拥塞控制: $bbr_status"
    echo "  队列调度: $fq_status"
    echo "  接收缓冲: $(sysctl net.core.rmem_max 2>/dev/null | awk '{print int($3/1024/1024)}')MB"
    echo "  发送缓冲: $(sysctl net.core.wmem_max 2>/dev/null | awk '{print int($3/1024/1024)}')MB"
    echo ""
    echo "安全配置:"
    local ssh_port=$(grep "^Port" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    echo "  SSH端口: $ssh_port"
    echo "  Fail2ban: $(systemctl is-active fail2ban 2>/dev/null || echo "未知")"
    echo "  Swap大小: $(free -h | grep Swap | awk '{print $2}' || echo "0")"
    echo "=========================================="
}

# 主菜单
main_menu() {
    echo ""
    echo "================================================="
    echo "          VPS 智能配置脚本 v3.3"
    echo "================================================="
    echo ""
    echo "请选择需要执行的操作："
    echo ""
    echo "  1. -> 一键完整配置 (推荐)"
    echo "  2. -> 更新系统并安装工具"
    echo "  3. -> 智能TCP网络优化"
    echo "  4. -> 配置Swap交换分区"
    echo "  5. -> SSH安全端口配置"
    echo "  6. -> 安装Fail2ban防护"
    echo "  7. -> 显示系统信息"
    echo "  8. -> 性能优化建议"
    echo "  0. -> 退出脚本"
    echo ""
    echo "================================================="
    read -p "请输入选择 [0-8] (默认1): " choice
    choice=${choice:-1}
    
    case "$choice" in
        1)
            log_info "开始执行完整配置流程..."
            detect_system
            update_system
            install_common_tools
            set_timezone
            intelligent_tcp_tuning
            configure_swap
            configure_ssh_port
            configure_security
            print_system_summary
            show_optimization_tips
            log_info "🎉 完整配置完成！建议重启系统以确保所有优化生效。"
            ;;
        2)
            detect_system
            update_system
            install_common_tools
            log_info "系统更新和工具安装完成"
            ;;
        3)
            detect_system
            install_common_tools
            intelligent_tcp_tuning
            log_info "TCP网络优化完成"
            ;;
        4)
            configure_swap
            log_info "Swap配置完成"
            ;;
        5)
            configure_ssh_port
            log_info "SSH配置完成"
            ;;
        6)
            detect_system
            configure_security
            log_info "安全防护配置完成"
            ;;
        7)
            detect_system
            print_system_summary
            ;;
        8)
            show_optimization_tips
            ;;
        0)
            log_info "退出脚本，未执行任何操作"
            exit 0
            ;;
        *)
            log_error "无效选择，请重新运行脚本"
            exit 1
            ;;
    esac
}

# ===============================================
# 脚本入口
# ===============================================
main_menu
