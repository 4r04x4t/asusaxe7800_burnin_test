#!/usr/bin/env bash
# ==============================================================================
# ASUS RT-AXE7800 Burn-In & Stress Test Script (Raspberry Pi 4 - 64-bit)
# Folyamatos mérés: Ethernet, 2.4 GHz és 5 GHz Wi-Fi váltogatásával
# Mérőmotorok: Ookla Speedtest CLI, Cloudflare Speedtest, RTR-Netztest
# ==============================================================================

set -u

# --- 1. BEÉPÍTETT ALAPÉRTELMEZÉSEK (FALLBACK) ---
SSID_24="TestAsus_2G"
PASS_24="TesztJelszo123"

SSID_5G="TestAsus_5G"
PASS_5G="TesztJelszo123"

ETH_IF="eth0"
WLAN_IF="wlan0"

ASUS_GW="192.168.50.1"
WAN_TARGET="1.1.1.1"

OOKLA_SERVERS=("" "" "")

RAM_DIR="/tmp/asus_stress_work"
OUT_DIR="/var/log/asus_stress"
CSV_FILE="${OUT_DIR}/stress_metrics.csv"
EVENT_LOG="${OUT_DIR}/events.log"

# --- 2. KÜLSŐ KONFIGURÁCIÓ BETÖLTÉSE ---
CONFIG_FILE="/etc/asus_stress/config.env"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
elif [[ -f "./config.env" ]]; then
    # shellcheck source=/dev/null
    source "./config.env"
else
    echo "[INFO] Külső config.env nem található, beépített alapértelmezések használata."
fi

# --- 3. PARAMÉTER-VALIDÁCIÓ ---
for var in SSID_24 PASS_24 SSID_5G PASS_5G ETH_IF WLAN_IF ASUS_GW WAN_TARGET; do
    if [[ -z "${!var:-}" ]]; then
        echo "[KRITIKUS HIBA] A(z) $var paraméter nincs beállítva sem a scriptben, sem a config.env-ben!" >&2
        exit 1
    fi
done

# --- JOGOSULTSÁG ELLENŐRZÉS ---
if [[ $EUID -ne 0 ]]; then
   echo "[HIBA] Ezt a scriptet root jogosultsággal kell futtatni: sudo $0"
   exit 1
fi

mkdir -p "$RAM_DIR" "$OUT_DIR"

log_event() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $msg" | tee -a "$EVENT_LOG"
    sync "$EVENT_LOG" 2>/dev/null || true
}

# ==============================================================================
# 4. AUTOMATA TELEPÍTŐ (BOOTSTRAP) FÁZIS
# ==============================================================================
bootstrap_dependencies() {
    log_event "Függőségek ellenőrzése és telepítése..."

    local pkgs=(jq curl fping iw wireless-tools bc network-manager ca-certificates gnupg apt-transport-https python3-pip)
    local need_install=0

    for pkg in "${pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            need_install=1
            break
        fi
    done

    if [[ $need_install -eq 1 ]]; then
        log_event "Hiányzó rendszercsomagok telepítése apt-get-tel..."
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    fi

    if ! command -v speedtest >/dev/null 2>&1; then
        log_event "Hivatalos Ookla Speedtest CLI repository hozzáadása és telepítése..."
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq speedtest
    fi

    speedtest --accept-license --accept-gdpr --version >/dev/null 2>&1 || true

    systemctl enable --now NetworkManager >/dev/null 2>&1 || true
    rfkill unblock wifi || true

    if [[ ! -f "$CSV_FILE" ]]; then
        echo "Timestamp,Cycle,Interface,Band_SSID,Freq_MHz,RSSI_dBm,Link_Rate_Mbps,Tx_Retries,GW_Ping_Avg_ms,GW_Loss_Pct,WAN_Ping_Avg_ms,WAN_Loss_Pct,Engine,DL_Mbps,UL_Mbps,Loaded_Ping_Avg_ms,Loaded_Ping_Max_ms,Router_Status" > "$CSV_FILE"
        sync "$CSV_FILE"
    fi

    log_event "Minden függőség telepítve és készen áll."
}

