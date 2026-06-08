# =========================
# 自用 sing-box 安装脚本
# 协议: vmess-argo(固定隧道) + hysteria2
# 平台: Ubuntu / Debian (systemd)
# 最后更新时间: 2026.6.8
# =========================

export LANG=en_US.UTF-8
export DEBIAN_FRONTEND=noninteractive

# ── 颜色 ──────────────────────────────────────────
re="\033[0m"
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
SCRIPT_URL="https://raw.githubusercontent.com/wot1026-cmd/sing-box/main/sing-box.sh"

export ARGO_PORT=${ARGO_PORT:-'8001'}
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
    if systemctl is-active "$name" 2>/dev/null | grep -q "^active$"; then
        green "running"; return 0
    else
        yellow "not running"; return 1
    fi
}

check_singbox() { check_service "sing-box" "${work_dir}/sing-box"; }
check_argo()    { check_service "argo"     "${work_dir}/argo"; }

# ── 包安装 ────────────────────────────────────────
install_packages() {
    apt update -y
    for pkg in "$@"; do
        command_exists "$pkg" && { green "${pkg} 已安装，跳过"; continue; }
        yellow "正在安装 ${pkg}..."
        apt install -y "$pkg" || { red "${pkg} 安装失败"; return 1; }
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
        iptables -P FORWARD DROP 2>/dev/null || true
        iptables -P OUTPUT ACCEPT 2>/dev/null || true
    fi
    if [ $has_ip6tables -eq 1 ]; then
        ip6tables -C INPUT -i lo -j ACCEPT 2>/dev/null || ip6tables -I INPUT -i lo -j ACCEPT 2>/dev/null || true
        ip6tables -C INPUT -p icmp -j ACCEPT 2>/dev/null || ip6tables -I INPUT -p icmp -j ACCEPT 2>/dev/null || true
        ip6tables -P FORWARD DROP 2>/dev/null || true
        ip6tables -P OUTPUT ACCEPT 2>/dev/null || true
    fi

    for rule in "$@"; do
        local port="${rule%/*}" proto="${rule#*/}"
        [ $has_ufw -eq 1 ] && ufw allow in "${port}/${proto}" >/dev/null 2>&1
        if [ $has_iptables -eq 1 ]; then
            iptables  -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                || iptables  -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
        if [ $has_ip6tables -eq 1 ]; then
            ip6tables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null \
                || ip6tables -A INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        fi
    done
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
}

# ── 节点名称 ──────────────────────────────────────
get_flag() {
    local code
    code=$(curl -sm3 -H "User-Agent: Mozilla/5.0" "https://api.ip.sb/geoip" \
           | jq -r '.country_code // empty' 2>/dev/null)
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

# ── Hysteria2 指纹（base64 格式）─────────────────
# 修复第10条：移除 python3 依赖，改用 xxd + base64
get_hy2_fingerprint() {
    local hex
    hex=$(openssl x509 -noout -fingerprint -sha256 -in "${work_dir}/cert.pem" 2>/dev/null \
        | cut -d'=' -f2 | tr -d ':')
    [ -z "$hex" ] && { echo ""; return; }
    echo "$hex" | xxd -r -p | base64 | tr -d '=' | tr -d '\n'
}

# ── 安装核心 ──────────────────────────────────────
install_singbox() {
    clear
    purple "正在安装 sing-box，请稍候..."

    local arch_raw arch
    arch_raw=$(uname -m)
    case "$arch_raw" in
        x86_64|amd64)  arch='amd64' ;;
        aarch64|arm64) arch='arm64' ;;
        *) red "不支持的架构: ${arch_raw}"; exit 1 ;;
    esac

    mkdir -p "${work_dir}" "${conf_dir}"
    chmod 700 "${work_dir}"

    yellow "正在下载 sing-box..."
    curl -fsSLo "${work_dir}/sing-box" "https://${arch}.ssss.nyc.mn/sbx-1.13.13" \
        || { red "sing-box 下载失败"; exit 1; }

    yellow "正在下载 argo..."
    curl -fsSLo "${work_dir}/argo" "https://${arch}.ssss.nyc.mn/bot" \
        || { red "argo 下载失败"; exit 1; }

    yellow "正在下载 qrencode..."
    curl -fsSLo "${work_dir}/qrencode" "https://${arch}.ssss.nyc.mn/qrencode" \
        || { red "qrencode 下载失败"; exit 1; }

    chmod +x "${work_dir}/sing-box" "${work_dir}/argo" "${work_dir}/qrencode"
    chown root:root "${work_dir}/sing-box" "${work_dir}/argo"

    local hy2_port uuid
    hy2_port=$(shuf -i 10000-65000 -n 1)
    uuid=$(cat /proc/sys/kernel/random/uuid)

    allow_port "${ARGO_PORT}/tcp" "${hy2_port}/udp"

    yellow "正在生成 TLS 证书..."
    openssl ecparam -genkey -name prime256v1 -out "${work_dir}/private.key" 2>/dev/null
    openssl req -new -x509 -days 3650 \
        -key "${work_dir}/private.key" \
        -out "${work_dir}/cert.pem" \
        -subj "/CN=bing.com" 2>/dev/null
    chmod 600 "${work_dir}/private.key"

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

    green "sing-box 核心安装完成"
    yellow "注意：需在 Argo 隧道管理 中配置固定隧道后，VMess 节点才可用"
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
}

