#!/bin/bash
#
# XMRig Auto-Optimization Script for Small Servers
# Targets: 2-4 vCPU, 2-8GB RAM (VPS / Cloud Servers)
# Detects CPU features (AVX/AVX2/AES-NI/SSE), cache sizes, Intel/AMD,
# and generates an optimized xmrig config.json
#

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

XMRIG_DIR="$(cd "$(dirname "$0")/../xmrig" && pwd)"
CONFIG_FILE="${XMRIG_DIR}/config.json"

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_err()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_title() { echo -e "\n${CYAN}=== $1 ===${NC}"; }

# ─── 0. Parse Arguments ───────────────────────────────────────────

WALLET="${WALLET:-}"
PROXY="${PROXY:-}"
WORKER_NAME="${WORKER_NAME:-}"
API_BIND="${API_BIND:-127.0.0.1}"
API_TOKEN="${API_TOKEN:-}"
THREADS="${THREADS:-}"   # empty = auto-detect; a number or 'max' overrides

usage() {
    cat <<USAGE
Usage: sudo bash auto-optimize.sh [options]

Options:
  -w, --wallet ADDR     Monero wallet address (or set WALLET env var).
                        Required unless --proxy is used.
  -p, --proxy IP:PORT   Mine through an XMRig-Proxy central node instead of
                        public pools. The wallet lives on the proxy, so no
                        wallet is needed in this mode.
  -n, --worker NAME     Worker / rig name (default: vps-<hostname>).
  -t, --threads N|max   Force the mining thread count instead of auto-detecting.
                        'max' uses every logical CPU. RandomX is cache-bound, so
                        more threads is not always faster — benchmark with
                        'curl -s http://127.0.0.1:4040/2/summary'.
      --api-bind ADDR   Address the local HTTP API binds to
                        (default: 127.0.0.1; use 0.0.0.0 to expose it).
      --api-token TOK   Bearer token protecting the HTTP API
                        (default: none; strongly recommended with 0.0.0.0).
  -h, --help            Show this help.

Examples:
  sudo bash auto-optimize.sh --wallet 4AbC...xyz
  sudo WALLET=4AbC...xyz bash auto-optimize.sh
  sudo bash auto-optimize.sh --proxy 10.0.0.5:3333 --worker vps-tokyo
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        -w|--wallet)  WALLET="$2"; shift 2;;
        -p|--proxy)   PROXY="$2"; shift 2;;
        -n|--worker)  WORKER_NAME="$2"; shift 2;;
        -t|--threads) THREADS="$2"; shift 2;;
        --api-bind)   API_BIND="$2"; shift 2;;
        --api-token)  API_TOKEN="$2"; shift 2;;
        -h|--help)    usage; exit 0;;
        *) log_err "Unknown option: $1"; usage; exit 1;;
    esac
done

# Validate a Monero address: standard ('4') or subaddress ('8'), 95 base58
# chars. Strips any pool worker suffix (".name" or "+diff") before checking.
# Uses the Monero base58 alphabet (excludes 0, O, I, l).
validate_wallet() {
    local addr="${1%%[.+]*}"
    echo "$addr" | grep -Eq '^[48][1-9A-HJ-NP-Za-km-z]{94}$'
}

# Reject values that could break out of the generated JSON string. Names and
# tokens are restricted to a safe charset; the proxy must look like host:port.
if [ -n "$WORKER_NAME" ] && ! echo "$WORKER_NAME" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    log_err "Invalid --worker name: ${WORKER_NAME} (use letters, digits, . _ - only)."
    exit 1
fi
if [ -n "$API_TOKEN" ] && ! echo "$API_TOKEN" | grep -Eq '^[A-Za-z0-9._-]+$'; then
    log_err "Invalid --api-token (use letters, digits, . _ - only)."
    exit 1
fi
if [ -n "$API_BIND" ] && ! echo "$API_BIND" | grep -Eq '^[A-Za-z0-9.:_-]+$'; then
    log_err "Invalid --api-bind: ${API_BIND} (expected an IP or hostname)."
    exit 1
fi
if [ -n "$THREADS" ] && [ "$THREADS" != "max" ] && ! echo "$THREADS" | grep -Eq '^[0-9]{1,3}$'; then
    log_err "Invalid --threads: ${THREADS} (expected a number or 'max')."
    exit 1
