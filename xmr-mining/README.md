# XMR Monero Mining Toolkit

Linux XMR (Monero) mining full toolkit: miner + proxy + dashboard + auto-optimization.

## Contents

```
xmr-mining/
├── xmrig/                          # XMRig v6.26.0 miner (Linux static)
│   └── xmrig-6.26.0-linux-static-x64.tar.gz
├── xmrig-proxy/                    # XMRig Proxy v6.26.0 (central relay node)
│   └── xmrig-proxy-6.26.0-linux-static-x64.tar.gz
├── xmrig-workers/                  # Workers Dashboard (web UI monitor)
│   └── public/                     # Static files, serve with nginx
└── scripts/
    ├── auto-optimize.sh            # Auto CPU/memory optimization for VPS
    ├── setup-proxy.sh              # Quick proxy setup with monitoring API
    └── install-worker.sh          # One-line installer for sub-nodes
```

## One-Line Worker Install (Sub-Nodes)

On any fresh Linux sub-node, install + auto-tune + connect to the central
proxy + register a systemd service in a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/yjh52110/min/main/xmr-mining/scripts/install-worker.sh \
  | sudo bash -s -- --proxy PROXY_IP:3333 --worker vps-tokyo
```

No wallet is needed on workers in proxy mode — the wallet lives on the proxy
and all worker hashrate is credited to it. To mine directly to a wallet
instead (no proxy), pass `--wallet 4Abc...xyz`.

## Quick Start

### 1. Auto-Optimize & Mine (Worker Node)

```bash
cd xmrig
tar xzf xmrig-6.26.0-linux-static-x64.tar.gz --strip-components=1

# Auto-detect CPU features AND inject your wallet (validated) in one step
sudo bash ../scripts/auto-optimize.sh --wallet 4Abc...your_xmr_wallet...xyz

# Or connect this node to a central proxy instead (no wallet needed here):
# sudo bash ../scripts/auto-optimize.sh --proxy PROXY_IP:3333 --worker vps-tokyo

# Start mining (wallet/pool already written to config.json)
./xmrig
```

The HTTP API binds to `127.0.0.1` by default. Expose it with
`--api-bind 0.0.0.0 --api-token YOUR_TOKEN` only if you need remote monitoring.

### 2. Setup Proxy (Central Node)

```bash
cd xmrig-proxy
tar xzf xmrig-proxy-6.26.0-linux-static-x64.tar.gz --strip-components=1

# Generate proxy config with your wallet (validated, injected into all pools)
bash ../scripts/setup-proxy.sh --wallet 4Abc...your_xmr_wallet...xyz

# Start proxy (wallet already written to config.json)
./xmrig-proxy
```

The monitoring API is read-only by default (`restricted: true`) and uses an
auto-generated bearer token. Pass `--api-writable` to allow remote config
changes, or `--api-bind 127.0.0.1` to keep it local and reverse-proxy via nginx.

### 3. Connect Workers to Proxy

On each worker machine:
```bash
./xmrig -o PROXY_IP:3333 -u worker-name -p x --no-tls
```

### 4. Monitor Workers

**API:**
```bash
# View all workers hashrate & online status
curl -H 'Authorization: Bearer YOUR_TOKEN' http://PROXY_IP:4048/1/workers

# Summary
curl -H 'Authorization: Bearer YOUR_TOKEN' http://PROXY_IP:4048/1/summary
```

**Web Dashboard:**
Serve `xmrig-workers/public/` with nginx:
```bash
# Copy dashboard files
sudo cp -r xmrig-workers/public/* /var/www/html/workers/

# Or use simple HTTP server
cd xmrig-workers/public && python3 -m http.server 8080
```
Then open `http://PROXY_IP:8080` in browser.

## Auto-Optimization Details

`scripts/auto-optimize.sh` automatically detects and optimizes:

| Feature | Detection | Optimization |
|---------|-----------|-------------|
| CPU Vendor | Intel / AMD | Vendor-specific code paths |
| AES-NI | `/proc/cpuinfo` flags | Hardware AES for RandomX |
| AVX / AVX2 / AVX-512 | CPU flags | Vectorized RandomX execution |
| L3 Cache | `lscpu` | Threads = L3_MB / 2 (2MB per thread) |
| Huge Pages | Kernel support | 2MB huge pages for RandomX dataset |
| 1GB Pages | `pdpe1gb` flag | For CPUs with 1GB page support |
| Hyper-Threading | Core vs thread count | Intel: use physical cores only |
| Memory | `/proc/meminfo` | Fast mode (>=2.5GB) or Light mode |
| CPU Governor | sysfs/cpufreq | Set to 'performance' |
| THP | transparent_hugepage | Disabled (reduces latency) |

### Estimated Hashrate by Server Spec

| Server | CPU | RAM | Threads | Est. Hashrate |
|--------|-----|-----|---------|---------------|
| 2H 2GB | 2 vCPU | 2 GB | 2 | 400-1000 H/s |
| 2H 4GB | 2 vCPU | 4 GB | 2 | 600-1200 H/s |
| 4H 4GB | 4 vCPU | 4 GB | 3 | 1200-2400 H/s |
| 4H 8GB | 4 vCPU | 8 GB | 3 | 1500-3600 H/s |

*Actual hashrate depends on CPU model, AES-NI/AVX2 support, and whether fast mode is usable.*

## Architecture

```
                    ┌──────────────┐
                    │  Mining Pool │
                    │ (supportxmr) │
                    └──────┬───────┘
                           │
                    ┌──────┴───────┐
                    │  XMRig Proxy │  ← Central node
                    │  :3333 (in)  │  ← Workers connect here
                    │  :4048 (api) │  ← Monitor API
                    └──────┬───────┘
                           │
            ┌──────────────┼──────────────┐
            │              │              │
     ┌──────┴──────┐┌─────┴──────┐┌──────┴──────┐
     │  Worker #1  ││ Worker #2  ││ Worker #3   │
     │  (XMRig)    ││ (XMRig)    ││ (XMRig)     │
     │  2H/4GB VPS ││ 4H/8GB VPS ││ 2H/2GB VPS  │
     └─────────────┘└────────────┘└─────────────┘

     Dashboard (xmrig-workers) → http://PROXY_IP:8080
     Shows: per-worker hashrate, online/offline, shares
```

## Versions

| Component | Version | Release Date |
|-----------|---------|-------------|
| XMRig | v6.26.0 | 2026-03-28 |
| XMRig Proxy | v6.26.0 | 2026-03-28 |
| XMRig Workers | latest | Dashboard UI |

## Recommended Mining Pools

| Pool | URL | Fee |
|------|-----|-----|
| SupportXMR | pool.supportxmr.com:443 | 0.6% |
| MoneroOcean | gulf.moneroocean.stream:443 | 0% (algo-switching) |
| P2Pool | p2pool.io | 0% (decentralized) |
| HashVault | pool.hashvault.pro:443 | 0.9% |
