# Raspberry Pi: Pi-hole + ProtonVPN Gateway

> 🇬🇧 English · 🇳🇴 [Norwegian version](README.md)

This project configures a Raspberry Pi as a combined DNS filtering server (Pi-hole) and an advanced VPN gateway. The solution uses the universal OpenVPN client, is tested with **Proton VPN (free tier)**, and features **selective routing**, allowing you to send traffic from only selected devices and/or ports through the VPN tunnel.

The project includes a robust startup process, self-healing logic, and monitoring via `systemd` and MQTT.

---

## ✨ Key Features

*   **Selective Routing:** Choose exactly which devices (by IP) and ports should use the VPN. All other traffic goes through your regular internet connection for maximum speed.
*   **Universal OpenVPN Client:** Built on the open OpenVPN standard. Thoroughly tested with the **Proton VPN free tier**.
*   **Pi-hole Integration:** All DNS traffic is handled by Pi-hole for network-wide ad and tracker blocking.
*   **Robust and Self-Healing:** A `systemd` service ensures automatic startup and restarts on failure. The script actively verifies that the VPN connection is working and re-establishes it if necessary.
*   **Safe Startup:** The service waits for the network and router to be available before starting.
*   **(Optional) Home Assistant Integration:** Send real-time data about VPN status and CPU temperature to your MQTT broker.
*   **Easy Troubleshooting:** Includes a verification script to see in real-time that the selective routing is working.

---

## 📦 Requirements

*   Raspberry Pi 3, 4, or 5 (a wired network connection is strongly recommended).
*   Raspberry Pi OS Lite (64-bit), Bookworm or newer.
*   A Proton VPN account (free or paid).
*   (Optional) An MQTT broker for Home Assistant integration.

---

## 🔧 Step-by-step Setup

### 0. System Setup

1.  Install Raspberry Pi OS Lite (64-bit).
2.  Connect via SSH.
3.  Update the system:

    sudo apt update && sudo apt full-upgrade -y
    sudo reboot

4.  **Set a static IP address:**
    Newer versions of Raspberry Pi OS use NetworkManager. **Customize the IP addresses for your own network.**

    # Replace "Wired connection 1" with the name of your connection if needed (check with 'nmcli con show')
    # Replace the IP addresses, gateway (your router's IP), and DNS servers
    sudo nmcli con mod "Wired connection 1" ipv4.method manual
    sudo nmcli con mod "Wired connection 1" ipv4.addresses 192.168.1.102/24
    sudo nmcli con mod "Wired connection 1" ipv4.gateway 192.168.1.1
    sudo nmcli con mod "Wired connection 1" ipv4.dns "1.1.1.1,8.8.8.8"
    
    # Apply the changes
    sudo nmcli con up "Wired connection 1"
    sudo reboot

### 1. Install Pi-hole

    curl -sSL https://install.pi-hole.net | bash

Follow the prompts. Choose `eth0` as the interface and select an upstream DNS provider (e.g., Cloudflare). Note down the admin password.

### 2. Enable IP Forwarding and Install `iptables-persistent`

    sudo apt install iptables-persistent -y

Enable IP forwarding by editing `/etc/sysctl.conf`:

    sudo nano /etc/sysctl.conf

Find the line `#net.ipv4.ip_forward=1` and remove the `#` at the beginning. Save the file (Ctrl+X, Y, Enter) and apply the change:

    sudo sysctl -p

### 3. Install OpenVPN and Configure Proton VPN

This step sets up the VPN client itself and fetches the necessary files from Proton VPN.

1.  **Install OpenVPN:**

    sudo apt update && sudo apt install openvpn -y