fi

if [ -n "$PROXY" ]; then
    if ! echo "$PROXY" | grep -Eq '^[A-Za-z0-9.:_-]+:[0-9]{1,5}$'; then
        log_err "Invalid --proxy: ${PROXY} (expected host:port, e.g. 10.0.0.5:3333)."
        exit 1
    fi
    if [ -n "$WALLET" ]; then
        log_warn "Both proxy and wallet are set; using proxy mode and ignoring the wallet."
    fi
    log_info "Proxy mode: worker will connect to ${PROXY} (wallet held by proxy)"
else
    if [ -z "$WALLET" ]; then
        log_err "No wallet address provided."
        log_err "Pass --wallet ADDR (or WALLET=... env var), or use --proxy IP:PORT."
        echo ""
        usage
        exit 1
    fi
    if ! validate_wallet "$WALLET"; then
        log_err "Invalid Monero wallet address: ${WALLET}"
        log_err "Expected 95 base58 chars starting with 4 (standard) or 8 (subaddress)."
        exit 1
    fi
    log_info "Wallet address validated"
fi

# ─── 1. Detect CPU Info ───────────────────────────────────────────

log_title "CPU Detection"

CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)
CPU_CORES=$(nproc)
CPU_THREADS=$(grep -c ^processor /proc/cpuinfo)
CPU_VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | cut -d: -f2 | xargs)

# Cache detection. The old `lscpu | grep L3 | awk '{print $NF}'` breaks on the
# summary format ("L3 cache: 320 MiB (1 instance)" => grabs "instance)"), so read
# sysfs first and fall back to lscpu's caches table.
sysfs_cache() {  # level [type]
    local lvl="$1" typ="$2" d
    for d in /sys/devices/system/cpu/cpu0/cache/index*; do
        [ -r "$d/level" ] || continue
        [ "$(cat "$d/level" 2>/dev/null)" = "$lvl" ] || continue
        if [ -z "$typ" ] || [ "$(cat "$d/type" 2>/dev/null)" = "$typ" ]; then
            cat "$d/size" 2>/dev/null && return 0
        fi
    done
    return 1
}
lscpu_cache() {  # level (e.g. L3)
    lscpu -C=NAME,ALL-SIZE 2>/dev/null | awk -v n="$1" '$1==n {print $2; exit}'
}
L1_CACHE=$(sysfs_cache 1 Data || lscpu_cache L1d)
L2_CACHE=$(sysfs_cache 2 || lscpu_cache L2)
L3_CACHE=$(sysfs_cache 3 || lscpu_cache L3)

# CPU flags
CPU_FLAGS=$(grep -m1 'flags' /proc/cpuinfo | cut -d: -f2)
HAS_AES=$(echo "$CPU_FLAGS" | grep -qw 'aes' && echo "true" || echo "false")
HAS_AVX=$(echo "$CPU_FLAGS" | grep -qw 'avx' && echo "true" || echo "false")
HAS_AVX2=$(echo "$CPU_FLAGS" | grep -qw 'avx2' && echo "true" || echo "false")
HAS_AVX512=$(echo "$CPU_FLAGS" | grep -qw 'avx512f' && echo "true" || echo "false")
HAS_SSE41=$(echo "$CPU_FLAGS" | grep -qw 'sse4_1' && echo "true" || echo "false")
HAS_PDPE1GB=$(echo "$CPU_FLAGS" | grep -qw 'pdpe1gb' && echo "true" || echo "false")

# Memory
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_MEM_MB=$((TOTAL_MEM_KB / 1024))
TOTAL_MEM_GB=$((TOTAL_MEM_MB / 1024))

log_info "CPU Model:    ${CPU_MODEL}"
log_info "Vendor:       ${CPU_VENDOR}"
log_info "Cores/Threads:${CPU_CORES} / ${CPU_THREADS}"
log_info "L1d Cache:    ${L1_CACHE:-N/A}"
log_info "L2 Cache:     ${L2_CACHE:-N/A}"
log_info "L3 Cache:     ${L3_CACHE:-N/A}"
log_info "AES-NI:       ${HAS_AES}"
log_info "AVX:          ${HAS_AVX}"
log_info "AVX2:         ${HAS_AVX2}"
log_info "AVX-512:      ${HAS_AVX512}"
log_info "SSE4.1:       ${HAS_SSE41}"
log_info "Memory:       ${TOTAL_MEM_MB} MB (${TOTAL_MEM_GB} GB)"