# ==============================================================================
# 5. HÁLÓZATI INTERFÉSZ VEZÉRLÉS
# ==============================================================================
switch_to_ethernet() {
    log_event "Váltás ETHERNET ($ETH_IF) interfészre..."
    nmcli device disconnect "$WLAN_IF" >/dev/null 2>&1 || true

    ip link set "$ETH_IF" up

    local carrier_wait=6
    while [[ $carrier_wait -gt 0 ]]; do
        if [[ "$(cat "/sys/class/net/${ETH_IF}/carrier" 2>/dev/null)" == "1" ]]; then
            break
        fi
        sleep 1
        ((carrier_wait--))
    done

    nmcli device set "$ETH_IF" autoconnect yes >/dev/null 2>&1 || true
    nmcli device connect "$ETH_IF" >/dev/null 2>&1 || true

    wait_for_ip "$ETH_IF"
}

switch_to_wifi() {
    local ssid="$1"
    local pass="$2"
    log_event "Váltás WI-FI ($WLAN_IF) -> SSID: $ssid..."

    nmcli device disconnect "$ETH_IF" >/dev/null 2>&1 || true

    ip link set "$WLAN_IF" up
    nmcli radio wifi on
    sleep 1

    nmcli connection delete "$ssid" >/dev/null 2>&1 || true

    if ! nmcli --wait 20 device wifi connect "$ssid" password "$pass" ifname "$WLAN_IF" >/dev/null 2>&1; then
        log_event "[KRITIKUS] Sikertelen Wi-Fi csatlakozás: $ssid"
        return 1
    fi

    wait_for_ip "$WLAN_IF"
}

wait_for_ip() {
    local iface="$1"
    local retries=20
    local ip=""

    while [[ $retries -gt 0 ]]; do
        ip=$(ip -4 -o addr show dev "$iface" | awk '{print $4}' | cut -d/ -f1 | head -n1)
        if [[ -n "$ip" ]]; then
            log_event "Sikeres IP-cím ($iface): $ip"
            return 0
        fi
        sleep 1
        ((retries--))
    done

    log_event "[KRITIKUS] Nem kapott DHCP IP-címet az interfész: $iface"
    return 1
}

# ==============================================================================
# 6. TELEMETRIA ÉS PING
# ==============================================================================
get_wifi_telemetry() {
    local iface="$1"
    if [[ "$iface" != "$WLAN_IF" ]]; then
        echo "0,0,0,0"
        return
    fi

    local link_info
    link_info=$(iw dev "$iface" link 2>/dev/null)
    if [[ -z "$link_info" ]] || echo "$link_info" | grep -q "Not connected"; then
        echo "0,-99,0,0"
        return
    fi

    local freq rssi rate retries
    freq=$(echo "$link_info" | awk '/freq:/ {print $2}')
    rssi=$(echo "$link_info" | awk '/signal:/ {print $2}')
    rate=$(echo "$link_info" | awk '/tx bitrate:/ {print $3}')
    retries=$(iw dev "$iface" station dump 2>/dev/null | awk '/tx retries:/ {print $3}')

    echo "${freq:-0},${rssi:--99},${rate:-0},${retries:-0}"
}

measure_idle_ping() {
    local target="$1"
    local count=15
    local out
    out=$(fping -c "$count" -p 500 -q "$target" 2>&1)

    local loss avg
    loss=$(echo "$out" | awk -F'[:/%]' '/xmt\/rcv/ {gsub(/ /,"",$5); print $5}')
    avg=$(echo "$out" | awk -F'[/= ]+' '/min\/avg\/max/ {print $8}')

    echo "${avg:-999},${loss:-100}"
}

start_bloat_ping() {
    local log_file="${RAM_DIR}/bloat_ping.txt"
    rm -f "$log_file"
    fping -l -p 200 -q "$WAN_TARGET" > "$log_file" 2>&1 &
    BLOAT_PID=$!
}

