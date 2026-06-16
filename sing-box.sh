#!/usr/bin/env bash
# =========================
# 自用 sing-box 安装脚本
# 协议: vless-argo(固定隧道) + hysteria2
# 平台: Ubuntu / Debian (systemd)
# 最后更新时间: 2026.6.15 18:30
# =========================

export LANG=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

# ── 颜色 ──────────────────────────────────────────
red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue(){ echo -e "\e[1;36m$1\033[0m"; }
reading(){ read -p "$(red "$1")" "$2"; }

# ── 常量 ──────────────────────────────────────────
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
backup_dir="/etc/sing-box-backup"
SCRIPT_URL="https://raw.githubusercontent.com/wot1026-cmd/sing-box/main/sing-box.sh"
ARGO_PORT="8001"

SB_VERSION="1.13.13"

export CFIP=${CFIP:-'cf.877774.xyz'}
export CFPORT=${CFPORT:-'443'}

# ── 前置检查 ──────────────────────────────────────
[[ $EUID -ne 0 ]] && red "请在 root 用户下运行脚本" && exit 1
command -v systemctl >/dev/null 2>&1 || { red "本脚本仅支持 systemd 系统（Ubuntu/Debian）"; exit 1; }

command_exists() { command -v "$1" >/dev/null 2>&1; }

# ── 服务状态检查 ───────────────────────────────────
check_service() {
    local name="$1" binary="$2"
    [[ ! -f "$binary" ]] && { red "not installed"; return 2; }
    if systemctl is-active "$name" &>/dev/null; then
        green "running"; return 0
    else
        yellow "not running"; return 1
    fi
}

check_singbox() { check_service "sing-box" "${work_dir}/sing-box"; }
check_argo()    { check_service "argo"     "${work_dir}/argo"; }

# ── 包安装 ────────────────────────────────────────
install_packages() {
    local to_install=()
    for pkg in "$@"; do
        command_exists "$pkg" && { yellow "${pkg} 已安装，跳过"; continue; }
        to_install+=("$pkg")
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        return 0
    fi
    apt-get update -y
    for pkg in "${to_install[@]}"; do
        yellow "正在安装 ${pkg}…"
        apt-get install -y "$pkg" || { red "${pkg} 安装失败"; return 1; }
    done
}

# ── 防火墙放行 ────────────────────────────────────
allow_port() {
    local has_ufw=0 has_iptables=0 has_ip6tables=0
    command_exists ufw       && has_ufw=1
    command_exists iptables  && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    [ $has_ufw -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1

    if [ $has_iptables -eq 1 ]; then
        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT -i lo -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I INPUT -p icmp -j ACCEPT 2>/dev/null || true
        iptables -C INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi
    if [ $has_ip6tables -eq 1 ]; then
        ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT -i lo -j ACCEPT 2>/dev/null || true
        ip6tables -C INPUT -p icmp -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p icmp -j ACCEPT 2>/dev/null || true
        ip6tables -C INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || ip6tables -I INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    fi

    for rule in "$@"; do
        local port="${rule%/*}" proto="${rule#*/}"
        [ $has_ufw -eq 1 ] && ufw allow in "${port}/${proto}" >/dev/null 2>&1
        if [ $has_iptables -eq 1 ]; then
            iptables  -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                || iptables  -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
        if [ $has_ip6tables -eq 1 ]; then
            ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                || ip6tables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    done

    if [ $has_iptables -eq 1 ] && command_exists iptables-save; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    if [ $has_ip6tables -eq 1 ] && command_exists ip6tables-save; then
        mkdir -p /etc/iptables
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
}

# ── 防火墙删除旧规则 ──────────────────────────────
remove_port() {
    local has_ufw=0 has_iptables=0 has_ip6tables=0
    command_exists ufw       && has_ufw=1
    command_exists iptables  && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    for rule in "$@"; do
        local port="${rule%/*}" proto="${rule#*/}"
        [ $has_ufw -eq 1 ] && ufw delete allow "${port}/${proto}" >/dev/null 2>&1
        if [ $has_iptables -eq 1 ]; then
            iptables  -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
        if [ $has_ip6tables -eq 1 ]; then
            ip6tables -D INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    done

    if [ $has_iptables -eq 1 ] && command_exists iptables-save; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    if [ $has_ip6tables -eq 1 ] && command_exists ip6tables-save; then
        mkdir -p /etc/iptables
        ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    fi
}

# ── 节点名称 ──────────────────────────────────────
get_flag() {
    local code
    code=$(curl -sm3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" | jq -r '.country_code // empty' 2>/dev/null)
    [ -z "$code" ] && code=$(curl -sm3 "https://ipapi.co/country_code" 2>/dev/null)
    case "$code" in
        US) echo "🇺🇸" ;; KR) echo "🇰🇷" ;; JP) echo "🇯🇵" ;;
        HK) echo "🇭🇰" ;; SG) echo "🇸🇬" ;; DE) echo "🇩🇪" ;;
        GB) echo "🇬🇧" ;; FR) echo "🇫🇷" ;; NL) echo "🇳🇱" ;;
        CA) echo "🇨🇦" ;; AU) echo "🇦🇺" ;; TW) echo "🇹🇼" ;;
        CN) echo "🇨🇳" ;; RU) echo "🇷🇺" ;; IN) echo "🇮🇳" ;;
        BR) echo "🇧🇷" ;; *)  echo "🌐" ;;
    esac
}

get_node_name() { echo "$(get_flag) $(hostname)"; }

# ── Hysteria2 指纹 ────────────────────────────────
get_hy2_fingerprint() {
    openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" 2>/dev/null \
        | cut -d'=' -f2 | sed 's/:/%3A/g'
}

# ── 官方源下载 ────────────────────────────────────
get_latest_sb_version() {
    curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        | jq -r '.tag_name // empty' | tr -d 'v'
}

download_singbox() {
    local arch="$1" version="$2" dest="$3"
    local base_url="https://github.com/SagerNet/sing-box/releases/download/v${version}"
    local tarball="sing-box-${version}-linux-${arch}.tar.gz"
    local tmp_tar tmp_dir
    tmp_tar=$(mktemp)
    tmp_dir=$(mktemp -d)

    yellow "正在下载 sing-box v${version}..."
    curl -fsSLo "$tmp_tar" "${base_url}/${tarball}" \
        || { red "sing-box 下载失败"; rm -f "$tmp_tar"; rm -rf "$tmp_dir"; return 1; }

    tar -xzf "$tmp_tar" -C "$tmp_dir" \
        || { red "解压失败"; rm -f "$tmp_tar"; rm -rf "$tmp_dir"; return 1; }
    mv "${tmp_dir}/sing-box-${version}-linux-${arch}/sing-box" "$dest" \
        || { red "移动文件失败"; rm -f "$tmp_tar"; rm -rf "$tmp_dir"; return 1; }

    rm -f "$tmp_tar"; rm -rf "$tmp_dir"
    chmod +x "$dest"
    chown root:root "$dest"
}

