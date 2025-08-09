#!/bin/bash

# ===============================================
# VPS 一键配置和调优脚本
# 作者：改进版
# 版本：2.8
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

# ===============================================
# 模块化功能函数定义
# ===============================================

# 模块 1: 更新系统软件包
update_system() {
    echo "---"
    echo ">> [任务] 正在更新软件包列表并更新已安装软件..."
    export DEBIAN_FRONTEND=noninteractive
    apt update -y
    apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
    if [ -f /var/run/reboot-required ]; then
        echo "    ⚠️  检测到系统更新需要重启才能完全生效"
        echo "    - 建议在脚本执行完成后重启系统"
    fi
    apt autoremove -y > /dev/null 2>&1
    apt autoclean > /dev/null 2>&1
    unset DEBIAN_FRONTEND
    echo "✓ 系统更新完成。"
}

# 模块 2: 安装常用工具
install_common_tools() {
    echo "---"
    echo ">> [任务] 正在安装常用软件（sudo, curl, wget, nano, vim, iproute2, bc）..."
    apt install -y sudo curl wget nano vim iproute2 bc > /dev/null 2>&1
    echo "✓ 常用软件安装完成。"
}

# 模块 3: 设置系统时区
set_timezone() {
    echo "---"
    echo ">> [任务] 正在设置系统时区为 Asia/Shanghai..."
    timedatectl set-timezone Asia/Shanghai
    echo "✓ 时区设置完成。当前时区为：$(timedatectl | grep "Time zone" | awk '{print $3}')"
}