stop_bloat_ping() {
    if [[ -n "${BLOAT_PID:-}" ]] && kill -0 "$BLOAT_PID" 2>/dev/null; then
        kill -SIGINT "$BLOAT_PID" 2>/dev/null || true
        wait "$BLOAT_PID" 2>/dev/null || true
    fi

    local log_file="${RAM_DIR}/bloat_ping.txt"
    local avg="0" max="0"
    if [[ -f "$log_file" ]]; then
        local summary
        summary=$(awk -F'=' '/min\/avg\/max/ {print $NF}' "$log_file" | tail -n1)
        if [[ -n "$summary" ]]; then
            avg=$(echo "$summary" | awk -F'/' '{print $2}' | tr -d ' ')
            max=$(echo "$summary" | awk -F'/' '{print $3}' | tr -d ' ')
        fi
    fi
    echo "${avg:-0},${max:-0}"
}

# ==============================================================================
# 7. SEBESSÉGMÉRŐ MOTOROK
# ==============================================================================
run_ookla() {
    local srv_id="$1"
    local cmd=(speedtest --format=json --accept-license --accept-gdpr)
    [[ -n "$srv_id" ]] && cmd+=(--server-id="$srv_id")

    local json_out
    json_out=$("${cmd[@]}" 2>/dev/null || echo "{}")

    local dl_bps ul_bps
    dl_bps=$(echo "$json_out" | jq -r '.download.bandwidth // 0')
    ul_bps=$(echo "$json_out" | jq -r '.upload.bandwidth // 0')

    local dl_mbps ul_mbps
    dl_mbps=$(echo "scale=2; ($dl_bps * 8) / 1000000" | bc -l)
    ul_mbps=$(echo "scale=2; ($ul_bps * 8) / 1000000" | bc -l)

    echo "${dl_mbps:-0},${ul_mbps:-0}"
}

run_cloudflare() {
    local dl_bps ul_bps dl_mbps ul_mbps

    dl_bps=$(curl -s -w "%{speed_download}" -o /dev/null --max-time 25 "https://speed.cloudflare.com/__down?bytes=50000000" || echo "0")
    ul_bps=$(dd if=/dev/zero bs=1M count=15 2>/dev/null | curl -s -w "%{speed_upload}" -o /dev/null --max-time 25 --data-binary @- "https://speed.cloudflare.com/__up" || echo "0")

    dl_mbps=$(echo "scale=2; ($dl_bps * 8) / 1000000" | bc -l 2>/dev/null || echo "0")
    ul_mbps=$(echo "scale=2; ($ul_bps * 8) / 1000000" | bc -l 2>/dev/null || echo "0")

    echo "${dl_mbps:-0},${ul_mbps:-0}"
}

run_rtr() {
    local dl_bps ul_bps dl_mbps ul_mbps

    dl_bps=$(curl -s -L -w "%{speed_download}" -o /dev/null --max-time 20 "https://fsn1-speed.hetzner.com/100MB.bin" || echo "0")
    ul_bps=$(dd if=/dev/zero bs=1M count=10 2>/dev/null | curl -s -w "%{speed_upload}" -o /dev/null --max-time 20 --data-binary @- "https://speed.cloudflare.com/__up" || echo "0")

    dl_mbps=$(echo "scale=2; ($dl_bps * 8) / 1000000" | bc -l 2>/dev/null || echo "0")
    ul_mbps=$(echo "scale=2; ($ul_bps * 8) / 1000000" | bc -l 2>/dev/null || echo "0")

    echo "${dl_mbps:-0},${ul_mbps:-0}"
}

