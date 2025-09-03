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
*(This section is identical to the previous project)*
...

### 1. Install Pi-hole
*(This section is identical to the previous project)*
...

### 2. Enable IP Forwarding and `iptables-persistent`
*(This section is identical to the previous project)*
...

### 3. Install OpenVPN and Configure Proton VPN

This step sets up the VPN client itself and fetches the necessary files from Proton VPN.

1.  **Install OpenVPN:**
    ```bash
    sudo apt update && sudo apt install openvpn -y
    ```
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
        ```
        YOUR_OPENVPN_USERNAME
        YOUR_OPENVPN_PASSWORD
        ```
    *   Save the file (Ctrl+X, Y, Enter) and **secure it** so only root can read it:
        ```bash
        sudo chmod 600 /etc/openvpn/client/proton_auth.txt
        ```

### 4. Create a Custom Routing Table for the VPN

    echo "200 vpn_table" | sudo tee -a /etc/iproute2/rt_tables

### 5. Configure Firewall and Selective Routing

These `iptables` rules are nearly identical to the previous project but have been updated to use the generic VPN interface `tun0`.

    # --- STEP 1 ...
    # ... (paste your entire iptables block here) ...
    
    # Rule 1: Allow marked traffic to exit through the VPN tunnel.
    sudo iptables -A FORWARD -i eth0 -o tun0 -m mark --mark 1 -j ACCEPT
    # Rule 2: ...
    # ...
    # --- STEP 6 ...
    sudo iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    # ...
    
    # --- STEP 7 ...
    sudo netfilter-persistent save

### 6. Create the main script `protonvpn-gateway.sh`

    # Download the script from the NEW repository (remember to change the link when it's ready)
    sudo wget -O /usr/local/bin/protonvpn-gateway.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-protonvpn-gateway/main/protonvpn-gateway.sh

    # Make it executable
    sudo chmod +x /usr/local/bin/protonvpn-gateway.sh
    # Open and customize
    sudo nano /usr/local/bin/protonvpn-gateway.sh

### 7. Create the `systemd` Service

1.  Create the service file:
    ```bash
    sudo nano /etc/systemd/system/protonvpn-gateway.service
    ```
2.  Paste the content below (note the changes in `Description` and `ExecStart`):
    ```ini
    [Unit]
    Description=ProtonVPN Gateway Service
    After=network-online.target pihole-FTL.service
    Wants=network-online.target

    [Service]
    Type=simple
    User=root
    ExecStartPre=... # (This can be kept, it just checks the gateway)
    ExecStart=/usr/local/bin/protonvpn-gateway.sh
    Restart=always
    RestartSec=30
    StandardOutput=file:/var/log/protonvpn-gateway.log
    StandardError=file:/var/log/protonvpn-gateway.log

    [Install]
    WantedBy=multi-user.target
    ```
3.  Enable the service:
    ```bash
    sudo systemctl daemon-reload
    sudo systemctl enable protonvpn-gateway.service
    sudo systemctl start protonvpn-gateway.service
    ```

### 8. Configure Your Router
*(This section is identical to the previous project)*
...

### 9. Testing and Verification (Updated)

Use these commands to check that everything is working:

*   **Check service status:** `sudo systemctl status protonvpn-gateway.service`
*   **Watch the log live:** `tail -f /var/log/protonvpn-gateway.log`
*   **Check the VPN interface:** `ip addr show tun0` (look for an IP address)
*   **Check routing rules:** `ip rule show` and `ip route show table vpn_table`