download_cloudflared() {
    local arch="$1" dest="$2"
    local bin_name="cloudflared-linux-${arch}"
    local base_url="https://github.com/cloudflare/cloudflared/releases/latest/download"
    local tmp_file
    tmp_file=$(mktemp)

    yellow "正在下载 cloudflared..."
    curl -fsSLo "$tmp_file" "${base_url}/${bin_name}" \
        || { red "cloudflared 下载失败"; rm -f "$tmp_file"; return 1; }

    mv "$tmp_file" "$dest"
    chmod +x "$dest"
    chown root:root "$dest"
}

# ── 查找未被占用的 UDP 端口 ───────────────────────
pick_free_udp_port() {
    local port attempts=0
    port=$(shuf -i 10000-65000 -n 1)
    while ss -ulnH | awk '{print $5}' | grep -q ":${port}$"; do
        port=$(shuf -i 10000-65000 -n 1)
        (( attempts++ > 100 )) && { red "无法找到空闲 UDP 端口"; return 1; }
    done
    echo "$port"
}

# ── 查找未被占用的 TCP 端口 ───────────────────────
pick_free_tcp_port() {
    local port attempts=0
    port=$(shuf -i 10000-65000 -n 1)
    while ss -tlnH | awk '{print $5}' | grep -q ":${port}$"; do
        port=$(shuf -i 10000-65000 -n 1)
        (( attempts++ > 100 )) && { red "无法找到空闲 TCP 端口"; return 1; }
    done
    echo "$port"
}

# ── 安装核心 ──────────────────────────────────────
install_singbox() {
    clear
    purple "正在安装 sing-box，请稍候…"

    local sb_ver="${1:-$SB_VERSION}"

    local arch_raw arch
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)  arch='amd64' ;;
        aarch64|arm64) arch='arm64' ;;
        *) red "不支持的架构: ${arch_raw}"; exit 1 ;;
    esac
    
    if ss -tlnH | awk '{print $5}' | grep -q ":${ARGO_PORT}$"; then
        red "端口 ${ARGO_PORT} 已被占用，请修改 ARGO_PORT 后重试"
        exit 1
    fi
    
    mkdir -p "${work_dir}" "${conf_dir}"
    chmod 700 "${work_dir}"

    download_singbox "$arch" "$sb_ver" "${work_dir}/sing-box" || exit 1
    download_cloudflared "$arch" "${work_dir}/argo"           || exit 1

    apt-get install -y qrencode 2>/dev/null || yellow "qrencode 安装失败，二维码功能不可用"

    local hy2_port uuid vless_path argo_port="${ARGO_PORT}"
    local restore_backup=false

    # ── 检测是否存在卸载时保留的备份配置 ──────────
    if [ -f "${backup_dir}/inbounds.json" ]; then
        yellow "\n检测到上次卸载时保留的节点配置备份"
        local restore_choice
        reading "是否恢复备份中的 UUID / 端口 / 隧道配置？(y/n，回车默认 y): " restore_choice
        if [[ -z "$restore_choice" || "$restore_choice" == [yY] ]]; then
            restore_backup=true
        fi
    fi

    if $restore_backup; then
        uuid=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid' "${backup_dir}/inbounds.json")
        vless_path=$(jq -r '.inbounds[] | select(.type=="vless") | .transport.path' "${backup_dir}/inbounds.json")
        hy2_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "${backup_dir}/inbounds.json")
        argo_port=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port' "${backup_dir}/inbounds.json")

        if [ -z "$uuid" ] || [ "$uuid" = "null" ] \
           || [ -z "$vless_path" ] || [ "$vless_path" = "null" ] \
           || ! [[ "$hy2_port" =~ ^[0-9]+$ ]] \
           || ! [[ "$argo_port" =~ ^[0-9]+$ ]]; then
            yellow "备份配置内容异常，已忽略备份，将生成全新配置"
            restore_backup=false
        else
            if ss -ulnH | awk '{print $5}' | grep -q ":${hy2_port}$"; then
                yellow "备份中的 Hysteria2 端口 ${hy2_port} 已被占用，将重新分配"
                hy2_port=$(pick_free_udp_port) || exit 1
            fi
            if ss -tlnH | awk '{print $5}' | grep -q ":${argo_port}$"; then
                yellow "备份中的 VLESS-Argo 端口 ${argo_port} 已被占用，将使用默认端口 ${ARGO_PORT}"
                argo_port="${ARGO_PORT}"
            fi
            green "已从备份恢复 UUID 与端口配置"
        fi
    fi

    if ! $restore_backup; then
        hy2_port=$(pick_free_udp_port) || exit 1
        uuid=$(cat /proc/sys/kernel/random/uuid)
        vless_path="/${uuid}-vless"
    fi

    allow_port "${hy2_port}/udp"

    # ── 证书：优先从备份恢复，保持 pinSHA256 不变 ─
    local cert_restored=false
    if $restore_backup \
       && [ -f "${backup_dir}/cert.pem" ] \
       && [ -f "${backup_dir}/private.key" ] \
       && openssl x509 -noout -in "${backup_dir}/cert.pem" 2>/dev/null; then
        cp "${backup_dir}/cert.pem"    "${work_dir}/cert.pem"
        cp "${backup_dir}/private.key" "${work_dir}/private.key"
        chmod 600 "${work_dir}/private.key"
        green "已从备份恢复 TLS 证书（pinSHA256 不变）"
        cert_restored=true
    else
        yellow "正在生成新 TLS 证书..."
        openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key" 2>/dev/null
        openssl req -new -x509 -days 3650 \
            -key "${work_dir}/private.key" \
            -out "${work_dir}/cert.pem" \
            -subj "/CN=bing.com" 2>/dev/null
        chmod 600 "${work_dir}/private.key"
    fi

    cat > "${conf_dir}/log.json" << EOF
{
  "log": {
    "disabled": false,
    "level": "error",
    "output": "${work_dir}/sb.log",
    "timestamp": true
  }
}
EOF

    cat > "${conf_dir}/ntp.json" << 'EOF'
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "60m"
  }
}
EOF

    cat > "${conf_dir}/dns.json" << 'EOF'
{
  "dns": {
    "servers": [{"tag": "local", "type": "local"}],
    "strategy": "ipv4_only"
  }
}
EOF

    cat > "${conf_dir}/inbounds.json" << EOF
{
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": ${argo_port},
      "users": [
        {
          "uuid": "${uuid}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "${vless_path}",
        "max_early_data": 2560,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hysteria2",
      "listen": "0.0.0.0",
      "listen_port": ${hy2_port},
      "users": [{"password": "${uuid}"}],
      "ignore_client_bandwidth": false,
      "masquerade": "https://bing.com",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "min_version": "1.3",
        "max_version": "1.3",
        "certificate_path": "${work_dir}/cert.pem",
        "key_path": "${work_dir}/private.key"
      }
    }
  ]
}
EOF

    cat > "${conf_dir}/outbounds.json" << 'EOF'
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ]
}
EOF

    cat > "${conf_dir}/route.json" << 'EOF'
{
  "route": {
    "rule_set": [],
    "rules": [],
    "final": "direct"
  }
}
EOF

    cat > "${conf_dir}/experimental.json" << EOF
{
  "experimental": {
    "cache_file": {
      "enabled": true,
      "path": "${work_dir}/cache.db"
    }
  }
}
EOF

    # ── 恢复 Argo 隧道与 CF 优选配置（若有备份）──
    if $restore_backup; then
        if [ -f "${backup_dir}/tunnel.yml" ]; then
            cp "${backup_dir}/tunnel.yml" "${work_dir}/tunnel.yml"
            sed -i "s|service: http://localhost:[0-9]*|service: http://localhost:${argo_port}|" \
                "${work_dir}/tunnel.yml"
        fi
        if [ -f "${backup_dir}/tunnel.json" ]; then
            cp "${backup_dir}/tunnel.json" "${work_dir}/tunnel.json"
            chmod 600 "${work_dir}/tunnel.json"
        fi
        if [ -f "${backup_dir}/argo_token" ]; then
            cp "${backup_dir}/argo_token" "${work_dir}/argo_token"
            chmod 600 "${work_dir}/argo_token"
        fi
        if [ -f "${backup_dir}/cf.env" ]; then
            cp "${backup_dir}/cf.env" "${work_dir}/cf.env"
            chmod 600 "${work_dir}/cf.env"
        fi
    fi

    green "sing-box 核心安装完成"
}