# ─── 2. Calculate Optimal Mining Threads ──────────────────────────

log_title "Thread Optimization"

# RandomX requires 2MB L3 cache per thread
# Parse L3 cache size to MB
parse_cache_mb() {
    local val="$1" num
    num=$(echo "$val" | grep -oE '[0-9.]+' | head -1 | cut -d. -f1)
    [ -z "$num" ] && return
    case "$val" in
        *G*|*g*) echo $((num * 1024));;   # GiB / GB / G
        *K*|*k*) echo $((num / 1024));;   # KiB / KB / K
        *)       echo "$num";;            # MiB / MB / M / bare number => MB
    esac
}

# Prefer getconf (portable, returns bytes; 0/empty when unknown), then the
# size string parsed from sysfs/lscpu above, then a conservative default.
L3_BYTES=$(getconf LEVEL3_CACHE_SIZE 2>/dev/null || true)
if [ -n "$L3_BYTES" ] && [ "$L3_BYTES" -gt 0 ] 2>/dev/null; then
    L3_MB=$((L3_BYTES / 1048576))
else
    L3_MB=$(parse_cache_mb "${L3_CACHE}")
fi
if [ -z "$L3_MB" ] || [ "$L3_MB" -eq 0 ] 2>/dev/null; then
    L3_MB=4
    log_warn "Could not detect L3 cache, assuming ${L3_MB} MB"
fi

# RandomX needs 2MB per thread
MAX_THREADS_BY_CACHE=$((L3_MB / 2))

# Reserve at least 512MB for OS, rest for mining (each thread uses ~2.5MB for dataset pages)
AVAILABLE_MEM_MB=$((TOTAL_MEM_MB - 512))
MAX_THREADS_BY_MEM=$((AVAILABLE_MEM_MB / 3))

# Don't exceed CPU thread count
OPTIMAL_THREADS=$CPU_THREADS
if [ "$MAX_THREADS_BY_CACHE" -lt "$OPTIMAL_THREADS" ]; then
    OPTIMAL_THREADS=$MAX_THREADS_BY_CACHE
fi
if [ "$MAX_THREADS_BY_MEM" -lt "$OPTIMAL_THREADS" ]; then
    OPTIMAL_THREADS=$MAX_THREADS_BY_MEM
fi
# At least 1 thread
if [ "$OPTIMAL_THREADS" -lt 1 ]; then
    OPTIMAL_THREADS=1
fi

# Default to ALL logical CPUs (only the cache/memory budgets above can lower it).
# Use --threads N to reserve cores for other workloads if you need to.

log_info "L3 Cache:          ${L3_MB} MB"
log_info "Max by cache (2MB/thread): ${MAX_THREADS_BY_CACHE}"
log_info "Max by memory:     ${MAX_THREADS_BY_MEM}"
log_info "Optimal threads:   ${OPTIMAL_THREADS}"

# ─── 3. CPU Governor & Performance Tuning ─────────────────────────

log_title "CPU Performance Tuning"

