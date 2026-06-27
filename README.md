# min

## Grass Node Packages

Official Grass network node installation packages.

### Downloads

| Platform | File | Version | Size |
|----------|------|---------|------|
| Linux (Ubuntu/Debian) | [Grass_7.3.1_amd64.deb](packages/Grass_7.3.1_amd64.deb) | v7.3.1 | 18 MB |
| Android | [Grass-v3.0.5.apk](packages/Grass-v3.0.5.apk) | v3.0.5 | 96 MB |

### Installation

**Linux (Ubuntu/Debian):**
```bash
sudo dpkg -i packages/Grass_7.3.1_amd64.deb
```

**Android:**
Transfer the APK file to your Android device and install it (enable "Install from unknown sources" in settings).

### Source

- Official website: https://www.grass.io/
- Download page: https://www.grass.io/download
- Documentation: https://grass-foundation.gitbook.io/grass-docs
- Google Play: https://play.google.com/store/apps/details?id=io.getgrass.www

## XMR Monero Mining Toolkit

Full XMR mining toolkit with auto-optimization for small servers. See [xmr-mining/README.md](xmr-mining/README.md) for details.

- **XMRig v6.26.0** — CPU miner (Linux static binary)
- **XMRig Proxy v6.26.0** — Central relay node with worker monitoring API
- **XMRig Workers Dashboard** — Web UI to view per-worker hashrate & online status
- **Auto-Optimize Script** — Detects CPU (AVX/AVX2/AES-NI/SSE, Intel/AMD), cache, memory and generates optimized config for 2-4 core VPS