# ── systemd 服务 ──────────────────────────────────
setup_services() {
    cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/etc/sing-box/sing-box run -C /etc/sing-box/conf
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/argo.service << 'EOF'
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/bin/true
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box && systemctl start sing-box
    systemctl enable argo

    TUNNEL_FULLY_RESTORED=false

    if [ -f "${work_dir}/tunnel.yml" ]; then
        if _rebuild_argo_service_from_tunnel_yml; then
            systemctl daemon-reload
            systemctl restart argo
        fi
    fi
}

# ── 根据 tunnel.yml 重建 argo.service（用于恢复备份场景）──
_rebuild_argo_service_from_tunnel_yml() {
    if grep -q '^# token mode' "${work_dir}/tunnel.yml" 2>/dev/null; then
        if [ ! -f "${work_dir}/argo_token" ]; then
            local argo_domain
            argo_domain=$(get_fixed_domain)
            yellow "检测到 Token 模式的隧道备份，域名：${argo_domain}"
            yellow "Token 文件缺失，请重新执行「Argo 隧道管理 → 配置固定隧道」输入 Token"
            TUNNEL_TOKEN_MODE=true
            return 1
        fi
        local argo_token
        argo_token=$(cat "${work_dir}/argo_token")
        cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_token}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        TUNNEL_FULLY_RESTORED=true
        return 0
    fi

    # JSON 凭据模式：tunnel.yml 已含 credentials-file，直接用
    if [ -f "${work_dir}/tunnel.json" ]; then
        cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/sing-box/argo tunnel --edge-ip-version auto --config ${work_dir}/tunnel.yml run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        TUNNEL_FULLY_RESTORED=true
        return 0
    fi

    yellow "隧道配置文件存在但缺少凭据，请重新配置固定隧道"
    return 1
}

# ── 服务管理 ──────────────────────────────────────
manage_service() {
    local name="$1" action="$2"
    case "$action" in
        start)
            yellow "正在启动 ${name}…"
            systemctl start "$name"
            systemctl is-active "$name" &>/dev/null && green "${name} 已启动" || red "${name} 启动失败"
            ;;
        stop)
            yellow "正在停止 ${name}…"
            systemctl stop "$name"
            ! systemctl is-active "$name" &>/dev/null && green "${name} 已停止" || red "${name} 停止失败"
            ;;
        restart)
            yellow "正在重启 ${name}…"
            systemctl daemon-reload
            systemctl restart "$name"
            systemctl is-active "$name" &>/dev/null && green "${name} 已重启" || red "${name} 重启失败"
            ;;
    esac
}

start_singbox()  { manage_service "sing-box" "start"; }
stop_singbox()   { manage_service "sing-box" "stop";  }
restart_singbox(){ manage_service "sing-box" "restart"; }
start_argo()     { manage_service "argo" "start"; }
stop_argo()      { manage_service "argo" "stop";  }
restart_argo()   { manage_service "argo" "restart"; }

# ── 隧道工具 ──────────────────────────────────────
get_fixed_domain() {
    grep 'hostname:' "${work_dir}/tunnel.yml" 2>/dev/null \
        | head -1 | sed 's/.*hostname:[[:space:]]*//' | tr -d '[:space:]'
}

is_fixed_tunnel_configured() { [ -f "${work_dir}/tunnel.yml" ]; }

# ── 节点信息生成 ──────────────────────────────────
get_info() {
    yellow "\nIP 检测中，请稍候…\n"
    local server_ip node_prefix
    server_ip=$(curl -4 -sm3 ip.sb)
    [ -z "$server_ip" ] && { red "获取 IP 失败"; return 1; }
    node_prefix=$(get_node_name)

    if [ -f "${work_dir}/cf.env" ]; then
        local _cfip _cfport
        _cfip=$(grep  '^CFIP='   "${work_dir}/cf.env" | cut -d'=' -f2-)
        _cfport=$(grep '^CFPORT=' "${work_dir}/cf.env" | cut -d'=' -f2-)
        [ -n "$_cfip" ]   && CFIP="$_cfip"
        [ -n "$_cfport" ] && CFPORT="$_cfport"
    fi

    clear

    local hy2_port uuid fingerprint
    hy2_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "${conf_dir}/inbounds.json")
    uuid=$(jq -r '.inbounds[] | select(.type=="vless") | .users[0].uuid' "${conf_dir}/inbounds.json")

    fingerprint=$(get_hy2_fingerprint)
    if [ -z "$fingerprint" ]; then
        red "证书读取失败，无法生成节点信息（请检查 ${work_dir}/cert.pem 是否存在）"
        return 1
    fi

    local vless_path
    vless_path=$(jq -r '.inbounds[] | select(.type=="vless") | .transport.path' "${conf_dir}/inbounds.json" \
        | sed 's|^/||')

    local argodomain=""
    is_fixed_tunnel_configured && argodomain=$(get_fixed_domain)

    if [ -z "$argodomain" ]; then
        yellow "未检测到固定隧道域名，VLESS 节点暂不可用，请先配置 Argo 固定隧道\n"
        cat > "${client_dir}" << EOF