if [ "$(id -u)" -eq 0 ]; then
    # Set CPU governor to performance
    if command -v cpufreq-set >/dev/null 2>&1; then
        for i in $(seq 0 $((CPU_THREADS - 1))); do
            cpufreq-set -c $i -g performance 2>/dev/null || true
        done
        log_info "CPU governor set to 'performance'"
    elif [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            echo performance > "$gov" 2>/dev/null || true
        done
        log_info "CPU governor set to 'performance'"
    else
        log_warn "Cannot set CPU governor (no cpufreq support, common on VPS)"
    fi

    # Disable transparent huge pages (can cause latency spikes)
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
        log_info "Transparent Huge Pages disabled (reduces latency)"
    fi

    # Increase vm.max_map_count for RandomX
    sysctl -w vm.max_map_count=262144 >/dev/null 2>&1 || true
else
    log_warn "Run as root for CPU governor and THP tuning"
fi

# ─── 4. Determine RandomX Mode ───────────────────────────────────

log_title "RandomX Mode Selection"

# fast mode needs ~2GB, light mode needs ~256MB
if [ "$TOTAL_MEM_MB" -ge 2560 ]; then
    RX_MODE="fast"
    log_info "Mode: FAST (full 2GB dataset in memory - best hashrate)"
else
    RX_MODE="light"
    log_info "Mode: LIGHT (256MB - lower hashrate but fits in low memory)"
fi

# ─── 5. Intel vs AMD Specific Tuning ──────────────────────────────

log_title "Vendor-Specific Optimization"

INTEL_SPECIFIC=""
if echo "$CPU_VENDOR" | grep -qi "Intel"; then
    log_info "Intel CPU detected - applying Intel optimizations"

    # Intel CPUs benefit from specific affinity and NUMA settings
    if [ "$HAS_AVX2" = "true" ]; then
        log_info "  AVX2 enabled - XMRig will auto-use optimized code paths"
    fi
    if [ "$HAS_AVX512" = "true" ]; then
        log_info "  AVX-512 detected - best RandomX performance tier"
    fi
    # Note: on Hyper-Threading CPUs RandomX may not scale much past the physical
    # core count, but we still default to all logical threads; use --threads to
    # tune down if a lower count benchmarks better.
    if [ "$CPU_THREADS" -gt "$CPU_CORES" ]; then
        log_info "  Hyper-Threading detected: using all ${CPU_THREADS} logical threads (use --threads to tune)"
    fi
elif echo "$CPU_VENDOR" | grep -qi "AMD"; then
    log_info "AMD CPU detected - applying AMD optimizations"
    if [ "$HAS_AVX2" = "true" ]; then
        log_info "  AVX2 enabled - good RandomX performance"
    fi
    # AMD Zen CPUs: each CCX has its own L3, keep threads within same CCX
    log_info "  Tip: AMD Zen CPUs work best with threads pinned to same CCX"
else
    log_info "Unknown CPU vendor: ${CPU_VENDOR}"
fi

# A user-supplied --threads value overrides the auto-detected count (and the
# RandomX cache/HT heuristics). 'max' means every logical CPU. Clamp to 1..CPU.
if [ -n "$THREADS" ]; then
    if [ "$THREADS" = "max" ]; then
        OPTIMAL_THREADS=$CPU_THREADS
    else
        OPTIMAL_THREADS=$THREADS
        [ "$OPTIMAL_THREADS" -gt "$CPU_THREADS" ] && OPTIMAL_THREADS=$CPU_THREADS
        [ "$OPTIMAL_THREADS" -lt 1 ] && OPTIMAL_THREADS=1
    fi
    log_warn "Thread override: using ${OPTIMAL_THREADS} thread(s) (--threads ${THREADS}); RandomX may not scale past physical cores."
fi

# ─── 6. Enable Huge Pages ────────────────────────────────────────
# Done after the thread count is final (auto + HT + --threads override) so the
# persisted vm.nr_hugepages matches the threads we actually run, not a stale
# pre-override value.

log_title "Huge Pages Setup"

# RandomX benefits greatly from 2MB huge pages
HUGEPAGES_NEEDED=$((OPTIMAL_THREADS + 8))  # threads + dataset pages overhead

if [ "$(id -u)" -eq 0 ]; then
    # Enable huge pages
    sysctl -w vm.nr_hugepages=${HUGEPAGES_NEEDED} >/dev/null 2>&1 || true
    CURRENT_HP=$(cat /proc/sys/vm/nr_hugepages)
    log_info "Huge pages set to: ${CURRENT_HP}"

    # Make persistent
    if ! grep -q 'vm.nr_hugepages' /etc/sysctl.conf 2>/dev/null; then
        echo "vm.nr_hugepages=${HUGEPAGES_NEEDED}" >> /etc/sysctl.conf
        log_info "Added vm.nr_hugepages=${HUGEPAGES_NEEDED} to /etc/sysctl.conf"
    else
        sed -i "s/vm.nr_hugepages=.*/vm.nr_hugepages=${HUGEPAGES_NEEDED}/" /etc/sysctl.conf
        log_info "Updated vm.nr_hugepages in /etc/sysctl.conf"
    fi

    # 1GB huge pages for supported CPUs
    if [ "$HAS_PDPE1GB" = "true" ] && [ "$TOTAL_MEM_GB" -ge 4 ]; then
        log_info "CPU supports 1GB huge pages (pdpe1gb flag detected)"
        log_info "For best performance, add 'hugepagesz=1G hugepages=3' to kernel boot params"
    fi
else
    log_warn "Not running as root. Run with sudo for huge pages setup:"
    log_warn "  sudo sysctl -w vm.nr_hugepages=${HUGEPAGES_NEEDED}"
fi

# ─── 7. Generate Optimized config.json ────────────────────────────

log_title "Generating Optimized Config"

# Build CPU thread list with affinity
THREAD_LIST=""
for i in $(seq 0 $((OPTIMAL_THREADS - 1))); do
    if [ $i -gt 0 ]; then
        THREAD_LIST="${THREAD_LIST}, "
    fi
    THREAD_LIST="${THREAD_LIST}${i}"
done

# Determine priority: small VPS use lower priority to avoid system lag
if [ "$CPU_THREADS" -le 2 ]; then
    PRIORITY=1
elif [ "$CPU_THREADS" -le 4 ]; then
    PRIORITY=2
else
    PRIORITY=3
fi

# MSR access for RandomX boost (Intel/AMD)
MSR_ENABLED="true"
if [ ! -e /dev/cpu/0/msr ] && [ "$(id -u)" -eq 0 ]; then
    modprobe msr 2>/dev/null || MSR_ENABLED="false"
fi

# Rig / worker name and pool list (direct pools or proxy)
RIG_ID="${WORKER_NAME:-vps-$(hostname | tr '[:upper:]' '[:lower:]')}"

if [ -n "$PROXY" ]; then
    POOLS_JSON=$(cat <<POOLS
        {
            "url": "${PROXY}",
            "user": "${RIG_ID}",
            "pass": "x",
            "rig-id": "${RIG_ID}",
            "keepalive": true,
            "tls": false
        }
POOLS
)
else
    POOLS_JSON=$(cat <<POOLS
        {
            "url": "pool.supportxmr.com:443",
            "user": "${WALLET}",
            "pass": "${RIG_ID}",
            "rig-id": "${RIG_ID}",
            "keepalive": true,
            "tls": true,
            "sni": true
        },
        {
            "url": "gulf.moneroocean.stream:443",
            "user": "${WALLET}",
            "pass": "${RIG_ID}",
            "rig-id": "${RIG_ID}",
            "keepalive": true,
            "tls": true,
            "algo": null
        }
POOLS
)
fi

# HTTP API access token (null = no token)
if [ -n "$API_TOKEN" ]; then
    API_TOKEN_JSON="\"${API_TOKEN}\""
else
    API_TOKEN_JSON="null"
fi

if [ "$API_BIND" = "0.0.0.0" ] && [ -z "$API_TOKEN" ]; then
    log_warn "HTTP API bound to 0.0.0.0 with no token — anyone can read it."
    log_warn "Pass --api-token TOKEN to protect it, or keep the default 127.0.0.1 bind."
fi

cat > "${CONFIG_FILE}" << XMRIG_CONFIG
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "huge-pages-jit": true,
        "hw-aes": ${HAS_AES},
        "priority": ${PRIORITY},
        "memory-pool": true,
        "yield": true,
        "max-threads-hint": 100,
        "asm": true,
        "argon2-impl": null,
        "rx": [${THREAD_LIST}],
        "rx/wow": [${THREAD_LIST}]
    },
    "randomx": {
        "init": -1,
        "init-avx2": -1,
        "mode": "${RX_MODE}",
        "1gb-pages": ${HAS_PDPE1GB},
        "rdmsr": ${MSR_ENABLED},
        "wrmsr": ${MSR_ENABLED},
        "cache_qos": false,
        "numa": true,
        "scratchpad_prefetch_mode": 1
    },
    "pools": [
${POOLS_JSON}
    ],
    "donate-level": 1,
    "donate-over-proxy": 1,
    "log-file": "${XMRIG_DIR}/xmrig.log",
    "print-time": 60,
    "retries": 5,
    "retry-pause": 5,
    "syslog": false,
    "http": {
        "enabled": true,
        "host": "${API_BIND}",
        "port": 4040,
        "access-token": ${API_TOKEN_JSON},
        "restricted": true
    }
}
XMRIG_CONFIG

