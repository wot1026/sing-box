#!/bin/bash

# =========================
# 自用 sing-box 安装脚本
# 协议: vmess-argo(固定隧道) + hysteria2
# 最后更新时间: 2026.6.8
# =========================

export LANG=en_US.UTF-8

# 颜色定义
re="\033[0m"
red="\033[1;91m"
green="\e[1;32m"
yellow="\e[1;33m"
purple="\e[1;35m"
skyblue="\e[1;36m"
red()    { echo -e "\e[1;91m$1\033[0m"; }
green()  { echo -e "\e[1;32m$1\033[0m"; }
yellow() { echo -e "\e[1;33m$1\033[0m"; }
purple() { echo -e "\e[1;35m$1\033[0m"; }
skyblue(){ echo -e "\e[1;36m$1\033[0m"; }
reading(){ read -p "$(red "$1")" "$2"; }

# 常量
server_name="sing-box"
work_dir="/etc/sing-box"
conf_dir="${work_dir}/conf"
client_dir="${work_dir}/url.txt"
SCRIPT_URL="https://raw.githubusercontent.com/wot1026-cmd/sing-box/main/sing-box.sh"

# 二进制哈希校验（SHA256，按架构填写实际值）
HASH_SINGBOX_amd64=""
HASH_SINGBOX_arm64=""
HASH_SINGBOX_386=""
HASH_SINGBOX_armv7=""
HASH_SINGBOX_s390x=""
HASH_ARGO_amd64=""
HASH_ARGO_arm64=""
HASH_ARGO_386=""
HASH_ARGO_armv7=""
HASH_ARGO_s390x=""

export ARGO_PORT=${ARGO_PORT:-'8001'}
export CFIP=${CFIP:-'cf.877774.xyz'}
export CFPORT=${CFPORT:-'443'}

# root 检查
[[ $EUID -ne 0 ]] && red "请在 root 用户下运行脚本" && exit 1

command_exists() { command -v "$1" >/dev/null 2>&1; }

# 二进制哈希校验
verify_binary() {
    local file="$1"
    local expected_hash="$2"
    local name="$3"

    # 若未配置预期哈希，跳过校验并警告
    if [ -z "$expected_hash" ]; then
        yellow "警告：${name} 未配置哈希校验，跳过验证\n"
        return 0
    fi

    local actual_hash
    actual_hash=$(sha256sum "$file" | awk '{print $1}')
    if [ "$actual_hash" != "$expected_hash" ]; then
        red "校验失败：${name} 哈希不匹配！"
        red "期望: ${expected_hash}"
        red "实际: ${actual_hash}"
        rm -f "$file"
        return 1
    fi
    green "${name} 校验通过\n"
    return 0
}

# 服务状态检查（修复返回值：running=0, not running=1, not installed=2）
check_service() {
    local service_name=$1
    local service_file=$2
    if [[ ! -f "${service_file}" ]]; then
        red "not installed"
        return 2
    fi
    if command_exists apk; then
        if rc-service "${service_name}" status 2>/dev/null | grep -q "started"; then
            green "running"
            return 0
        else
            yellow "not running"
            return 1
        fi
    else
        if systemctl is-active "${service_name}" 2>/dev/null | grep -q "^active$"; then
            green "running"
            return 0
        else
            yellow "not running"
            return 1
        fi
    fi
}

check_singbox() { check_service "sing-box" "${work_dir}/${server_name}"; }
check_argo()    { check_service "argo" "${work_dir}/argo"; }

# 包管理
manage_packages() {
    if [ $# -lt 2 ]; then red "Unspecified package name or action"; return 1; fi
    action=$1; shift
    if [ "$action" == "install" ] && [ ! -d "$work_dir" ]; then
        yellow "正在更新系统软件包...\n"
        if command_exists apt; then DEBIAN_FRONTEND=noninteractive apt update -y && DEBIAN_FRONTEND=noninteractive apt upgrade -y
        elif command_exists dnf; then dnf update -y
        elif command_exists yum; then yum update -y
        elif command_exists apk; then apk update && apk upgrade
        fi
        green "系统更新完成\n"
    fi
    for package in "$@"; do
        if [ "$action" == "install" ]; then
            command_exists "$package" && { green "${package} already installed"; continue; }
            yellow "正在安装 ${package}..."
            if command_exists apt; then DEBIAN_FRONTEND=noninteractive apt install -y "$package"
            elif command_exists dnf; then dnf install -y "$package"
            elif command_exists yum; then yum install -y "$package"
            elif command_exists apk; then apk add "$package"
            fi
        elif [ "$action" == "uninstall" ]; then
            ! command_exists "$package" && { yellow "${package} is not installed"; continue; }
            yellow "正在卸载 ${package}..."
            if command_exists apt; then apt remove -y "$package" && apt autoremove -y
            elif command_exists dnf; then dnf remove -y "$package" && dnf autoremove -y
            elif command_exists yum; then yum remove -y "$package" && yum autoremove -y
            elif command_exists apk; then apk del "$package"
            fi
        fi
    done
    return 0
}

# 获取国旗 emoji
get_flag() {
    local country_code
    # 优先用 jq 解析，已安装 jq
    country_code=$(curl -sm 3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" \
        | jq -r '.country_code // empty' 2>/dev/null)
    [ -z "$country_code" ] && country_code=$(curl -sm 3 "https://ipapi.co/country_code" 2>/dev/null)
    case "$country_code" in
        US) echo "🇺🇸" ;; KR) echo "🇰🇷" ;; JP) echo "🇯🇵" ;;
        HK) echo "🇭🇰" ;; SG) echo "🇸🇬" ;; DE) echo "🇩🇪" ;;
        GB) echo "🇬🇧" ;; FR) echo "🇫🇷" ;; NL) echo "🇳🇱" ;;
        CA) echo "🇨🇦" ;; AU) echo "🇦🇺" ;; TW) echo "🇹🇼" ;;
        CN) echo "🇨🇳" ;; RU) echo "🇷🇺" ;; IN) echo "🇮🇳" ;;
        BR) echo "🇧🇷" ;; *)  echo "🌐" ;;
    esac
}