hysteria2://${uuid}@${server_ip}:${hy2_port}?sni=bing.com&pinSHA256=${fingerprint}&alpn=h3#${node_prefix} hy2
EOF
    else
        green "\nArgo 域名：${argodomain}\n"

        local _port="${CFPORT:-443}"
        [[ "$_port" =~ ^[0-9]+$ ]] || _port="443"

        local encoded_path
        encoded_path="%2F${vless_path}%3Fed%3D2560"

        cat > "${client_dir}" << EOF
vless://${uuid}@${CFIP}:${_port}?encryption=none&security=tls&sni=${argodomain}&fp=chrome&type=ws&host=${argodomain}&path=${encoded_path}#${node_prefix} argo

hysteria2://${uuid}@${server_ip}:${hy2_port}?sni=bing.com&pinSHA256=${fingerprint}&alpn=h3#${node_prefix} hy2
EOF
    fi

    echo ""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "\e[1;35m${line}\033[0m"
    done < "${client_dir}"
}

# ── 查看节点 ──────────────────────────────────────
check_nodes() {
    [ ! -f "${client_dir}" ] && { red "节点信息不存在，请先安装 sing-box"; return 1; }
    clear; echo ""
    green "=== 当前节点信息 ===\n"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "\e[1;35m${line}\033[0m\n"
        command_exists qrencode && qrencode -t ANSIUTF8 "$line"
        echo ""
    done < "${client_dir}"
}

# ── 大陆拦截 ──────────────────────────────────────
cn_block_manage() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return; }

    local route_file="${conf_dir}/route.json"
    jq empty "$route_file" 2>/dev/null || { red "route.json 格式异常，请检查文件内容"; sleep 2; return 1; }
    local block_enabled=false
    jq -e '.route.rules[] | select(.rule_set[]? == "geosite-cn")' \
        "$route_file" >/dev/null 2>&1 && block_enabled=true

    clear; echo ""
    green "=== 大陆域名拦截管理 ===\n"
    $block_enabled && green "当前状态：已开启\n" || yellow "当前状态：未开启\n"
    green  "1. 开启大陆拦截"
    skyblue "---------------"
    red    "2. 关闭大陆拦截"
    skyblue "---------------"
    purple "0. 返回主菜单"
    skyblue "---------------"
    reading "请输入选择: " choice

    case "$choice" in
        1)
            if $block_enabled; then
                yellow "大陆拦截已开启，无需重复操作\n"; sleep 1; return
            fi
            local tmp_file
            tmp_file=$(mktemp)
            jq '
              del(.route.rules[] | select(.rule_set[]? == "geosite-cn")) |
              del(.route.rules[] | select(
                  .domain_regex? and .outbound == "direct" and
                  (.domain_regex[] | test("googleapis"))
              )) |
              del(.route.rule_set[] | select(.tag == "geosite-cn")) |
              .route.rule_set += [{"type":"remote","tag":"geosite-cn","format":"binary",
                "url":"https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
                "download_detour":"direct"}] |
              .route.rules = [
                {"domain_regex":["^([a-zA-Z0-9_-]+\\.)*googleapis\\.cn",
                  "^([a-zA-Z0-9_-]+\\.)*googleapis\\.com",
                  "^([a-zA-Z0-9_-]+\\.)*gstatic\\.com",
                  "^([a-zA-Z0-9_-]+\\.)*xn--ngstr-lra8j\\.com"],
                 "outbound":"direct"},
                {"rule_set":["geosite-cn"],"outbound":"block"}
              ] + .route.rules
            ' "$route_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置写入失败"; sleep 2; return
            fi
            mv "$tmp_file" "$route_file"
            restart_singbox
            green "\n大陆域名拦截已开启\n"
            ;;
        2)
            if ! $block_enabled; then
                yellow "大陆拦截未开启\n"; sleep 1; return
            fi
            local tmp_file
            tmp_file=$(mktemp)
            jq '
              del(.route.rules[] | select(.rule_set[]? == "geosite-cn")) |
              del(.route.rules[] | select(
                  .domain_regex? and .outbound == "direct" and
                  (.domain_regex[] | test("googleapis"))
              )) |
              del(.route.rule_set[] | select(.tag == "geosite-cn"))
            ' "$route_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置写入失败"; sleep 2; return
            fi
            mv "$tmp_file" "$route_file"
            restart_singbox
            green "\n大陆域名拦截已关闭\n"
            ;;
        0) return ;;
        *) red "无效选项" ;;
    esac
}

# ── 修改节点配置 ──────────────────────────────────
change_config() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return; }

    local inbounds_file="${conf_dir}/inbounds.json"
    local sb_status
    sb_status=$(check_singbox 2>&1)

    clear; echo ""
    green "=== 修改节点配置 === sing-box: ${sb_status}\n"
    green  "1. 修改 UUID"
    green  "2. 修改 Hysteria2 端口"
    green  "3. 修改 VLESS-Argo 端口"
    green  "4. 修改 CF 优选域名/IP"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "$choice" in
        1)
            reading "\n请输入新的 UUID（回车随机生成）: " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            if [[ -n "$new_uuid" ]] && \
               ! [[ "$new_uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
                red "UUID 格式不合法"; sleep 1; return
            fi

            local tmp_file
            tmp_file=$(mktemp)
            jq --arg u "$new_uuid" --arg p "/${new_uuid}-vless" '
                (.inbounds[] | select(.type=="vless")     | .users[] | .uuid)     = $u |
                (.inbounds[] | select(.type=="vless")     | .transport.path)      = $p |
                (.inbounds[] | select(.type=="hysteria2") | .users[] | .password) = $u
            ' "$inbounds_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置文件写入失败，请检查！"; sleep 2; return
            fi
            mv "$tmp_file" "$inbounds_file"
            restart_singbox && get_info
            green "\nUUID 已修改为：${new_uuid}\n"
            ;;

        2)
            reading "\n请输入新的 Hysteria2 端口（回车随机生成）: " new_port
            if [ -z "$new_port" ]; then
                new_port=$(pick_free_udp_port)
            else
                if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
                    red "端口无效（1-65535）"; sleep 1; return
                fi
                if ss -ulnH | awk '{print $5}' | grep -q ":${new_port}$"; then
                    red "端口 ${new_port} 已被占用，请换一个"; sleep 1; return
                fi
            fi
            local old_port
            old_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$inbounds_file")
            local tmp_file
            tmp_file=$(mktemp)
            jq --argjson p "$new_port" \
                '(.inbounds[] | select(.type=="hysteria2") | .listen_port) = $p' \
                "$inbounds_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置写入失败"; sleep 1; return
            fi
            mv "$tmp_file" "$inbounds_file"
            remove_port "${old_port}/udp"
            allow_port "${new_port}/udp"
            restart_singbox && get_info
            green "\nHysteria2 端口已修改为：${new_port}\n"
            ;;

        3)
            reading "\n请输入新的 VLESS-Argo 端口（回车随机生成）: " new_port
            [ -z "$new_port" ] && new_port=$(pick_free_tcp_port)
            if ! [[ "$new_port" =~ ^[0-9]+$ ]] || (( new_port < 1 || new_port > 65535 )); then
                red "端口无效（1-65535）"; sleep 1; return
            fi
            if ss -tlnH | awk '{print $5}' | grep -q ":${new_port}$"; then
                red "端口 ${new_port} 已被占用，请换一个"; sleep 1; return
            fi
            local tmp_file
            tmp_file=$(mktemp)
            jq --argjson p "$new_port" \
                '(.inbounds[] | select(.type=="vless") | .listen_port) = $p' \
                "$inbounds_file" > "$tmp_file"
            if [ $? -ne 0 ] || [ ! -s "$tmp_file" ]; then
                rm -f "$tmp_file"; red "配置写入失败"; sleep 1; return
            fi
            mv "$tmp_file" "$inbounds_file"
            if [ -f "${work_dir}/tunnel.yml" ]; then
                if grep -q '^# token mode' "${work_dir}/tunnel.yml" 2>/dev/null; then
                    yellow "⚠ Token 模式：请同步在 Cloudflare Dashboard 中将后端端口改为 ${new_port}"
                else
                    sed -i "s|service: http://localhost:[0-9]*|service: http://localhost:${new_port}|" \
                        "${work_dir}/tunnel.yml"
                fi
            fi
            restart_singbox && restart_argo && get_info
            green "\nVLESS-Argo 端口已修改为：${new_port}\n"
            ;;

        4)
            clear
            green "1: ct.877774.xyz  2: cf.877774.xyz  3: cloudflare-ech.com  4: www.visa.com.sg\n"
            reading "请输入优选域名或 IP[:端口]（回车默认 cloudflare-ech.com）: " input
            local cfip cfport
            case "$input" in
                ""|"3") cfip="cloudflare-ech.com"; cfport="443" ;;
                "1")    cfip="ct.877774.xyz";      cfport="443" ;;
                "2")    cfip="cf.877774.xyz";      cfport="443" ;;
                "4")    cfip="www.visa.com.sg";    cfport="443" ;;
                *)
                    if [[ "$input" =~ : ]]; then
                        cfip="${input%%:*}"; cfport="${input##*:}"
                        [[ ! "$cfport" =~ ^[0-9]+$ ]] || (( cfport > 65535 )) && cfport="443"
                    else
                        cfip="$input"; cfport="443"
                    fi
                    ;;
            esac
            printf 'CFIP=%s\nCFPORT=%s\n' "$cfip" "$cfport" > "${work_dir}/cf.env"
            chmod 600 "${work_dir}/cf.env"
            get_info
            green "\nCF 优选已更新为：${cfip}:${cfport}\n"
            ;;

        0) return ;;
        *) red "无效选项！" ;;
    esac
}

