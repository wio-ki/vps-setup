#!/usr/bin/env bash
# =============================================================================
#  VPS 初始化脚本 — Debian 12 专用
#  目录规范：所有数据统一存放于 /data_back/
#  GitHub: https://github.com/wio-ki/vps-setup
#  执行方式（VPS 上运行，tr -d '\r' 防止 Windows 换行符问题）：
#    curl -fsSL https://raw.githubusercontent.com/wio-ki/vps-setup/main/vps-setup.sh | tr -d '\r' | bash
# =============================================================================
set -euo pipefail

# ── 全程非交互式，防止 dpkg conffile 交互提示卡住脚本 ───────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*"; exit 1; }

# ── 必须以 root 运行 ──────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "请以 root 身份运行此脚本"

# =============================================================================
# 1. 更新系统 & 安装基础工具
# =============================================================================
section_1() {
    info "━━━ [1/7] 更新系统软件包 & 配置 SSH ━━━"
    apt-get update -y
    apt-get -y $APT_OPTS upgrade
    apt-get -y $APT_OPTS install \
        sudo curl wget nano gnupg2 ca-certificates \
        lsb-release debian-archive-keyring apt-transport-https \
        openssl unzip socat cron
    ok "系统更新 & 基础工具安装完成"

    # ── SSH 端口 + keepalive ───────────────────────────────────────────────────
    info "配置 SSH 端口 → 61692 & keepalive..."
    SSHD_CONF=/etc/ssh/sshd_config
    # 端口
    sed -i "/^#*Port /d" "$SSHD_CONF"
    echo "Port 61692" >> "$SSHD_CONF"
    # keepalive
    sed -i "/^ClientAliveInterval/d" "$SSHD_CONF"
    sed -i "/^ClientAliveCountMax/d" "$SSHD_CONF"
    echo "ClientAliveInterval 60" >> "$SSHD_CONF"
    echo "ClientAliveCountMax 10" >> "$SSHD_CONF"
    systemctl reload sshd
    ok "SSH 端口已改为 61692，keepalive 60s × 10次"
    echo -e "\033[1;33m[重要] SSH 端口已改为 61692，当前连接不受影响，下次登录请用新端口！\033[0m"
}

# =============================================================================
# 2. 校正时区为上海
# =============================================================================
section_2() {
    info "━━━ [2/7] 设置时区 → Asia/Shanghai ━━━"
    timedatectl set-timezone Asia/Shanghai
    ok "当前时间：$(date)"
}

# =============================================================================
# 3. 创建统一目录结构
# =============================================================================
section_3() {
    info "━━━ [3/7] 创建 /data_back/ 目录结构 ━━━"
    mkdir -p /data_back/nginx/conf.d    # nginx 站点配置
    mkdir -p /data_back/nginx/ssl        # SSL 证书
    mkdir -p /data_back/nginx/logs       # nginx 日志
    mkdir -p /data_back/compose          # 各服务 docker compose 文件
    mkdir -p /data_back/scripts          # 运维脚本
    ok "/data_back/ 目录结构已创建"
    ls -R /data_back/
}

# =============================================================================
# 4. 安装 Docker（官方 apt 仓库，最新稳定版）+ 创建示例 compose 文件
# =============================================================================
section_4() {
    info "━━━ [4/7] 安装 Docker ━━━"

    # 移除旧版冲突包
    apt-get remove -y docker.io docker-compose docker-doc podman-docker \
        containerd runc 2>/dev/null || true

    # 导入 Docker GPG 密钥
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # 添加官方仓库
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y
    apt-get -y $APT_OPTS install \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl start docker

    docker --version
    docker compose version

    # 创建空白示例 compose 文件
    cat > /data_back/compose/docker-compose.yml <<'EOF'
# =============================================================================
# 全局 Docker Compose 示例文件
# 新增服务请在此文件继续添加，或在 /data_back/compose/ 下新建子目录
# =============================================================================
# services:
#   example:
#     image: nginx:alpine
#     restart: unless-stopped
#     ports:
#       - "8080:80"
#     volumes:
#       - /data_back/nginx:/etc/nginx
EOF

    ok "Docker 安装完成，示例文件 → /data_back/compose/docker-compose.yml"
}