# 获取节点名称前缀（国旗 + hostname）
get_node_name() {
    local flag hostname_val
    flag=$(get_flag)
    hostname_val=$(hostname)
    echo "${flag} ${hostname_val}"
}

# 防火墙放行
allow_port() {
    has_ufw=0; has_firewalld=0; has_iptables=0; has_ip6tables=0
    command_exists ufw && has_ufw=1
    command_exists firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1 && has_firewalld=1
    command_exists iptables && has_iptables=1
    command_exists ip6tables && has_ip6tables=1

    [ "$has_ufw" -eq 1 ] && ufw --force default allow outgoing >/dev/null 2>&1
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --zone=public --set-target=ACCEPT >/dev/null 2>&1
    [ "$has_iptables" -eq 1 ] && {
        iptables -C INPUT -i lo -j ACCEPT 2>/dev/null || iptables -I INPUT 3 -i lo -j ACCEPT
        iptables -C INPUT -p icmp -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p icmp -j ACCEPT
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    }
    [ "$has_ip6tables" -eq 1 ] && {
        ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT 3 -i lo -j ACCEPT
        ip6tables -C INPUT -p icmp -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p icmp -j ACCEPT
        ip6tables -P FORWARD DROP 2>/dev/null || true
        ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    }
    for rule in "$@"; do
        port=${rule%/*}; proto=${rule#*/}
        [ "$has_ufw" -eq 1 ] && ufw allow in "${port}/${proto}" >/dev/null 2>&1
        [ "$has_firewalld" -eq 1 ] && firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1
        [ "$has_iptables" -eq 1 ] && (iptables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || iptables -I INPUT 4 -p "${proto}" --dport "${port}" -j ACCEPT)
        [ "$has_ip6tables" -eq 1 ] && (ip6tables -C INPUT -p "${proto}" --dport "${port}" -j ACCEPT 2>/dev/null || ip6tables -I INPUT 4 -p "${proto}" --dport "${port}" -j ACCEPT)
    done
    [ "$has_firewalld" -eq 1 ] && firewall-cmd --reload >/dev/null 2>&1
}