# ── 升级 sing-box ─────────────────────────────────
upgrade_singbox() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return; }

    local arch_raw arch
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)  arch='amd64' ;;
        aarch64|arm64) arch='arm64' ;;
        *) red "不支持的架构: ${arch_raw}"; return 1 ;;
    esac

    local current_ver
    current_ver=$("${work_dir}/sing-box" version 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    yellow "当前版本: ${current_ver:-未知}"

    yellow "正在查询最新版本…"
    local latest_ver
    latest_ver=$(get_latest_sb_version)
    if [ -z "$latest_ver" ]; then
        yellow "无法获取最新版本，将使用脚本内置版本 ${SB_VERSION}"
        latest_ver="$SB_VERSION"
    else
        green "最新版本: ${latest_ver}"
    fi

    if [ "$current_ver" = "$latest_ver" ]; then
        green "已是最新版 ${latest_ver}，无需升级\n"
        return
    fi

    reading "确认升级到 v${latest_ver}？(y/n): " confirm
    [[ "$confirm" != [yY] ]] && { purple "已取消\n"; return; }

    local tmp_dest
    tmp_dest=$(mktemp)
    download_singbox "$arch" "$latest_ver" "$tmp_dest" || return 1

    stop_singbox

    cp "${work_dir}/sing-box" "${work_dir}/sing-box.bak"

    if mv "$tmp_dest" "${work_dir}/sing-box" && \
       chmod +x "${work_dir}/sing-box" && \
       chown root:root "${work_dir}/sing-box" && \
       "${work_dir}/sing-box" version &>/dev/null; then
        rm -f "${work_dir}/sing-box.bak"
        start_singbox
        green "\nsing-box 已升级至 v${latest_ver}\n"
        "${work_dir}/sing-box" version
    else
        red "升级失败，正在回滚…"
        mv "${work_dir}/sing-box.bak" "${work_dir}/sing-box"
        start_singbox
        red "已回滚到旧版本，请检查网络或稍后重试\n"
    fi
}

# ── 配置固定 Argo 隧道 ────────────────────────────
configure_fixed_tunnel() {
    clear
    yellow "\n固定隧道支持 JSON 凭据或 Token 两种方式"
    yellow "JSON 获取：https://fscarmen.cloudflare.now.cc\n"

    local argo_domain argo_auth
    reading "\n请输入 Argo 域名: " argo_domain
    [ -z "$argo_domain" ] && { red "域名不能为空"; return 1; }

    if ! [[ "$argo_domain" =~ ^[A-Za-z0-9._-]+\.[A-Za-z]{2,}$ ]]; then
        red "域名格式不合法"; return 1
    fi

    reading "\n请输入 Argo 密钥（Token 或 JSON）: " argo_auth
    [ -z "$argo_auth" ] && { red "密钥不能为空"; return 1; }

    local current_argo_port
    current_argo_port=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port' "${conf_dir}/inbounds.json" 2>/dev/null)
    [[ "$current_argo_port" =~ ^[0-9]+$ ]] || current_argo_port="${ARGO_PORT}"
    yellow "当前 VLESS 端口: ${current_argo_port}\n"

    if [[ "$argo_auth" =~ TunnelSecret ]]; then
        echo "$argo_auth" > "${work_dir}/tunnel.json"
        chmod 600 "${work_dir}/tunnel.json"
        local tunnel_id
        tunnel_id=$(echo "$argo_auth" \
            | jq -r '(.TunnelID // .tunnelID // .tunnel_id) // empty' 2>/dev/null)

        [ -z "$tunnel_id" ] && { red "无法解析 TunnelID，请检查 JSON 格式"; return 1; }

        cat > "${work_dir}/tunnel.yml" << EOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: ${argo_domain}
    service: http://localhost:${current_argo_port}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF

        cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/sing-box/argo tunnel --edge-ip-version auto --config ${work_dir}/tunnel.yml run
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    elif [[ "$argo_auth" =~ ^[A-Za-z0-9+/=._-]{100,500}$ ]]; then
        printf '# token mode\nhostname: %s\n' "$argo_domain" > "${work_dir}/tunnel.yml"
        echo "$argo_auth" > "${work_dir}/argo_token"
        chmod 600 "${work_dir}/argo_token"
        cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
ExecStart=/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${argo_auth}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    else
        red "密钥格式不匹配（请确认是 JSON 凭据或有效 Token）"; return 1
    fi

    systemctl daemon-reload
    restart_argo
    sleep 2
    get_info
    green "\n固定隧道配置完成，域名：${argo_domain}\n"
}

