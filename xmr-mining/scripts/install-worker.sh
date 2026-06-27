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
XMRIG_VERSION="${XMRIG_VERSION:-6.26.0}"
XMRIG_TARBALL="${XMRIG_TARBALL:-xmrig-${XMRIG_VERSION}-linux-static-x64.tar.gz}"
# Expected sha256 of the official static x64 tarball (matches the repo's LFS object).
XMRIG_SHA256="${XMRIG_SHA256:-fc6f8ae5f64e4f17481f7e3be29a1c56949f216a998414188003eae1db20c9e5}"

PROXY="${PROXY:-}"
WALLET="${WALLET:-}"
WORKER_NAME="${WORKER_NAME:-}"
THREADS="${THREADS:-}"

usage() {
    cat <<USAGE
XMR Worker One-Line Installer

Usage: sudo bash install-worker.sh [options]

Options:
  -p, --proxy IP:PORT   Central XMRig-Proxy to connect to (recommended).
                        Wallet lives on the proxy, so none is needed here.
  -w, --wallet ADDR     Mine directly to this Monero wallet (no proxy).
  -n, --worker NAME     Worker / rig name (default: vps-<hostname>).
  -t, --threads N|max   Force mining thread count ('max' = all logical CPUs).
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
        -t|--threads) THREADS="$2"; shift 2;;
        --dir)        INSTALL_DIR="$2"; shift 2;;
        --repo)       REPO="$2"; shift 2;;
        --branch)     BRANCH="$2"; shift 2;;
        --optimize-sha256) OPTIMIZE_SHA256="$2"; shift 2;;
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
    # The repo stores the tarball via Git LFS, so raw.githubusercontent.com only
    # serves a pointer file. Pull the binary from the official xmrig release
    # (primary), then fall back to GitHub's LFS media endpoint for the repo.
    OFFICIAL_URL="https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VERSION}/${XMRIG_TARBALL}"
    LFS_MEDIA_URL="https://media.githubusercontent.com/media/${REPO}/${BRANCH}/xmr-mining/xmrig/${XMRIG_TARBALL}"
    log_info "Fetching ${XMRIG_TARBALL} from official release..."
    if ! fetch "$OFFICIAL_URL" "${TMP_TARBALL}"; then
        log_warn "Official release download failed; trying repo LFS media URL..."
        fetch "$LFS_MEDIA_URL" "${TMP_TARBALL}"
    fi
    # Reject an LFS pointer or any non-gzip payload before extracting.
    if ! tar tzf "${TMP_TARBALL}" >/dev/null 2>&1; then
        log_warn "Downloaded file is not a valid gzip archive; retrying via repo LFS media URL..."
        fetch "$LFS_MEDIA_URL" "${TMP_TARBALL}"
    fi
    if [ -n "$XMRIG_SHA256" ] && command -v sha256sum >/dev/null 2>&1; then
        DL_SHA=$(sha256sum "${TMP_TARBALL}" | awk '{print $1}')
        if [ "$DL_SHA" != "$XMRIG_SHA256" ]; then
            log_err "xmrig checksum mismatch (expected ${XMRIG_SHA256}, got ${DL_SHA}). Aborting."
            exit 1
        fi
        log_info "xmrig checksum verified"
    fi
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

# Optional integrity check of the remotely fetched script. Pass
# --optimize-sha256 <hash> (or set OPTIMIZE_SHA256) to enforce it.
if [ -n "${OPTIMIZE_SHA256:-}" ]; then
    ACTUAL_SHA=$(sha256sum "${INSTALL_DIR}/scripts/auto-optimize.sh" | awk '{print $1}')
    if [ "$ACTUAL_SHA" != "$OPTIMIZE_SHA256" ]; then
        log_err "Checksum mismatch for auto-optimize.sh!"
        log_err "  expected: ${OPTIMIZE_SHA256}"
        log_err "  actual:   ${ACTUAL_SHA}"
        log_err "Aborting to avoid running an unexpected script."
        exit 1
    fi
    log_info "auto-optimize.sh checksum verified"
