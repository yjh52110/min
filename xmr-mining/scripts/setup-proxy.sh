#!/bin/bash
#
# XMRig Proxy Quick Setup Script
# Sets up a central proxy node that all miner workers connect to
# Provides HTTP API to monitor each worker's hashrate and online status
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_title() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

PROXY_DIR="$(cd "$(dirname "$0")/../xmrig-proxy" && pwd)"
PROXY_CONFIG="${PROXY_DIR}/config.json"

# ─── 0. Parse Arguments ───────────────────────────────────────────

WALLET="${WALLET:-}"
WORKER_PORT="${WORKER_PORT:-3333}"
API_PORT="${API_PORT:-4048}"
API_BIND="${API_BIND:-0.0.0.0}"
API_TOKEN="${API_TOKEN:-}"
API_RESTRICTED="${API_RESTRICTED:-true}"

usage() {
    cat <<USAGE
Usage: bash setup-proxy.sh [options]

Options:
  -w, --wallet ADDR    Monero wallet address (or set WALLET env var). Required.
                       All workers' hashrate is credited to this address.
      --port PORT      Port workers connect to (default: 3333).
      --api-port PORT  HTTP monitoring API port (default: 4048).
      --api-bind ADDR  Address the API binds to (default: 0.0.0.0).
                       Use 127.0.0.1 if you reverse-proxy it via nginx.
      --api-token TOK  API bearer token (default: auto-generated).
      --api-writable   Allow config changes via the API (default: read-only).
  -h, --help           Show this help.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -w|--wallet)   WALLET="$2"; shift 2;;
        --port)        WORKER_PORT="$2"; shift 2;;
        --api-port)    API_PORT="$2"; shift 2;;
        --api-bind)    API_BIND="$2"; shift 2;;
        --api-token)   API_TOKEN="$2"; shift 2;;
        --api-writable) API_RESTRICTED="false"; shift;;
        -h|--help)     usage; exit 0;;
        *) log_err "Unknown option: $1"; usage; exit 1;;
    esac
done

# Monero base58 alphabet excludes 0, O, I, l.
validate_wallet() {
    local addr="${1%%[.+]*}"
    echo "$addr" | grep -Eq '^[48][1-9A-HJ-NP-Za-km-z]{94}$'
}

log_title "XMRig Proxy Setup"

if [ -z "$WALLET" ]; then
    log_err "No wallet address provided — pass --wallet ADDR or set WALLET env var."
    log_err "All worker hashrate is credited to the proxy's wallet."
    exit 1
fi
if ! validate_wallet "$WALLET"; then
    log_err "Invalid Monero wallet address: ${WALLET}"
    log_err "Expected 95 base58 chars starting with 4 (standard) or 8 (subaddress)."
    exit 1
fi
if [ -n "$API_TOKEN" ] && ! echo "$API_TOKEN" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    log_err "Invalid --api-token (use letters, digits, . _ - only)."
    exit 1
fi
if ! echo "$API_BIND" | grep -Eq '^[A-Za-z0-9.:_-]+$'; then
    log_err "Invalid --api-bind: ${API_BIND} (expected an IP or hostname)."
    exit 1
fi
# Ports are interpolated unquoted into JSON number fields, so they must be numeric.
for _p in "$WORKER_PORT" "$API_PORT"; do
    if ! echo "$_p" | grep -Eq '^[0-9]{1,5}$' || [ "$_p" -lt 1 ] || [ "$_p" -gt 65535 ]; then
        log_err "Invalid port: ${_p} (expected 1-65535)."
        exit 1
    fi
done
log_info "Wallet address validated"

# ─── 1. Extract binary ───────────────────────────────────────────

TARBALL=$(ls "${PROXY_DIR}"/xmrig-proxy-*.tar.gz 2>/dev/null | head -1)
if [ -n "$TARBALL" ] && [ ! -f "${PROXY_DIR}/xmrig-proxy" ]; then
    log_info "Extracting proxy binary..."
    tar xzf "$TARBALL" -C "${PROXY_DIR}" --strip-components=1
fi

# ─── 2. Generate proxy config ────────────────────────────────────

log_title "Generating Proxy Config"

if [ -z "$API_TOKEN" ]; then
    ACCESS_TOKEN="xmr-proxy-$(head -c 8 /dev/urandom | xxd -p)"
else
    ACCESS_TOKEN="$API_TOKEN"
fi