# 安装 sing-box 核心及 argo
install_singbox() {
    clear
    purple "正在安装 sing-box，请稍候..."
    ARCH_RAW=$(uname -m)
    case "${ARCH_RAW}" in
        'x86_64'|'amd64')    ARCH='amd64' ;;
        'x86'|'i686'|'i386') ARCH='386' ;;
        'aarch64'|'arm64')   ARCH='arm64' ;;
        'armv7l')             ARCH='armv7' ;;
        's390x')              ARCH='s390x' ;;
        *) red "不支持的架构: ${ARCH_RAW}"; exit 1 ;;
    esac

    [ ! -d "${work_dir}" ] && mkdir -p "${work_dir}" && chmod 755 "${work_dir}" && mkdir -p "${conf_dir}"

    # 下载二进制
    curl -sLo "${work_dir}/qrencode" "https://$ARCH.ssss.nyc.mn/qrencode"
    curl -sLo "${work_dir}/sing-box" "https://$ARCH.ssss.nyc.mn/sbx-1.13.13"
    curl -sLo "${work_dir}/argo"     "https://$ARCH.ssss.nyc.mn/bot"

    # 哈希校验（变量名动态拼接）
    eval "hash_sb=\${HASH_SINGBOX_${ARCH}}"
    eval "hash_argo=\${HASH_ARGO_${ARCH}}"
    verify_binary "${work_dir}/sing-box" "$hash_sb"  "sing-box" || exit 1
    verify_binary "${work_dir}/argo"     "$hash_argo" "argo"     || exit 1

    chown root:root "${work_dir}"
    chmod 755 "${work_dir}"
    chmod +x "${work_dir}/${server_name}" "${work_dir}/argo" "${work_dir}/qrencode"

    hy2_port=$(shuf -i 10000-65000 -n 1)
    uuid=$(cat /proc/sys/kernel/random/uuid)

    allow_port "${ARGO_PORT}/tcp" "${hy2_port}/udp" > /dev/null 2>&1

    # 生成自签证书
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key"
    openssl req -new -x509 -days 3650 -key "${work_dir}/private.key" \
        -out "${work_dir}/cert.pem" -subj "/CN=bing.com"

    # log
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

    # ntp
    cat > "${conf_dir}/ntp.json" << EOF
{
  "ntp": {
    "enabled": true,
    "server": "time.apple.com",
    "server_port": 123,
    "interval": "60m"
  }
}
EOF

    # dns（仅 IPv4）
    cat > "${conf_dir}/dns.json" << EOF
{
  "dns": {
    "servers": [{"tag": "local", "type": "local"}],
    "strategy": "ipv4_only"
  }
}
EOF

    # inbounds：vmess-argo + hysteria2
    cat > "${conf_dir}/inbounds.json" << EOF
{
  "inbounds": [
    {
      "type": "vmess",
      "tag": "vmess-ws",
      "listen": "0.0.0.0",
      "listen_port": ${ARGO_PORT},
      "users": [{"uuid": "${uuid}"}],
      "transport": {
        "type": "ws",
        "path": "/vmess-argo",
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

    # outbounds
    cat > "${conf_dir}/outbounds.json" << EOF
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ]
}
EOF

    # route
    cat > "${conf_dir}/route.json" << EOF
{
  "route": {
    "rule_set": [],
    "rules": [],
    "final": "direct"
  }
}
EOF

    # experimental
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

    green "sing-box 核心安装完成\n"
    yellow "注意：Argo 固定隧道需在主菜单 -> Argo 隧道管理 中配置后才能使用 VMess 节点\n"
}

# systemd 服务（argo 初始为占位，配置固定隧道后再启动）
main_systemd_services() {
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

    # argo 服务：仅固定隧道，ExecStart 由配置函数写入
    cat > /etc/systemd/system/argo.service << EOF
[Unit]
Description=Cloudflare Tunnel (Fixed)
After=network.target

[Service]
Type=simple
NoNewPrivileges=yes
TimeoutStartSec=0
EnvironmentFile=-/etc/sing-box/argo.env
ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1"
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    if [ -f /etc/centos-release ]; then
        yum install -y chrony
        systemctl start chronyd && systemctl enable chronyd
        chronyc -a makestep
        yum update -y ca-certificates
        bash -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    fi
    systemctl daemon-reload
    systemctl enable sing-box && systemctl start sing-box
    # argo 不在此处启动，等固定隧道配置完成后再启动
    systemctl enable argo
}

# alpine openrc（仅固定隧道）
alpine_openrc_services() {
    cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
description="sing-box service"
command="/etc/sing-box/sing-box"
command_args="run -C /etc/sing-box/conf"
command_background=true
pidfile="/var/run/sing-box.pid"
EOF
    cat > /etc/init.d/argo << 'EOF'
#!/sbin/openrc-run
description="Cloudflare Tunnel (Fixed)"
command="/etc/sing-box/argo"
command_args="tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run"
command_background=true
pidfile="/var/run/argo.pid"
output_log="/etc/sing-box/argo.log"
error_log="/etc/sing-box/argo.log"
EOF
    chmod +x /etc/init.d/sing-box /etc/init.d/argo
    rc-update add sing-box default > /dev/null 2>&1
    rc-update add argo default     > /dev/null 2>&1
}

# 通用服务管理
manage_service() {
    local service_name="$1" action="$2"
    case "$action" in
        start)
            yellow "正在启动 ${service_name}...\n"
            if command_exists rc-service; then rc-service "$service_name" start
            else systemctl daemon-reload && systemctl start "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 已启动\n" || red "${service_name} 启动失败\n"
            ;;
        stop)
            yellow "正在停止 ${service_name}...\n"
            if command_exists rc-service; then rc-service "$service_name" stop
            else systemctl stop "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 已停止\n" || red "${service_name} 停止失败\n"
            ;;
        restart)
            yellow "正在重启 ${service_name}...\n"
            if command_exists rc-service; then rc-service "$service_name" restart
            else systemctl daemon-reload && systemctl restart "$service_name"; fi
            [ $? -eq 0 ] && green "${service_name} 已重启\n" || red "${service_name} 重启失败\n"
            ;;
    esac
}

start_singbox()  { manage_service "sing-box" "start"; }
stop_singbox()   { manage_service "sing-box" "stop"; }
restart_singbox(){ manage_service "sing-box" "restart"; }
start_argo()     { manage_service "argo" "start"; }
stop_argo()      { manage_service "argo" "stop"; }
restart_argo()   { manage_service "argo" "restart"; }

# 获取固定隧道域名
get_fixed_domain() {
    grep -oP '(?<=hostname: )\S+' "${work_dir}/tunnel.yml" 2>/dev/null | head -1
}

# 检查固定隧道是否已配置
is_fixed_tunnel_configured() {
    [ -f "${work_dir}/tunnel.yml" ]
}

