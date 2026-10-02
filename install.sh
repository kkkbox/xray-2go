#!/usr/bin/env bash
# ============================================================
# Xray VLESS + TCP + REALITY + XTLS Vision 极简安装脚本
# 适用：Debian 11/12、Ubuntu 20.04/22.04/24.04（systemd）
# 资源目标：64 MB RAM + 1 GB Disk
#
# 不安装：Caddy、Nginx、Cloudflared、Docker、面板、订阅服务
# 默认：VLESS TCP Reality，端口 443，伪装域名 www.microsoft.com
#
# 用法：
#   bash install.sh
#
# 自定义：
#   PORT=443 SNI=www.microsoft.com bash install.sh
#   PORT=2053 SNI=www.apple.com SERVER_IP=1.2.3.4 bash install.sh
# ============================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly XRAY_DIR="/etc/xray"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_ENV="${XRAY_DIR}/reality.env"
readonly XRAY_LINK="${XRAY_DIR}/vless.txt"
readonly XRAY_SERVICE="/etc/systemd/system/xray.service"
readonly XRAY_BACKUP_DIR="/root/xray-backup"

PORT="${PORT:-443}"
SNI="${SNI:-www.microsoft.com}"
SERVER_IP="${SERVER_IP:-}"
UUID="${UUID:-}"
SHORT_ID="${SHORT_ID:-}"
XRAY_TAG="vless-reality-vision"

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
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

info() {
    printf "${CYAN}%s${RESET}\n" "$*"
}

die() {
    red "错误：$*"
    exit 1
}

on_error() {
    local line="$1"
    red "脚本在第 ${line} 行执行失败。"
    red "如已生成配置，可用以下命令查看日志："
    red "journalctl -u xray -n 100 --no-pager"
}

trap 'on_error $LINENO' ERR

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 用户运行：sudo -i 后再执行脚本。"
}

check_system() {
    [[ -r /etc/os-release ]] || die "无法识别 Linux 系统。"

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            ;;
        *)
            die "当前脚本只支持 Debian / Ubuntu。当前系统：${PRETTY_NAME:-未知}"
            ;;
    esac

    command -v systemctl >/dev/null 2>&1 || die "未检测到 systemd，本脚本不支持当前 init 系统。"
    command -v apt-get >/dev/null 2>&1 || die "未检测到 apt-get。"
}

check_port() {
    local port="$1"

    [[ "${port}" =~ ^[0-9]+$ ]] || die "端口必须是数字：${port}"
    (( port >= 1 && port <= 65535 )) || die "端口范围必须是 1-65535：${port}"

    if command -v ss >/dev/null 2>&1; then
        if ss -lntH "sport = :${port}" 2>/dev/null | grep -q .; then
            die "TCP 端口 ${port} 已被占用，请换一个端口。"
        fi
    fi
}

check_sni_format() {
    [[ -n "${SNI}" ]] || die "SNI 不能为空。"
    [[ "${SNI}" =~ ^[A-Za-z0-9.-]+$ ]] || die "SNI 格式不正确：${SNI}"
    [[ "${SNI}" != .* ]] || die "SNI 不能以 . 开头。"
    [[ "${SNI}" != *..* ]] || die "SNI 不能包含连续的 .."
}

