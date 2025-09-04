# Raspberry Pi: Pi-hole + ProtonVPN Gateway

🇳🇴 [Norsk](README.md) · 🇬🇧 [English](README.en.md)

This project sets up a Raspberry Pi as a combined DNS filtering server (Pi-hole) and ProtonVPN gateway with selective routing based on IP and/or ports. It includes robust startup and monitoring via MQTT and systemd.

---

## 🧭 Goals

- Raspberry Pi with static IP address.
- Pi-hole for local DNS blocking on the whole network.
- ProtonVPN connection via OpenVPN for traffic from selected clients and/or ports.
- Automatic recovery of the VPN connection in case of router/network failure.
- (Optional) Integration with Home Assistant via MQTT for monitoring.

---

## 📦 Requirements

- Raspberry Pi 3, 4 or 5 (wired connection strongly recommended).
- Raspberry Pi OS Lite (64-bit), Bookworm or newer.
- ProtonVPN account.
- MQTT broker (optional, only for Home Assistant integration).

---

## ⚠️ Important before you start
- **IPv6**: The setup is IPv4-based. If IPv6 is enabled in your network, traffic may bypass the VPN. Either disable IPv6 on the Pi and clients, or add equivalent IPv6 firewall rules.  
- **CORRECT_GATEWAY**: In `protonvpn-gateway.sh`, set the variable `CORRECT_GATEWAY` to the IP of your router (e.g. `192.168.1.1`).  
- **CPU-temp**: Publishing CPU temperature to MQTT is **disabled by default** (`ENABLE_CPU_TEMP=false`). Enable it if you want to use it.

---

## 🔧 Step-by-step setup

### 0. System setup

1. Install Raspberry Pi OS Lite (64-bit).
2. Connect via SSH.
3. Update the system:

   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo reboot
   ```
4. **Set a static IP address:**
   On newer versions of Raspberry Pi OS (Bookworm and newer), NetworkManager is used. The following commands set a static IP. **Adjust addresses for your own network.**

   ```bash
   # Replace "Wired connection 1" with the name of your connection if needed (check with 'nmcli con show')
   # Replace IP addresses, gateway (your router IP) and DNS servers
   sudo nmcli con mod "Wired connection 1" ipv4.method manual
   sudo nmcli con mod "Wired connection 1" ipv4.addresses 192.168.1.102/24
   sudo nmcli con mod "Wired connection 1" ipv4.gateway 192.168.1.1
   sudo nmcli con mod "Wired connection 1" ipv4.dns "1.1.1.1,8.8.8.8"

   # Apply changes
   sudo nmcli con up "Wired connection 1"
   ```

   After changes, reboot to ensure everything is correct:

   ```bash
   sudo reboot
   ```

> ℹ️ On older images without NetworkManager you can use `dhcpcd.conf` or `systemd-networkd` instead.

---

### 1. Install Pi-hole

```bash
curl -sSL https://install.pi-hole.net | bash
```

Follow the instructions. Choose eth0 as interface and select an upstream DNS provider (e.g. Cloudflare or Google). Note down the admin password.

### 2. Install iptables-persistent and enable IP forwarding

```bash
sudo apt install iptables-persistent -y
```

Edit `/etc/sysctl.conf` and ensure the following line is active:

```ini
net.ipv4.ip_forward=1
```

Activate:

```bash
sudo sysctl -p
```

### 3. Install and configure ProtonVPN (OpenVPN)

Follow ProtonVPN documentation and download `.ovpn` configuration + auth file. Place them in `/etc/openvpn/client/`.

### 4. Create dedicated routing table for VPN

```bash
grep -qE '^\s*200\s+vpn_table\b' /etc/iproute2/rt_tables || \
  echo "200 vpn_table" | sudo tee -a /etc/iproute2/rt_tables
```

### 5. Configure Firewall and Selective Routing (iptables)

```bash
# --- STEP 1: Flush everything for a clean start ---
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
sudo iptables -X && sudo iptables -t nat -X && sudo iptables -t mangle -X

# --- STEP 2: Set secure default policy ---
# ⚠️ Make sure SSH rule is in place before setting INPUT DROP!
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

# --- STEP 3: INPUT rules ---
sudo iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -p icmp -j ACCEPT
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 22 -j ACCEPT # SSH
sudo iptables -A INPUT -s 192.168.1.0/24 -p udp --dport 53 -j ACCEPT # Pi-hole DNS
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 53 -j ACCEPT # Pi-hole DNS
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 80 -j ACCEPT # Pi-hole Web

