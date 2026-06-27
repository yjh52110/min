#!/bin/bash
#
# XMR Worker One-Line Installer
#
# Installs XMRig on a fresh Linux sub-node, auto-tunes it, connects it to a
# central XMRig-Proxy node (or directly to public pools), and registers a
# systemd service so it survives reboots.
#
# Usage (run as root):
#   curl -fsSL https://raw.githubusercontent.com/yjh52110/min/main/xmr-mining/scripts/install-worker.sh \
#     | sudo bash -s -- --proxy PROXY_IP:3333 --worker vps-tokyo
#
#   # or mine directly to a wallet (no proxy):
#   curl -fsSL .../install-worker.sh | sudo bash -s -- --wallet 4Abc...xyz
#

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_title() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# ─── Defaults / config ────────────────────────────────────────────
REPO="${REPO:-yjh52110/min}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/xmr-worker}"
XMRIG_TARBALL="${XMRIG_TARBALL:-xmrig-6.26.0-linux-static-x64.tar.gz}"

PROXY="${PROXY:-}"
WALLET="${WALLET:-}"
WORKER_NAME="${WORKER_NAME:-}"

usage() {
    cat <<USAGE
XMR Worker One-Line Installer

Usage: sudo bash install-worker.sh [options]

Options:
  -p, --proxy IP:PORT   Central XMRig-Proxy to connect to (recommended).
                        Wallet lives on the proxy, so none is needed here.
  -w, --wallet ADDR     Mine directly to this Monero wallet (no proxy).
  -n, --worker NAME     Worker / rig name (default: vps-<hostname>).
      --dir PATH        Install directory (default: /opt/xmr-worker).
      --repo OWNER/REPO Source repo (default: yjh52110/min).
      --branch NAME     Source branch (default: main).
  -h, --help            Show this help.

Provide exactly one of --proxy or --wallet.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -p|--proxy)   PROXY="$2"; shift 2;;
        -w|--wallet)  WALLET="$2"; shift 2;;
        -n|--worker)  WORKER_NAME="$2"; shift 2;;
        --dir)        INSTALL_DIR="$2"; shift 2;;
        --repo)       REPO="$2"; shift 2;;
        --branch)     BRANCH="$2"; shift 2;;
        -h|--help)    usage; exit 0;;
        *) log_err "Unknown option: $1"; usage; exit 1;;
    esac
done

# ─── Pre-flight checks ────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    log_err "Please run as root (use sudo). Needed for huge pages + systemd."
    exit 1
fi

if [ -z "$PROXY" ] && [ -z "$WALLET" ]; then
    log_err "Provide --proxy IP:PORT (connect to central node) or --wallet ADDR."
    echo ""
    usage
    exit 1
fi
if [ -n "$PROXY" ] && [ -n "$WALLET" ]; then
    log_warn "Both --proxy and --wallet given; using --proxy and ignoring --wallet."
    WALLET=""
fi

# Download helper (curl or wget)
fetch() {  # fetch URL DEST
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1" -o "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$1" -O "$2"
    else
        log_err "Neither curl nor wget is available. Install one and retry."
        exit 1
    fi
}

RAW_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}/xmr-mining"

log_title "XMR Worker Installer"
log_info "Source:      ${REPO}@${BRANCH}"
log_info "Install dir: ${INSTALL_DIR}"
if [ -n "$PROXY" ]; then
    log_info "Mode:        proxy → ${PROXY}"
else
    log_info "Mode:        direct → wallet ${WALLET}"
fi

# Ensure tar is present
if ! command -v tar >/dev/null 2>&1; then
    log_info "Installing tar..."
    (apt-get update -qq && apt-get install -y -qq tar) >/dev/null 2>&1 || true
fi

# ─── 1. Download & extract XMRig ──────────────────────────────────
log_title "Downloading XMRig"
mkdir -p "${INSTALL_DIR}/xmrig" "${INSTALL_DIR}/scripts"

if [ ! -x "${INSTALL_DIR}/xmrig/xmrig" ]; then
    TMP_TARBALL="${INSTALL_DIR}/xmrig/${XMRIG_TARBALL}"
    log_info "Fetching ${XMRIG_TARBALL}..."
    fetch "${RAW_BASE}/xmrig/${XMRIG_TARBALL}" "${TMP_TARBALL}"
    log_info "Extracting..."
    tar xzf "${TMP_TARBALL}" -C "${INSTALL_DIR}/xmrig" --strip-components=1
    rm -f "${TMP_TARBALL}"
fi

if [ ! -x "${INSTALL_DIR}/xmrig/xmrig" ]; then
    log_err "xmrig binary not found after extraction. Aborting."
    exit 1
fi
log_info "XMRig ready: $(${INSTALL_DIR}/xmrig/xmrig --version 2>/dev/null | head -1)"

# ─── 2. Download tuning script ────────────────────────────────────
log_title "Downloading Auto-Optimize Script"
fetch "${RAW_BASE}/scripts/auto-optimize.sh" "${INSTALL_DIR}/scripts/auto-optimize.sh"
chmod +x "${INSTALL_DIR}/scripts/auto-optimize.sh"

# ─── 3. Tune + generate config + install service ──────────────────
log_title "Tuning & Generating Config"
OPT_ARGS=()
if [ -n "$PROXY" ]; then
    OPT_ARGS+=(--proxy "$PROXY")
else
    OPT_ARGS+=(--wallet "$WALLET")
fi
if [ -n "$WORKER_NAME" ]; then
    OPT_ARGS+=(--worker "$WORKER_NAME")
fi

bash "${INSTALL_DIR}/scripts/auto-optimize.sh" "${OPT_ARGS[@]}"

# ─── 4. Enable & start systemd service ────────────────────────────
log_title "Starting Miner Service"
if [ -f /etc/systemd/system/xmrig.service ]; then
    systemctl daemon-reload
    systemctl enable --now xmrig
    sleep 2
    systemctl --no-pager --full status xmrig | head -12 || true
    log_info "Miner service started. Logs: journalctl -u xmrig -f"
else
    log_warn "Service file not found; starting xmrig in background instead."
    nohup "${INSTALL_DIR}/xmrig/xmrig" --config="${INSTALL_DIR}/xmrig/config.json" \
        >"${INSTALL_DIR}/xmrig/xmrig.out" 2>&1 &
    log_info "Started. Logs: ${INSTALL_DIR}/xmrig/xmrig.out"
fi

log_title "Done"
log_info "Worker installed at ${INSTALL_DIR}"
if [ -n "$PROXY" ]; then
    log_info "Connected to proxy ${PROXY}. Check it on the dashboard."
fi