# 模块 4: 智能TCP调优
intelligent_tcp_tuning() {
    echo "---"
    echo ">> [任务] 正在进行智能系统调优（BBR + FQ + 动态TCP缓冲区计算）..."
    
    total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_ram_mb=$((total_ram_kb / 1024))
    cpu_cores=$(nproc)

    echo "VPS基础配置信息："
    echo "  - 内存：${total_ram_mb} MB"
    echo "  - CPU核心：${cpu_cores} 核"

    echo ""
    echo ">> 正在检测网络性能参数..."

    detected_bandwidth_mbps=0
    for interface in $(ls /sys/class/net/ | grep -E '^(eth|ens|enp|venet)'); do
        speed=$(cat /sys/class/net/$interface/speed 2>/dev/null)
        if [ "$speed" != "-1" ] && [ ! -z "$speed" ] && [ "$speed" -gt 0 ]; then
            detected_bandwidth_mbps=$speed
            break
        fi
    done

    echo "  - 正在检测网络延迟..."
    avg_rtt=0
    rtt_samples=0
    test_targets=("8.8.8.8" "1.1.1.1" "114.114.114.114")
    for target in "${test_targets[@]}"; do
        rtt=$(ping -c 2 -W 2 "$target" 2>/dev/null | grep "avg" | awk -F'/' '{print int($5)}' 2>/dev/null)
        if [ ! -z "$rtt" ] && [ "$rtt" -gt 0 ]; then
            avg_rtt=$((avg_rtt + rtt))
            rtt_samples=$((rtt_samples + 1))
        fi
    done
    if [ "$rtt_samples" -gt 0 ]; then
        avg_rtt=$((avg_rtt / rtt_samples))
    else
        avg_rtt=50
    fi

    echo ""
    echo ">> 正在计算最优TCP缓冲区参数..."
    final_bandwidth_mbps=$detected_bandwidth_mbps

    # 如果网卡速度无法检测，提供手动输入或内存估算选项
    if [ "$final_bandwidth_mbps" -eq 0 ]; then
        echo "  - 无法自动检测到网卡速度。"
        echo ""
        echo "请选择获取带宽的方式："
        echo "1. 手动输入带宽值（推荐使用 iperf3 的测速结果）"
        echo "2. 使用内存大小进行估算"
        echo ""
        read -p "请输入您的选择 [1/2] (回车默认选择1): " bandwidth_choice
        
        if [[ "$bandwidth_choice" == "1" || "$bandwidth_choice" == "" ]]; then
            while true; do
                read -p "请输入您的VPS实际带宽值 (Mbps): " user_bandwidth
                if [[ "$user_bandwidth" =~ ^[0-9]+$ ]] && [ "$user_bandwidth" -gt 0 ]; then
                    final_bandwidth_mbps=$user_bandwidth
                    break
                else
                    echo "输入无效，请输入一个大于 0 的整数。"
                fi
            done
            echo "  - 已使用手动输入的带宽：${final_bandwidth_mbps} Mbps"
        else
            if [ $total_ram_mb -le 512 ]; then final_bandwidth_mbps=100;
            elif [ $total_ram_mb -le 1024 ]; then final_bandwidth_mbps=200;
            elif [ $total_ram_mb -le 4096 ]; then final_bandwidth_mbps=500;
            else final_bandwidth_mbps=1000; fi
            echo "  - 已使用内存估算带宽：${final_bandwidth_mbps} Mbps"
        fi
    fi

    echo "  - 估算带宽：${final_bandwidth_mbps} Mbps"
    echo "  - 平均延迟：${avg_rtt} ms"

    bandwidth_bps=$((final_bandwidth_mbps * 1000 * 1000))
    rtt_seconds=$(echo "scale=6; $avg_rtt / 1000" | bc -l)
    bdp_bytes=$(echo "scale=0; ($bandwidth_bps * $rtt_seconds) / 8" | bc -l)
    if ! [[ "$bdp_bytes" =~ ^[0-9]+$ ]] || [ "$bdp_bytes" -le 0 ]; then
        bdp_bytes=$((100 * 1000 * 1000 * 50 / 1000 / 8))
    fi

    tcp_rmem_max=$((bdp_bytes * 2))
    tcp_wmem_max=$((bdp_bytes * 3 / 2))
    max_buffer_bytes=$((total_ram_kb * 1024 / 10))
    if [ "$tcp_rmem_max" -gt "$max_buffer_bytes" ]; then tcp_rmem_max=$max_buffer_bytes; fi
    if [ "$tcp_wmem_max" -gt "$max_buffer_bytes" ]; then tcp_wmem_max=$max_buffer_bytes; fi
    min_buffer_bytes=$((16 * 1024 * 1024))
    if [ "$tcp_rmem_max" -lt "$min_buffer_bytes" ]; then tcp_rmem_max=$min_buffer_bytes; fi
    if [ "$tcp_wmem_max" -lt "$min_buffer_bytes" ]; then tcp_wmem_max=$min_buffer_bytes; fi
    tcp_rmem_default=$((tcp_rmem_max / 3))
    tcp_wmem_default=$((tcp_wmem_max / 3))

    netdev_backlog=$((1000 * cpu_cores))
    if [ "$netdev_backlog" -lt 2048 ]; then netdev_backlog=2048; fi
    syn_backlog=$((netdev_backlog * 2))

    echo ">> 智能计算的优化参数："
    echo "  - TCP接收缓冲区：最小 4KB，默认 $(echo "scale=0; $tcp_rmem_default / 1024" | bc -l)KB，最大 $(echo "scale=1; $tcp_rmem_max / 1024 / 1024" | bc -l)MB"
    echo "  - TCP发送缓冲区：最小 4KB，默认 $(echo "scale=0; $tcp_wmem_default / 1024" | bc -l)KB，最大 $(echo "scale=1; $tcp_wmem_max / 1024 / 1024" | bc -l)MB"
    echo "  - 网络设备队列：$netdev_backlog"
    echo "  - SYN队列大小：$syn_backlog"

    cat <<EOF > /etc/sysctl.d/99-vps-tuning.conf
# ===============================================
# 智能TCP调优配置
# 基于VPS性能动态计算生成
# ===============================================
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_rmem = 4096 $tcp_rmem_default $tcp_rmem_max
net.ipv4.tcp_wmem = 4096 $tcp_wmem_default $tcp_wmem_max
net.core.rmem_max = $tcp_rmem_max
net.core.wmem_max = $tcp_wmem_max
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_max_syn_backlog = $syn_backlog
net.core.netdev_max_backlog = $netdev_backlog
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_rfc1337 = 1
EOF

    sysctl --system > /dev/null 2>&1
    echo "✓ 智能TCP调优参数已应用。"
    echo "当前拥塞控制算法：$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}')"
    echo "当前队列调度算法：$(sysctl net.core.default_qdisc | awk '{print $3}')"
}