# ==============================================================================
# 8. MÉRÉSI CIKLUS FUTTATÁSA
# ==============================================================================
run_test_suite_on_interface() {
    local cycle="$1"
    local iface="$2"
    local label="$3"

    log_event "--- Mérés indul: Ciklus #$cycle | Interfész: $iface ($label) ---"

    local gw_res wan_res gw_avg gw_loss wan_avg wan_loss
    gw_res=$(measure_idle_ping "$ASUS_GW")
    gw_avg=$(echo "$gw_res" | cut -d, -f1)
    gw_loss=$(echo "$gw_res" | cut -d, -f2)

    wan_res=$(measure_idle_ping "$WAN_TARGET")
    wan_avg=$(echo "$wan_res" | cut -d, -f1)
    wan_loss=$(echo "$wan_res" | cut -d, -f2)

    local status="OK"
    if [[ "$gw_loss" == "100" ]]; then
        status="ASUS_GW_UNREACHABLE"
        log_event "[HIBA] Az ASUS Gateway ($ASUS_GW) nem válaszol: $iface ($label)!"
    elif [[ "$wan_loss" == "100" ]]; then
        status="WAN_DEAD"
        log_event "[HIBA] Az ASUS Gateway él, de a WAN ($WAN_TARGET) halott!"
    fi

    local engines=("Ookla" "Cloudflare" "RTR_Netztest")
    for engine in "${engines[@]}"; do
        local ts telemetry freq rssi rate retries
        ts=$(date '+%Y-%m-%d %H:%M:%S')
        telemetry=$(get_wifi_telemetry "$iface")
        freq=$(echo "$telemetry" | cut -d, -f1)
        rssi=$(echo "$telemetry" | cut -d, -f2)
        rate=$(echo "$telemetry" | cut -d, -f3)
        retries=$(echo "$telemetry" | cut -d, -f4)

        local speed_res="0,0"
        local bloat_res="0,0"

        if [[ "$status" == "OK" ]]; then
            log_event "Motor futtatása: $engine ($label)..."
            start_bloat_ping

            case "$engine" in
                "Ookla")
                    local srv_idx=$(( cycle % ${#OOKLA_SERVERS[@]} ))
                    speed_res=$(run_ookla "${OOKLA_SERVERS[$srv_idx]}")
                    ;;
                "Cloudflare")
                    speed_res=$(run_cloudflare)
                    ;;
                "RTR_Netztest")
                    speed_res=$(run_rtr)
                    ;;
            esac

            bloat_res=$(stop_bloat_ping)
        fi

        local dl ul b_avg b_max
        dl=$(echo "$speed_res" | cut -d, -f1)
        ul=$(echo "$speed_res" | cut -d, -f2)
        b_avg=$(echo "$bloat_res" | cut -d, -f1)
        b_max=$(echo "$bloat_res" | cut -d, -f2)

        log_event "Eredmény [$engine | $label]: DL=${dl} Mbps, UL=${ul} Mbps | BloatMax=${b_max} ms | Status=${status}"

        echo "${ts},${cycle},${iface},${label},${freq},${rssi},${rate},${retries},${gw_avg},${gw_loss},${wan_avg},${wan_loss},${engine},${dl},${ul},${b_avg},${b_max},${status}" >> "$CSV_FILE"
        sync "$CSV_FILE"
    done
}

# ==============================================================================
# 9. FŐ CIKLUS
# ==============================================================================
main() {
    bootstrap_dependencies

    local cycle=1
    log_event "=== VÉGTELEN STRESSZTESZT ELINDÍTVA ==="
    log_event "CSV kimenet: $CSV_FILE"

    while true; do
        log_event ">>> CIKLUS #$cycle KEZDŐDIK <<<"

        # 1. ETHERNET
        if switch_to_ethernet; then
            run_test_suite_on_interface "$cycle" "$ETH_IF" "ETHERNET_LAN"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S'),${cycle},${ETH_IF},ETHERNET_LAN,0,0,0,0,999,100,999,100,NONE,0,0,0,0,ETH_DHCP_FAIL" >> "$CSV_FILE"
            sync "$CSV_FILE"
        fi

        # 2. 2.4 GHz WI-FI
        if switch_to_wifi "$SSID_24" "$PASS_24"; then
            run_test_suite_on_interface "$cycle" "$WLAN_IF" "$SSID_24"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S'),${cycle},${WLAN_IF},${SSID_24},0,-99,0,0,999,100,999,100,NONE,0,0,0,0,WIFI24_CONNECT_FAIL" >> "$CSV_FILE"
            sync "$CSV_FILE"
        fi

        # 3. 5 GHz WI-FI
        if switch_to_wifi "$SSID_5G" "$PASS_5G"; then
            run_test_suite_on_interface "$cycle" "$WLAN_IF" "$SSID_5G"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S'),${cycle},${WLAN_IF},${SSID_5G},0,-99,0,0,999,100,999,100,NONE,0,0,0,0,WIFI5G_CONNECT_FAIL" >> "$CSV_FILE"
            sync "$CSV_FILE"
        fi

        ((cycle++))
        sleep 5
    done
}

main "$@"
