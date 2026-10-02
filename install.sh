#!/usr/bin/env bash
# ==============================================================================
# Xray Lite Installer
# VLESS + TCP + REALITY + XTLS Vision
#
# 面向低配 VPS：
#   - 最低：64 MB RAM + 1 GB Disk
#   - 推荐：64 MB RAM + 256 MB Swap
#
# 支持：
#   - Debian 11 / 12 / 13
#   - Ubuntu 20.04 / 22.04 / 24.04
#   - systemd
#
# 不安装：
#   - Caddy / Nginx
#   - Cloudflared / Argo
#   - Docker
#   - Web 面板
#   - jq
#   - Python
#   - 订阅服务
#
# 用法：
#   bash install.sh
#
# 自定义：
#   PORT=443 SNI=www.microsoft.com bash install.sh
#   PORT=2053 SNI=www.apple.com bash install.sh
#   SERVER_IP=1.2.3.4 PORT=443 SNI=www.microsoft.com bash install.sh
#
# 安装后：
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
# 路径与默认参数
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
# 颜色与基础函数
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
    local exit_code="$1"
    local line_no="$2"

    echo
    red "脚本在第 ${line_no} 行执行失败，退出代码：${exit_code}"

    echo
    yellow "可执行以下命令排查："
    echo "  free -h"
    echo "  swapon --show"
    echo "  df -h /"
    echo "  dmesg -T | tail -n 50"
    echo "  journalctl -u xray -n 100 --no-pager"
}

trap 'on_error $? $LINENO' ERR

# ------------------------------------------------------------------------------
# 环境检查
# ------------------------------------------------------------------------------

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "请使用 root 用户运行。可执行：sudo -i"
    fi
}

check_system() {
    [[ -f /etc/os-release ]] || die "无法识别系统：缺少 /etc/os-release。"

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            ;;
        *)
            die "仅支持 Debian / Ubuntu。当前系统：${PRETTY_NAME:-未知系统}"
            ;;
    esac

    command -v systemctl >/dev/null 2>&1 \
        || die "未检测到 systemd，当前脚本仅支持 systemd 系统。"

    command -v apt-get >/dev/null 2>&1 \
        || die "未检测到 apt-get。"
}

check_disk_space() {
    local available_kb

    available_kb="$(df -Pk / | awk 'NR==2 {print $4}')"

    [[ -n "${available_kb}" ]] || die "无法检测根分区可用空间。"

    if (( available_kb < 180000 )); then
        warn "根分区可用空间少于约 180 MB。"
        warn "建议先执行：apt-get clean && rm -rf /var/lib/apt/lists/*"
        warn "当前空间不足可能导致下载、解压或安装失败。"
    fi
}

check_port() {
    local port="$1"

    [[ "${port}" =~ ^[0-9]+$ ]] || die "端口必须是纯数字：${port}"

    if (( port < 1 || port > 65535 )); then
        die "端口范围必须是 1-65535：${port}"
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -lntH "sport = :${port}" 2>/dev/null | grep -q .; then
            die "TCP 端口 ${port} 已被占用。请换端口，例如 PORT=2053 bash install.sh"
        fi
    fi
}

check_sni() {
    [[ -n "${SNI}" ]] || die "SNI 不能为空。"

    if [[ ! "${SNI}" =~ ^[A-Za-z0-9.-]+$ ]]; then
        die "SNI 格式不正确：${SNI}"
    fi

    if [[ "${SNI}" == .* || "${SNI}" == *..* ]]; then
        die "SNI 格式不正确：${SNI}"
    fi
}

# ------------------------------------------------------------------------------
# Swap：64MB VPS 的关键保障
# ------------------------------------------------------------------------------

swap_is_enabled() {
    swapon --noheadings --show 2>/dev/null | grep -q .
}

