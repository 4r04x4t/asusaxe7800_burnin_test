# Router Burn-In & Multi-Engine Stress Tester

Automated headless stress-testing tool designed for Raspberry Pi 4 (64-bit) to diagnose hardware/driver stability issues on problematic routers (e.g. Broadcom-based ASUS RT-AXE7800).

## Features
- **Interface Rotation:** Sequentially tests Gigabit Ethernet (`eth0`), 2.4 GHz Wi-Fi, and 5 GHz Wi-Fi (`wlan0`).
- **Multi-Engine Speedtests:** Rotates between official **Ookla CLI**, **Cloudflare Speed**, and **RTR-Netztest** (Austrian Regulatory Authority RMBT protocol).
- **Bufferbloat / Loaded Latency Tracking:** Measures real-time ICMP bloat and jitter during active transfers.
- **Detailed Telemetry:** Logs frequency, RSSI (dBm), link rate, hardware retry counters, and packet loss to CSV.
- **Headless systemd integration:** Runs continuously on boot, survives network teardowns and reconnects.

## Quick Start
```bash
git clone https://github.com/4r04x4t/asusaxe7800_burnin_test.git](https://github.com/4r04x4t/asusaxe7800_burnin_test.git
cd asus-burnin-tester
chmod +x install.sh
sudo ./install.sh
sudo nano /etc/asus_stress/config.env
sudo systemctl start asus-stress.service

Metrics
Metrics are synced to /var/log/asus_stress/stress_metrics.csv after every cycle.
```