# 模块 5: 配置 Swap 大小
configure_swap() {
    echo "---"
    echo ">> [任务] 正在配置 Swap 交换分区..."
    total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    total_ram_mb=$((total_ram_kb / 1024))
    recommended_swap=$((total_ram_mb * 2))
    existing_swap=$(free -m | grep "Swap:" | awk '{print $2}')
    
    if [ "$existing_swap" -gt 0 ]; then
        echo "检测到系统已有 ${existing_swap} MB 的 Swap，推荐大小为 ${recommended_swap} MB。"
        
        echo ""
        read -p "当前Swap大小已为推荐值，是否要修改？[y/N] (回车默认不修改): " modify_swap
        
        if [[ "$modify_swap" == "y" || "$modify_swap" == "Y" ]]; then
            echo ""
            echo "请选择："
            echo "1. 移除现有 Swap，创建推荐大小 (${recommended_swap} MB) 的新 Swap [默认]"
            echo "2. 移除现有 Swap，自定义新 Swap 大小"
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
        else
            echo "✓ 保持现有 Swap 配置，跳过修改。"
            echo "当前 Swap 大小：$(free -m | grep "Swap:" | awk '{print $2}') MB"
            return
        fi

        echo ">> 正在移除现有 Swap 分区..."
        swapoff /swapfile > /dev/null 2>&1
        rm -f /swapfile > /dev/null 2>&1
        sed -i '/swapfile/d' /etc/fstab > /dev/null 2>&1
        echo "✓ 现有 Swap 已移除。"
    else
        echo "当前 VPS 没有 Swap 交换分区。"
        echo "当前 VPS 的物理内存 (RAM) 为：${total_ram_mb} MB"
        echo "建议创建 Swap 大小：${recommended_swap} MB (RAM 的 2 倍)"
        echo ""
        read -p "是否创建 Swap？[Y/n] (回车默认创建): " create_swap_choice
        
        if [[ "$create_swap_choice" == "n" || "$create_swap_choice" == "N" ]]; then
            echo "✓ 跳过创建 Swap。"
            return
        fi
        
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
    fi
    
    echo ">> 正在创建 ${swap_size_mb} MB 的 Swap 文件..."
    swap_file_path="/swapfile"
    fallocate -l ${swap_size_mb}M $swap_file_path
    chmod 600 $swap_file_path
    mkswap $swap_file_path > /dev/null
    swapon $swap_file_path
    if ! grep -q "$swap_file_path" /etc/fstab; then
        echo "$swap_file_path none swap sw 0 0" >> /etc/fstab
    fi
    sysctl vm.swappiness=10 > /dev/null
    if ! grep -q "vm.swappiness=10" /etc/sysctl.conf; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
    fi
    echo "✓ Swap 交换分区创建完成。"
    echo "当前 Swap 大小：$(free -m | grep "Swap:" | awk '{print $2}') MB"
}

# 模块 6: 修改 SSH 端口
configure_ssh_port() {
    echo "---"
    echo ">> [任务] 正在配置 SSH 端口..."
    current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null)
    if [ -z "$current_port" ]; then current_port="22"; fi
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
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)
        if grep -q "^Port" /etc/ssh/sshd_config; then
            sed -i "s/^Port .*/Port $new_port/" /etc/ssh/sshd_config
        elif grep -q "^#Port 22" /etc/ssh/sshd_config; then
            sed -i "s/^#Port 22/Port $new_port/" /etc/ssh/sshd_config
        else
            echo "Port $new_port" >> /etc/ssh/sshd_config
        fi
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
        else
            echo "✗ SSH 配置有误，恢复备份..."
            cp /etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S) /etc/ssh/sshd_config
            echo "SSH 配置已恢复，端口保持为 $current_port"
        fi
    else
        echo "✓ SSH 端口保持为 $current_port"
    fi
}