create_swap_if_needed() {
    local disk_kb

    if swap_is_enabled; then
        info "已检测到可用 Swap："
        swapon --show
        return 0
    fi

    disk_kb="$(df -Pk / | awk 'NR==2 {print $4}')"

    if (( disk_kb < (SWAP_SIZE_MB * 1024 + 180000) )); then
        warn "磁盘空间不足，无法安全创建 ${SWAP_SIZE_MB} MB Swap。"
        warn "将继续安装，但 64 MB 内存下 apt/dpkg 仍可能被 OOM 杀死。"
        return 0
    fi

    info "未检测到 Swap，尝试创建 ${SWAP_SIZE_MB} MB Swap..."

    if [[ -e "${SWAP_FILE}" ]]; then
        warn "${SWAP_FILE} 已存在，但未启用。尝试启用。"
    else
        if command -v fallocate >/dev/null 2>&1; then
            fallocate -l "${SWAP_SIZE_MB}M" "${SWAP_FILE}" 2>/dev/null || true
        fi

        if [[ ! -s "${SWAP_FILE}" ]]; then
            info "fallocate 不可用或创建失败，使用 dd 创建 Swap 文件..."
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

        green "Swap 创建并启用成功："
        swapon --show
    else
        warn "无法启用 Swap。"
        warn "该 VPS 可能是限制 Swap 的 OpenVZ / LXC 容器。"
        warn "如后续 apt-get 再次显示 Killed，建议升级到至少 128 MB 内存或更换支持 Swap 的 KVM VPS。"
        rm -f "${SWAP_FILE}" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# APT 修复与最小依赖安装
# ------------------------------------------------------------------------------

repair_apt() {
    info "检查并修复可能中断的 dpkg / apt 状态..."

    export DEBIAN_FRONTEND=noninteractive

    dpkg --configure -a || true
    apt-get -f install -y || true

    apt-get clean || true
    rm -rf /var/lib/apt/lists/* || true
}

install_dependencies() {
    local packages=()

    info "更新 APT 软件包索引..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update \
        -o Acquire::Languages=none \
        -o Acquire::PDiffs=false \
        -qq

    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v unzip >/dev/null 2>&1 || packages+=(unzip)
    command -v openssl >/dev/null 2>&1 || packages+=(openssl)
    command -v ss >/dev/null 2>&1 || packages+=(iproute2)
    command -v timeout >/dev/null 2>&1 || packages+=(coreutils)
    command -v ca-certificates >/dev/null 2>&1 || packages+=(ca-certificates)

    if (( ${#packages[@]} > 0 )); then
        info "安装最小依赖：${packages[*]}"

        # 单次只安装一个包，降低低内存 VPS 上 dpkg 的瞬时内存峰值。
        local package
        for package in "${packages[@]}"; do
            apt-get install -y --no-install-recommends "${package}"
        done
    else
        green "所需依赖已存在，跳过安装。"
    fi

    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

# ------------------------------------------------------------------------------
# Xray 下载与安装
# ------------------------------------------------------------------------------

get_architecture() {
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

get_latest_xray_version() {
    local version

    version="$(
        curl -fsSL \
            --retry 3 \
            --retry-delay 2 \
            --connect-timeout 12 \
            --max-time 30 \
            "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null \
        | sed -n 's/^[[:space:]]*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n 1
    )"

    printf '%s' "${version}"
}

backup_old_xray() {
    if [[ -d "${XRAY_DIR}" || -f "${XRAY_SERVICE}" || -f "${XRAY_BIN}" ]]; then
        local backup_file

        backup_file="${XRAY_BACKUP_DIR}/xray-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

        info "检测到旧的 Xray 文件，正在备份..."

        mkdir -p "${XRAY_BACKUP_DIR}"

        tar -czf "${backup_file}" \
            /etc/xray \
            /etc/systemd/system/xray.service \
            /usr/local/bin/xray \
            2>/dev/null || true

        green "旧配置备份位置：${backup_file}"
    fi
}

download_xray() {
    local arch version tmpdir zip_file download_url

    arch="$(get_architecture)"
    version="$(get_latest_xray_version)"
    tmpdir="$(mktemp -d)"
    zip_file="${tmpdir}/xray.zip"

    trap 'rm -rf "${tmpdir}"' RETURN

    if [[ -n "${version}" ]]; then
        download_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"
        info "下载 Xray ${version}，架构：${arch}..."
    else
        download_url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
        warn "无法从 GitHub API 获取版本号，改用 latest 下载地址。"
    fi

    curl -fL \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 180 \
        -o "${zip_file}" \
        "${download_url}"

    unzip -oq "${zip_file}" -d "${tmpdir}/xray"

    [[ -f "${tmpdir}/xray/xray" ]] || die "下载文件中未找到 xray 可执行文件。"

    install -d -m 700 "${XRAY_DIR}"
    install -m 0755 "${tmpdir}/xray/xray" "${XRAY_BIN}"

    rm -rf "${tmpdir}"
    trap - RETURN

    "${XRAY_BIN}" version >/dev/null 2>&1 || die "Xray 可执行文件运行失败。"

    green "Xray 安装成功：$("${XRAY_BIN}" version | head -n 1)"
}

# ------------------------------------------------------------------------------
# Reality 配置生成
# ------------------------------------------------------------------------------

generate_values() {
    UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"
    SHORT_ID="${SHORT_ID:-$(openssl rand -hex 8)}"

    [[ "${UUID}" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] \
        || die "UUID 格式不正确：${UUID}"

    [[ "${SHORT_ID}" =~ ^[a-fA-F0-9]{1,16}$ ]] \
        || die "SHORT_ID 必须是 1-16 位十六进制字符。"
}

generate_reality_keys() {
    local key_output

    info "生成 Reality 密钥对..."

    key_output="$("${XRAY_BIN}" x25519)"

    PRIVATE_KEY="$(awk '/PrivateKey:/ {print $2}' <<< "${key_output}")"
    PUBLIC_KEY="$(awk '/Password/ {print $NF}' <<< "${key_output}")"

    [[ -n "${PRIVATE_KEY}" ]] || die "Reality 私钥生成失败。"
    [[ -n "${PUBLIC_KEY}" ]] || die "Reality 公钥生成失败。"
}

check_reality_target() {
    info "检测 Reality 伪装目标：${SNI}:443"

    if timeout 12 openssl s_client \
        -connect "${SNI}:443" \
        -servername "${SNI}" \
        -brief </dev/null >/dev/null 2>&1; then
        green "伪装目标 TLS 检测通过。"
    else
        warn "无法从当前 VPS 验证 ${SNI}:443。"
        warn "脚本会继续安装；但该目标站点不可访问或 TLS 不兼容时，Reality 可能无法正常工作。"
    fi
}

write_xray_config() {
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
# 此文件包含敏感信息，请勿公开或上传到 GitHub
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
# systemd、安全与日志配置
# ------------------------------------------------------------------------------

write_systemd_service() {
    info "写入 Xray systemd 服务..."

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

NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=${XRAY_DIR}
LockPersonality=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${XRAY_SERVICE}"
}

configure_journald() {
    info "设置日志占用限制..."

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
# 节点链接与管理命令
# ------------------------------------------------------------------------------

get_server_ip() {
    local ip=""

    if [[ -n "${SERVER_IP}" ]]; then
        printf '%s' "${SERVER_IP}"
        return 0
    fi

    ip="$(curl -4fsS --connect-timeout 5 --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
        printf '%s' "${ip}"
        return 0
    fi

    ip="$(curl -4fsS --connect-timeout 5 --max-time 8 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "${ip}" ]]; then
        printf '%s' "${ip}"
        return 0
    fi

    ip="$(curl -6fsS --connect-timeout 5 --max-time 8 https://api64.ipify.org 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
        printf '[%s]' "${ip}"
        return 0
    fi

    printf 'YOUR_SERVER_IP'
}

write_client_link() {
    local ip node_name

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
        red "请使用 root 运行。"
        exit 1
    }
}

usage() {
    cat <<USAGE
Xray Lite 管理命令：

  xray-lite status       查看 Xray 状态
  xray-lite start        启动 Xray
  xray-lite stop         停止 Xray
  xray-lite restart      测试配置后重启 Xray
  xray-lite logs [数量]  查看日志，默认 100 行
  xray-lite follow       实时查看日志
  xray-lite links        查看 VLESS 导入链接
  xray-lite info         查看 Reality 参数
  xray-lite test         测试配置文件
  xray-lite port         查看 Xray 监听端口
  xray-lite uninstall    卸载 Xray Lite
USAGE
}

uninstall_xray() {
    need_root

    yellow "即将停止并卸载 Xray Lite。"
    read -r -p "确认卸载？配置会先备份到 /root/xray-backup/ (y/N): " answer

    case "${answer}" in
        y|Y|yes|YES)
            ;;
        *)
            yellow "已取消卸载。"
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
    rm -f /etc/sysctl.d/99-xray-lite-memory.conf

    systemctl daemon-reload
    systemctl restart systemd-journald 2>/dev/null || true

    green "Xray Lite 已卸载。旧配置备份位于：/root/xray-backup/"
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
        [[ -f "${XRAY_LINK}" ]] || {
            red "未找到节点链接文件：${XRAY_LINK}"
            exit 1
        }
        cat "${XRAY_LINK}"
        ;;
    info)
        [[ -f "${XRAY_ENV}" ]] || {
            red "未找到参数文件：${XRAY_ENV}"
            exit 1
        }
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
# 启动和结果显示
# ------------------------------------------------------------------------------

test_and_start_xray() {
    info "验证 Xray 配置..."

    "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" \
        || die "Xray 配置校验失败。"

    systemctl daemon-reload
    systemctl enable xray >/dev/null
    systemctl restart xray

    sleep 2

    if systemctl is-active --quiet xray; then
        green "Xray 已启动，并已设置开机自动启动。"
    else
        red "Xray 启动失败，最近日志如下："
        journalctl -u xray -n 100 --no-pager || true
        exit 1
    fi
}

show_result() {
    local ip

    ip="$(get_server_ip)"

    echo
    green "================================================================"
    green "          Xray VLESS + TCP + Reality + Vision 安装完成"
    green "================================================================"
    echo

    blue "服务端信息："
    echo "  服务器地址 : ${ip}"
    echo "  服务器端口 : ${PORT}"
    echo "  UUID       : ${UUID}"
    echo "  Reality SNI: ${SNI}"
    echo "  Public Key : ${PUBLIC_KEY}"
    echo "  Short ID   : ${SHORT_ID}"

    echo
    yellow "VLESS 客户端导入链接："
    cat "${XRAY_LINK}"

    echo
    yellow "请务必在 VPS 服务商安全组 / 防火墙中放行：TCP ${PORT}"
    yellow "本脚本不会修改 iptables、nftables、UFW、SSH 或云防火墙。"

    echo
    blue "资源状态："
    free -h || true
    df -h / || true

    echo
    blue "常用管理命令："
    echo "  查看状态   : xray-lite status"
    echo "  查看链接   : xray-lite links"
    echo "  查看参数   : xray-lite info"
    echo "  重启服务   : xray-lite restart"
    echo "  查看日志   : xray-lite logs"
    echo "  实时日志   : xray-lite follow"
    echo "  测试配置   : xray-lite test"
    echo "  卸载服务   : xray-lite uninstall"

    echo
    blue "关键文件位置："
    echo "  Xray 程序  : ${XRAY_BIN}"
    echo "  服务端配置 : ${XRAY_CONFIG}"
    echo "  节点链接   : ${XRAY_LINK}"
    echo "  参数文件   : ${XRAY_ENV}"

    echo
    green "================================================================"
}

# ------------------------------------------------------------------------------
# 主流程
# ------------------------------------------------------------------------------

main() {
    require_root
    check_system
    check_disk_space

    # 先创建 Swap，避免后续 apt/dpkg 进程在 64MB 内存下 OOM。
    create_swap_if_needed

    # 修复上一次因 OOM 被中断的 apt/dpkg 状态。
    repair_apt

    # 安装最少的必要依赖，不安装 jq。
    install_dependencies

    # 安装 iproute2 后再二次检查端口。
    check_port "${PORT}"
    check_sni

    backup_old_xray
    download_xray

    generate_values
    generate_reality_keys
    check_reality_target

    write_xray_config
    write_systemd_service
    configure_journald
    write_client_link
    write_manager

    test_and_start_xray
    show_result
}

main "$@"