# 更新 url.txt 中的 VMess Argo 域名（接受参数，不依赖全局变量）
update_vmess_domain() {
    local new_domain="$1"
    if [ -z "$new_domain" ]; then
        red "域名为空，无法更新 VMess 节点\n"
        return 1
    fi
    if [ ! -f "$client_dir" ]; then
        red "url.txt 不存在，请先完成节点信息生成\n"
        return 1
    fi

    local vmess_url encoded_vmess decoded_vmess updated_vmess encoded_updated new_vmess
    vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir")
    if [ -z "$vmess_url" ]; then
        red "未找到 VMess 节点，无法更新\n"
        return 1
    fi
    encoded_vmess="${vmess_url#vmess://}"
    decoded_vmess=$(echo "$encoded_vmess" | base64 --decode 2>/dev/null)
    updated_vmess=$(echo "$decoded_vmess" | jq \
        --arg d "$new_domain" \
        '.host = $d | .sni = $d | .fp = "chrome" | .allowInsecure = false')
    encoded_updated=$(echo "$updated_vmess" | base64 | tr -d '\n')
    new_vmess="vmess://${encoded_updated}"
    sed -i "s|${vmess_url}|${new_vmess}|" "$client_dir"
    green "VMess 节点已更新\n"
    purple "$new_vmess\n"
}

# 获取节点信息并输出链接
get_info() {
    yellow "\nIP 检测中，请稍候...\n"
    server_ip=$(curl -4 -sm 3 ip.sb)
    node_prefix=$(get_node_name)
    clear

    hy2_port=$(jq -r '.inbounds[] | select(.type == "hysteria2") | .listen_port' "${conf_dir}/inbounds.json")
    uuid=$(jq -r '.inbounds[] | select(.type == "vmess") | .users[0].uuid' "${conf_dir}/inbounds.json")
    fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" \
        | cut -d'=' -f2 | sed 's/:/%3A/g')

    # 固定隧道域名
    local argodomain=""
    if is_fixed_tunnel_configured; then
        argodomain=$(get_fixed_domain)
    fi

    if [ -z "$argodomain" ]; then
        yellow "未检测到固定隧道域名，VMess 节点暂不可用，请先配置 Argo 固定隧道\n"
    else
        green "\nArgo 域名：${purple}${argodomain}${re}\n"
    fi

    local VMESS_JSON
    VMESS_JSON=$(jq -n \
        --arg ps   "${node_prefix} argo" \
        --arg add  "${CFIP}" \
        --arg port "${CFPORT}" \
        --arg id   "${uuid}" \
        --arg host "${argodomain}" \
        '{
            v: "2", ps: $ps, add: $add, port: $port,
            id: $id, aid: "0", scy: "none",
            net: "ws", type: "none",
            host: $host, path: "/vmess-argo?ed=2560",
            tls: "tls", sni: $host,
            alpn: "", fp: "chrome",
            allowInsecure: false
        }')

    cat > "${work_dir}/url.txt" << EOF
vmess://$(echo "$VMESS_JSON" | base64 | tr -d '\n')

hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none#${node_prefix} hy2
EOF

    echo ""
    while IFS= read -r line; do echo -e "${purple}$line"; done < "${work_dir}/url.txt"
    echo -e "${re}"
}

# 查看节点
check_nodes() {
    [ ! -f "${work_dir}/url.txt" ] && { red "节点信息不存在，请先安装 sing-box"; return 1; }
    clear; echo ""
    green "=== 当前节点信息 ===\n"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo -e "${purple}${line}${re}\n"
        [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "$line"
        echo ""
    done < "${work_dir}/url.txt"
}

# 大陆拦截管理
cn_block_manage() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; menu; return; }

    if ! command_exists python3; then
        yellow "正在安装 python3...\n"
        manage_packages install python3
        if ! command_exists python3; then
            red "python3 安装失败，无法继续"; sleep 2; return
        fi
    fi

    local route_file="${conf_dir}/route.json"
    local block_enabled=false
    jq -e '.route.rules[] | select(.rule_set[]? == "geosite-cn")' "$route_file" >/dev/null 2>&1 && block_enabled=true

    clear; echo ""
    green "=== 大陆域名拦截管理 ===\n"
    if $block_enabled; then
        green "当前状态：${purple}已开启${re}\n"
    else
        yellow "当前状态：未开启\n"
    fi
    green "1. 开启大陆拦截"
    skyblue "---------------"
    red   "2. 关闭大陆拦截"
    skyblue "---------------"
    purple "0. 返回主菜单"
    skyblue "---------------"
    reading "请输入选择: " choice
    case "$choice" in
        1)
            if $block_enabled; then
                yellow "大陆拦截已开启，无需重复操作\n"; sleep 1; return
            fi
            # 用环境变量传路径，避免插值问题
            ROUTE_CFG="$route_file" python3 << 'PYEOF'
import json, os, sys
cfg = os.environ['ROUTE_CFG']
with open(cfg) as f:
    c = json.load(f)

