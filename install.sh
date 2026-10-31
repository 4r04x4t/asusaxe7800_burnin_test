#!/usr/bin/env bash
set -e

if [[ $EUID -ne 0 ]]; then
   echo "[HIBA] Futtasd rootként: sudo ./install.sh"
   exit 1
fi

echo "Telepítés folyamatban..."

mkdir -p /etc/asus_stress /var/log/asus_stress

# Config másolása ha még nincs
if [[ ! -f /etc/asus_stress/config.env ]]; then
    cp config.env.example /etc/asus_stress/config.env
    echo "Hozd létre és szerkeszd a beállításokat: nano /etc/asus_stress/config.env"
fi

cp asus_burnin.sh /usr/local/bin/asus_burnin.sh
chmod +x /usr/local/bin/asus_burnin.sh

cp asus-stress.service /etc/systemd/system/asus-stress.service
systemctl daemon-reload
systemctl enable asus-stress.service

echo "Telepítés kész! Indítás: sudo systemctl start asus-stress.service"