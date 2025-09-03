# Raspberry Pi: Pi-hole + ProtonVPN Gateway

> 🇳🇴 Norsk · 🇬🇧 [English version](README.en.md)

Dette prosjektet setter opp en Raspberry Pi som en kombinert DNS-filtreringsserver (Pi-hole) og en avansert VPN-gateway. Løsningen bruker den universelle OpenVPN-klienten, er testet med **Proton VPN (gratisversjon)**, og har funksjonalitet for **selektiv ruting**, som lar deg sende trafikk fra kun utvalgte enheter og/eller porter gjennom VPN-tunnelen.

Prosjektet inkluderer robust oppstart, selvreparerende logikk og overvåkning via `systemd` og MQTT.

---

## ✨ Nøkkelfunksjoner

*   **Selektiv Ruting:** Velg nøyaktig hvilke enheter (via IP) og porter som skal bruke VPN. All annen trafikk går via din vanlige internettforbindelse for maksimal hastighet.
*   **Universell OpenVPN-klient:** Bygget på den åpne standarden OpenVPN. Grundig testet med **Proton VPNs gratisversjon**.
*   **Pi-hole Integrasjon:** All DNS-trafikk håndteres av Pi-hole for nettverksdekkende annonse- og sporingsblokkering.
*   **Robust og Selvreparerende:** En `systemd`-tjeneste sørger for automatisk oppstart og omstart ved feil. Skriptet verifiserer aktivt at VPN-tilkoblingen fungerer og gjenoppretter den om nødvendig.
*   **Sikker Oppstart:** Tjenesten venter på at nettverket og ruteren er tilgjengelig før den starter.
*   **(Valgfritt) Home Assistant Integrasjon:** Send sanntidsdata om VPN-status og CPU-temperatur til din MQTT-broker.
*   **Enkel Feilsøking:** Inkluderer et verifiseringsskript for å se live at den selektive rutingen fungerer.

---

## 📦 Krav

*   Raspberry Pi 3, 4 eller 5 (kablet nettverk er sterkt anbefalt).
*   Raspberry Pi OS Lite (64-bit), Bookworm eller nyere.
*   En Proton VPN-konto (gratis eller betalt).
*   (Valgfritt) En MQTT-broker for Home Assistant-integrasjon.

---

## 🔧 Steg-for-steg-oppsett

### 0. Systemoppsett (Identisk med forrige prosjekt)
... *(behold denne delen som den er)* ...

### 1. Installer Pi-hole (Identisk med forrige prosjekt)
... *(behold denne delen som den er)* ...

### 2. Aktiver IP Forwarding og `iptables-persistent` (Identisk med forrige prosjekt)
... *(behold denne delen som den er)* ...

### 3. Installer OpenVPN og konfigurer Proton VPN

Dette steget setter opp selve VPN-klienten og henter de nødvendige filene fra Proton VPN.

1.  **Installer OpenVPN:**
    ```bash
    sudo apt update && sudo apt install openvpn -y
    ```
2.  **Opprett en gratis Proton VPN-konto** på [protonvpn.com](https://protonvpn.com).

3.  **Hent dine OpenVPN-credentials:**
    *   Logg inn på din Proton-konto.
    *   Naviger til **Konto -> OpenVPN / IKEv2 brukernavn**.
    *   Noter ned **Brukernavnet** og **Passordet** som vises her. **OBS:** Dette er *ikke* ditt vanlige Proton-passord.

4.  **Last ned en server-konfigurasjonsfil:**
    *   På samme side, naviger til **Nedlastinger -> OpenVPN-konfigurasjonsfiler**.
    *   Velg **Linux** som plattform og **UDP** som protokoll.
    *   Last ned en server-fil fra et av gratislandene (f.eks. Nederland, Japan eller USA).

5.  **Overfør filene til din Raspberry Pi:**
    *   Opprett en mappe for konfigurasjonen: `sudo mkdir -p /etc/openvpn/client`
    *   Overfør `.ovpn`-filen du lastet ned til denne mappen. Gi den et enkelt navn, f.eks.: `sudo mv din-nedlastede-fil.ovpn /etc/openvpn/client/proton.ovpn`
    *   Opprett en fil for dine credentials: `sudo nano /etc/openvpn/client/proton_auth.txt`
    *   Lim inn brukernavnet og passordet fra steg 3 på to separate linjer:
        ```
        DITT_OPENVPN_BRUKERNAVN
        DITT_OPENVPN_PASSORD
        ```
    *   Lagre filen (Ctrl+X, Y, Enter) og **sikre den** slik at kun root kan lese den:
        ```bash
        sudo chmod 600 /etc/openvpn/client/proton_auth.txt
        ```

### 4. Opprett egen routing-tabell for VPN

    echo "200 vpn_table" | sudo tee -a /etc/iproute2/rt_tables

### 5. Konfigurer Brannmur og Selektiv Ruting

Disse `iptables`-reglene er nesten identiske med forrige prosjekt, men er oppdatert til å bruke det generiske VPN-grensesnittet `tun0`.

    # --- STEG 1 ...
    # ... (lim inn hele iptables-blokken din her) ...
    
    # Regel 1: Tillat merket trafikk å gå ut VPN-tunnelen.
    sudo iptables -A FORWARD -i eth0 -o tun0 -m mark --mark 1 -j ACCEPT
    # Regel 2: ...
    # ...
    # --- STEG 6 ...
    sudo iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    # ...
    
    # --- STEG 7 ...
    sudo netfilter-persistent save

### 6. Opprett hovedskriptet `protonvpn-gateway.sh`

    # Last ned skriptet fra det NYE repoet (husk å endre linken når det er klart)
    sudo wget -O /usr/local/bin/protonvpn-gateway.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-protonvpn-gateway/main/protonvpn-gateway.sh

    # Gjør det kjørbart
    sudo chmod +x /usr/local/bin/protonvpn-gateway.sh
    # Åpne og tilpass
    sudo nano /usr/local/bin/protonvpn-gateway.sh

### 7. Opprett `systemd`-tjeneste

1.  Opprett tjenestefilen:
    ```bash
    sudo nano /etc/systemd/system/protonvpn-gateway.service
    ```
2.  Lim inn innholdet under (merk endringene i `Description` og `ExecStart`):
    ```ini
    [Unit]
    Description=ProtonVPN Gateway Service
    After=network-online.target pihole-FTL.service
    Wants=network-online.target

    [Service]
    Type=simple
    User=root
    ExecStartPre=... # (Denne kan beholdes, den sjekker bare gateway)
    ExecStart=/usr/local/bin/protonvpn-gateway.sh
    Restart=always
    RestartSec=30
    StandardOutput=file:/var/log/protonvpn-gateway.log
    StandardError=file:/var/log/protonvpn-gateway.log

    [Install]
    WantedBy=multi-user.target
    ```
3.  Aktiver tjenesten:
    ```bash
    sudo systemctl daemon-reload
    sudo systemctl enable protonvpn-gateway.service
    sudo systemctl start protonvpn-gateway.service
    ```

### 8. Konfigurer ruteren din (Identisk med forrige prosjekt)
... *(behold denne delen som den er)* ...

### 9. Testing og Verifisering (Oppdatert)

Bruk disse kommandoene for å sjekke at alt fungerer:

*   **Sjekk tjenestestatus:** `sudo systemctl status protonvpn-gateway.service`
*   **Se på loggen live:** `tail -f /var/log/protonvpn-gateway.log`
*   **Sjekk VPN-grensesnittet:** `ip addr show tun0` (se etter en IP-adresse)
*   **Sjekk rutingregler:** `ip rule show` og `ip route show table vpn_table`