route = c['route']
rules = [r for r in route.get('rules', []) if not (
    'rule_set' in r and r.get('outbound') in ('block', 'direct') and
    any(x in r.get('rule_set', []) for x in ['geosite-cn', 'geoip-cn'])
)]
rules = [r for r in rules if not ('domain_regex' in r and r.get('outbound') == 'direct')]

rules.insert(0, {
    'domain_regex': [
        '^([a-zA-Z0-9_-]+\\.)*googleapis\\.cn',
        '^([a-zA-Z0-9_-]+\\.)*googleapis\\.com',
        '^([a-zA-Z0-9_-]+\\.)*gstatic\\.com',
        '^([a-zA-Z0-9_-]+\\.)*xn--ngstr-lra8j\\.com'
    ],
    'outbound': 'direct'
})
rules.insert(1, {'rule_set': ['geosite-cn'], 'outbound': 'block'})
route['rules'] = rules

rule_sets = route.get('rule_set', [])
tags = [rs['tag'] for rs in rule_sets]
if 'geosite-cn' not in tags:
    rule_sets.append({
        'type': 'remote',
        'tag': 'geosite-cn',
        'format': 'binary',
        'url': 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs',
        'download_detour': 'direct'
    })
route['rule_set'] = rule_sets
c['route'] = route

with open(cfg, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
print('完成')
PYEOF
            [ $? -ne 0 ] && { red "配置写入失败"; sleep 2; return; }
            restart_singbox
            green "\n大陆域名拦截已开启\n"
            ;;
        2)
            if ! $block_enabled; then
                yellow "大陆拦截未开启\n"; sleep 1; return
            fi
            ROUTE_CFG="$route_file" python3 << 'PYEOF'
import json, os
cfg = os.environ['ROUTE_CFG']
with open(cfg) as f:
    c = json.load(f)

route = c['route']
route['rules'] = [r for r in route.get('rules', []) if not (
    ('rule_set' in r and 'geosite-cn' in r.get('rule_set', [])) or
    ('domain_regex' in r and r.get('outbound') == 'direct' and
     any('googleapis' in x for x in r.get('domain_regex', [])))
)]
route['rule_set'] = [rs for rs in route.get('rule_set', []) if rs['tag'] != 'geosite-cn']
c['route'] = route

with open(cfg, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
print('完成')
PYEOF
            [ $? -ne 0 ] && { red "配置写入失败"; sleep 2; return; }
            restart_singbox
            green "\n大陆域名拦截已关闭\n"
            ;;
        0) menu ;;
        *) red "无效选项" ;;
    esac
}

