#!/usr/bin/env bash
# =============================================================================
#  VPS 初始化脚本 — Debian 12 专用
#  目录规范：所有数据统一存放于 /data_back/
#  GitHub: https://github.com/vvkoi/vps-init   （公开仓库，不含任何密钥）
# =============================================================================
set -euo pipefail

# ── 颜色输出 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERR ]${NC}  $*"; exit 1; }

# ── 必须以 root 运行 ──────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "请以 root 身份运行此脚本（sudo bash init_vps.sh）"

# =============================================================================
# 1. 更新系统 & 安装基础工具
# =============================================================================
section_1() {
    info "━━━ [1/7] 更新系统软件包 ━━━"
    apt update -y && apt upgrade -y
    apt install -y sudo curl wget nano gnupg2 ca-certificates \
        lsb-release debian-archive-keyring apt-transport-https \
        openssl unzip socat cron
    ok "系统更新 & 基础工具安装完成"
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

    # 核心目录
    mkdir -p /data_back/nginx/conf.d       # nginx 站点配置
    mkdir -p /data_back/nginx/ssl           # SSL 证书
    mkdir -p /data_back/nginx/logs          # nginx 日志
    mkdir -p /data_back/compose             # 各服务的 docker compose 文件
    mkdir -p /data_back/scripts            # 运维脚本

    ok "/data_back/ 目录结构已创建"
    tree /data_back/ 2>/dev/null || ls -R /data_back/
}

# =============================================================================
# 4. 安装 Docker（官方 apt 仓库，最新稳定版）+ 创建根 compose 文件
# =============================================================================
section_4() {
    info "━━━ [4/7] 安装 Docker ━━━"

    # 移除旧版冲突包（忽略未安装的报错）
    apt remove -y docker.io docker-compose docker-doc podman-docker \
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

    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    # 开机自启
    systemctl enable docker
    systemctl start docker

    # 验证
    docker --version
    docker compose version

    # 在 /data_back/compose/ 下创建空白示例 compose 文件
    cat > /data_back/compose/docker-compose.yml <<'EOF'
# =============================================================================
# 全局 Docker Compose 示例文件
# 新增服务请在此文件下继续添加，或在 /data_back/compose/ 下新建子目录
# =============================================================================
# services:
#   示例服务:
#     image: nginx:alpine
#     restart: unless-stopped
#     ports:
#       - "8080:80"
#     volumes:
#       - /data_back/nginx:/etc/nginx
EOF

    ok "Docker 安装完成，空白 compose 文件已创建于 /data_back/compose/docker-compose.yml"
}

# =============================================================================
# 5. 安装最新版 nginx（官方稳定版仓库）并将配置目录指向 /data_back/nginx/
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

    # 仓库优先级：优先使用 nginx.org 而非系统默认仓库
    echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
        | tee /etc/apt/preferences.d/99nginx > /dev/null

    apt update -y
    apt install -y nginx

    nginx -v

    # ── 将 nginx 配置文件迁移到 /data_back/nginx/ ──────────────────────────
    # 备份原配置
    cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig

    # 确保 ssl / conf.d / logs 目录存在（section_3 已创建，双保险）
    mkdir -p /data_back/nginx/{conf.d,ssl,logs}

    # 写入新的 nginx.conf，include 指向 /data_back/nginx/conf.d/
    cat > /etc/nginx/nginx.conf <<'NGINXCONF'
user www-data;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
    multi_accept on;
}

