# ASUS RT-AXE7800 Burn-In & Multi-Engine Stress Tester

[![Platform](https://img.shields.io/badge/Platform-Raspberry%20Pi%204%20(64--bit)-red.svg)](https://www.raspberrypi.com/)
[![OS](https://img.shields.io/badge/OS-Raspberry%20Pi%20OS%20Bookworm-blue.svg)](https://www.raspberrypi.com/software/)
[![Service](https://img.shields.io/badge/Daemon-systemd-orange.svg)](https://systemd.io/)
[![Engines](https://img.shields.io/badge/Engines-Ookla%20%7C%20Cloudflare%20%7C%20Hetzner-green.svg)](#multi-engine-benchmark-methodology)

An enterprise-grade, headless network burn-in and continuous stress-testing framework designed to run on a **Raspberry Pi 4 (64-bit)**. 

The tool was created to systematically evaluate, stress, and validate problematic router platforms—such as the **ASUS RT-AXE7800** (Broadcom BCM6756/BCM4912 platform with MaxLinear GPY211 2.5GbE PHY)—detecting thermal throttling, driver crashes, PHY flapping, bufferbloat, and DFS radar radar-backoff anomalies over long periods (12–48+ hours).

---

## Architecture & Operational Flow

The test script runs in an infinite, automated cycle. It tests three network pathways in strict sequence to isolate performance and stability per physical radio and wire interface:

```
                  ┌─────────────────────────────────────────────────────────┐
                  │                 Burn-In Test Loop (Cycle N)             │
                  └────────────────────────────┬────────────────────────────┘
                                               │
               ┌───────────────────────────────┼───────────────────────────────┐
               ▼                               ▼                               ▼
       [Phase 1: Ethernet]            [Phase 2: Wi-Fi 2.4G]           [Phase 3: Wi-Fi 5G]
       • Disconnect wlan0             • Disconnect eth0               • Disconnect eth0
       • Wait for PHY Carrier (6s)    • Connect "TestAsus_2G"         • Connect "TestAsus_5G"
       • DHCP Lease via eth0          • DHCP Lease via wlan0          • DHCP Lease via wlan0
       • Probe GW & WAN Ping          • Read RSSI / Freq / Retries    • Read RSSI / Freq / Retries
       • Run 3 Benchmark Engines      • Run 3 Benchmark Engines       • Run 3 Benchmark Engines
       • Log loaded Bufferbloat       • Log loaded Bufferbloat        • Log loaded Bufferbloat
               │                               │                               │
               └───────────────────────────────┼───────────────────────────────┘
                                               │
                                 ┌─────────────▼─────────────┐
                                 │ Flush & Sync Metrics CSV  │
                                 │ Sleep 5s -> Next Cycle    │
                                 └───────────────────────────┘
```

### Key Highlights
- **Strict Interface Isolation:** Automatically disconnects and disables inactive interfaces before measuring, ensuring zero traffic leakage across alternate default routes.
- **Microsecond Flash Protection (RAM-first I/O):** High-frequency intermediate ping logs and socket buffers run inside `/tmp/asus_stress_work` (`tmpfs` in RAM) to prevent SD card wear. Only finalised, aggregated metrics are synced atomically to disk.
- **Physical Link-Carrier Sensing:** Features intelligent Auto-Negotiation detection (`/sys/class/net/eth0/carrier`) to prevent DHCP race conditions during Ethernet link reconstruction.

---

## Multi-Engine Benchmark Methodology

To eliminate ISP CDN caching artifacts and single-provider rate-limiting, each interface phase executes three independent transfer engines:

| Engine | Protocol | Workload | Target Infrastructure |
| :--- | :--- | :--- | :--- |
| **Ookla CLI** | Native Ookla binary (JSON) | Multi-stream DL / UL | Rotated Tier-1 regional speedtest hosts |
| **Cloudflare Speed** | Chunked HTTPS streaming | 50 MB DL / 15 MB UL | Anycast Edge (`speed.cloudflare.com`) |
| **European CDN / Hetzner** | HTTP/2 Follow-Redirects (`-L`) | 100 MB DL / 10 MB UL | Dedicated backbone mirrors (`fsn1-speed.hetzner.com`) |

During all active transfers, an asynchronous **ICMP bufferbloat daemon** runs in the background at 200 ms intervals toward `1.1.1.1` to measure loaded latency deltas and jitter.

---

## File Structure

```text
asusaxe7800_burnin_test/
├── .gitignore               # Excludes secrets (config.env), test logs, and CSV outputs
├── README.md                # Comprehensive documentation
├── config.env.example       # Template configuration
├── install.sh               # One-touch automated setup & dependency installer
├── asus-stress.service      # systemd unit definition
└── asus_burnin.sh           # Core benchmark and orchestration engine
```

---

## Quick Start Guide

### 1. Hardware Preparation
1. Connect your **Raspberry Pi 4** Ethernet port (`eth0`) to a **LAN port** of the ASUS RT-AXE7800 using a Cat.6 cable.
2. Ensure the ASUS router 2.5G WAN port is connected to your primary modem or upstream network.
3. Power the Raspberry Pi using an official 5.1V / 3A power supply to avoid undervoltage issues during full CPU and radio load.

### 2. Clone and Deploy
Run the following commands on the Raspberry Pi:

```bash
# Clone the repository
git clone https://github.com/4r04x4t/asusaxe7800_burnin_test.git
cd asusaxe7800_burnin_test

# Make the installer executable and run setup
chmod +x install.sh asus_burnin.sh
sudo ./install.sh
```

### 3. Configure Network Secrets
Edit the system configuration file generated in `/etc/asus_stress/`:

```bash
sudo nano /etc/asus_stress/config.env
```

Set your exact Wi-Fi credentials and IP addresses:

```bash
# Wi-Fi Credentials
SSID_24="TestAsus_2G"
PASS_24="YourStrongPasswordHere"

SSID_5G="TestAsus_5G"
PASS_5G="YourStrongPasswordHere"

# Hardware Interfaces
ETH_IF="eth0"
WLAN_IF="wlan0"

# Target Gateways
ASUS_GW="192.168.50.1"
WAN_TARGET="1.1.1.1"

# Specific Ookla Server IDs (Leave empty for auto-selection)
OOKLA_SERVERS=("" "" "")
```

Save and exit (`Ctrl + O`, `Enter`, `Ctrl + X`).

### 4. Enable Regional Radio Domain & Start Service
```bash
# Set regulatory domain to prevent 5GHz band lockouts (e.g. HU, DE, US)
sudo raspi-config nonint do_wifi_country HU

# Start and monitor the stress test service
sudo systemctl start asus-stress.service
```

---

## Service Management & Monitoring

### Process Lifecycle
```bash
# Check service status
sudo systemctl status asus-stress.service

# Live follow the execution log
tail -f /var/log/asus_stress/events.log

# Read systemd journal errors
journalctl -u asus-stress.service -f

# Stop the burn-in service
sudo systemctl stop asus-stress.service

# Disable automatic boot startup
sudo systemctl disable asus-stress.service
```

### Reviewing Metric Tables
Print the last 15 benchmark results in a formatted table:

```bash
column -s, -t /var/log/asus_stress/stress_metrics.csv | tail -n 16
```

Filter 5 GHz metrics to check for link-rate drops:
```bash
awk -F',' '$4=="TestAsus_5G" {print $1" | Engine: "$13" | DL: "$14" Mbps | UL: "$15" Mbps | RSSI: "$6" dBm"}' /var/log/asus_stress/stress_metrics.csv
```

---

## CSV Output Schema (`stress_metrics.csv`)

Every executed test run appends a synchronized record to `/var/log/asus_stress/stress_metrics.csv`:

| Column # | Field Name | Description | Example |
| :---: | :--- | :--- | :--- |
| **1** | `Timestamp` | ISO execution date and time | `2026-10-31 13:02:57` |
| **2** | `Cycle` | Monotonically increasing loop counter | `14` |
| **3** | `Interface` | System device used for the benchmark | `eth0`, `wlan0` |
| **4** | `Band_SSID` | SSID name or Ethernet network label | `ETHERNET_LAN`, `TestAsus_5G` |
| **5** | `Freq_MHz` | Radio center frequency (0 on Ethernet) | `2412`, `5260` |
| **6** | `RSSI_dBm` | Signal power at the client antenna | `-36`, `-60` |
| **7** | `Link_Rate_Mbps` | Negotiated Wi-Fi PHY bitrate | `72.2`, `433.3` |
| **8** | `Tx_Retries` | Hardware-level frame transmission retries | `12` |
| **9** | `GW_Ping_Avg_ms` | Baseline unloaded latency to the router | `0.65` |
| **10** | `GW_Loss_Pct` | Packet loss percentage to router | `0` |
| **11** | `WAN_Ping_Avg_ms` | Baseline latency to public DNS target | `7.42` |
| **12** | `WAN_Loss_Pct` | Packet loss percentage to public target | `0` |
| **13** | `Engine` | Benchmark engine utilized | `Ookla`, `Cloudflare`, `RTR_Netztest` |
| **14** | `DL_Mbps` | Calculated downlink bandwidth | `754.26` |
| **15** | `UL_Mbps` | Calculated uplink bandwidth | `256.84` |
| **16** | `Loaded_Ping_Avg_ms`| Mean latency during full pipeline saturation | `24.1` |
| **17** | `Loaded_Ping_Max_ms`| Peak latency spikes during saturation (Bloat) | `124` |
| **18** | `Router_Status` | Health evaluation code | `OK`, `ASUS_GW_UNREACHABLE` |

---

## Hardware Field Notes: ASUS RT-AXE7800

During extensive test runs on this router platform, keep the following hardware characteristics in mind:

1. **5 GHz DFS Radar Interference (Channels 52–144):**  
   If the ASUS 5 GHz radio is set to `Auto` channel, it frequently defaults to DFS spectrum (e.g. Channel 52 or 100). If radar patterns or channel clearances occur, the router initiates a Quiet Period or enforces strict MCS0 (6 Mbps) rate stepping on client devices.  
   *Remedy:* For clean throughput testing, set 5 GHz channel selection to **Channel 36, 40, 44, or 48** (80 MHz non-DFS).

2. **Wi-Fi Power Management on Raspberry Pi OS:**  
   The Raspberry Pi onboard Broadcom chip enables 802.11 power saving by default. During high-bandwidth transfers, this can cause artificial 4–6 Mbps upload throttling. The test suite automatically suppresses power saving using `iw dev wlan0 set power_save off`.

3. **2.5GbE PHY Auto-Negotiation (GPY211):**  
   The router's 2.5G WAN port utilizes a MaxLinear GPY211 transceiver. If using sub-standard cabling or poorly crimped jacks, the driver triggers an internal link-flapping workaround (`GPY211 WAR AUTO`) and downgrades to 100 Mbps. Always verify that Cat.5e/Cat.6 cabling is seated firmly.

---

## Maintenance & Metric Resets

To purge logs and start a clean test session:

```bash
# Stop the runner
sudo systemctl stop asus-stress.service

# Clear the metric history while preserving the CSV headers
sudo truncate -s 0 /var/log/asus_stress/events.log
sudo bash -c 'echo "Timestamp,Cycle,Interface,Band_SSID,Freq_MHz,RSSI_dBm,Link_Rate_Mbps,Tx_Retries,GW_Ping_Avg_ms,GW_Loss_Pct,WAN_Ping_Avg_ms,WAN_Loss_Pct,Engine,DL_Mbps,UL_Mbps,Loaded_Ping_Avg_ms,Loaded_Ping_Max_ms,Router_Status" > /var/log/asus_stress/stress_metrics.csv'

# Restart the service
sudo systemctl start asus-stress.service
```

## License
Open-source under the MIT License. Feel free to modify and deploy for burn-in testing across any router hardware platform.
