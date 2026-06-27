#!/bin/bash
#
# XMRig Proxy Quick Setup Script
# Sets up a central proxy node that all miner workers connect to
# Provides HTTP API to monitor each worker's hashrate and online status
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_title() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

PROXY_DIR="$(cd "$(dirname "$0")/../xmrig-proxy" && pwd)"
PROXY_CONFIG="${PROXY_DIR}/config.json"

log_title "XMRig Proxy Setup"

# ─── 1. Extract binary ───────────────────────────────────────────

TARBALL=$(ls "${PROXY_DIR}"/xmrig-proxy-*.tar.gz 2>/dev/null | head -1)
if [ -n "$TARBALL" ] && [ ! -f "${PROXY_DIR}/xmrig-proxy" ]; then
    log_info "Extracting proxy binary..."
    tar xzf "$TARBALL" -C "${PROXY_DIR}" --strip-components=1
fi

# ─── 2. Generate proxy config ────────────────────────────────────

log_title "Generating Proxy Config"

WORKER_PORT=3333
API_PORT=4048
ACCESS_TOKEN="xmr-proxy-$(head -c 8 /dev/urandom | xxd -p)"

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
            "user": "YOUR_XMR_WALLET_ADDRESS",
            "pass": "proxy1",
            "rig-id": "proxy-main",
            "keepalive": true,
            "tls": true
        },
        {
            "url": "gulf.moneroocean.stream:443",
            "user": "YOUR_XMR_WALLET_ADDRESS",
            "pass": "proxy1",
            "rig-id": "proxy-main",
            "keepalive": true,
            "tls": true,
            "algo": null
        }
    ],
    "http": {
        "enabled": true,
        "host": "0.0.0.0",
        "port": ${API_PORT},
        "access-token": "${ACCESS_TOKEN}",
        "restricted": false
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
log_info "  API access token:                  ${ACCESS_TOKEN}"

# ─── 3. API Usage Guide ──────────────────────────────────────────

log_title "Monitoring API Usage"

echo ""
echo "  View all workers (hashrate + online status):"
echo "    curl -H 'Authorization: Bearer ${ACCESS_TOKEN}' http://localhost:${API_PORT}/2/workers"
echo ""
echo "  View summary:"
echo "    curl -H 'Authorization: Bearer ${ACCESS_TOKEN}' http://localhost:${API_PORT}/2/summary"
echo ""
echo "  View specific worker backends:"
echo "    curl -H 'Authorization: Bearer ${ACCESS_TOKEN}' http://localhost:${API_PORT}/2/backends"
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
echo "  1. Edit ${PROXY_CONFIG}"
echo "     Replace YOUR_XMR_WALLET_ADDRESS with your Monero wallet"
echo "  2. Run: ${PROXY_DIR}/xmrig-proxy --config=${PROXY_CONFIG}"
echo "  3. Connect workers to PROXY_IP:${WORKER_PORT}"
echo "  4. Monitor at: http://PROXY_IP:${API_PORT}"
echo "  5. Open the Workers Dashboard in browser for visual monitoring"
echo ""