install_dependencies() {
    info "安装必要依赖..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq

    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
        openssl \
        jq \
        iproute2 \
        coreutils

    apt-get clean
    rm -rf /var/lib/apt/lists/*
}

get_architecture() {
    case "$(uname -m)" in
        x86_64)
            echo "64"
            ;;
        i386|i686)
            echo "32"
            ;;
        aarch64|arm64)
            echo "arm64-v8a"
            ;;
        armv7l|armv7)
            echo "arm32-v7a"
            ;;
        *)
            die "不支持的 CPU 架构：$(uname -m)"
            ;;
    esac
}

backup_existing_config() {
    if [[ -d "${XRAY_DIR}" ]]; then
        mkdir -p "${XRAY_BACKUP_DIR}"
        local backup_file="${XRAY_BACKUP_DIR}/xray-$(date +%Y%m%d-%H%M%S).tar.gz"

        tar -C /etc -czf "${backup_file}" xray 2>/dev/null || true
        yellow "检测到旧 Xray 配置，已备份至：${backup_file}"
    fi
}

download_xray() {
    local arch version tmpdir zip_file

    arch="$(get_architecture)"
    tmpdir="$(mktemp -d)"
    zip_file="${tmpdir}/xray.zip"

    info "获取 Xray 最新稳定版版本号..."

    version="$(
        curl -fsSL --retry 3 --connect-timeout 10 \
            "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r '.tag_name'
    )"

    [[ -n "${version}" && "${version}" != "null" ]] || die "无法获取 Xray 最新版本。"

    info "下载 Xray ${version}（架构：${arch}）..."

    curl -fL --retry 3 --connect-timeout 15 \
        -o "${zip_file}" \
        "https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${arch}.zip"

    unzip -oq "${zip_file}" -d "${tmpdir}/xray"

    [[ -x "${tmpdir}/xray/xray" ]] || die "Xray 压缩包中未找到 xray 可执行文件。"

    install -d -m 700 "${XRAY_DIR}"
    install -m 0755 "${tmpdir}/xray/xray" "${XRAY_BIN}"

    rm -rf "${tmpdir}"

    "${XRAY_BIN}" version >/dev/null 2>&1 || die "Xray 二进制文件无法执行。"

    green "Xray 安装完成：$("${XRAY_BIN}" version | head -n 1)"
}

validate_target_site() {
    info "检测 Reality 伪装站点 TLS 可用性：${SNI}:443"

    if timeout 12 openssl s_client \
        -connect "${SNI}:443" \
        -servername "${SNI}" \
        -brief </dev/null >/dev/null 2>&1; then
        green "伪装站点可访问。"
    else
        yellow "无法验证 ${SNI}:443。"
        yellow "这不一定会阻止安装，但如果该站点不可达或 TLS 不兼容，Reality 可能无法连接。"
        yellow "建议改用可从 VPS 访问、支持 TLS 1.3 的域名。"
    fi
}

generate_reality_keys() {
    local key_output

    key_output="$("${XRAY_BIN}" x25519)"

    PRIVATE_KEY="$(awk '/PrivateKey:/ {print $2}' <<<"${key_output}")"
    PUBLIC_KEY="$(awk '/Password/ {print $NF}' <<<"${key_output}")"

    [[ -n "${PRIVATE_KEY}" ]] || die "无法生成 Reality 私钥。"
    [[ -n "${PUBLIC_KEY}" ]] || die "无法生成 Reality 公钥。"
}

generate_values() {
    UUID="${UUID:-$(cat /proc/sys/kernel/random/uuid)}"

    if [[ -z "${SHORT_ID}" ]]; then
        SHORT_ID="$(openssl rand -hex 8)"
    fi

    [[ "${UUID}" =~ ^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$ ]] \
        || die "UUID 格式不正确：${UUID}"

    [[ "${SHORT_ID}" =~ ^[a-fA-F0-9]{1,16}$ ]] \
        || die "SHORT_ID 必须是 1-16 位十六进制字符。"
}

write_config() {
    info "写入 Xray Reality 配置..."

    cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "none",
    "error": "none"
  },
  "inbounds": [
    {
      "tag": "${XRAY_TAG}",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "email": "default-user"
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
UUID=${UUID}
PORT=${PORT}
SNI=${SNI}
PRIVATE_KEY=${PRIVATE_KEY}
PUBLIC_KEY=${PUBLIC_KEY}
SHORT_ID=${SHORT_ID}
EOF

    chmod 600 "${XRAY_ENV}"
}

write_systemd_service() {
    info "创建 systemd 服务..."

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
MemoryDenyWriteExecute=false

LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "${XRAY_SERVICE}"
}

configure_journald_limit() {
    info "限制系统日志占用空间..."

    install -d -m 755 /etc/systemd/journald.conf.d

    cat > /etc/systemd/journald.conf.d/20-xray-lite.conf <<EOF
[Journal]
SystemMaxUse=50M
SystemKeepFree=100M
RuntimeMaxUse=20M
MaxRetentionSec=7day
Compress=yes
EOF

    systemctl restart systemd-journald || true
    journalctl --vacuum-size=50M >/dev/null 2>&1 || true
}

get_server_ip() {
    if [[ -n "${SERVER_IP}" ]]; then
        printf '%s' "${SERVER_IP}"
        return 0
    fi

    local ip=""

    ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
        printf '%s' "${ip}"
        return 0
    fi

    ip="$(curl -4fsS --max-time 5 https://ipv4.icanhazip.com 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "${ip}" ]]; then
        printf '%s' "${ip}"
        return 0
    fi

    ip="$(curl -6fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
        printf '[%s]' "${ip}"
        return 0
    fi

    printf 'YOUR_SERVER_IP'
}

write_client_link() {
    local server_ip node_name

    server_ip="$(get_server_ip)"
    node_name="VLESS-Reality-${server_ip//[:\[\]]/_}"

    cat > "${XRAY_LINK}" <<EOF
vless://${UUID}@${server_ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${node_name}
EOF

    chmod 600 "${XRAY_LINK}"
}

test_and_start() {
    info "校验 Xray 配置..."

    "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" \
        || die "Xray 配置校验失败，服务不会启动。"

    systemctl daemon-reload
    systemctl enable xray >/dev/null
    systemctl restart xray

    sleep 2

    if systemctl is-active --quiet xray; then
        green "Xray 服务已启动并设置为开机自启。"
    else
        red "Xray 启动失败，以下为最近日志："
        journalctl -u xray -n 80 --no-pager || true
        exit 1
    fi
}

show_result() {
    local server_ip

    server_ip="$(get_server_ip)"

    echo
    green "============================================================"
    green "       Xray VLESS + TCP + REALITY 安装完成"
    green "============================================================"
    echo

    info "服务状态："
    systemctl --no-pager --full status xray | sed -n '1,8p' || true

    echo
    info "服务端参数："
    echo "  地址       : ${server_ip}"
    echo "  端口       : ${PORT}"
    echo "  UUID       : ${UUID}"
    echo "  Reality SNI: ${SNI}"
    echo "  Public Key : ${PUBLIC_KEY}"
    echo "  Short ID   : ${SHORT_ID}"

    echo
    yellow "客户端 VLESS 链接："
    cat "${XRAY_LINK}"

    echo
    yellow "重要：请在 VPS 服务商安全组/云防火墙放行 TCP ${PORT}。"
    yellow "本脚本不会修改 iptables、nftables、UFW 或 SSH 配置。"

    echo
    info "文件位置："
    echo "  Xray 程序 : ${XRAY_BIN}"
    echo "  Xray 配置 : ${XRAY_CONFIG}"
    echo "  客户端链接: ${XRAY_LINK}"
    echo "  参数备份  : ${XRAY_ENV}"

    echo
    info "常用命令："
    echo "  查看状态 : systemctl status xray --no-pager"
    echo "  重启服务 : systemctl restart xray"
    echo "  停止服务 : systemctl stop xray"
    echo "  查看日志 : journalctl -u xray -n 100 --no-pager"
    echo "  实时日志 : journalctl -u xray -f"
    echo "  配置测试 : ${XRAY_BIN} run -test -config ${XRAY_CONFIG}"
    echo "  查看链接 : cat ${XRAY_LINK}"

    echo
    yellow "修改 /etc/xray/config.json 前，请先备份并在修改后执行配置测试。"
    green "============================================================"
}

main() {
    require_root
    check_system
    check_port "${PORT}"
    check_sni_format
    backup_existing_config
    install_dependencies
    download_xray
    validate_target_site
    generate_values
    generate_reality_keys
    write_config
    write_systemd_service
    configure_journald_limit
    write_client_link
    test_and_start
    show_result
}

main "$@"