# ── Argo 管理菜单 ─────────────────────────────────
manage_argo() {
    local argo_status
    argo_status=$(check_argo 2>&1)
    clear; echo ""
    green "=== Argo 隧道管理 === 状态: ${argo_status}\n"
    is_fixed_tunnel_configured && green "当前域名: $(get_fixed_domain)\n" || yellow "固定隧道尚未配置\n"
    green  "1. 启动 Argo"
    green  "2. 停止 Argo"
    green  "3. 重启 Argo"
    green  "4. 配置固定隧道"
    purple "0. 返回主菜单"
    skyblue "————"
    reading "\n请输入选择: " choice
    case "$choice" in
        1) start_argo ;;
        2) stop_argo ;;
        3) restart_argo ;;
        4) configure_fixed_tunnel ;;
        0) return ;;
        *) red "无效选项！" ;;
    esac
}

# ── sing-box 管理菜单 ─────────────────────────────
manage_singbox() {
    local sb_status
    while true; do
        sb_status=$(check_singbox 2>&1)
        clear; echo ""
        green "=== sing-box 管理 === 状态: ${sb_status}\n"
        green  "1. 启动 sing-box"
        green  "2. 停止 sing-box"
        green  "3. 重启 sing-box"
        purple "0. 返回主菜单"
        skyblue "————"
        reading "\n请输入选择: " choice
        case "$choice" in
            1) start_singbox ;;
            2) stop_singbox ;;
            3) restart_singbox ;;
            0) return ;;
            *) red "无效选项！"; sleep 1 ;;
        esac
    done
}