http {
    # 基础设置
    sendfile            on;
    tcp_nopush          on;
    tcp_nodelay         on;
    keepalive_timeout   65;
    types_hash_max_size 2048;
    server_tokens       off;

    include      /etc/nginx/mime.types;
    default_type application/octet-stream;

    # 日志路径统一到 /data_back/nginx/logs/
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

    # SSL 全局默认设置
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    # ── 站点配置从 /data_back/nginx/conf.d/ 加载 ──
    include /data_back/nginx/conf.d/*.conf;
}
NGINXCONF

    # 写一个默认站点示例，方便参考
    cat > /data_back/nginx/conf.d/default.conf <<'DEFAULTCONF'
# 默认站点示例（HTTP → HTTPS 重定向）
# 将 your.domain.com 替换成你的域名，取消注释后使用

# server {
#     listen 80;
#     server_name your.domain.com;
#     return 301 https://$host$request_uri;
# }

# server {
#     listen 443 ssl;
#     server_name your.domain.com;
#
#     ssl_certificate     /data_back/nginx/ssl/vvkoi.com.fullchain.pem;
#     ssl_certificate_key /data_back/nginx/ssl/vvkoi.com.key.pem;
#
#     location / {
#         proxy_pass http://127.0.0.1:8080;
#         proxy_set_header Host $host;
#         proxy_set_header X-Real-IP $remote_addr;
#         proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
#         proxy_set_header X-Forwarded-Proto $scheme;
#     }
# }
DEFAULTCONF

    # 测试配置并重载
    nginx -t
    systemctl enable nginx
    systemctl restart nginx

    ok "Nginx 安装完成，配置目录 → /data_back/nginx/"
}

# =============================================================================
# 6. 添加 Swap（自动检测内存，生成 1× 内存大小的 swap）
# =============================================================================
#
# 关于 swap 倍数的说明：
#   - 1× 内存：适合 RAM ≥ 2GB 的 VPS，够用且不浪费磁盘。
#   - 2× 内存：适合 RAM < 1GB 的低配机器，此脚本对低配(<= 1GB)自动用2x，其余用1x。
#   - swap 并不能替代真实 RAM，只是防止 OOM Killer 杀进程的最后防线。
#
section_6() {
    info "━━━ [6/7] 配置 Swap ━━━"

    # 如果已有 swap 则跳过
    if swapon --show | grep -q '/'; then
        warn "已存在 swap，跳过创建：$(swapon --show)"
        return
    fi

    # 获取物理内存（MB）
    MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
    info "物理内存：${MEM_MB} MB"

    # 低配（≤ 1024 MB）用 2×，其余用 1×
    if [[ $MEM_MB -le 1024 ]]; then
        SWAP_MB=$((MEM_MB * 2))
        info "低配机器，Swap = 2× 内存 = ${SWAP_MB} MB"
    else
        SWAP_MB=$MEM_MB
        info "Swap = 1× 内存 = ${SWAP_MB} MB"
    fi

    SWAP_FILE=/swapfile

    fallocate -l "${SWAP_MB}M" "$SWAP_FILE"
    chmod 600 "$SWAP_FILE"
    mkswap "$SWAP_FILE"
    swapon "$SWAP_FILE"

    # 写入 fstab，保证重启后生效
    if ! grep -q "$SWAP_FILE" /etc/fstab; then
        echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
    fi

    # 调整 swappiness（60 → 10，减少不必要的 swap 使用）
    sysctl -w vm.swappiness=10
    if ! grep -q 'vm.swappiness' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi

    swapon --show
    free -h
    ok "Swap ${SWAP_MB}MB 创建完成"
}

# =============================================================================
# 7. 系统调优 & BBRx 加速，完成后自动重启
# =============================================================================
section_7() {
    info "━━━ [7/7] 系统调优 & BBRx 加速 ━━━"

    info "→ 运行系统参数调优脚本（tune.sh -t）..."
    bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Tune/main/tune.sh) -t

    info "→ 开启 BBRx 加速（tune.sh -x）..."
    bash <(wget -qO- https://raw.githubusercontent.com/jerry048/Tune/main/tune.sh) -x

    ok "调优完成！"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  VPS 即将在 10 秒后自动重启...${NC}"
    echo -e "${YELLOW}  重启完成后，请等待 1~2 分钟再次登录（BBRx 内核可能需要时间加载）。${NC}"
    echo -e "${YELLOW}  登录后建议再手动执行一次 reboot 以确认内核参数完全生效。${NC}"
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
    section_7   # 调优 & 重启

    # 注意：section_7 末尾会 reboot，以下内容正常不会执行
    ok "全部步骤执行完毕"
}

main "$@"