log_info "Config written to: ${CONFIG_FILE}"

# ─── 8. Generate systemd Service ──────────────────────────────────

log_title "Systemd Service"

# Write to a private temp file (avoids a predictable /tmp path that another
# user could pre-create or symlink).
SERVICE_FILE="$(mktemp "${TMPDIR:-/tmp}/xmrig.service.XXXXXX")"
cat > "${SERVICE_FILE}" << SYSTEMD_SERVICE
[Unit]
Description=XMRig Monero Miner
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'sysctl -w vm.nr_hugepages=${HUGEPAGES_NEEDED} || true'
ExecStart=${XMRIG_DIR}/xmrig --config=${CONFIG_FILE}
Restart=always
RestartSec=15
Nice=-10
CPUWeight=90
LimitMEMLOCK=infinity
# Tell the kernel OOM killer to avoid this service when memory runs low.
OOMScoreAdjust=-1000

[Install]
WantedBy=multi-user.target
SYSTEMD_SERVICE

if [ "$(id -u)" -eq 0 ]; then
    cp "${SERVICE_FILE}" /etc/systemd/system/xmrig.service
    rm -f "${SERVICE_FILE}"
    log_info "Systemd service installed: /etc/systemd/system/xmrig.service"
    log_info "Enable with: systemctl enable --now xmrig"
