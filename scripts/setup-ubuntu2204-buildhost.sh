#!/usr/bin/env bash
#
# Bootstrap an Ubuntu 22.04 x86_64 host for the local LineageOS build.
#
# This script is intentionally self-contained so it can be copied to a fresh
# Huawei Cloud ECS and run once as root (or with sudo).  Edit the Mihomo block
# below before copying it to the server.  If the block is left empty, Mihomo
# is installed but not started and no system proxy is changed.
#
# The Android 8.1 compiler dependencies are installed inside the project's
# Ubuntu 18.04 Docker image by scripts/build-local.sh.  The apt list below is
# the host-side toolchain needed to run that wrapper, Docker, repo and Codex.
#
# Usage:
#   sudo bash setup-ubuntu2204-buildhost.sh
#   sudo -iu <target-user>
#   codex login --device-auth
#   ~/start-lineage-build.sh
#
set -Eeuo pipefail

log() { printf '\n==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die() { printf '!! %s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
    echo "请用 root 或 sudo 运行此脚本。" >&2
    exit 1
fi

[[ "$(uname -m)" == "x86_64" ]] || die "此构建必须运行在 x86_64 ECS 上；当前架构是 $(uname -m)。"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "22.04" ]] || \
        die "此脚本只支持 Ubuntu 22.04；当前是 ${PRETTY_NAME:-未知系统}。"
else
    die "找不到 /etc/os-release，无法确认系统版本。"
fi

# ============================ 只需编辑这里 ================================
# Paste the complete Mihomo YAML between YAML markers.  The default ports must
# match the ports in that YAML; change them here if your config uses others.
MIHOMO_HTTP_PORT="${MIHOMO_HTTP_PORT:-7890}"
MIHOMO_SOCKS_PORT="${MIHOMO_SOCKS_PORT:-7891}"
MIHOMO_HTTP_PROXY="${MIHOMO_HTTP_PROXY:-http://127.0.0.1:${MIHOMO_HTTP_PORT}}"
MIHOMO_SOCKS_PROXY="${MIHOMO_SOCKS_PROXY:-socks5://127.0.0.1:${MIHOMO_SOCKS_PORT}}"
MIHOMO_NO_PROXY="${MIHOMO_NO_PROXY:-127.0.0.1,localhost,::1}"

MIHOMO_CONFIG_YAML=$(cat <<'YAML'
# Paste your Mihomo config here, for example:
# mixed-port: 7890
# allow-lan: false
# mode: rule
# log-level: info
# (Replace these comments with your real config before running.)
YAML
)

# The extra EVS disk should normally be mounted at /work before building.  Set
# BUILDROOT to that mount point if your mount path differs.
BUILDROOT="${BUILDROOT:-/work/lineage-build}"
CCACHE_SIZE="${CCACHE_SIZE:-32G}"
BUILD_JOBS="${BUILD_JOBS:-16}"
REPO_URL="${REPO_URL:-https://github.com/baiyunquan/Action-LineageOS-Builder.git}"
REPO_DIR="${REPO_DIR:-}"
# Huawei documents repo.huaweicloud.com/ubuntu for Ubuntu packages.  Aliyun is
# used only when the Huawei mirror cannot refresh the selected Ubuntu release.
APT_MIRROR_PRIMARY="${APT_MIRROR_PRIMARY:-https://repo.huaweicloud.com/ubuntu}"
APT_MIRROR_FALLBACK="${APT_MIRROR_FALLBACK:-https://mirrors.aliyun.com/ubuntu}"
# ========================== 编辑区结束 ====================================

export DEBIAN_FRONTEND=noninteractive

if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && id "${SUDO_USER}" &>/dev/null; then
    TARGET_USER="${TARGET_USER:-${SUDO_USER}}"
elif id ubuntu &>/dev/null; then
    TARGET_USER="${TARGET_USER:-ubuntu}"
else
    TARGET_USER="${TARGET_USER:-builder}"
fi

if [[ "${TARGET_USER}" == "root" ]]; then
    die "TARGET_USER 不能是 root；请设置 TARGET_USER=<普通用户>。"
fi

if ! id "${TARGET_USER}" &>/dev/null; then
    log "创建构建用户 ${TARGET_USER}"
    useradd --create-home --shell /bin/bash "${TARGET_USER}"
fi
TARGET_HOME="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
[[ -n "${TARGET_HOME}" && -d "${TARGET_HOME}" ]] || die "无法确定 ${TARGET_USER} 的 home 目录"

