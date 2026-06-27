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
    └── setup-proxy.sh              # Quick proxy setup with monitoring API
```

## Quick Start

### 1. Auto-Optimize & Mine (Worker Node)

```bash
cd xmrig
tar xzf xmrig-6.26.0-linux-static-x64.tar.gz --strip-components=1

# Auto-detect CPU features and generate optimized config
sudo bash ../scripts/auto-optimize.sh

# Edit config - set your wallet address
nano config.json
# Change YOUR_XMR_WALLET_ADDRESS to your Monero wallet

# Start mining
./xmrig
```

### 2. Setup Proxy (Central Node)

```bash
cd xmrig-proxy
tar xzf xmrig-proxy-6.26.0-linux-static-x64.tar.gz --strip-components=1

# Generate proxy config
bash ../scripts/setup-proxy.sh

# Edit config - set your wallet address
nano config.json

# Start proxy
./xmrig-proxy
```

### 3. Connect Workers to Proxy

On each worker machine:
```bash
./xmrig -o PROXY_IP:3333 -u worker-name -p x --no-tls
```

### 4. Monitor Workers

**API:**
```bash
# View all workers hashrate & online status
curl -H 'Authorization: Bearer YOUR_TOKEN' http://PROXY_IP:4048/2/workers

# Summary
curl -H 'Authorization: Bearer YOUR_TOKEN' http://PROXY_IP:4048/2/summary
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