# --- STEP 4: MANGLE rules (Mark traffic for VPN) ---
CLIENT_IPS_TO_VPN="192.168.1.128 192.168.1.129 192.168.1.130 192.168.1.131"
for ip in $CLIENT_IPS_TO_VPN; do
    sudo iptables -t mangle -A PREROUTING -s "$ip" -p tcp --dport 8080 -j MARK --set-mark 1
    echo "Rule added for $ip"
done

> 💡 Adjust the list in `CLIENT_IPS_TO_VPN` with the clients you want routed via VPN.  
> You can also change the port (`--dport 8080`) if you want to mark traffic on other ports.

# --- STEP 5: FORWARD rules ---
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o tun0 -m mark --mark 1 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o eth0 -j ACCEPT

# --- STEP 6: NAT rules ---
sudo iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Note: MASQUERADE on eth0 is only needed if the Pi routes between subnets. In a simple LAN it can be removed.

# --- STEP 7: Save ---
sudo netfilter-persistent save
```

### 6. Download and customize the main script

```bash
# Download main script from GitHub
sudo wget -O /usr/local/bin/protonvpn-gateway.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-protonvpn-gateway/main/protonvpn-gateway.sh

# Make it executable
sudo chmod +x /usr/local/bin/protonvpn-gateway.sh

# Open the file to adjust your personal variables
sudo nano /usr/local/bin/protonvpn-gateway.sh
```

### 7. Create systemd service

Create the service file:

```bash
sudo nano /etc/systemd/system/protonvpn-gateway.service
```

Paste the following content (adjusted for journald logging, or use file logging if you prefer a log file):

```ini
[Unit]
Description=ProtonVPN Gateway Service
After=network-online.target pihole-FTL.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/protonvpn-gateway.sh
Restart=always
RestartSec=30
# Logs to journald; view with: journalctl -u protonvpn-gateway -f
# (If you prefer a file: use StandardOutput/StandardError to /var/log/protonvpn-gateway.log)

[Install]
WantedBy=multi-user.target
```

Enable the service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable protonvpn-gateway.service
sudo systemctl start protonvpn-gateway.service
```

---

### 8. Configure your router

Log in to your router and make the following changes in the DHCP settings for your local network:

* Set **Default Gateway** to your Raspberry Pi IP (e.g. `192.168.1.102`).
* Set **DNS Server** to the same Raspberry Pi IP (e.g. `192.168.1.102`).

Then restart the devices on your network so they get the new settings.

---

### 9. Testing and Verification

* Service status: `sudo systemctl status protonvpn-gateway.service`
* Logs: `journalctl -u protonvpn-gateway -f`
* Check routing: `ip rule show`, `ip route show table vpn_table`

- Install tcpdump (required for the verify script):

  ```bash
  sudo apt install tcpdump
  ```

- Download and run the verification script to confirm selective routing works:

  ```bash
  wget https://raw.githubusercontent.com/Howard0000/raspberrypi-protonvpn-gateway/main/verify_traffic.sh
  chmod +x verify_traffic.sh
  sudo ./verify_traffic.sh
  ```

> You can customize `verify_traffic.sh` by editing three variables at the top:
>
> ```
> PORT=8080
> IFACE="tun0"
> PROTO="tcp"
> ```
>
> Example: `wg0` + UDP 51820 for WireGuard.

---

## 💾 Backup and Maintenance

- Backup: `/etc/iptables/rules.v4`, `protonvpn-gateway.sh`, and the systemd unit file.
- If you use file logging (`/var/log/protonvpn-gateway.log` and `/var/log/openvpn.log`), set up `logrotate` to prevent logs from growing indefinitely.

---

## 📡 MQTT and Home Assistant

MQTT is **off** by default (`MQTT_ENABLED=false`).  
Set to `true` and fill in broker/user/password in `protonvpn-gateway.sh` to enable.  
CPU temperature sensor (`ENABLE_CPU_TEMP`) is also off by default.

---

## 🙌 Acknowledgements

Project written and maintained by @Howard0000. A KI assistant helped simplify explanations, tidy the README, and polish scripts. All suggestions were manually reviewed before inclusion, and all configuration and testing was done by me.

---

## 📝 License

MIT — see LICENSE.