log "安装 Ubuntu 22.04 主机依赖"
# Use an isolated source list for this bootstrap.  It avoids mixing an old
# vendor source with the selected mirror and leaves the operator's apt config
# untouched after installation.
APT_SOURCE_LIST="$(mktemp /run/lineage-build-apt.XXXXXX.list)"
APT_GET=(apt-get -o "Dir::Etc::sourcelist=${APT_SOURCE_LIST}" \
    -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0)
write_jammy_sources() {
    local mirror="${1%/}"
    printf '%s\n' \
        "deb ${mirror} jammy main restricted universe multiverse" \
        "deb ${mirror} jammy-updates main restricted universe multiverse" \
        "deb ${mirror} jammy-security main restricted universe multiverse" \
        >"${APT_SOURCE_LIST}"
}
APT_MIRROR_SELECTED=""
for candidate in "${APT_MIRROR_PRIMARY}" "${APT_MIRROR_FALLBACK}"; do
    write_jammy_sources "${candidate}"
    if "${APT_GET[@]}" update; then
        APT_MIRROR_SELECTED="${candidate}"
        log "APT 镜像源: ${candidate}"
        break
    fi
    warn "APT 镜像源不可用: ${candidate}"
done
[[ -n "${APT_MIRROR_SELECTED}" ]] || die "华为云和阿里云 APT 镜像都不可用"
"${APT_GET[@]}" install -y --no-install-recommends \
    ca-certificates curl git git-lfs rsync unzip zip python3 python3-pip \
    python3-venv build-essential bc bison flex gperf ccache docker.io \
    gnupg jq lz4 squashfs-tools xsltproc libxml2-utils sudo gzip \
    openssh-client openssh-server tmux
rm -f "${APT_SOURCE_LIST}"

usermod -aG sudo "${TARGET_USER}"
systemctl enable --now docker
usermod -aG docker "${TARGET_USER}"
systemctl enable --now ssh

TARGET_REPO_DIR="${REPO_DIR:-${TARGET_HOME}/Action-LineageOS-Builder}"

run_as_target() {
    runuser -u "${TARGET_USER}" -- env \
        HOME="${TARGET_HOME}" USER="${TARGET_USER}" LOGNAME="${TARGET_USER}" \
        PATH="${TARGET_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        http_proxy="${http_proxy:-}" https_proxy="${https_proxy:-}" \
        HTTP_PROXY="${HTTP_PROXY:-}" HTTPS_PROXY="${HTTPS_PROXY:-}" \
        all_proxy="${all_proxy:-}" ALL_PROXY="${ALL_PROXY:-}" \
        no_proxy="${no_proxy:-}" NO_PROXY="${NO_PROXY:-}" "$@"
}

append_once() {
    local line="$1" file="$2"
    grep -Fqx "$line" "$file" 2>/dev/null || printf '%s\n' "$line" >>"$file"
}

# shellcheck disable=SC2016 # literal variables are intentionally written to .profile
append_once 'export PATH="$HOME/.local/bin:$PATH"' "${TARGET_HOME}/.profile"
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.profile"

log "安装或更新 Mihomo"
if [[ ! -x /usr/local/bin/mihomo ]]; then
    release_tmp="$(mktemp)"
    trap 'rm -f "${release_tmp:-}"' EXIT
    curl -fsSL -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/MetaCubeX/mihomo/releases/latest \
        -o "${release_tmp}"
    mihomo_asset_url="$(python3 - "${release_tmp}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    release = json.load(fh)

assets = [
    a for a in release.get("assets", [])
    if a.get("name", "").startswith("mihomo-linux-amd64")
    and a.get("name", "").endswith(".gz")
]

# The compatible build is the safest default for an arbitrary x86_64 ECS CPU.
preferred = [a for a in assets if "-compatible-" in a["name"]]
if not preferred:
    preferred = [a for a in assets if "-v1-" in a["name"]]
if not preferred:
    preferred = assets
if not preferred:
    raise SystemExit("latest Mihomo release has no linux-amd64 .gz asset")

preferred.sort(key=lambda item: item["name"])
print(preferred[0]["browser_download_url"])
PY
)"
    mihomo_asset="${mihomo_asset_url##*/}"
    curl -fL --retry 3 -o "/tmp/${mihomo_asset}" "${mihomo_asset_url}"
    gzip -dc "/tmp/${mihomo_asset}" > /usr/local/bin/mihomo
    chmod 0755 /usr/local/bin/mihomo
    rm -f "/tmp/${mihomo_asset}" "${release_tmp}"
    trap - EXIT