# 模块 7: 安装和配置 Fail2ban
configure_fail2ban() {
    echo "---"
    echo ">> [任务] 正在安装和配置 Fail2ban..."
    if ! command -v fail2ban-server >/dev/null 2>&1; then
        apt install -y fail2ban > /dev/null 2>&1
        echo "✓ Fail2ban 安装完成。"
    else
        echo "✓ Fail2ban 已安装。"
    fi
    ssh_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null)
    if [ -z "$ssh_port" ]; then ssh_port="ssh"; else ssh_port="$ssh_port"; fi
    cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 1d
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
banaction = iptables-multiport
mta = sendmail
[sshd]
enabled = true
port = $ssh_port
filter = sshd
backend = auto
maxretry = 3
findtime = 600
bantime = 3600
EOF
    echo "✓ Fail2ban 配置文件创建完成。"
    systemctl enable fail2ban > /dev/null 2>&1
    systemctl restart fail2ban
    sleep 2
    echo "✓ Fail2ban 服务已启动。"
    echo ">> Fail2ban 状态检查："
    systemctl status fail2ban --no-pager -l
    echo ""
    echo ">> Fail2ban 活动监狱："
    fail2ban-client status
}

# 模块 8: 完成总结
print_summary() {
    echo ""
    echo "---"
    echo ">> [任务] 配置完成！"
    echo "---"
    echo "✅ 配置总结："
    echo "    - 系统已更新并安装常用软件"
    echo "    - 时区已设置为 Asia/Shanghai"
    echo "    - 系统已启用智能TCP调优，并开启BBR"
    echo "    - Swap 交换分区已配置"
    current_port=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null)
    if [ -z "$current_port" ]; then current_port="22"; fi
    echo "    - SSH 端口已配置为 $current_port"
    echo "    - Fail2ban 已安装并配置完成"
    echo ""
    echo "🎉 VPS 配置完成！建议重启系统以确保所有设置生效。"
    echo "---"
}

# ===============================================
# 主菜单逻辑
# ===============================================
main_menu() {
    echo ""
    echo "---"
    echo "欢迎使用 VPS 自动配置脚本，请选择需要执行的操作："
    echo "1. 一键执行脚本所有内容（推荐）"
    echo "2. 更新软件包并安装常用软件"
    echo "3. 智能系统调优（TCP调优/开启BBR/开启FQ）"
    echo "4. 配置 Swap 交换分区"
    echo "5. 修改 SSH 端口"
    echo "6. 安装并配置 Fail2ban"
    echo "0. 退出脚本"
    echo "---"
    read -p "请输入您的选择 [1-6] (回车默认选择1): " choice

    case "$choice" in
        1 | "")
            update_system
            install_common_tools
            set_timezone
            intelligent_tcp_tuning
            configure_swap
            configure_ssh_port
            configure_fail2ban
            print_summary
            ;;
        2)
            update_system
            install_common_tools
            echo "✓ 软件包更新和软件安装任务完成。"
            ;;
        3)
            install_common_tools
            intelligent_tcp_tuning
            echo "✓ 智能TCP调优任务完成。"
            ;;
        4)
            configure_swap
            echo "✓ Swap 交换分区配置任务完成。"
            ;;
        5)
            configure_ssh_port
            echo "✓ SSH 端口配置任务完成。"
            ;;
        6)
            configure_fail2ban
            echo "✓ Fail2ban 配置任务完成。"
            ;;
        0)
            echo "退出脚本，未执行任何操作。"
            exit 0
            ;;
        *)
            echo "无效的选择，请重新运行脚本并输入正确的选项。"
            exit 1
            ;;
    esac
}

main_menu

