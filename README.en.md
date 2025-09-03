# Raspberry Pi: Pi-hole + Proton VPN Gateway (selective routing)

> 🇬🇧 English · 🇳🇴 [Norsk versjon](README.md)

This project turns a Raspberry Pi into a **DNS filter (Pi-hole)** and **Proton VPN gateway** with **selective routing**: only chosen clients/ports are sent through the VPN, while everything else follows the normal WAN route. The setup is hardened with iptables and made robust with systemd.

## ✨ Features
- Pi-hole as the **primary DNS** for your LAN (no DNS leakage — keep `nordvpn set dns off`).
- **Selective routing** (e.g., **TCP :8080** for specific clients) via **NordLynx** (WireGuard).
- Robust boot order (waits for network and Pi-hole), dedicated **routing table**, and auto-reconnect.
- Optional **MQTT/Home Assistant** status (CPU temp, service state, etc.).
- Clean repo layout: `scripts/`, `systemd/`, `docs/`, `examples/`.

## 📦 Requirements
- Raspberry Pi 3/4/5, preferably wired (eth0), running Raspberry Pi OS (Bookworm or newer).
- A NordVPN account and Pi-hole installed.
- `iptables-persistent` for saving rules.

## 🚀 Quick start
> **Never commit secrets.** Use `/etc/nordvpn-gateway.env` for credentials and local values.

1. **Install dependencies**
   ```bash
   sudo apt update && sudo apt install -y iptables-persistent
   echo "200 nordvpntabell" | sudo tee -a /etc/iproute2/rt_tables
   sudo sysctl -w net.ipv4.ip_forward=1
   ```

2. **Copy files**
   ```bash
   sudo cp scripts/nordvpn-gateway.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/nordvpn-gateway.sh

   sudo cp scripts/iptables-setup.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/iptables-setup.sh

   sudo cp scripts/verify_traffic.sh /usr/local/bin/
   sudo chmod +x /usr/local/bin/verify_traffic.sh

   sudo cp systemd/nordvpn-gateway.service /etc/systemd/system/
   ```

3. **Environment file (secrets & config)**
   ```bash
   sudo cp examples/nordvpn-gateway.env.example /etc/nordvpn-gateway.env
   sudo nano /etc/nordvpn-gateway.env    # fill in values (broker IP, user/pass, etc.)
   ```

4. **Apply firewall rules**
   ```bash
   sudo /usr/local/bin/iptables-setup.sh
   ```

5. **NordVPN client configuration**
   ```bash
   nordvpn login
   nordvpn set killswitch disabled
   nordvpn set dns off
   nordvpn set autoconnect disabled
   nordvpn set firewall disabled
   nordvpn set routing disabled
   nordvpn set technology NordLynx
   ```

6. **Enable the service**
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now nordvpn-gateway.service
   sudo systemctl status nordvpn-gateway.service
   tail -f /var/log/nordvpn-gateway.log
   ```

## 🧪 Verification
```bash
# Ensure traffic for TCP :8080 is marked/routed via 'nordlynx'
sudo /usr/local/bin/verify_traffic.sh
```

## 🔗 Pi-hole’s role
- Pi-hole is the **DNS** for your entire LAN. In iptables, only open **53/UDP+TCP** and **80/TCP** to the Pi (LAN only).
- The systemd unit uses `After=pihole-FTL.service` so DNS is ready before the gateway script starts.
- More notes in `docs/PIHOLE.no.md`.

## 🛠️ Troubleshooting
- `nordvpn status` — is the VPN up?
- `ip rule show` + `ip route show table nordvpntabell` — does marked traffic use the VPN table?
- `sudo iptables -t mangle -L PREROUTING -v -n` — are counters increasing for `tcp dpt:8080`?
- `sudo tcpdump -i nordlynx -n 'tcp and port 8080'` — do you see packets on the VPN interface?

## 🔐 Security notes
- Do **not** expose the Pi-hole web UI to WAN.
- Keep secrets in `/etc/nordvpn-gateway.env` (MQTT user/pass, etc.).
- Consider logrotate for `/var/log/nordvpn-gateway.log`.

## 📝 License
MIT — see `LICENSE`.
