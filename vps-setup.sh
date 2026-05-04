#!/usr/bin/env bash
# =============================================================================
#  VPS 初始化脚本 — Debian 12 专用
#  场景：nginx 443 反代后端容器（127.0.0.1:port），无 ufw
#  目录规范：所有数据统一存放于 /data_back/
#  执行方式：
#    curl -fsSL https://raw.githubusercontent.com/wio-ki/vps-setup/main/vps-setup.sh | tr -d '\r' | bash
# =============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "请以 root 身份运行此脚本"

# ── 全程记录日志 ──────────────────────────────────────────────────────────────
mkdir -p /data_back/scripts
LOG_FILE=/data_back/scripts/install-$(date +%Y%m%d-%H%M%S).log
exec > >(tee -a "$LOG_FILE") 2>&1
info "安装日志保存至：$LOG_FILE"

# ── 确认 Debian 12 ────────────────────────────────────────────────────────────
source /etc/os-release
[[ "$ID" == "debian" && "$VERSION_ID" == "12" ]] \
    || die "此脚本仅支持 Debian 12，当前系统：$PRETTY_NAME"

# =============================================================================
# 1. 更新系统 & 安装基础工具 & 配置 SSH
# =============================================================================
section_1() {
    info "━━━ [1/8] 更新系统软件包 & 配置 SSH ━━━"
    apt-get update -y
    apt-get -y $APT_OPTS upgrade
    apt-get -y $APT_OPTS install \
        sudo curl wget nano gnupg2 ca-certificates \
        lsb-release debian-archive-keyring apt-transport-https \
        openssl unzip socat cron
    ok "系统更新 & 基础工具安装完成"

    info "配置 SSH 端口 → 61692 & keepalive..."
    SSHD_CONF=/etc/ssh/sshd_config
    sed -i "/^#*Port /d"              "$SSHD_CONF"
    sed -i "/^ClientAliveInterval/d"  "$SSHD_CONF"
    sed -i "/^ClientAliveCountMax/d"  "$SSHD_CONF"
    cat >> "$SSHD_CONF" <<'EOF'
Port 61692
ClientAliveInterval 60
ClientAliveCountMax 10
EOF
    # 验证配置再 reload，避免改坏了锁死自己
    sshd -t || die "sshd_config 语法错误，已中止"
    systemctl reload sshd
    ok "SSH 端口已改为 61692，keepalive 60s × 10次"
    warn "下次登录请用：ssh root@<IP> -p 61692"
}

# =============================================================================
# 2. 校正时区为上海
# =============================================================================
section_2() {
    info "━━━ [2/8] 设置时区 → Asia/Shanghai ━━━"
    timedatectl set-timezone Asia/Shanghai
    ok "当前时间：$(date)"
}

# =============================================================================
# 3. 创建统一目录结构
# =============================================================================
section_3() {
    info "━━━ [3/8] 创建 /data_back/ 目录结构 ━━━"
    mkdir -p /data_back/nginx/{conf.d,ssl,logs}
    mkdir -p /data_back/compose
    mkdir -p /data_back/scripts
    ok "/data_back/ 目录结构已创建"
}

# =============================================================================
# 4. 安装 Docker（官方 apt 仓库）
# =============================================================================
section_4() {
    info "━━━ [4/8] 安装 Docker ━━━"

    apt-get remove -y docker.io docker-compose docker-doc podman-docker \
        containerd runc 2>/dev/null || true

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get -y $APT_OPTS install \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker
    docker --version
    docker compose version
    ok "Docker 安装完成"
}


# =============================================================================
# 5. 安装 sing-box（docker compose）
# =============================================================================
section_5() {
    info "━━━ [5/8] 安装 sing-box（docker compose）━━━"

    mkdir -p /data_back/compose/sing-box/data
    : > /data_back/compose/sing-box/config.json
    cat > /data_back/compose/sing-box/docker-compose.yml <<'YAML'
services:
  sing-box:
    image: ghcr.io/sagernet/sing-box
    container_name: sing-box
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./:/etc/sing-box/
      - /data_back/nginx/ssl:/data_back/nginx/ssl:ro
    command: -D /etc/sing-box/data -C /etc/sing-box/ run
YAML
}