# ── 卸载核心逻辑（共享） ──────────────────────────
_do_uninstall_core() {
    local keep_config="${1:-false}"
    BACKUP_SUCCESS=false

    if [ "$keep_config" = true ]; then
        yellow "正在备份节点配置以便重装时恢复…"
        mkdir -p "$backup_dir"
        chmod 700 "$backup_dir"
        rm -f "${backup_dir}"/* 2>/dev/null

        [ -f "${conf_dir}/inbounds.json" ]  && cp "${conf_dir}/inbounds.json"  "${backup_dir}/inbounds.json"
        [ -f "${work_dir}/cert.pem" ]        && cp "${work_dir}/cert.pem"        "${backup_dir}/cert.pem"
        [ -f "${work_dir}/private.key" ]     && cp "${work_dir}/private.key"     "${backup_dir}/private.key"
        [ -f "${work_dir}/tunnel.yml" ]      && cp "${work_dir}/tunnel.yml"      "${backup_dir}/tunnel.yml"
        [ -f "${work_dir}/tunnel.json" ]     && cp "${work_dir}/tunnel.json"     "${backup_dir}/tunnel.json"
        [ -f "${work_dir}/cf.env" ]          && cp "${work_dir}/cf.env"          "${backup_dir}/cf.env"
        [ -f "${work_dir}/argo_token" ]      && cp "${work_dir}/argo_token"      "${backup_dir}/argo_token"
        chmod -R go-rwx "$backup_dir" 2>/dev/null

        if [ -s "${backup_dir}/inbounds.json" ] && [ -s "${backup_dir}/cert.pem" ]; then
            green "节点配置与证书已备份至 ${backup_dir}，重装时将自动检测并询问是否恢复"
            BACKUP_SUCCESS=true
        else
            red "备份失败（inbounds.json 或 cert.pem 缺失），将按未保留配置继续卸载"
            rm -rf "$backup_dir" 2>/dev/null
        fi
    else
        rm -rf "$backup_dir" 2>/dev/null
    fi

    systemctl stop    sing-box argo 2>/dev/null
    systemctl disable sing-box argo 2>/dev/null
    systemctl daemon-reload
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service

    local hy2_port
    hy2_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' \
        "${conf_dir}/inbounds.json" 2>/dev/null)
    if [ -n "$hy2_port" ] && [ "$hy2_port" != "null" ]; then
        remove_port "${hy2_port}/udp"
    else
        yellow "警告：无法读取 Hy2 端口，防火墙规则可能未清理，请手动检查 iptables\n"
    fi

    rm -rf "${work_dir}"
    rm -f /usr/bin/sb
}

# ── 卸载（交互） ──────────────────────────────────
uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice
    [[ "$choice" != [yY] ]] && { purple "已取消卸载\n"; return; }

    reading "是否保留节点配置与证书（UUID/端口/隧道/pinSHA256）以便重装时恢复？(y/n，回车默认 y): " keep_choice
    local keep_config=false
    [[ -z "$keep_choice" || "$keep_choice" == [yY] ]] && keep_config=true

    yellow "正在卸载…"
    _do_uninstall_core "$keep_config"

    if $keep_config && [ "${BACKUP_SUCCESS:-false}" = true ]; then
        green "\nsing-box 卸载完成，节点配置与证书已保留，下次安装时可选择恢复\n"
    else
        green "\nsing-box 卸载完成\n"
    fi
    exit 0
}

# ── 快捷指令 ──────────────────────────────────────
create_shortcut() {
    cat > "${work_dir}/sb.sh" << EOF
#!/usr/bin/env bash
bash <(curl -fsSL ${SCRIPT_URL}) \$1
EOF
    chmod +x "${work_dir}/sb.sh"
    ln -sf "${work_dir}/sb.sh" /usr/bin/sb
    [ -s /usr/bin/sb ] && green "\n快捷指令 sb 创建成功\n" || red "\n快捷指令创建失败\n"
}

# ── 更新脚本 ──────────────────────────────────────
update_script() {
    yellow "正在从 GitHub 拉取最新脚本…\n"
    local tmp
    tmp=$(mktemp)
    curl -fsSL "$SCRIPT_URL" -o "$tmp"
    if [ -s "$tmp" ] && [ "$(wc -c < "$tmp")" -gt 50 ]; then
        mv "$tmp" "${work_dir}/sb.sh"
        chmod +x "${work_dir}/sb.sh"
        ln -sf "${work_dir}/sb.sh" /usr/bin/sb
        green "脚本已更新，请重新运行 sb\n"
        exit 0
    else
        rm -f "$tmp"
        red "更新失败：下载内容异常，已回滚\n"
    fi
}

# ── 主菜单 ────────────────────────────────────────
menu() {
    local sb_status argo_status
    sb_status=$(check_singbox 2>&1)
    argo_status=$(check_argo 2>&1)
    clear; echo ""
    purple "=== 自用 sing-box 脚本 ===\n"
    purple "  Argo 状态: ${argo_status}"
    purple "singbox 状态: ${sb_status}\n"
    green  "1. 安装 sing-box"
    red    "2. 卸载 sing-box"
    echo   "==============="
    green  "3. sing-box 管理"
    green  "4. Argo 隧道管理"
    echo   "==============="
    green  "5. 刷新节点信息"
    green  "6. 修改节点配置"
    echo   "==============="
    green  "7. 大陆域名拦截"
    echo   "==============="
    green  "8. 升级 sing-box"
    green  "9. 更新脚本"
    echo   "==============="
    purple "10. SSH 综合工具箱"
    echo   "==============="
    red    "0. 退出脚本"
    echo   "==========="
}

# ── 安装后防火墙收尾 ─────────────────────────────

#!/usr/bin/env bash
# ── 安装后防火墙收尾 ─────────────────────────────

# ── 辅助：循环删除 INPUT 链中所有兜底规则（DROP / REJECT 各变种）──
_flush_default_rules() {
    local tbl="$1"

    # 空值保护 + 命令存在性检查，防止无限循环
    [[ -z "$tbl" ]] && return 1
    command -v "$tbl" &>/dev/null || return 1

    while "$tbl" -D INPUT -j DROP                                        2>/dev/null; do :; done
    while "$tbl" -D INPUT -j REJECT                                      2>/dev/null; do :; done
    while "$tbl" -D INPUT -j REJECT --reject-with icmp-host-prohibited   2>/dev/null; do :; done
    while "$tbl" -D INPUT -j REJECT --reject-with icmp-port-unreachable  2>/dev/null; do :; done
    while "$tbl" -D INPUT -j REJECT --reject-with tcp-reset              2>/dev/null; do :; done
}

setup_firewall_base() {
    # ── 0. 前置检查 ──
    command -v iptables &>/dev/null || { yellow "iptables 未找到，跳过防火墙配置"; return; }

    # 非 root 时 ss 看不到进程名，提前警告
    if [ "$(id -u)" -ne 0 ]; then
        yellow "警告：当前非 root，进程名将无法显示"
    fi

    # ── 1. 放行 ESTABLISHED/RELATED（锁定在第 1 条）──
    iptables  -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
        || iptables  -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
    ip6tables -C INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 1 -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

    # ── 2. 放行 loopback（锁定在第 2 条）──
    iptables  -C INPUT -i lo -j ACCEPT 2>/dev/null \
        || iptables  -I INPUT 2 -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 2 -i lo -j ACCEPT 2>/dev/null || true

    # ── 3. 放行 SSH 端口（锁定在第 3 条）──
    local ssh_port
    ssh_port=$(ss -tlnpH 2>/dev/null | grep 'sshd' \
        | awk '{print $5}' | grep -oE '[0-9]+$' | head -1)
    if [ -z "$ssh_port" ]; then
        ssh_port=22
        yellow "警告：未检测到 sshd 监听端口，默认放行 22"
    fi
    iptables  -C INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null \
        || iptables  -I INPUT 3 -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null || true
    ip6tables -C INPUT -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null \
        || ip6tables -I INPUT 3 -p tcp --dport "$ssh_port" -j ACCEPT 2>/dev/null || true

    # ── 4. 清空所有兜底规则，稍后统一在链尾追加 DROP ──
    _flush_default_rules iptables
    _flush_default_rules ip6tables

    # ── 5. 扫描公网监听端口，收集未放行的端口 ──
    # IPv4 和 IPv6 已放行端口分别查询，独立判断
    local accepted4_tcp accepted4_udp accepted6_tcp accepted6_udp
    accepted4_tcp=$(iptables  -S INPUT 2>/dev/null \
        | grep ' -p tcp ' | grep -oE -- '--dport [0-9]+' | awk '{print $2}')
    accepted4_udp=$(iptables  -S INPUT 2>/dev/null \
        | grep ' -p udp ' | grep -oE -- '--dport [0-9]+' | awk '{print $2}')
    accepted6_tcp=$(ip6tables -S INPUT 2>/dev/null \
        | grep ' -p tcp ' | grep -oE -- '--dport [0-9]+' | awk '{print $2}')
    accepted6_udp=$(ip6tables -S INPUT 2>/dev/null \
        | grep ' -p udp ' | grep -oE -- '--dport [0-9]+' | awk '{print $2}')

    local unknown_ports=()
    # 循环内用到的变量统一提到循环外
    local addr port proto proc already4 already6 dup_key is_dup existing
    while IFS= read -r line; do
        addr=$(echo "$line"  | awk '{print $5}')
        port=$(echo "$addr"  | grep -oE '[0-9]+$')

        # sed 's/6$//' 只去掉末尾的 6，tcp6→tcp，udp6→udp
        proto=$(echo "$line" | awk '{print $1}' | sed 's/6$//')

        proc=$(echo "$line"  | grep -oE 'users:\(\("[^"]+' \
            | grep -oE '"[^"]+' | tr -d '"')

        # 修复2：兼容 [::1] 无端口后缀的写法
        echo "$addr" | grep -qE '^127\.|^\[?::1\]?[:\[]?' && continue

        echo "$proc" | grep -qE '(cloudflared|argo)' && continue

        # 端口为空（含通配符 * 的行）打印警告后跳过
        if [ -z "$port" ]; then
            yellow "  警告：无法解析端口，跳过：$line"
            continue
        fi

        # 分别对 IPv4/IPv6 规则集判断是否已放行
        already4=false
        already6=false
        if [ "$proto" = "tcp" ]; then
            echo "$accepted4_tcp" | grep -qx "$port" && already4=true
            echo "$accepted6_tcp" | grep -qx "$port" && already6=true
        elif [ "$proto" = "udp" ]; then
            echo "$accepted4_udp" | grep -qx "$port" && already4=true
            echo "$accepted6_udp" | grep -qx "$port" && already6=true
        fi

        [[ "$already4" == true && "$already6" == true ]] && continue

        # 修复6：双栈场景下 tcp+tcp6 会产生重复条目，去重后只问一次
        dup_key="${port}|${proto}"
        is_dup=false
        for existing in "${unknown_ports[@]}"; do
            [[ "$existing" == "${dup_key}|"* ]] && is_dup=true && break
        done
        $is_dup && continue

        unknown_ports+=("${port}|${proto}|${proc:-unknown}")
    done < <(ss -tlunpH 2>/dev/null)

    # ── 6. 逐一询问，收集用户选择放行的端口 ──
    local ports_to_allow=()
    if [ ${#unknown_ports[@]} -gt 0 ]; then
        echo ""
        yellow "检测到以下端口有进程监听但未在防火墙放行，逐一确认是否放行："
        for entry in "${unknown_ports[@]}"; do
            local p_port p_proto p_proc reply
            p_port=$(echo "$entry"  | cut -d'|' -f1)
            p_proto=$(echo "$entry" | cut -d'|' -f2)
            p_proc=$(echo "$entry"  | cut -d'|' -f3)

            echo ""
            skyblue "  端口：${p_port}/${p_proto}  进程：${p_proc}"
            printf "  是否放行？[y/N]（30 秒后自动跳过） "
            read -r -t 30 reply </dev/tty || reply="n"
            case "$reply" in
                [Yy]*) ports_to_allow+=("${p_port}|${p_proto}") ;;
                *)     yellow "  跳过 ${p_port}/${p_proto}" ;;
            esac
        done
    fi

    # ── 7. 统一追加放行规则，最后追加 DROP ──
    for entry in "${ports_to_allow[@]}"; do
        local p_port p_proto
        p_port=$(echo "$entry"  | cut -d'|' -f1)
        p_proto=$(echo "$entry" | cut -d'|' -f2)
        iptables  -A INPUT -p "$p_proto" --dport "$p_port" -j ACCEPT 2>/dev/null || true
        ip6tables -A INPUT -p "$p_proto" --dport "$p_port" -j ACCEPT 2>/dev/null || true
        green "  已放行 ${p_port}/${p_proto}"
    done

    # 无论用户是否放行了端口，都追加 DROP 兜底
    iptables  -A INPUT -j DROP 2>/dev/null || true
    ip6tables -A INPUT -j DROP 2>/dev/null || true

    # ── 8. 持久化 ──
    # 用 tmpfile + mv，防止 iptables-save 失败时清空原文件
    mkdir -p /etc/iptables 2>/dev/null || true

    local tmp4 tmp6
    tmp4=$(mktemp 2>/dev/null)
    if [ -n "$tmp4" ] && iptables-save > "$tmp4" 2>/dev/null; then
        mv "$tmp4" /etc/iptables/rules.v4
    else
        rm -f "$tmp4"
        yellow "保存 rules.v4 失败"
    fi

    tmp6=$(mktemp 2>/dev/null)
    if [ -n "$tmp6" ] && ip6tables-save > "$tmp6" 2>/dev/null; then
        mv "$tmp6" /etc/iptables/rules.v6
    else
        rm -f "$tmp6"
        yellow "保存 rules.v6 失败"
    fi

    # ── 9. 持久化服务检查 ──
    # 修复5：非 systemd 系统上 systemctl 不存在，分开处理避免误判
    if command -v systemctl &>/dev/null; then
        if ! systemctl is-enabled netfilter-persistent 2>/dev/null | grep -q enabled; then
            yellow "警告：重启后规则可能不会自动恢复"
            printf "是否现在安装 iptables-persistent？[y/N] "
            local ans_persist
            read -r -t 30 ans_persist </dev/tty || ans_persist="n"
            case "$ans_persist" in
                [Yy]*)
                    apt-get install -y iptables-persistent 2>/dev/null \
                        || dnf install -y iptables-services 2>/dev/null \
                        || yum install -y iptables-services 2>/dev/null \
                        || yellow "自动安装失败，请手动安装 iptables-persistent"
                    ;;
                *)
                    yellow "跳过，建议手动安装 iptables-persistent"
                    ;;
            esac
        fi
    else
        yellow "警告：非 systemd 系统，请手动确保 iptables 规则开机加载"
    fi

    green "防火墙规则已配置完成"
}

# ── 安装流程 ──────────────────────────────────────
do_install() {
    TUNNEL_FULLY_RESTORED=false
    BACKUP_SUCCESS=false
    TUNNEL_TOKEN_MODE=false

    install_packages jq openssl curl

    yellow "正在查询 sing-box 最新版本…"
    local install_ver
    install_ver=$(get_latest_sb_version)
    if [ -z "$install_ver" ]; then
        yellow "无法获取最新版本，使用内置版本 ${SB_VERSION}"
        install_ver="$SB_VERSION"
    else
        green "将安装最新版本 v${install_ver}"
    fi

    install_singbox "$install_ver"
    setup_services
    sleep 2
    create_shortcut

    if [ -s "${conf_dir}/inbounds.json" ]; then
        [ -d "$backup_dir" ] && rm -rf "$backup_dir"
    else
        yellow "警告：inbounds.json 未落盘，保留备份目录以供重试"
    fi
    setup_firewall_base
    green "\nsing-box 安装完成！"

    if is_fixed_tunnel_configured && [ "${TUNNEL_FULLY_RESTORED}" = true ]; then
        green "Argo 固定隧道已完整恢复"
        get_info
    elif is_fixed_tunnel_configured && [ "${TUNNEL_TOKEN_MODE}" = true ]; then
        yellow "检测到 Token 模式隧道备份，域名：$(get_fixed_domain)"
        yellow "请进入 Argo 隧道管理 → 配置固定隧道，重新输入 Token 后用 sb -c 查看节点\n"
    elif is_fixed_tunnel_configured; then
        yellow "隧道配置文件存在但缺少凭据，请重新配置固定隧道\n"
    else
        yellow "请进入 Argo 隧道管理 配置固定隧道，再用 sb -c 查看节点\n"
    fi
}

# ── 入口 ──────────────────────────────────────────
trap 'echo ""; red "强制退出"; exit 1' INT

case "$1" in
    -i|--install)
        check_singbox &>/dev/null
        [ $? -ne 2 ] && { yellow "sing-box 已安装，跳过"; exit 0; }
        do_install
        ;;
    -u|--uninstall)
        yellow "正在无交互卸载 sing-box…\n"
        _do_uninstall_core false
        green "\nsing-box 卸载完成\n"
        ;;
    -c|--check)
        check_nodes
        ;;
    -h|--help)
        echo ""
        green "用法: sb [参数]"
        green "  -i, --install    安装"
        green "  -u, --uninstall  卸载"
        green "  -c, --check      查看节点"
        green "  -h, --help       帮助"
        green "  （无参数）       交互菜单"
        echo ""
        ;;
    "")
        while true; do
            menu
            reading "请输入选择(0-10): " choice
            echo ""
            need_pause=true
            case "$choice" in
                1)
                    check_singbox &>/dev/null
                    if [ $? -ne 2 ]; then
                        yellow "sing-box 已经安装！\n"
                    else
                        do_install
                    fi
                    ;;
                2)  uninstall_singbox;  need_pause=false ;;
                3)  manage_singbox;     need_pause=false ;;
                4)  manage_argo;        need_pause=true  ;;
                5)  get_info;           need_pause=true  ;;
                6)  change_config;      need_pause=true  ;;
                7)  cn_block_manage;    need_pause=true  ;;
                8)  upgrade_singbox;    need_pause=true  ;;
                9)  update_script;      need_pause=false ;;
                10)
                    clear
                    bash <(curl -fsSL https://ssh_tool.eooce.com)
                    need_pause=false
                    ;;
                0) exit 0 ;;
                *) red "无效选项，请输入 0-10" ;;
            esac
            [ "$need_pause" = true ] && read -n1 -s -r -p $'\033[1;91m按任意键返回…\033[0m'
            echo ""
        done
        ;;
    *)
        red "未知参数: $1"
        green "用法: sb [-i|-u|-c|-h]"
        exit 1
        ;;
esac