else
    echo "   已存在 /usr/local/bin/mihomo，跳过下载（删除它可强制更新）。"
fi

id mihomo &>/dev/null || useradd --system --home-dir /var/lib/mihomo \
    --create-home --shell /usr/sbin/nologin mihomo
install -d -o mihomo -g mihomo -m 0750 /etc/mihomo /var/lib/mihomo

cat >/etc/systemd/system/mihomo.service <<'UNIT'
[Unit]
Description=Mihomo proxy service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=mihomo
Group=mihomo
WorkingDirectory=/etc/mihomo
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT

config_payload="$(printf '%s\n' "${MIHOMO_CONFIG_YAML}" \
    | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d')"
MIHOMO_CONFIG_PRESENT=0
if [[ -n "${config_payload}" ]]; then
    printf '%s\n' "${MIHOMO_CONFIG_YAML}" >/etc/mihomo/config.yaml
    chown mihomo:mihomo /etc/mihomo/config.yaml
    chmod 0640 /etc/mihomo/config.yaml
    MIHOMO_CONFIG_PRESENT=1
elif [[ -f /etc/mihomo/config.yaml ]] && \
     sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' /etc/mihomo/config.yaml \
        | grep -q .; then
    echo "   使用已有的 /etc/mihomo/config.yaml。"
    MIHOMO_CONFIG_PRESENT=1
else
    cat >/etc/mihomo/config.yaml <<'YAML'
# Mihomo is installed but not started.
# Put the real YAML in setup-ubuntu2204-buildhost.sh and run it again.
YAML
    chown mihomo:mihomo /etc/mihomo/config.yaml
    chmod 0640 /etc/mihomo/config.yaml
fi

systemctl daemon-reload

configure_proxy() {
    log "启动 Mihomo 并设置系统代理"
    if ! systemctl enable --now mihomo || ! systemctl is-active --quiet mihomo; then
        systemctl --no-pager --full status mihomo || true
        journalctl -u mihomo -n 80 --no-pager || true
        die "Mihomo 启动失败；未写入全局代理配置。"
    fi

    cat >/etc/profile.d/mihomo-proxy.sh <<EOF
export http_proxy="${MIHOMO_HTTP_PROXY}"
export https_proxy="${MIHOMO_HTTP_PROXY}"
export HTTP_PROXY="${MIHOMO_HTTP_PROXY}"
export HTTPS_PROXY="${MIHOMO_HTTP_PROXY}"
export all_proxy="${MIHOMO_SOCKS_PROXY}"
export ALL_PROXY="${MIHOMO_SOCKS_PROXY}"
export no_proxy="${MIHOMO_NO_PROXY}"
export NO_PROXY="${MIHOMO_NO_PROXY}"
EOF
    chmod 0644 /etc/profile.d/mihomo-proxy.sh

    cat >/etc/apt/apt.conf.d/80mihomo-proxy <<EOF
Acquire::http::Proxy "${MIHOMO_HTTP_PROXY}";
Acquire::https::Proxy "${MIHOMO_HTTP_PROXY}";
EOF

    run_as_target git config --global http.proxy "${MIHOMO_HTTP_PROXY}"
    run_as_target git config --global https.proxy "${MIHOMO_HTTP_PROXY}"
    run_as_target git config --global url.https://github.com/.insteadOf git://github.com/

    # Docker uses this file for proxy variables inside build/run containers;
    # the systemd drop-in below covers image pulls by the daemon itself.
    install -d -o "${TARGET_USER}" -g "${TARGET_USER}" -m 0700 "${TARGET_HOME}/.docker"
    PROXY_HTTP="${MIHOMO_HTTP_PROXY}" PROXY_SOCKS="${MIHOMO_SOCKS_PROXY}" \
        PROXY_NO_PROXY="${MIHOMO_NO_PROXY}" \
        python3 - "${TARGET_HOME}/.docker/config.json" <<'PY'
import json
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text()) if path.exists() else {}
except (OSError, json.JSONDecodeError):
    data = {}
if not isinstance(data, dict):
    data = {}
data.setdefault("proxies", {})["default"] = {
    "httpProxy": os.environ["PROXY_HTTP"],
    "httpsProxy": os.environ["PROXY_HTTP"],
    "allProxy": os.environ["PROXY_SOCKS"],
    "noProxy": os.environ["PROXY_NO_PROXY"],
}
path.write_text(json.dumps(data, indent=2) + "\n")
PY
    chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/.docker/config.json"
    chmod 0600 "${TARGET_HOME}/.docker/config.json"

    install -d -m 0755 /etc/systemd/system/docker.service.d
    cat >/etc/systemd/system/docker.service.d/10-mihomo-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=${MIHOMO_HTTP_PROXY}"