else
    log_info "Systemd service file generated at: ${SERVICE_FILE}"
    log_warn "Run as root to install: sudo cp ${SERVICE_FILE} /etc/systemd/system/"
fi

# ─── 9. Summary ──────────────────────────────────────────────────

log_title "Optimization Summary"

echo ""
echo "  CPU:              ${CPU_MODEL}"
echo "  Vendor:           ${CPU_VENDOR}"
echo "  Mining Threads:   ${OPTIMAL_THREADS} / ${CPU_THREADS} available"
echo "  RandomX Mode:     ${RX_MODE}"
echo "  Huge Pages:       ${HUGEPAGES_NEEDED} (2MB pages)"
echo "  1GB Pages:        ${HAS_PDPE1GB}"
echo "  AES-NI:           ${HAS_AES}"
echo "  AVX/AVX2/AVX512:  ${HAS_AVX} / ${HAS_AVX2} / ${HAS_AVX512}"
echo "  Memory:           ${TOTAL_MEM_MB} MB"
echo "  Thread Priority:  ${PRIORITY}"
if [ -n "$PROXY" ]; then
echo "  Mining target:    proxy ${PROXY} (worker: ${RIG_ID})"
else
echo "  Mining target:    public pools (wallet: ${WALLET})"
fi
echo "  HTTP API bind:    ${API_BIND}:4040"
echo "  Config:           ${CONFIG_FILE}"
echo "  Log file:         ${XMRIG_DIR}/xmrig.log"
echo ""

# Estimated hashrate ranges
if [ "$HAS_AVX2" = "true" ] && [ "$RX_MODE" = "fast" ]; then
    HR_LOW=$((OPTIMAL_THREADS * 600))
    HR_HIGH=$((OPTIMAL_THREADS * 1200))
elif [ "$HAS_AES" = "true" ] && [ "$RX_MODE" = "fast" ]; then
    HR_LOW=$((OPTIMAL_THREADS * 400))
    HR_HIGH=$((OPTIMAL_THREADS * 800))
else
    HR_LOW=$((OPTIMAL_THREADS * 200))
    HR_HIGH=$((OPTIMAL_THREADS * 500))
fi

log_info "Estimated hashrate: ${HR_LOW} - ${HR_HIGH} H/s"
echo ""
log_info "Next steps:"
if [ ! -x "${XMRIG_DIR}/xmrig" ]; then
echo "  1. Extract xmrig binary:"
echo "     cd ${XMRIG_DIR} && tar xzf xmrig-*.tar.gz --strip-components=1"
echo "  2. Run: ${XMRIG_DIR}/xmrig"
echo "  3. Or install service: sudo systemctl enable --now xmrig"
else
echo "  1. Run: ${XMRIG_DIR}/xmrig"
echo "  2. Or install service: sudo systemctl enable --now xmrig"
fi
echo ""
log_info "Wallet/pool already written to config — no manual editing needed."
echo ""