2.  **Create a free Proton VPN account** at [protonvpn.com](https://protonvpn.com).

3.  **Get your OpenVPN credentials:**
    *   Log into your Proton account.
    *   Navigate to **Account -> OpenVPN / IKEv2 username**.
    *   Note down the **Username** and **Password** shown here. **NOTE:** This is *not* your regular Proton password.

4.  **Download a server configuration file:**
    *   On the same page, navigate to **Downloads -> OpenVPN configuration files**.
    *   Choose **Linux** as the platform and **UDP** as the protocol.
    *   Download a server file from one of the free countries (e.g., Netherlands, Japan, or USA).

5.  **Transfer the files to your Raspberry Pi:**
    *   Create a directory for the configuration: `sudo mkdir -p /etc/openvpn/client`
    *   Transfer the `.ovpn` file you downloaded to this directory. Give it a simple name, e.g.: `sudo mv your-downloaded-file.ovpn /etc/openvpn/client/proton.ovpn`
    *   Create a file for your credentials: `sudo nano /etc/openvpn/client/proton_auth.txt`
    *   Paste the username and password from step 3 on two separate lines:

        YOUR_OPENVPN_USERNAME
        YOUR_OPENVPN_PASSWORD

    *   Save the file (Ctrl+X, Y, Enter) and **secure it** so only root can read it:

        sudo chmod 600 /etc/openvpn/client/proton_auth.txt

### 4. Create a Custom Routing Table for the VPN

    echo "200 vpn_table" | sudo tee -a /etc/iproute2/rt_tables

### 5. Configure Firewall and Selective Routing

These `iptables` rules use the generic VPN interface `tun0`.

    # --- STEP 1: Flush everything for a clean start ---
    sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
    sudo iptables -X && sudo iptables -t nat -X && sudo iptables -t mangle -X

    # --- STEP 2: Set a secure default policy ---
    sudo iptables -P INPUT DROP
    sudo iptables -P FORWARD DROP
    sudo iptables -P OUTPUT ACCEPT

    # --- STEP 3: INPUT rules (Necessary exceptions for the Pi itself) ---
    sudo iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A INPUT -i lo -j ACCEPT
    sudo iptables -A INPUT -p icmp -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT # SSH
    sudo iptables -A INPUT -p udp --dport 53 -j ACCEPT # Pi-hole DNS
    sudo iptables -A INPUT -p tcp --dport 53 -j ACCEPT # Pi-hole DNS
    sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT # Pi-hole Web

    # --- STEP 4: MANGLE rules (Mark the specific traffic for the VPN) ---
    # CUSTOMIZE: Add the IP addresses of the clients that should use the VPN.
    CLIENT_IPS_TO_VPN="192.168.1.128 192.168.1.129 192.168.1.130"
    for ip in $CLIENT_IPS_TO_VPN; do
        echo "Adding MARK rule for $ip (TCP port 8080 only)"
        # CUSTOMIZE: Change the port number if you need something other than 8080.
        sudo iptables -t mangle -A PREROUTING -s "$ip" -p tcp --dport 8080 -j MARK --set-mark 1
    done

    # --- STEP 5: FORWARD rules (The correct logic for selective routing) ---
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # Rule 1: Allow marked traffic to exit through the VPN tunnel.
    sudo iptables -A FORWARD -i eth0 -o tun0 -m mark --mark 1 -j ACCEPT
    # Rule 2: Allow all other traffic from the LAN to exit through the regular route.
    sudo iptables -A FORWARD -i eth0 -o eth0 -j ACCEPT

    # --- STEP 6: NAT rules (Critical for both traffic types to work) ---
    sudo iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

    # --- STEP 7: Save the rules permanently ---
    sudo netfilter-persistent save
    echo "Firewall rules have been set and saved."

### 6. Create the main script `protonvpn-gateway.sh`

    # Download the main script from GitHub
    sudo wget -O /usr/local/bin/protonvpn-gateway.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-protonvpn-gateway/main/protonvpn-gateway.sh

    # Make it executable
    sudo chmod +x /usr/local/bin/protonvpn-gateway.sh

    # Open the file to customize your personal variables
    sudo nano /usr/local/bin/protonvpn-gateway.sh

### 7. Create the `systemd` Service

1.  Create the service file:
    
    sudo nano /etc/systemd/system/protonvpn-gateway.service
    
2.  Paste the content below:
    
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
    StandardOutput=file:/var/log/protonvpn-gateway.log
    StandardError=file:/var/log/protonvpn-gateway.log

    [Install]
    WantedBy=multi-user.target
    
3.  Enable the service:
    
    sudo systemctl daemon-reload
    sudo systemctl enable protonvpn-gateway.service
    sudo systemctl start protonvpn-gateway.service

### 8. Configure Your Router

Log into your router and make the following changes to the DHCP settings for your local network:
*   Set the **Default Gateway** to your Raspberry Pi's IP (e.g., `192.168.1.102`).
*   Set the **DNS Server** to your Raspberry Pi's IP (e.g., `192.168.1.102`).

Reboot the devices on your network for them to receive the new settings.

---

## Acknowledgements
This project is written and maintained by @Howard0000. An AI assistant helped simplify explanations, clean up the README, and refine the scripts. All suggestions were manually reviewed before implementation, and all configuration and testing were done by me.

## 📝 License
MIT — see the `LICENSE` file.

## 🔬 Testing and Verification

Use these commands to check that everything is working:

*   **Check service status:** `sudo systemctl status protonvpn-gateway.service`
*   **Watch the log live:** `tail -f /var/log/protonvpn-gateway.log`
*   **Check the VPN interface:** `ip addr show tun0`
*   **Check routing rules:** `ip rule show` and `ip route show table vpn_table`

### Verification Script

    # Download the verification script from GitHub
    wget https://raw.githubusercontent.com/Howard0000/raspberrypi-protonvpn-gateway/main/verify_traffic.sh
    chmod +x verify_traffic.sh
    sudo ./verify_traffic.sh