# =============================================================================
# 5. 安装最新版 Nginx（官方稳定版仓库），配置目录指向 /data_back/nginx/
# =============================================================================
section_5() {
    info "━━━ [5/7] 安装 Nginx（官方稳定版）━━━"

    # 导入 nginx 官方签名密钥
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor \
        | tee /usr/share/keyrings/nginx-archive-keyring.gpg > /dev/null

    # 添加稳定版仓库
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
https://nginx.org/packages/debian $(lsb_release -cs) nginx" \
        | tee /etc/apt/sources.list.d/nginx.list > /dev/null

    # 优先使用 nginx.org 官方仓库
    printf 'Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n' \
        | tee /etc/apt/preferences.d/99nginx > /dev/null

    apt-get update -y
    apt-get -y $APT_OPTS install nginx

    nginx -v

    # 备份原始配置
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig

    # 确保目录存在
    mkdir -p /data_back/nginx/{conf.d,ssl,logs}

    # 写新的 nginx.conf，include 指向 /data_back/nginx/conf.d/
    cat > /etc/nginx/nginx.conf <<'NGINXCONF'
user www-data;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    server_tokens       off;

    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    # 日志统一到 /data_back/nginx/logs/
    access_log  /data_back/nginx/logs/access.log;
    error_log   /data_back/nginx/logs/error.log warn;

    # Gzip
    gzip              on;
    gzip_vary         on;
    gzip_proxied      any;
    gzip_comp_level   6;
    gzip_types        text/plain text/css text/xml application/json
                      application/javascript application/xml+rss
                      application/atom+xml image/svg+xml;

    # SSL 全局设置
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # 站点配置从 /data_back/nginx/conf.d/ 加载
    include /data_back/nginx/conf.d/*.conf;
}
NGINXCONF

    # 写默认站点示例（全注释，仅供参考）
    cat > /data_back/nginx/conf.d/default.conf <<'DEFAULTCONF'
# 站点配置示例，取消注释并替换域名后生效
#
# server {
#     listen 80;
#     server_name your.domain.com;
#     return 301 https://$host$request_uri;
# }
#
# server {
#     listen 443 ssl;
#     server_name your.domain.com;
#
#     ssl_certificate     /data_back/nginx/ssl/vvkoi.com.fullchain.pem;
#     ssl_certificate_key /data_back/nginx/ssl/vvkoi.com.key.pem;
#
#     location / {
#         proxy_pass http://127.0.0.1:8080;
#         proxy_set_header Host              $host;
#         proxy_set_header X-Real-IP         $remote_addr;
#         proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
#         proxy_set_header X-Forwarded-Proto $scheme;
#     }
# }
DEFAULTCONF

    nginx -t
    systemctl enable nginx
    systemctl restart nginx

    ok "Nginx 安装完成，配置目录 → /data_back/nginx/"
}

# =============================================================================
# 6. 添加 Swap（自动按内存大小决定倍数）
#    RAM <= 1GB → 2× 内存；RAM > 1GB → 1× 内存
# =============================================================================
section_6() {
    info "━━━ [6/7] 配置 Swap ━━━"

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
    fallocate -l "${SWAP_MB}M" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"

    grep -q "$SWAP_FILE" /etc/fstab || echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab

    sysctl -w vm.swappiness=10
    grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

    swapon --show
    free -h
    ok "Swap ${SWAP_MB} MB 创建完成"
}

# =============================================================================
# 7. 开启 BBR + fq，完成后自动重启
# =============================================================================
section_7() {
    info "━━━ [7/7] 开启 BBR + fq 拥塞控制 ━━━"

    # 写入 sysctl 持久化配置
    SYSCTL_CONF=/etc/sysctl.d/99-bbr.conf
    cat > "$SYSCTL_CONF" <<'SYSCTL'
# TCP BBR 拥塞控制 + fq 队列调度
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL

    # 立即生效
    sysctl --system

    # 验证
    CC=$(sysctl -n net.ipv4.tcp_congestion_control)
    QD=$(sysctl -n net.core.default_qdisc)
    ok "拥塞控制：${CC}，队列调度：${QD}"

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  VPS 将在 10 秒后自动重启...${NC}"
    echo -e "${YELLOW}  重启后请用新端口 61692 登录：ssh root@<IP> -p 61692${NC}"
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

    section_1   # 更新系统 & 基础工具
    section_2   # 设置时区
    section_3   # 创建目录结构
    section_4   # 安装 Docker
    section_5   # 安装 Nginx
    section_6   # 配置 Swap
    section_7   # 调优 & 重启（末尾自动 reboot）
}

main "$@"