# 修改节点配置
change_config() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; menu; return; }

    local singbox_status
    check_singbox > /tmp/_sb_status 2>&1; singbox_status=$(cat /tmp/_sb_status)
    clear; echo ""
    green "=== 修改节点配置 ===\n"
    green "sing-box 当前状态: ${singbox_status}\n"
    green "1. 修改 UUID"
    skyblue "------------"
    green "2. 修改 Hysteria2 端口"
    skyblue "-------------------"
    green "3. 修改 VMess-Argo 端口"
    skyblue "---------------------"
    green "4. 修改 CF 优选域名"
    skyblue "------------------"
    green "5. 修改节点 IP 为 IPv4"
    skyblue "--------------------"
    green "6. 修改节点 IP 为 IPv6"
    skyblue "--------------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    local inbounds_file="${conf_dir}/inbounds.json"
    case "$choice" in
        1)
            reading "\n请输入新的 UUID（直接回车随机生成）: " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            jq --arg uuid "$new_uuid" \
               '(.inbounds[] | select(.users != null) | .users[] | select(.uuid != null).uuid) = $uuid |
                (.inbounds[] | select(.users != null) | .users[] | select(.password != null).password) = $uuid' \
               "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            restart_singbox
            get_info
            green "\nUUID 已修改为：${purple}${new_uuid}${re}\n"
            ;;
        2)
            reading "\n请输入新的 Hysteria2 端口（直接回车随机生成）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 10000-65000 -n 1)
            jq --argjson port "$new_port" \
               '(.inbounds[] | select(.type == "hysteria2").listen_port) = $port' \
               "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${new_port}/udp" > /dev/null 2>&1
            restart_singbox
            get_info
            green "\nHysteria2 端口已修改为：${purple}${new_port}${re}\n"
            ;;
        3)
            reading "\n请输入新的 VMess-Argo 端口（直接回车随机生成）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 10000-65000 -n 1)
            jq --argjson port "$new_port" \
               '(.inbounds[] | select(.type == "vmess").listen_port) = $port' \
               "$inbounds_file" > "${inbounds_file}.tmp" && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${new_port}/tcp" > /dev/null 2>&1
            # 更新 tunnel.yml 中的 service 端口
            if [ -f "${work_dir}/tunnel.yml" ]; then
                sed -i "s|service: http://localhost:[0-9]*|service: http://localhost:${new_port}|" "${work_dir}/tunnel.yml"
            fi
            restart_singbox
            restart_argo
            get_info
            green "\nVMess-Argo 端口已修改为：${purple}${new_port}${re}\n"
            ;;
        4)
            clear
            green "1: cf.090227.xyz  2: cf.877774.xyz  3: cf.877771.xyz  4: cdns.doon.eu.org\n"
            reading "请输入优选域名或 IP（直接回车默认 cf.877774.xyz）: " cfip_input
            case "$cfip_input" in
                ""|"2") cfip="cf.877774.xyz"; cfport="443" ;;
                "1")    cfip="cf.090227.xyz"; cfport="443" ;;
                "3")    cfip="cf.877771.xyz"; cfport="443" ;;
                "4")    cfip="cdns.doon.eu.org"; cfport="443" ;;
                *)
                    if [[ "$cfip_input" =~ : ]]; then
                        cfip=$(echo "$cfip_input" | cut -d':' -f1)
                        cfport=$(echo "$cfip_input" | cut -d':' -f2)
                    else
                        cfip="$cfip_input"; cfport="443"
                    fi
                    ;;
            esac
            local vmess_url encoded decoded updated new_encoded new_vmess
            vmess_url=$(grep -o 'vmess://[^ ]*' "$client_dir")
            encoded="${vmess_url#vmess://}"
            decoded=$(echo "$encoded" | base64 --decode 2>/dev/null)
            updated=$(echo "$decoded" | jq --arg cfip "$cfip" --arg cfport "$cfport" \
                '.add = $cfip | .port = $cfport | .fp = "chrome" | .allowInsecure = false')
            new_encoded=$(echo "$updated" | base64 | tr -d '\n')
            new_vmess="vmess://$new_encoded"
            sed -i "s|${vmess_url}|${new_vmess}|" "$client_dir"
            green "\nCF 优选域名已更新为：${purple}${cfip}:${cfport}${re}\n"
            purple "$new_vmess\n"
            ;;
        5)
            new_ipv4=$(curl -4 -sm 3 ip.sb)
            [[ ! "$new_ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { red "\n获取 IPv4 失败\n"; return 1; }
            sed -i -E "/^hysteria2:\/\// s#@\[[0-9a-fA-F:]+\]#@${new_ipv4}#g" "$client_dir"
            green "\n节点 IP 已切换为 IPv4: ${purple}${new_ipv4}${re}\n"
            check_nodes
            ;;
        6)
            new_ipv6=$(curl -6 -sm 3 ip.sb)
            [[ ! "$new_ipv6" =~ ^[0-9a-fA-F:]+$ ]] && { red "\n获取 IPv6 失败\n"; return 1; }
            sed -i -E "/^hysteria2:\/\// s#@([0-9]{1,3}\.){3}[0-9]{1,3}#@[${new_ipv6}]#g" "$client_dir"
            green "\n节点 IP 已切换为 IPv6: ${purple}[${new_ipv6}]${re}\n"
            check_nodes
            ;;
        0) menu ;;
        *) red "无效选项！" ;;
    esac
}

# 配置固定 Argo 隧道（写入 tunnel.yml，token 存 env 文件）
configure_fixed_tunnel() {
    clear
    yellow "\n固定隧道支持 json 或 token 两种方式，端口为 ${ARGO_PORT}\njson 获取：${purple}https://fscarmen.cloudflare.now.cc${re}\n"
    reading "\n请输入 Argo 域名: " argo_domain
    if [ -z "$argo_domain" ]; then
        red "域名不能为空"; return 1
    fi
    reading "\n请输入 Argo 密钥（token 或 json）: " argo_auth
    if [ -z "$argo_auth" ]; then
        red "密钥不能为空"; return 1
    fi

    if [[ $argo_auth =~ TunnelSecret ]]; then
        # JSON 凭据
        echo "$argo_auth" > "${work_dir}/tunnel.json"
        local tunnel_id
        tunnel_id=$(echo "$argo_auth" | jq -r '.TunnelID // empty' 2>/dev/null)
        [ -z "$tunnel_id" ] && tunnel_id=$(cut -d'"' -f12 <<< "$argo_auth")
        cat > "${work_dir}/tunnel.yml" << EOF
tunnel: ${tunnel_id}
credentials-file: ${work_dir}/tunnel.json
protocol: http2

ingress:
  - hostname: ${argo_domain}
    service: http://localhost:${ARGO_PORT}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
        # systemd：直接用 tunnel.yml，不含敏感信息
        if command_exists systemctl; then
            sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --config /etc/sing-box/tunnel.yml run 2>&1"' \
                /etc/systemd/system/argo.service
            systemctl daemon-reload
        fi

    elif [[ $argo_auth =~ ^[A-Z0-9a-z=]{120,250}$ ]]; then
        # Token 凭据：写入独立 env 文件，服务读取，避免暴露在 ExecStart
        echo "ARGO_TOKEN=${argo_auth}" > "${work_dir}/argo.env"
        chmod 600 "${work_dir}/argo.env"
        # tunnel.yml 仅用于记录域名（argo token 模式不需要 tunnel.yml，此处仅占位供 get_fixed_domain 使用）
        cat > "${work_dir}/tunnel.yml" << EOF
# token mode - domain record only
hostname: ${argo_domain}
EOF
        if command_exists systemctl; then
            # 从 env 文件读取 token
            sed -i '/^ExecStart=/c ExecStart=/bin/sh -c "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token \${ARGO_TOKEN} 2>&1"' \
                /etc/systemd/system/argo.service
            systemctl daemon-reload
        elif command_exists rc-service; then
            # Alpine：将 token 写入 openrc conf
            echo "ARGO_TOKEN=${argo_auth}" > "/etc/conf.d/argo"
            chmod 600 "/etc/conf.d/argo"
            cat > /etc/init.d/argo << 'EOF'
#!/sbin/openrc-run
description="Cloudflare Tunnel (Fixed Token)"
pidfile="/var/run/argo.pid"

start() {
    [ -f /etc/conf.d/argo ] && . /etc/conf.d/argo
    ebegin "Starting argo"
    start-stop-daemon --start --background \
        --make-pidfile --pidfile "$pidfile" \
        --stdout /etc/sing-box/argo.log \
        --stderr /etc/sing-box/argo.log \
        --exec /bin/sh -- -c \
        "/etc/sing-box/argo tunnel --edge-ip-version auto --no-autoupdate --protocol http2 run --token ${ARGO_TOKEN}"
    eend $?
}

stop() {
    ebegin "Stopping argo"
    start-stop-daemon --stop --pidfile "$pidfile"
    eend $?
}
EOF
            chmod +x /etc/init.d/argo
        fi
    else
        yellow "输入格式不匹配，请重新配置"; return 1
    fi

    restart_argo
    sleep 2
    # get_info 会生成/更新 url.txt 并写入正确的 Argo 域名
    get_info
    green "\n固定隧道已配置完成，域名：${purple}${argo_domain}${re}\n"
}