# ── 服务管理 ──────────────────────────────────────
manage_service() {
    local name="$1" action="$2"
    case "$action" in
        start)
            yellow "正在启动 ${name}..."
            systemctl start "$name"
            [ $? -eq 0 ] && green "${name} 已启动" || red "${name} 启动失败"
            ;;
        stop)
            yellow "正在停止 ${name}..."
            systemctl stop "$name"
            [ $? -eq 0 ] && green "${name} 已停止" || red "${name} 停止失败"
            ;;
        restart)
            yellow "正在重启 ${name}..."
            systemctl daemon-reload
            systemctl restart "$name"
            [ $? -eq 0 ] && green "${name} 已重启" || red "${name} 重启失败"
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
        | head -1 \
        | sed 's/.*hostname:[[:space:]]*//' \
        | tr -d '[:space:]'
}

is_fixed_tunnel_configured() { [ -f "${work_dir}/tunnel.yml" ]; }

# ── 节点信息生成 ──────────────────────────────────
get_info() {
    yellow "\nIP 检测中，请稍候...\n"
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
    uuid=$(jq -r '.inbounds[] | select(.type=="vmess") | .users[0].uuid' "${conf_dir}/inbounds.json")
    fingerprint=$(get_hy2_fingerprint)

    local argodomain=""
    is_fixed_tunnel_configured && argodomain=$(get_fixed_domain)

    if [ -z "$argodomain" ]; then
        yellow "未检测到固定隧道域名，VMess 节点暂不可用，请先配置 Argo 固定隧道\n"
    else
        green "\nArgo 域名：${argodomain}\n"
    fi

    local vmess_json
    vmess_json=$(jq -n \
        --arg ps   "${node_prefix} argo" \
        --arg add  "${CFIP}" \
        --arg port "${CFPORT}" \
        --arg id   "${uuid}" \
        --arg host "${argodomain}" \
        '{v:"2", ps:$ps, add:$add, port:$port,
          id:$id, aid:"0", scy:"none",
          net:"ws", type:"none",
          host:$host, path:"/vmess-argo?ed=2560",
          tls:"tls", sni:$host,
          alpn:"", fp:"chrome", allowInsecure:false}')

    cat > "${client_dir}" << EOF
vmess://$(echo "$vmess_json" | base64 | tr -d '\n')

hysteria2://${uuid}@${server_ip}:${hy2_port}/?sni=bing.com&insecure=1&pinSHA256=${fingerprint}&alpn=h3&obfs=none#${node_prefix} hy2
EOF

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
        [ -x "${work_dir}/qrencode" ] && "${work_dir}/qrencode" "$line"
        echo ""
    done < "${client_dir}"
}