else
    log_warn "No --optimize-sha256 given; skipping integrity check of the fetched script."
    log_warn "Pin a checksum with --optimize-sha256 <hash> for a trusted install."
fi
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
if [ -n "$THREADS" ]; then
    OPT_ARGS+=(--threads "$THREADS")
fi

bash "${INSTALL_DIR}/scripts/auto-optimize.sh" "${OPT_ARGS[@]}"

# ─── 4. Start the miner ───────────────────────────────────────────
# Use systemd only when it is actually the init system. Containers/LXC/WSL often
# have systemctl present but no running systemd (/run/systemd/system absent),
# where `systemctl enable` fails with "Failed to connect to bus".
log_title "Starting Miner Service"

# Stop any miner already running so we don't end up with multiple xmrig
# instances connecting as the same worker (doubles the proxy's hash counter).
# Stop a previous watchdog FIRST, otherwise it would just relaunch the old miner.
pkill -f "${INSTALL_DIR}/watchdog.sh" 2>/dev/null || true
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl stop xmrig 2>/dev/null || true
fi
if pgrep -f "${INSTALL_DIR}/xmrig/xmrig" >/dev/null 2>&1; then
    log_warn "Stopping previously running xmrig instance(s) to avoid duplicates."
    pkill -f "${INSTALL_DIR}/xmrig/xmrig" 2>/dev/null || true
    sleep 2
fi

if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 \
        && [ -f /etc/systemd/system/xmrig.service ]; then
    systemctl daemon-reload
    systemctl enable --now xmrig
    sleep 2
    systemctl --no-pager --full status xmrig | head -12 || true
    log_info "Miner service started. Speed log: tail -f ${INSTALL_DIR}/xmrig/xmrig.log (or journalctl -u xmrig -f)"
else
    log_warn "systemd not available (container/WSL?); starting xmrig in background instead."
    XMRIG_BIN="${INSTALL_DIR}/xmrig/xmrig"
    XMRIG_CFG="${INSTALL_DIR}/xmrig/config.json"
    nohup "$XMRIG_BIN" --config="$XMRIG_CFG" >"${INSTALL_DIR}/xmrig/xmrig.out" 2>&1 &
    MINER_PID=$!
    # Shield the miner from the kernel OOM killer (best-effort; needs root).
    echo -1000 > "/proc/${MINER_PID}/oom_score_adj" 2>/dev/null || true
    log_info "Started in background (PID ${MINER_PID}). Speed log: tail -f ${INSTALL_DIR}/xmrig/xmrig.log"

    # Watchdog: relaunch xmrig within ~30s if it ever exits or gets killed, so a
    # transient kill / crash doesn't stop mining (no systemd to do this for us).
    cat > "${INSTALL_DIR}/watchdog.sh" <<WATCHDOG
#!/bin/bash
BIN="${XMRIG_BIN}"; CFG="${XMRIG_CFG}"; OUT="${INSTALL_DIR}/xmrig/xmrig.out"
while true; do
    if ! pgrep -f "\$BIN" >/dev/null 2>&1; then
        nohup "\$BIN" --config="\$CFG" >"\$OUT" 2>&1 &
        echo -1000 > "/proc/\$!/oom_score_adj" 2>/dev/null || true
    fi
    sleep 30
done
WATCHDOG
    chmod +x "${INSTALL_DIR}/watchdog.sh"
    nohup "${INSTALL_DIR}/watchdog.sh" >/dev/null 2>&1 &
    echo -1000 > "/proc/$!/oom_score_adj" 2>/dev/null || true
    log_info "Watchdog running — auto-restarts xmrig if it stops."
    log_warn "After a FULL reboot there's no systemd to auto-start; re-run this install command."
    log_info "Stop mining completely: pkill -f ${INSTALL_DIR}/watchdog.sh && pkill -f ${XMRIG_BIN}"
fi

log_title "Done"
log_info "Worker installed at ${INSTALL_DIR}"
if [ -n "$PROXY" ]; then
    log_info "Connected to proxy ${PROXY}. Check it on the dashboard."
fi