# Argo 隧道管理（仅固定隧道）
manage_argo() {
    local argo_status
    check_argo > /tmp/_argo_status 2>&1; argo_status=$(cat /tmp/_argo_status)
    clear; echo ""
    green "=== Argo 隧道管理（固定隧道）===\n"
    green "Argo 当前状态: ${argo_status}\n"
    if is_fixed_tunnel_configured; then
        green "当前域名: ${purple}$(get_fixed_domain)${re}\n"
    else
        yellow "固定隧道尚未配置\n"
    fi
    green "1. 启动 Argo"
    skyblue "------------"
    green "2. 停止 Argo"
    skyblue "------------"
    green "3. 重启 Argo"
    skyblue "------------"
    green "4. 配置固定隧道"
    skyblue "--------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "$choice" in
        1) start_argo ;;
        2) stop_argo ;;
        3) restart_argo ;;
        4) configure_fixed_tunnel ;;
        0) menu ;;
        *) red "无效选项！" ;;
    esac
}

# sing-box 管理
manage_singbox() {
    local singbox_status
    check_singbox > /tmp/_sb_status 2>&1; singbox_status=$(cat /tmp/_sb_status)
    clear; echo ""
    green "=== sing-box 管理 ===\n"
    green "sing-box 当前状态: ${singbox_status}\n"
    green "1. 启动 sing-box"
    skyblue "-----------------"
    green "2. 停止 sing-box"
    skyblue "-----------------"
    green "3. 重启 sing-box"
    skyblue "-----------------"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "$choice" in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        0) menu ;;
        *) red "无效选项！" && sleep 1 && manage_singbox ;;
    esac
}

# 卸载
uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice
    case "$choice" in
        y|Y)
            yellow "正在卸载 sing-box...\n"
            if command_exists rc-service; then
                rc-service sing-box stop; rc-service argo stop
                rm -f /etc/init.d/sing-box /etc/init.d/argo /etc/conf.d/argo
                rc-update del sing-box default; rc-update del argo default
            else
                systemctl stop sing-box argo
                systemctl disable sing-box argo
                systemctl daemon-reload
            fi
            rm -rf "${work_dir}"
            rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
            rm -f /usr/bin/sb /tmp/_sb_status /tmp/_argo_status
            green "\nsing-box 卸载成功\n"
            exit 0
            ;;
        *) purple "已取消卸载\n" ;;
    esac
}

# 创建快捷指令
create_shortcut() {
    cat > "${work_dir}/sb.sh" << EOF
#!/usr/bin/env bash
bash <(curl -Ls ${SCRIPT_URL}) \$1
EOF
    chmod +x "${work_dir}/sb.sh"
    ln -sf "${work_dir}/sb.sh" /usr/bin/sb
    [ -s /usr/bin/sb ] && green "\n快捷指令 sb 创建成功\n" || red "\n快捷指令创建失败\n"
}

# 更新脚本
update_script() {
    yellow "正在从 GitHub 更新脚本...\n"
    curl -Ls "${SCRIPT_URL}" -o "${work_dir}/sb.sh"
    if [ $? -eq 0 ]; then
        chmod +x "${work_dir}/sb.sh"
        ln -sf "${work_dir}/sb.sh" /usr/bin/sb
        green "脚本已更新完成，请重新运行 sb\n"
        exit 0
    else
        red "更新失败，请检查网络或 GitHub 链接\n"
    fi
}