# ── 大陆拦截 ──────────────────────────────────────
cn_block_manage() {
    check_singbox &>/dev/null
    [ $? -eq 2 ] && { yellow "sing-box 尚未安装！"; sleep 1; return; }

    local route_file="${conf_dir}/route.json"
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
            jq '
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
            ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
            [ $? -ne 0 ] && { red "配置写入失败"; sleep 2; return; }
            restart_singbox
            green "\n大陆域名拦截已开启\n"
            ;;
        2)
            if ! $block_enabled; then
                yellow "大陆拦截未开启\n"; sleep 1; return
            fi
            jq '
              del(.route.rules[] | select(.rule_set[]? == "geosite-cn")) |
              del(.route.rules[] | select(.domain_regex? and .outbound == "direct")) |
              del(.route.rule_set[] | select(.tag == "geosite-cn"))
            ' "$route_file" > "${route_file}.tmp" && mv "${route_file}.tmp" "$route_file"
            [ $? -ne 0 ] && { red "配置写入失败"; sleep 2; return; }
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
    green  "3. 修改 VMess-Argo 端口"
    green  "4. 修改 CF 优选域名/IP"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "请输入选择: " choice

    case "$choice" in
        1)
            reading "\n请输入新的 UUID（回车随机生成）: " new_uuid
            [ -z "$new_uuid" ] && new_uuid=$(cat /proc/sys/kernel/random/uuid)
            jq --arg u "$new_uuid" '
                (.inbounds[] | select(.users) | .users[] | select(.uuid)     | .uuid)     = $u |
                (.inbounds[] | select(.users) | .users[] | select(.password) | .password) = $u
            ' "$inbounds_file" > "${inbounds_file}.tmp" \
                && mv "${inbounds_file}.tmp" "$inbounds_file"
            restart_singbox && get_info
            green "\nUUID 已修改为：${new_uuid}\n"
            ;;
        2)
            reading "\n请输入新的 Hysteria2 端口（回车随机生成）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 10000-65000 -n 1)
            # 修复第9条：先删除旧端口防火墙规则
            old_port=$(jq -r '.inbounds[] | select(.type=="hysteria2") | .listen_port' "$inbounds_file")
            remove_port "${old_port}/udp"
            # 写入新配置
            jq --argjson p "$new_port" \
                '(.inbounds[] | select(.type=="hysteria2") | .listen_port) = $p' \
                "$inbounds_file" > "${inbounds_file}.tmp" \
                && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${new_port}/udp"
            restart_singbox && get_info
            green "\nHysteria2 端口已修改为：${new_port}\n"
            ;;
        3)
            reading "\n请输入新的 VMess-Argo 端口（回车随机生成）: " new_port
            [ -z "$new_port" ] && new_port=$(shuf -i 10000-65000 -n 1)
            # 修复第9条：先删除旧端口防火墙规则
            old_port=$(jq -r '.inbounds[] | select(.type=="vmess") | .listen_port' "$inbounds_file")
            remove_port "${old_port}/tcp"
            # 写入新配置
            jq --argjson p "$new_port" \
                '(.inbounds[] | select(.type=="vmess") | .listen_port) = $p' \
                "$inbounds_file" > "${inbounds_file}.tmp" \
                && mv "${inbounds_file}.tmp" "$inbounds_file"
            allow_port "${new_port}/tcp"
            if [ -f "${work_dir}/tunnel.yml" ]; then
                sed -i "s|service: http://localhost:[0-9]*|service: http://localhost:${new_port}|" \
                    "${work_dir}/tunnel.yml"
            fi
            restart_singbox && restart_argo && get_info
            green "\nVMess-Argo 端口已修改为：${new_port}\n"
            ;;
        4)
            clear
            green "1: cf.090227.xyz  2: cf.877774.xyz  3: cf.877771.xyz  4: cdns.doon.eu.org\n"
            reading "请输入优选域名或 IP[:端口]（回车默认 cf.877774.xyz）: " input
            local cfip cfport
            case "$input" in
                ""|"2") cfip="cf.877774.xyz";    cfport="443" ;;
                "1")    cfip="cf.090227.xyz";    cfport="443" ;;
                "3")    cfip="cf.877771.xyz";    cfport="443" ;;
                "4")    cfip="cdns.doon.eu.org"; cfport="443" ;;
                *)
                    if [[ "$input" =~ : ]]; then
                        cfip="${input%%:*}"; cfport="${input##*:}"
                    else
                        cfip="$input"; cfport="443"
                    fi
                    ;;
            esac
            printf 'CFIP=%s\nCFPORT=%s\n' "$cfip" "$cfport" > "${work_dir}/cf.env"
            CFIP="$cfip"; CFPORT="$cfport"
            get_info
            green "\nCF 优选已更新为：${cfip}:${cfport}\n"
            ;;
        0) return ;;
        *) red "无效选项！" ;;
    esac
}