# Persist the token to a root-readable file rather than echoing it to the
# terminal, so it is not captured in shell history or CI logs.
TOKEN_FILE="${PROXY_DIR}/api-token.txt"
( umask 077; printf '%s\n' "$ACCESS_TOKEN" > "$TOKEN_FILE" )
chmod 600 "$TOKEN_FILE" 2>/dev/null || true

cat > "${PROXY_CONFIG}" << PROXY_CFG
{
    "background": false,
    "colors": true,
    "log-file": "proxy.log",
    "access-log-file": "access.log",
    "retries": 5,
    "retry-pause": 5,
    "donate-level": 1,
    "bind": [
        {
            "host": "0.0.0.0",
            "port": ${WORKER_PORT},
            "tls": false
        }
    ],
    "pools": [
        {
            "url": "pool.supportxmr.com:443",
            "user": "${WALLET}",
            "pass": "proxy1",
            "rig-id": "proxy-main",
            "keepalive": true,
            "tls": true
        },
        {
            "url": "gulf.moneroocean.stream:443",
            "user": "${WALLET}",
            "pass": "proxy1",
            "rig-id": "proxy-main",
            "keepalive": true,
            "tls": true,
            "algo": null
        }
    ],
    "http": {
        "enabled": true,
        "host": "${API_BIND}",
        "port": ${API_PORT},
        "access-token": "${ACCESS_TOKEN}",
        "restricted": ${API_RESTRICTED}
    },
    "workers": true,
    "mode": "nicehash",
    "custom-diff": 0,
    "custom-diff-stats": 2500,
    "verbose": 1
}
PROXY_CFG

log_info "Proxy config: ${PROXY_CONFIG}"
log_info ""
log_info "Configuration:"
log_info "  Worker port (miners connect here): ${WORKER_PORT}"
log_info "  API port (monitoring):             ${API_PORT}"
log_info "  API access token saved to:         ${TOKEN_FILE} (chmod 600)"
log_info "  Read it with:                      cat ${TOKEN_FILE}"

# ─── 3. API Usage Guide ──────────────────────────────────────────

log_title "Monitoring API Usage"

echo ""
echo "  (token: cat ${TOKEN_FILE})"
echo ""
echo "  View all workers (hashrate + online status):"
echo "    curl -H \"Authorization: Bearer \$(cat ${TOKEN_FILE})\" http://localhost:${API_PORT}/1/workers"
echo ""
echo "  View summary:"
echo "    curl -H \"Authorization: Bearer \$(cat ${TOKEN_FILE})\" http://localhost:${API_PORT}/1/summary"
echo ""

# ─── 4. Worker connection guide ───────────────────────────────────

log_title "Worker Node Setup"

echo ""
echo "  On each worker/miner machine, point XMRig to this proxy:"
echo ""
echo "    ./xmrig -o PROXY_SERVER_IP:${WORKER_PORT} -u worker-name -p x --no-tls"
echo ""
echo "  Or in config.json on worker:"
echo '    "pools": [{'
echo "        \"url\": \"PROXY_SERVER_IP:${WORKER_PORT}\","
echo '        "user": "worker-name",'
echo '        "pass": "x",'
echo '        "tls": false'
echo '    }]'
echo ""

# ─── 5. Systemd service ──────────────────────────────────────────

SERVICE_FILE="/tmp/xmrig-proxy.service"
cat > "${SERVICE_FILE}" << SYSTEMD_SVC
[Unit]
Description=XMRig Proxy - Mining Proxy Node
After=network.target

[Service]
Type=simple
ExecStart=${PROXY_DIR}/xmrig-proxy --config=${PROXY_CONFIG}
Restart=always
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SYSTEMD_SVC

log_title "Systemd Service"
log_info "Service file: ${SERVICE_FILE}"
log_info "Install: sudo cp ${SERVICE_FILE} /etc/systemd/system/"
log_info "Start:   sudo systemctl enable --now xmrig-proxy"
echo ""

# ─── 6. Next steps ───────────────────────────────────────────────

log_title "Next Steps"
echo "  1. Run: ${PROXY_DIR}/xmrig-proxy --config=${PROXY_CONFIG}"
echo "  2. Connect workers to PROXY_IP:${WORKER_PORT}"
echo "  3. Monitor at: http://PROXY_IP:${API_PORT}"
echo "  4. Open the Workers Dashboard in browser for visual monitoring"
echo ""
log_info "Wallet/pool already written to config — no manual editing needed."
echo ""
