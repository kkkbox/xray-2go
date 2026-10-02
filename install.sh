#!/usr/bin/env bash
# ==============================================================================
# Xray Lite Installer - Low Memory Edition
# VLESS + TCP + REALITY + XTLS Vision
#
# 适合：
# - Debian 11 / 12 / 13
# - Ubuntu 20.04 / 22.04 / 24.04
# - systemd
# - 64 MB RAM + 1 GB Disk 的低配 VPS
#
# 默认参数：
# - PORT=443
# - SNI=www.microsoft.com
# - 自动创建 256 MB Swap（环境允许时）
#
# 用法：
#   bash install.sh
#
# 自定义：
#   PORT=2053 SNI=www.microsoft.com bash install.sh
#   SERVER_IP=1.2.3.4 PORT=443 SNI=www.apple.com bash install.sh
#
# 安装后管理：
#   xray-lite status
#   xray-lite links
#   xray-lite restart
#   xray-lite logs
#   xray-lite uninstall
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ------------------------------------------------------------------------------
# 路径和参数
# ------------------------------------------------------------------------------

readonly XRAY_DIR="/etc/xray"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_ENV="${XRAY_DIR}/reality.env"
readonly XRAY_LINK="${XRAY_DIR}/vless.txt"
readonly XRAY_SERVICE="/etc/systemd/system/xray.service"
readonly XRAY_MANAGER="/usr/local/bin/xray-lite"
readonly XRAY_BACKUP_DIR="/root/xray-backup"
readonly JOURNAL_CONF="/etc/systemd/journald.conf.d/20-xray-lite.conf"
readonly SWAP_FILE="/swapfile"

PORT="${PORT:-443}"
SNI="${SNI:-www.microsoft.com}"
SERVER_IP="${SERVER_IP:-}"
UUID="${UUID:-}"
SHORT_ID="${SHORT_ID:-}"
SWAP_SIZE_MB="${SWAP_SIZE_MB:-256}"

PRIVATE_KEY=""
PUBLIC_KEY=""

# ------------------------------------------------------------------------------
# 输出函数
# ------------------------------------------------------------------------------

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
RESET='\033[0m'

red() {
    printf "${RED}%s${RESET}\n" "$*"
}

green() {
    printf "${GREEN}%s${RESET}\n" "$*"
}

yellow() {
    printf "${YELLOW}%s${RESET}\n" "$*"
}

blue() {
    printf "${BLUE}%s${RESET}\n" "$*"
}

info() {
    printf "${CYAN}%s${RESET}\n" "$*"
}

die() {
    red "错误：$*"
    exit 1
}

warn() {
    yellow "警告：$*"
}

on_error() {
    local code="$1"
    local line="$2"

    echo
    red "脚本在第 ${line} 行执行失败，退出代码：${code}"
    yellow "排查命令："
    echo "  free -h"
    echo "  swapon --show"
    echo "  df -h /"
    echo "  systemctl status xray --no-pager -l"
    echo "  journalctl -xeu xray.service --no-pager | tail -n 100"
}

trap 'on_error $? $LINENO' ERR

# ------------------------------------------------------------------------------
# 环境检查
# ------------------------------------------------------------------------------

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户执行脚本。"
}

check_system() {
    [[ -f /etc/os-release ]] || die "无法识别系统，缺少 /etc/os-release。"

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            ;;
        *)
            die "仅支持 Debian 或 Ubuntu。当前系统：${PRETTY_NAME:-未知}"
            ;;
    esac

    command -v systemctl >/dev/null 2>&1 \
        || die "未检测到 systemd，当前脚本不适用于该系统。"

    command -v apt-get >/dev/null 2>&1 \
        || die "未检测到 apt-get。"
}

check_disk_space() {
    local available_kb

    available_kb="$(df -Pk / | awk 'NR==2 {print $4}')"

    [[ -n "${available_kb}" ]] || die "无法获取根分区可用空间。"

    if (( available_kb < 180000 )); then
        warn "根分区剩余空间不足约 180 MB。"
        warn "建议先执行：apt-get clean && rm -rf /var/lib/apt/lists/*"
    fi
}