Environment="HTTPS_PROXY=${MIHOMO_HTTP_PROXY}"
Environment="ALL_PROXY=${MIHOMO_SOCKS_PROXY}"
Environment="NO_PROXY=${MIHOMO_NO_PROXY}"
EOF
    systemctl daemon-reload
    systemctl restart docker

    # Make downloads performed by this script use Mihomo as well.
    export http_proxy="${MIHOMO_HTTP_PROXY}"
    export https_proxy="${MIHOMO_HTTP_PROXY}"
    export HTTP_PROXY="${MIHOMO_HTTP_PROXY}"
    export HTTPS_PROXY="${MIHOMO_HTTP_PROXY}"
    export all_proxy="${MIHOMO_SOCKS_PROXY}"
    export ALL_PROXY="${MIHOMO_SOCKS_PROXY}"
    export no_proxy="${MIHOMO_NO_PROXY}"
    export NO_PROXY="${MIHOMO_NO_PROXY}"
}

if [[ "${MIHOMO_CONFIG_PRESENT}" -eq 1 ]]; then
    configure_proxy
else
    warn "Mihomo 配置区仍为空：已安装但未启动，也未改动 apt/Git/Docker 的代理。"
fi

log "安装 repo 工具"
if ! command -v repo >/dev/null 2>&1; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
        -o /usr/local/bin/repo
    chmod 0755 /usr/local/bin/repo
fi

log "安装 Codex CLI（不在脚本中登录）"
if ! run_as_target bash -c 'command -v codex >/dev/null 2>&1'; then
    run_as_target bash -c \
        'curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh'
fi
# shellcheck disable=SC2016 # expand PATH in the target user's shell
run_as_target bash -c 'export PATH="$HOME/.local/bin:$PATH"; codex --version'

log "准备 LineageOS 构建仓库"
if [[ -e "${TARGET_REPO_DIR}/.git" ]]; then
    echo "   已存在 ${TARGET_REPO_DIR}，不自动 pull，保留本地改动。"
else
    install -d -o "${TARGET_USER}" -g "${TARGET_USER}" "$(dirname "${TARGET_REPO_DIR}")"
    run_as_target git clone "${REPO_URL}" "${TARGET_REPO_DIR}"
fi
run_as_target git lfs install
chown -R "${TARGET_USER}:${TARGET_USER}" "${TARGET_REPO_DIR}"

log "创建构建快捷脚本"
install -d -o "${TARGET_USER}" -g "${TARGET_USER}" "${BUILDROOT}"
cat >"${TARGET_HOME}/start-lineage-build.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "${TARGET_REPO_DIR}"
exec ./scripts/build-local.sh \\
  --workdir "${BUILDROOT}" \\
  --jobs "\${JOBS:-${BUILD_JOBS}}" \\
  --ccache-size "\${CCACHE_SIZE:-${CCACHE_SIZE}}" "\$@"
EOF
chown "${TARGET_USER}:${TARGET_USER}" "${TARGET_HOME}/start-lineage-build.sh"
chmod 0755 "${TARGET_HOME}/start-lineage-build.sh"

disk_free_gb="$(( $(df -Pk "${BUILDROOT}" | awk 'NR==2 {print $4}') / 1024 / 1024 ))"
if systemctl is-active --quiet mihomo; then
    mihomo_status="active"
else
    mihomo_status="未启动"
fi
echo
echo "================================ 完成 ================================"
echo "目标用户:       ${TARGET_USER}"
echo "Mihomo 配置:    /etc/mihomo/config.yaml"
echo "构建仓库:       ${TARGET_REPO_DIR}"
echo "构建目录:       ${BUILDROOT}（当前可用约 ${disk_free_gb} GiB）"
echo "Mihomo 状态:    ${mihomo_status}"
echo
if [[ "${MIHOMO_CONFIG_PRESENT}" -eq 0 ]]; then
    echo "请先编辑脚本中的 MIHOMO_CONFIG_YAML，再重新运行一次以启动代理。"
fi
echo "下一步："
echo "  sudo -iu ${TARGET_USER}"
echo "  codex login --device-auth"
echo "  ~/start-lineage-build.sh"
echo
echo "如需断点续编，可使用：~/start-lineage-build.sh --skip-sync"
echo "======================================================================="