# alpine 适配
change_hosts() {
    sh -c 'echo "0 0" > /proc/sys/net/ipv4/ping_group_range'
    sed -i '1s/.*/127.0.0.1   localhost/' /etc/hosts
    sed -i '2s/.*/::1         localhost/' /etc/hosts
}

# 主菜单
menu() {
    local singbox_status argo_status
    check_singbox > /tmp/_sb_status   2>&1; singbox_status=$(cat /tmp/_sb_status)
    check_argo    > /tmp/_argo_status 2>&1; argo_status=$(cat /tmp/_argo_status)

    clear; echo ""
    purple "=== 自用 sing-box 安装脚本 ===\n"
    purple "---Argo 状态: ${argo_status}"
    purple "singbox 状态: ${singbox_status}\n"
    green  "1. 安装 sing-box"
    red    "2. 卸载 sing-box"
    echo   "==============="
    green  "3. sing-box 管理"
    green  "4. Argo 隧道管理"
    echo   "==============="
    green  "5. 查看节点信息"
    green  "6. 修改节点配置"
    echo   "==============="
    green  "7. 大陆域名拦截"
    echo   "==============="
    green  "8. 更新脚本"
    echo   "==============="
    red    "0. 退出脚本"
    echo   "==========="
}

trap 'red "\n强制退出"; exit' INT

case "$1" in
    -i|--install)
        check_singbox &>/dev/null
        if [ $? -eq 0 ]; then
            yellow "sing-box 已安装，跳过"; exit 0
        fi
        manage_packages install jq tar openssl lsof coreutils
        install_singbox
        if command_exists systemctl; then
            main_systemd_services
        elif command_exists rc-update; then
            alpine_openrc_services
            change_hosts
            rc-service sing-box restart
        else
            red "不支持的 init 系统"; exit 1
        fi
        sleep 3
        green "\nsing-box 安装完成\n"
        yellow "请进入菜单 -> Argo 隧道管理 -> 配置固定隧道，再使用 sb -c 查看节点\n"
        create_shortcut
        ;;
    -u|--uninstall)
        yellow "正在无交互卸载 sing-box...\n"
        if command_exists rc-service; then
            rc-service sing-box stop >/dev/null 2>&1
            rc-service argo stop >/dev/null 2>&1
            rc-update del sing-box default >/dev/null 2>&1
            rc-update del argo default >/dev/null 2>&1
            rm -f /etc/init.d/sing-box /etc/init.d/argo /etc/conf.d/argo
        elif command_exists systemctl; then
            systemctl stop sing-box argo >/dev/null 2>&1
            systemctl disable sing-box argo >/dev/null 2>&1
            systemctl daemon-reload >/dev/null 2>&1
            rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/argo.service
        fi
        rm -rf "${work_dir}"
        rm -f /usr/bin/sb /tmp/_sb_status /tmp/_argo_status
        green "\nsing-box 卸载完成\n"
        ;;
    -c|--check)
        check_nodes; exit 0
        ;;
    -h|--help)
        echo ""
        green "用法: sb [参数]"
        green "  -i, --install     无交互安装（安装后需手动配置固定隧道）"
        green "  -c, --check       查看节点信息"
        green "  -u, --uninstall   无交互卸载"
        green "  -h, --help        显示帮助"
        green "  不带参数          进入交互式主菜单"
        echo ""
        exit 0
        ;;
    "")
        while true; do
            menu
            reading "请输入选择(0-8): " choice
            echo ""
            need_pause=true
            case "$choice" in
                1)
                    check_singbox &>/dev/null; singbox_check=$?
                    if [ $singbox_check -eq 0 ]; then
                        yellow "sing-box 已经安装！\n"
                    else
                        manage_packages install jq tar openssl lsof coreutils
                        install_singbox
                        if command_exists systemctl; then
                            main_systemd_services
                        elif command_exists rc-update; then
                            alpine_openrc_services
                            change_hosts
                            rc-service sing-box restart
                        else
                            red "不支持的 init 系统"; exit 1
                        fi
                        sleep 3
                        green "\nsing-box 安装完成，请进入 Argo 隧道管理配置固定隧道\n"
                        create_shortcut
                    fi
                    ;;
                2) uninstall_singbox; need_pause=false ;;
                3) manage_singbox;    need_pause=false ;;
                4) manage_argo;       need_pause=true ;;
                5) check_nodes;       need_pause=true ;;
                6) change_config;     need_pause=true ;;
                7) cn_block_manage;   need_pause=true ;;
                8) update_script;     need_pause=false ;;
                0) exit 0 ;;
                *) red "无效的选项，请输入 0-8"; need_pause=true ;;
            esac
            [ "$need_pause" = true ] && read -n 1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
        done
        ;;
    *)
        red "未知参数: $1"
        green "用法: sb [-i|-u|-c|-h]"
        exit 1
        ;;
esac
