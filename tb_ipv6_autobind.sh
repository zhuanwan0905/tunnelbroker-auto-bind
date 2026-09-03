#!/usr/bin/env bash
# ==============================================================================
# 脚本名称: tb_ipv6_autobind.sh
# 作用: Tunnelbroker (HE) 自动登录、列出隧道、兼容/64与/48、更新 Client IPv4 并自动配置本机网络
# ==============================================================================

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "[!] 请使用 root 权限或 sudo 运行此脚本。"
    exit 1
fi

# 检查并安装必要依赖
DEPENDENCIES=("curl" "grep" "sed" "awk" "ip")
MISSING_DEPS=()
for dep in "${DEPENDENCIES[@]}"; do
    if ! command -v "$dep" >/dev/null 2>&1; then
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "[*] 检测到缺失依赖: ${MISSING_DEPS[*]}，正在自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y "${MISSING_DEPS[@]}"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "${MISSING_DEPS[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${MISSING_DEPS[@]}"
    else
        echo "[!] 未识别的包管理器，请手动安装: ${MISSING_DEPS[*]}"
        exit 1
    fi
fi

COOKIE_JAR=$(mktemp)
HTML_PAGE=$(mktemp)
trap 'rm -f "$COOKIE_JAR" "$HTML_PAGE"' EXIT

echo "============================================================"
echo "          Tunnelbroker (HE) IPv6 隧道一键绑定配置脚本        "
echo "============================================================"

read -r -p "请输入 Tunnelbroker 用户名 (Username): " TB_USER
read -r -s -p "请输入 Tunnelbroker 密码 (Password): " TB_PASS
echo ""

if [ -z "$TB_USER" ] || [ -z "$TB_PASS" ]; then
    echo "[!] 用户名或密码不能为空！"
    exit 1
fi

echo "[*] 正在登录 Tunnelbroker..."
LOGIN_RES=$(curl -s --compressed -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
    -d "f_user=${TB_USER}" \
    -d "f_pass=${TB_PASS}" \
    -d "Login=Login" \
    -L "https://tunnelbroker.net/login.php")

if echo "$LOGIN_RES" | grep -qi "Incorrect username or password"; then
    echo "[!] 登录失败：用户名或密码错误，请检查后重试。"
    exit 1
fi

# 获取管理主页 (使用 --compressed)
curl -s --compressed -b "$COOKIE_JAR" -L "https://tunnelbroker.net/index.php" > "$HTML_PAGE"

# 解析主页中的隧道列表（ID 数组）
TUNNEL_IDS=($(grep -oP 'tunnel_detail\.php\?tid=\K[0-9]+' "$HTML_PAGE" | sort -u))

if [ ${#TUNNEL_IDS[@]} -eq 0 ]; then
    echo "[!] 未在当前账户下检测到任何已创建的 IPv6 隧道，请先在官网创建隧道。"
    exit 1
fi

echo "------------------------------------------------------------"
echo "[+] 成功获取到 ${#TUNNEL_IDS[@]} 条隧道："

declare -A TUNNEL_NAME_MAP
declare -A TUNNEL_R64_MAP
declare -A TUNNEL_R48_MAP

INDEX=1
for TID in "${TUNNEL_IDS[@]}"; do
    # 从主页精准提取域名
    TNAME=$(grep "tid=${TID}" "$HTML_PAGE" | grep -oP "tunnel${TID}[a-zA-Z0-9\.]+" | head -n 1 || echo "Tunnel-${TID}")
    
    # 提取详情页全部内容，预先剥离 <b> 标签和 html 标签
    RAW_DETAIL=$(curl -s --compressed -b "$COOKIE_JAR" "https://tunnelbroker.net/tunnel_detail.php?tid=${TID}")
    CLEAN_DETAIL=$(echo "$RAW_DETAIL" | sed -e 's/<b>//g' -e 's/<\/b>//g')

    # 解析主页/详情页中的段
    R64=$(echo "$CLEAN_DETAIL" | grep -oP 'Routed /64:</span><span class="fr">\K[0-9a-fA-F:]+::/64' || echo "None")
    R48=$(echo "$CLEAN_DETAIL" | grep -oP 'Routed /48:</span><span class="fr" id="routed_48">\K[0-9a-fA-F:]+::/48' || echo "None")

    TUNNEL_NAME_MAP[$TID]="$TNAME"
    TUNNEL_R64_MAP[$TID]="$R64"
    TUNNEL_R48_MAP[$TID]="$R48"

    echo " [${INDEX}] 隧道 ID: ${TID}"
    echo "     域名: ${TNAME}"
    echo "     分配 Routed /64: ${R64}"
    echo "     分配 Routed /48: ${R48}"
    echo "------------------------------------------------------------"
    INDEX=$((INDEX + 1))
done

# 检测本机当前公网 IPv4
echo "[*] 正在获取本机公网 IPv4 地址..."
LOCAL_V4=$(curl -s4 --connect-timeout 5 https://api.ipify.org || \
          curl -s4 --connect-timeout 5 https://ipv4.icanhazip.com || \
          curl -s4 --connect-timeout 5 https://ifconfig.me)

if [ -z "$LOCAL_V4" ]; then
    echo "[!] 无法自动检测到公网 IPv4 地址，请手动输入："
    read -r -p "本机公网 IPv4: " LOCAL_V4
else
    echo "[+] 检测到当前机器公网 IPv4 为: ${LOCAL_V4}"
fi

# 选择要操作的隧道
SELECTED_TID=""
if [ ${#TUNNEL_IDS[@]} -eq 1 ]; then
    SELECTED_TID="${TUNNEL_IDS[0]}"
    echo "[*] 当前账户仅有 1 个隧道，自动选中隧道 ID: ${SELECTED_TID}"
else
    while true; do
        read -r -p "请选择要绑定的序号 (1-${#TUNNEL_IDS[@]}): " CHOICE
        if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#TUNNEL_IDS[@]}" ]; then
            SELECTED_INDEX=$((CHOICE - 1))
            SELECTED_TID="${TUNNEL_IDS[$SELECTED_INDEX]}"
            break
        else
            echo "[!] 输入无效，请重新输入。"
        fi
    done
fi

echo "============================================================"
echo "[*] 正在解析选定隧道 ${SELECTED_TID} 的详细连接参数..."

# 抓取选定隧道的干净页面
DETAIL_HTML=$(curl -s --compressed -b "$COOKIE_JAR" "https://tunnelbroker.net/tunnel_detail.php?tid=${SELECTED_TID}" | sed -e 's/<b>//g' -e 's/<\/b>//g')

# 精确解析对应的 span
TARGET_SERVER_V4=$(echo "$DETAIL_HTML" | grep -oP 'Server IPv4 Address:</span><span class="fr">\K[0-9.]+' | head -n 1)
TARGET_SERVER_V6=$(echo "$DETAIL_HTML" | grep -oP 'Server IPv6 Address:</span><span class="fr">\K[0-9a-fA-F:]+(?=/64)' | head -n 1)
TARGET_CLIENT_V6=$(echo "$DETAIL_HTML" | grep -oP 'Client IPv6 Address:</span><span class="fr">\K[0-9a-fA-F:]+(?=/64)' | head -n 1)
TARGET_ROUTED_48="${TUNNEL_R48_MAP[$SELECTED_TID]}"

echo "[+] 参数解析成功："
echo "    对端 Server IPv4: ${TARGET_SERVER_V4}"
echo "    对端 Server IPv6: ${TARGET_SERVER_V6}"
echo "    本机 Client IPv6: ${TARGET_CLIENT_V6}/64"

# 更新 Client IPv4
echo "------------------------------------------------------------"
echo "[*] 正在将对端绑定的 Client IPv4 更新为本机: ${LOCAL_V4}..."

# 调用官方 Update 接口
curl -s --compressed -b "$COOKIE_JAR" \
    "https://tunnelbroker.net/ipv4_update.php" \
    -d "tid=${SELECTED_TID}" \
    -d "ipv4_client=${LOCAL_V4}" >/dev/null 2>&1 || true

# 通过 API 接口兜底更新
curl -s -k "https://${TB_USER}:${TB_PASS}@ipv4.tunnelbroker.net/nic/update?hostname=${SELECTED_TID}&myip=${LOCAL_V4}" >/dev/null 2>&1 || true

echo "[+] HE 端 Client IPv4 更新命令已成功投递！"

# 处理 /48 选项
BIND_48_IP=""
if [ -n "$TARGET_ROUTED_48" ] && [ "$TARGET_ROUTED_48" != "None" ]; then
    echo "------------------------------------------------------------"
    echo "[*] 检测到分配的 Routed /48 段: ${TARGET_ROUTED_48}"
    read -r -p "是否附加绑定 ${TARGET_ROUTED_48%%::*}::1/48 到隧道接口？(y/n, 默认 y): " USE_48
    USE_48=${USE_48:-y}
    if [[ "$USE_48" =~ ^[Yy]$ ]]; then
        BIND_48_IP="${TARGET_ROUTED_48%%::*}::1"
        echo "[+] 已选择绑定: ${BIND_48_IP}/48"
    fi
fi

# 本机 SIT 隧道网络配置
IFACE_NAME="he-ipv6"
echo "------------------------------------------------------------"
echo "[*] 正在配置本地网络接口: ${IFACE_NAME}..."

if ip link show "$IFACE_NAME" >/dev/null 2>&1; then
    ip link set dev "$IFACE_NAME" down || true
    ip tunnel del "$IFACE_NAME" || true
fi

# 检查是否为 NAT 环境
LOCAL_BIND_IP="$LOCAL_V4"
if ! ip -4 addr | grep -q "$LOCAL_V4"; then
    INTERNAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' || true)
    if [ -n "$INTERNAL_IP" ]; then
        echo "[*] 检测到处于 NAT 环境，隧道 local 绑定私网 IP: ${INTERNAL_IP}"
        LOCAL_BIND_IP="$INTERNAL_IP"
    fi
fi

ip tunnel add "$IFACE_NAME" mode sit remote "$TARGET_SERVER_V4" local "$LOCAL_BIND_IP" ttl 255
ip link set "$IFACE_NAME" up
ip addr add "${TARGET_CLIENT_V6}/64" dev "$IFACE_NAME"

if [ -n "$BIND_48_IP" ]; then
    ip addr add "${BIND_48_IP}/48" dev "$IFACE_NAME"
fi

ip route add ::/0 dev "$IFACE_NAME" metric 1

echo "[+] 本地运行时网络接口配置完毕！"

# 持久化开机自启
read -r -p "是否将该隧道写入开机自启配置？(y/n, 默认 y): " PERSIST
PERSIST=${PERSIST:-y}

if [[ "$PERSIST" =~ ^[Yy]$ ]]; then
    if [ -d "/etc/network/interfaces.d" ] || [ -f "/etc/network/interfaces" ]; then
        NET_FILE="/etc/network/interfaces.d/he-ipv6.cfg"
        echo "[*] 写入持久化文件: ${NET_FILE}"
        cat <<EOF > "$NET_FILE"
auto ${IFACE_NAME}
iface ${IFACE_NAME} inet6 v4tunnel
    address ${TARGET_CLIENT_V6}
    netmask 64
    endpoint ${TARGET_SERVER_V4}
    local ${LOCAL_BIND_IP}
    ttl 255
    gateway ${TARGET_SERVER_V6}
EOF
        if [ -n "$BIND_48_IP" ]; then
            echo "    up ip addr add ${BIND_48_IP}/48 dev ${IFACE_NAME}" >> "$NET_FILE"
        fi
        echo "[+] Debian/Ubuntu 接口配置保存完毕。"

    elif [ -d "/etc/sysconfig/network-scripts" ]; then
        NET_FILE="/etc/sysconfig/network-scripts/ifcfg-${IFACE_NAME}"
        echo "[*] 写入持久化文件: ${NET_FILE}"
        cat <<EOF > "$NET_FILE"
DEVICE=${IFACE_NAME}
BOOTPROTO=none
ONBOOT=yes
IPV6INIT=yes
IPV6TUNNELIPV4=${TARGET_SERVER_V4}
IPV6TUNNELIPV4LOCAL=${LOCAL_BIND_IP}
IPV6ADDR=${TARGET_CLIENT_V6}/64
IPV6_DEFAULTGW=${TARGET_SERVER_V6}
EOF
        if [ -n "$BIND_48_IP" ]; then
            echo "IPV6ADDR_SECONDARIES=\"${BIND_48_IP}/48\"" >> "$NET_FILE"
        fi
        echo "[+] RHEL/CentOS 接口配置保存完毕。"
    fi
fi

# 连通性测试
echo "------------------------------------------------------------"
echo "[*] 正在验证 IPv6 连通性 (ping6 2001:4860:4860::8888)..."
if ping6 -c 3 -W 3 2001:4860:4860::8888 >/dev/null 2>&1; then
    echo "[√] 恭喜！IPv6 隧道握手成功，网络全面通畅！"
    echo "    点对点互联 IPv6: ${TARGET_CLIENT_V6}"
    if [ -n "$BIND_48_IP" ]; then
        echo "    本机附加 Routed IPv6: ${BIND_48_IP}"
    fi
else
    echo "[!] 警告: ping6 测试超时。请检查 RackNerd 防火墙或上级安全组是否开启了 Protocol 41 (SIT) 和 ICMP。"
fi

echo "============================================================"
echo "配置流程完成。"