# =============================================================================
# 6. 安装 Nginx（官方稳定版），配置目录指向 /data_back/nginx/
#    场景：纯反代，监听 443，后端均为 127.0.0.1:port
# =============================================================================
section_6() {
    info "━━━ [6/8] 安装 Nginx（官方稳定版）━━━"

    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor \
        | tee /usr/share/keyrings/nginx-archive-keyring.gpg > /dev/null

    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
https://nginx.org/packages/debian ${VERSION_CODENAME} nginx" \
        | tee /etc/apt/sources.list.d/nginx.list > /dev/null

    # 优先使用 nginx.org 官方包，防止被 Debian 默认包覆盖
    cat > /etc/apt/preferences.d/99nginx <<'EOF'
Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: 900
EOF

    apt-get update -y
    apt-get -y $APT_OPTS install nginx
    nginx -v

    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
    mkdir -p /data_back/nginx/{conf.d,ssl,logs}

    # ── 写 nginx.conf ──────────────────────────────────────────────────────────
    # 注意：
    #   - user nginx      → 官方 nginx.org 包创建的用户（非 www-data）
    #   - real_ip         → 从 X-Forwarded-For 还原真实 IP（CDN/反代场景）
    #   - log_format      → 包含 $http_x_forwarded_for 便于溯源
    #   - map $http_upgrade → 供 conf.d 里的 WebSocket 服务使用：
    #                         proxy_set_header Upgrade    $http_upgrade;
    #                         proxy_set_header Connection $connection_upgrade;
    cat > /etc/nginx/nginx.conf <<'NGINXCONF'
user nginx;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    server_tokens   off;

    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    # ── 真实 IP（适用于本机即为终点，如有上层 CDN 按需修改 set_real_ip_from）──
    real_ip_header     X-Forwarded-For;
    real_ip_recursive  on;

    # ── 日志格式（含真实 IP 与 upstream 耗时）────────────────────────────────
    log_format main '$remote_addr - $http_x_forwarded_for [$time_local] '
                    '"$request" $status $body_bytes_sent '
                    '"$http_referer" "$http_user_agent" '
                    'upstream=$upstream_addr rt=$request_time';

    access_log  /data_back/nginx/logs/access.log main;
    error_log   /data_back/nginx/logs/error.log warn;

    # ── Gzip ──────────────────────────────────────────────────────────────────
    gzip              on;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_comp_level   6;
    gzip_types        text/plain text/css text/xml application/json
                      application/javascript application/xml+rss
                      application/atom+xml image/svg+xml;

    # ── SSL 全局设置 ──────────────────────────────────────────────────────────
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_stapling        on;
    ssl_stapling_verify on;

    # ── WebSocket 升级映射（在 conf.d 反代配置里这样使用）────────────────────
    #    proxy_set_header Upgrade    $http_upgrade;
    #    proxy_set_header Connection $connection_upgrade;
    map $http_upgrade $connection_upgrade {
        default  upgrade;
        ''       close;
    }

    # ── 站点配置从 /data_back/nginx/conf.d/ 加载 ─────────────────────────────
    include /data_back/nginx/conf.d/*.conf;
}
NGINXCONF

    nginx -t || die "nginx.conf 语法错误，已中止"
    systemctl enable nginx
    systemctl restart nginx
    ok "Nginx 安装完成，站点配置目录 → /data_back/nginx/conf.d/"

    # ── 证书目录提示 ──────────────────────────────────────────────────────────
    info "SSL 证书目录：/data_back/nginx/ssl/"
    info "别忘了使用 acme.sh 申请证书"
}

# =============================================================================
# 7. 配置 Swap（按内存自动计算）
# =============================================================================
section_7() {
    info "━━━ [7/8] 配置 Swap ━━━"

    if swapon --show | grep -q '/'; then
        warn "已存在 swap，跳过：$(swapon --show)"
        return
    fi

    MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    info "物理内存：${MEM_MB} MB"

    if [[ $MEM_MB -le 1024 ]]; then
        SWAP_MB=$((MEM_MB * 2))
        info "低配机器，Swap = 2× = ${SWAP_MB} MB"
    else
        SWAP_MB=$MEM_MB
        info "Swap = 1× = ${SWAP_MB} MB"
    fi

    SWAP_FILE=/swapfile
    # fallocate 在 btrfs 等 CoW 文件系统上会失败，fallback 到 dd
    fallocate -l "${SWAP_MB}M" "$SWAP_FILE" 2>/dev/null \
        || dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$SWAP_MB" status=progress
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"

    grep -q "$SWAP_FILE" /etc/fstab \
        || echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab

    swapon --show
    free -h
    ok "Swap ${SWAP_MB} MB 创建完成"
}

# =============================================================================
# 8. 开启 BBR + fq，验证后自动重启
# =============================================================================
section_8() {
    info "━━━ [8/8] 开启 BBR + fq 拥塞控制 ━━━"

    cat > /etc/sysctl.d/99-bbr.conf <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
vm.swappiness = 10
SYSCTL

    sysctl --system

    CC=$(sysctl -n net.ipv4.tcp_congestion_control)
    QD=$(sysctl -n net.core.default_qdisc)
    [[ "$CC" == "bbr" ]] || warn "BBR 未生效（当前：${CC}），请确认内核 ≥ 4.9"
    ok "拥塞控制：${CC}，队列调度：${QD}"

    # 重启前最终验证
    nginx -t || die "nginx 配置有误，已中止重启，请检查后手动 reboot"
    sshd -t  || die "sshd 配置有误，已中止重启，请检查后手动 reboot"

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  安装日志已保存至：$LOG_FILE${NC}"
    echo -e "${YELLOW}  VPS 将在 10 秒后自动重启...${NC}"
    echo -e "${YELLOW}  重启后请用新端口登录：ssh root@<IP> -p 61692${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    sleep 10
    reboot
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         VPS 初始化脚本  —  Debian 12  —  /data_back/        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    section_1   # 更新系统 & 配置 SSH
    section_2   # 设置时区
    section_3   # 创建目录结构
    section_4   # 安装 Docker
    section_5   # 安装 sing-box
    section_6   # 安装 Nginx
    section_7   # 配置 Swap
    section_8   # BBR + 重启
}

main "$@"