# ── 配置固定 Argo 隧道 ────────────────────────────
configure_fixed_tunnel() {
    clear
    yellow "\n固定隧道支持 JSON 凭据或 Token 两种方式，VMess 端口: ${ARGO_PORT}"
    yellow "JSON 获取：https://fscarmen.cloudflare.now.cc\n"

    reading "\n请输入 Argo 域名: " argo_domain
    [ -z "$argo_domain" ] && { red "域名不能为空"; return 1; }

    reading "\n请输入 Argo 密钥（Token 或 JSON）: " argo_auth
    [ -z "$argo_auth" ] && { red "密钥不能为空"; return 1; }

    if [[ "$argo_auth" =~ TunnelSecret ]]; then
        echo "$argo_auth" > "${work_dir}/tunnel.json"
        chmod 600 "${work_dir}/tunnel.json"
        local tunnel_id
        tunnel_id=$(echo "$argo_auth" | jq -r '.TunnelID // empty' 2>/dev/null)
        [ -z "$tunnel_id" ] && tunnel_id=$(cut -d'"' -f12 <<< "$argo_auth")
        if [ -z "$tunnel_id" ]; then
            red "无法解析 TunnelID，请检查 JSON 格式"; return 1
        fi
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

    elif [[ "$argo_auth" =~ ^[A-Za-z0-9=]{120,250}$ ]]; then
        printf '# token mode\nhostname: %s\n' "$argo_domain" > "${work_dir}/tunnel.yml"
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
    is_fixed_tunnel_configured \
        && green "当前域名: $(get_fixed_domain)\n" \
        || yellow "固定隧道尚未配置\n"
    green  "1. 启动 Argo"
    green  "2. 停止 Argo"
    green  "3. 重启 Argo"
    green  "4. 配置固定隧道"
    purple "0. 返回主菜单"
    skyblue "------------"
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
    sb_status=$(check_singbox 2>&1)
    clear; echo ""
    green "=== sing-box 管理 === 状态: ${sb_status}\n"
    green  "1. 启动 sing-box"
    green  "2. 停止 sing-box"
    green  "3. 重启 sing-box"
    purple "0. 返回主菜单"
    skyblue "------------"
    reading "\n请输入选择: " choice
    case "$choice" in
        1) start_singbox ;;
        2) stop_singbox ;;
        3) restart_singbox ;;
        0) return ;;
        *) red "无效选项！"; sleep 1; manage_singbox ;;
    esac
}

# ── 卸载 ──────────────────────────────────────────
uninstall_singbox() {
    reading "确定要卸载 sing-box 吗? (y/n): " choice
    [[ "$choice" != [yY] ]] && { purple "已取消卸载\n"; return; }
    yellow "正在卸载..."
    systemctl stop    sing-box argo 2>/dev/null
    systemctl disable sing-box argo 2>/dev/null
    systemctl daemon-reload
    rm -f /etc/systemd/system/sing-box.service \
          /etc/systemd/system/argo.service
    rm -rf "${work_dir}"
    rm -f /usr/bin/sb
    green "\nsing-box 卸载完成\n"
    exit 0
}

# ── 快捷指令 ──────────────────────────────────────
create_shortcut() {
    cat > "${work_dir}/sb.sh" << EOF
#!/usr/bin/env bash
bash <(curl -Ls ${SCRIPT_URL}) \$1
EOF
    chmod +x "${work_dir}/sb.sh"
    ln -sf "${work_dir}/sb.sh" /usr/bin/sb
    [ -s /usr/bin/sb ] && green "\n快捷指令 sb 创建成功\n" || red "\n快捷指令创建失败\n"
}

# ── 更新脚本 ──────────────────────────────────────
update_script() {
    yellow "正在从 GitHub 拉取最新脚本...\n"
    local tmp="${work_dir}/sb.sh.tmp"
    curl -fsSL "${SCRIPT_URL}" -o "$tmp"
    if [ $? -eq 0 ] && grep -q "sing-box" "$tmp" && [ "$(wc -l < "$tmp")" -gt 50 ]; then
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
    green  "8. 更新脚本"
    echo   "==============="
    purple "9. SSH 综合工具箱"
    echo   "==============="
    red    "0. 退出脚本"
    echo   "==========="
}

# ── 安装流程 ──────────────────────────────────────
do_install() {
    install_packages jq openssl curl
    install_singbox
    setup_services
    sleep 2
    create_shortcut
    green "\nsing-box 安装完成！"
    yellow "请进入 Argo 隧道管理 配置固定隧道，再用 sb -c 查看节点\n"
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
        yellow "正在无交互卸载 sing-box...\n"
        systemctl stop    sing-box argo 2>/dev/null
        systemctl disable sing-box argo 2>/dev/null
        systemctl daemon-reload
        rm -f /etc/systemd/system/sing-box.service \
              /etc/systemd/system/argo.service
        rm -rf "${work_dir}"
        rm -f /usr/bin/sb
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
            reading "请输入选择(0-9): " choice
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
                2) uninstall_singbox;  need_pause=false ;;
                3) manage_singbox;     need_pause=false ;;
                4) manage_argo;        need_pause=true ;;
                5) get_info;           need_pause=true ;;
                6) change_config;      need_pause=true ;;
                7) cn_block_manage;    need_pause=true ;;
                8) update_script;      need_pause=false ;;
                9)
                    clear
                    bash <(curl -Ls ssh_tool.eooce.com)
                    need_pause=false
                    ;;
                0) exit 0 ;;
                *) red "无效选项，请输入 0-9" ;;
            esac
            [ "$need_pause" = true ] && read -n1 -s -r -p $'\033[1;91m按任意键返回...\033[0m'
            echo ""
        done
        ;;
    *)
        red "未知参数: $1"
        green "用法: sb [-i|-u|-c|-h]"
        exit 1
        ;;
esac