check_port() {
    local port="$1"

    [[ "${port}" =~ ^[0-9]+$ ]] || die "端口必须为数字：${port}"
    (( port >= 1 && port <= 65535 )) || die "端口必须在 1-65535 之间：${port}"

    if command -v ss >/dev/null 2>&1; then
        if ss -lntH "sport = :${port}" 2>/dev/null | grep -q .; then
            die "TCP 端口 ${port} 已被占用。请使用其他端口，例如：PORT=2053 bash install.sh"
        fi
    fi
}

check_sni() {
    [[ -n "${SNI}" ]] || die "SNI 不能为空。"

    [[ "${SNI}" =~ ^[A-Za-z0-9.-]+$ ]] \
        || die "SNI 格式不正确：${SNI}"

    [[ "${SNI}" != .* && "${SNI}" != *..* ]] \
        || die "SNI 格式不正确：${SNI}"
}

# ------------------------------------------------------------------------------
# Swap 管理
# ------------------------------------------------------------------------------

swap_enabled() {
    swapon --noheadings --show 2>/dev/null | grep -q .
}

create_swap_if_needed() {
    local available_kb
    local required_kb

    if swap_enabled; then
        info "已检测到 Swap："
        swapon --show
        return 0
    fi

    available_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
    required_kb=$((SWAP_SIZE_MB * 1024 + 180000))

    if (( available_kb < required_kb )); then
        warn "磁盘可用空间不足，跳过创建 ${SWAP_SIZE_MB} MB Swap。"
        warn "64 MB 内存且无 Swap 时，apt/dpkg 可能再次出现 Killed。"
        return 0
    fi

    info "未检测到 Swap，正在尝试创建 ${SWAP_SIZE_MB} MB Swap..."

    if [[ ! -e "${SWAP_FILE}" ]]; then
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "${SWAP_SIZE_MB}M" "${SWAP_FILE}" 2>/dev/null || true
        fi

        if [[ ! -s "${SWAP_FILE}" ]]; then
            info "使用 dd 创建 Swap 文件..."
            dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${SWAP_SIZE_MB}" status=progress
        fi
    fi

    chmod 600 "${SWAP_FILE}"

    if ! file "${SWAP_FILE}" 2>/dev/null | grep -qi 'swap'; then
        mkswap "${SWAP_FILE}" >/dev/null
    fi

    if swapon "${SWAP_FILE}" 2>/dev/null; then
        grep -q "^${SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null || \
            echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab

        cat > /etc/sysctl.d/99-xray-lite-memory.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

        sysctl -p /etc/sysctl.d/99-xray-lite-memory.conf >/dev/null 2>&1 || true

        green "Swap 已创建并启用："
        swapon --show
    else
        warn "无法启用 Swap。"
        warn "当前 VPS 可能是限制 Swap 的 OpenVZ 或 LXC 容器。"
        rm -f "${SWAP_FILE}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# APT 修复和最小依赖
# ------------------------------------------------------------------------------

repair_apt() {
    info "修复可能被中断的 APT / dpkg 状态..."

    export DEBIAN_FRONTEND=noninteractive

    dpkg --configure -a || true
    apt-get -f install -y || true

    apt-get clean || true
    rm -rf /var/lib/apt/lists/* || true
}

install_dependencies() {
    local packages=()
    local package

    export DEBIAN_FRONTEND=noninteractive

    info "更新 APT 软件包索引..."

    apt-get update \
        -o Acquire::Languages=none \
        -o Acquire::PDiffs=false \
        -qq

    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v unzip >/dev/null 2>&1 || packages+=(unzip)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl)
    command -v ss >/dev/null 2>&1 || packages+=(iproute2)
    command -v timeout >/dev/null 2>&1 || packages+=(coreutils)

    if (( ${#packages[@]} == 0 )); then
        green "所有必要依赖已存在。"
    else
        for package in "${packages[@]}"; do
            info "安装依赖：${package}"
            apt-get install -y --no-install-recommends "${package}"
        done
    fi

    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

# ------------------------------------------------------------------------------
# Xray 下载和安装
# ------------------------------------------------------------------------------

get_arch() {
    case "$(uname -m)" in
        x86_64)
            printf '64'
            ;;
        i386|i686)
            printf '32'
            ;;
        aarch64|arm64)
            printf 'arm64-v8a'
            ;;
        armv7l|armv7)
            printf 'arm32-v7a'
            ;;
        *)
            die "不支持的 CPU 架构：$(uname -m)"
            ;;
    esac
}

get_latest_version() {
    curl -fsSL \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 12 \
        --max-time 30 \
        "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
    | sed -n 's/^[[:space:]]*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

backup_old_files() {
    local backup_file

    if [[ -d "${XRAY_DIR}" || -f "${XRAY_SERVICE}" || -f "${XRAY_BIN}" ]]; then
        info "检测到旧版 Xray，正在备份..."

        mkdir -p "${XRAY_BACKUP_DIR}"
        backup_file="${XRAY_BACKUP_DIR}/xray-$(date +%Y%m%d-%H%M%S).tar.gz"

        tar -czf "${backup_file}" \
            /etc/xray \
            /etc/systemd/system/xray.service \
            /usr/local/bin/xray \
            2>/dev/null || true

        green "旧文件已备份：${backup_file}"
    fi
}

download_xray() {
    local arch
    local version
    local download_url
    local temp_dir
    local zip_file

    arch="$(get_arch)"
    version="$(get_latest_version)"
    temp_dir="$(mktemp -d)"
    zip_file="${temp_dir}/xray.zip"

    trap 'rm -rf "${temp_dir}"' RETURN

    if [[ -n "${version}" ]]; then
        download_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
        info "下载 Xray ${version}（${arch}）..."
    else
        download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
        warn "无法读取最新版本号，使用 latest 下载地址。"
    fi

    curl -fL \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 180 \
        -o "${zip_file}" \
        "${download_url}"

    unzip -oq "${zip_file}" -d "${temp_dir}/xray"

    [[ -f "${temp_dir}/xray/xray" ]] \
        || die "Xray 下载包内没有找到 xray 二进制文件。"

    install -d -m 700 "${XRAY_DIR}"
    install -m 0755 "${temp_dir}/xray/xray" "${XRAY_BIN}"

    rm -rf "${temp_dir}"
    trap - RETURN

    "${XRAY_BIN}" version >/dev/null 2>&1 \
        || die "Xray 二进制文件无法执行。"

    green "Xray 安装成功：$("${XRAY_BIN}" version | head -n 1)"
}

# ------------------------------------------------------------------------------
# Reality 配置
# ------------------------------------------------------------------------------

generate_values() {
    UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
    SHORT_ID="${SHORT_ID:-$(openssl rand -hex 8)}"

    [[ "${UUID}" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] \
        || die "UUID 格式不正确：${UUID}"

    [[ "${SHORT_ID}" =~ ^[a-fA-F0-9]{1,16}$ ]] \
        || die "SHORT_ID 必须为 1-16 位十六进制字符。"
}

generate_keys() {
    local result

    info "生成 Reality 密钥对..."

    result="$("${XRAY_BIN}" x25519)"

    PRIVATE_KEY="$(awk '/PrivateKey:/ {print $2}' <<< "${result}")"
    PUBLIC_KEY="$(awk '/Password/ {print $NF}' <<< "${result}")"

    [[ -n "${PRIVATE_KEY}" ]] || die "无法生成 Reality 私钥。"
    [[ -n "${PUBLIC_KEY}" ]] || die "无法生成 Reality 公钥。"
}

check_reality_target() {
    info "检测 Reality 伪装目标：${SNI}:443"

    if timeout 12 openssl s_client \
        -connect "${SNI}:443" \
        -servername "${SNI}" \
        -brief </dev/null >/dev/null 2>&1; then
        green "伪装目标 TLS 检测通过。"
    else
        warn "无法检测 ${SNI}:443 的 TLS。脚本会继续，但该目标不可达时 Reality 可能不可用。"
    fi
}

write_config() {
    info "写入 Xray VLESS + Reality 配置..."

    install -d -m 700 "${XRAY_DIR}"

    cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "none"
  },
  "inbounds": [
    {
      "tag": "vless-reality-vision",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "default"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${SNI}:443",
          "xver": 0,
          "serverNames": [
            "${SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF

    chmod 600 "${XRAY_CONFIG}"

    cat > "${XRAY_ENV}" <<EOF
# 请勿公开此文件，也不要上传到 GitHub
UUID=${UUID}
PORT=${PORT}
SNI=${SNI}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
EOF

    chmod 600 "${XRAY_ENV}"
}

# ------------------------------------------------------------------------------
# systemd：不使用沙箱，优先保证低配容器兼容性
# ------------------------------------------------------------------------------

write_systemd_service() {
    info "写入兼容型 Xray systemd 服务..."

    cat > "${XRAY_SERVICE}" <<EOF
[Unit]
Description=Xray VLESS Reality Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
User=root
Group=root

ExecStartPre=${XRAY_BIN} run -test -config ${XRAY_CONFIG}
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}

Restart=always
RestartSec=5
TimeoutStopSec=15
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${XRAY_SERVICE}"
}

configure_journal() {
    info "设置 journal 日志大小限制..."

    install -d -m 755 /etc/systemd/journald.conf.d

    cat > "${JOURNAL_CONF}" <<EOF
[Journal]
SystemMaxUse=50M
SystemKeepFree=100M
RuntimeMaxUse=20M
MaxRetentionSec=7day
Compress=yes
EOF

    systemctl restart systemd-journald 2>/dev/null || true
    journalctl --vacuum-size=50M >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# 节点链接和管理命令
# ------------------------------------------------------------------------------

get_server_ip() {
    local ip=""

    if [[ -n "${SERVER_IP}" ]]; then
        printf '%s' "${SERVER_IP}"
        return 0
    fi

    ip="$(curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "${ip}" ]] && {
        printf '%s' "${ip}"
        return 0
    }

    ip="$(curl -4fsS --connect-timeout 5 --max-time 8 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
    [[ -n "${ip}" ]] && {
        printf '%s' "${ip}"
        return 0
    }

    ip="$(curl -6fsS --connect-timeout 5 --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
    [[ -n "${ip}" ]] && {
        printf '[%s]' "${ip}"
        return 0
    }

    printf 'YOUR_SERVER_IP'
}

write_link() {
    local ip
    local node_name

    ip="$(get_server_ip)"
    node_name="VLESS-Reality-${ip//[:\[\]]/_}"

    cat > "${XRAY_LINK}" <<EOF
vless://${UUID}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${node_name}
EOF

    chmod 600 "${XRAY_LINK}"
}

write_manager() {
    cat > "${XRAY_MANAGER}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

XRAY_DIR="/etc/xray"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_LINK="${XRAY_DIR}/vless.txt"
XRAY_ENV="${XRAY_DIR}/reality.env"
XRAY_SERVICE="/etc/systemd/system/xray.service"
XRAY_MANAGER="/usr/local/bin/xray-lite"

red() {
    printf '\033[1;31m%s\033[0m\n' "$*"
}

green() {
    printf '\033[1;32m%s\033[0m\n' "$*"
}

yellow() {
    printf '\033[1;33m%s\033[0m\n' "$*"
}

need_root() {
    [[ "${EUID}" -eq 0 ]] || {
        red "请使用 root 用户运行。"
        exit 1
    }
}

usage() {
    cat <<USAGE
Xray Lite 管理命令：

  xray-lite status       查看服务状态
  xray-lite start        启动服务
  xray-lite stop         停止服务
  xray-lite restart      测试配置后重启服务
  xray-lite logs [数量]  查看日志，默认 100 行
  xray-lite follow       实时查看日志
  xray-lite links        查看 VLESS 导入链接
  xray-lite info         查看 Reality 参数
  xray-lite test         校验 Xray 配置
  xray-lite port         查看监听端口
  xray-lite uninstall    停止并卸载 Xray
USAGE
}

uninstall_xray() {
    need_root

    yellow "即将卸载 Xray Lite。"
    read -r -p "确认继续吗？旧配置会备份到 /root/xray-backup/ (y/N): " answer

    case "${answer}" in
        y|Y|yes|YES)
            ;;
        *)
            yellow "已取消。"
            exit 0
            ;;
    esac

    mkdir -p /root/xray-backup

    if [[ -d "${XRAY_DIR}" ]]; then
        tar -czf "/root/xray-backup/xray-uninstall-$(date +%Y%m%d-%H%M%S).tar.gz" \
            "${XRAY_DIR}" 2>/dev/null || true
    fi

    systemctl disable --now xray 2>/dev/null || true

    rm -f "${XRAY_SERVICE}"
    rm -f "${XRAY_BIN}"
    rm -rf "${XRAY_DIR}"
    rm -f "${XRAY_MANAGER}"
    rm -f /etc/systemd/journald.conf.d/20-xray-lite.conf

    systemctl daemon-reload
    systemctl restart systemd-journald 2>/dev/null || true

    green "卸载完成。备份目录：/root/xray-backup/"
}

case "${1:-help}" in
    status)
        systemctl status xray --no-pager
        ;;
    start)
        need_root
        systemctl start xray
        ;;
    stop)
        need_root
        systemctl stop xray
        ;;
    restart)
        need_root
        "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}"
        systemctl restart xray
        green "Xray 已重启。"
        ;;
    logs)
        journalctl -u xray -n "${2:-100}" --no-pager
        ;;
    follow)
        journalctl -u xray -f
        ;;
    links)
        cat "${XRAY_LINK}"
        ;;
    info)
        cat "${XRAY_ENV}"
        ;;
    test)
        "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}"
        ;;
    port)
        ss -lntp | grep -E 'xray|LISTEN' || true
        ;;
    uninstall)
        uninstall_xray
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        red "未知命令：${1}"
        usage
        exit 1
        ;;
esac
EOF

    chmod 755 "${XRAY_MANAGER}"
}

# ------------------------------------------------------------------------------
# 服务启动
# ------------------------------------------------------------------------------

test_and_start() {
    info "验证 Xray 配置..."

    "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" \
        || die "Xray 配置验证失败。"

    systemctl daemon-reload
    systemctl reset-failed xray 2>/dev/null || true
    systemctl enable xray >/dev/null
    systemctl restart xray

    sleep 2

    if systemctl is-active --quiet xray; then
        green "Xray 已启动，并已启用开机自启。"
    else
        red "Xray 服务启动失败。"
        journalctl -xeu xray.service --no-pager | tail -n 100 || true
        exit 1
    fi
}

show_result() {
    local ip

    ip="$(get_server_ip)"

    echo
    green "================================================================"
    green "      Xray VLESS + TCP + Reality + XTLS Vision 已安装完成"
    green "================================================================"
    echo

    blue "服务端参数："
    echo "  服务器地址 : ${ip}"
    echo "  服务端口   : ${PORT}"
    echo "  UUID       : ${UUID}"
    echo "  Reality SNI: ${SNI}"
    echo "  Public Key : ${PUBLIC_KEY}"
    echo "  Short ID   : ${SHORT_ID}"

    echo
    yellow "VLESS 节点链接："
    cat "${XRAY_LINK}"

    echo
    yellow "必须在云服务商安全组 / 防火墙放行 TCP ${PORT}。"
    yellow "脚本没有修改 iptables、nftables、UFW、SSH 或云防火墙。"

    echo
    blue "常用命令："
    echo "  查看状态   : xray-lite status"
    echo "  查看链接   : xray-lite links"
    echo "  查看参数   : xray-lite info"
    echo "  重启服务   : xray-lite restart"
    echo "  查看日志   : xray-lite logs"
    echo "  实时日志   : xray-lite follow"
    echo "  测试配置   : xray-lite test"
    echo "  卸载服务   : xray-lite uninstall"

    echo
    blue "关键文件："
    echo "  Xray 程序  : ${XRAY_BIN}"
    echo "  Xray 配置  : ${XRAY_CONFIG}"
    echo "  节点链接   : ${XRAY_LINK}"
    echo "  Reality 参数: ${XRAY_ENV}"

    echo
    blue "当前资源："
    free -h || true
    df -h / || true

    echo
    green "================================================================"
}

# ------------------------------------------------------------------------------
# 主程序
# ------------------------------------------------------------------------------

main() {
    require_root
    check_system
    check_disk_space

    # 先创建 Swap，降低 apt/dpkg 在 64MB 环境被 OOM 杀掉的概率。
    create_swap_if_needed

    # 修复之前可能被强杀中断的 apt/dpkg 事务。
    repair_apt

    # 只安装绝对必要的依赖，不使用 jq。
    install_dependencies

    # iproute2 安装后，再进行端口检查。
    check_port "${PORT}"
    check_sni

    backup_old_files
    download_xray

    generate_values
    generate_keys
    check_reality_target

    write_config
    write_systemd_service
    configure_journal
    write_link
    write_manager

    test_and_start
    show_result
}

main "$@"
