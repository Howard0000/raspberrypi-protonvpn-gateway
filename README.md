# Raspberry Pi: Pi-hole + ProtonVPN Gateway

> 🇳🇴 Norsk · 🇬🇧 [English version](README.en.md)

Dette prosjektet setter opp en Raspberry Pi som en kombinert DNS-filtreringsserver (Pi-hole) og en avansert Proton VPN-gateway. Løsningen bruker den offisielle Proton VPN-klienten med OpenVPN-protokollen og har funksjonalitet for **selektiv ruting**, som lar deg sende trafikk fra kun utvalgte enheter og/eller porter gjennom VPN-tunnelen.

Prosjektet inkluderer robust oppstart, selvreparerende logikk og overvåkning via `systemd` og MQTT.

---

## ✨ Nøkkelfunksjoner

*   **Selektiv Ruting:** Velg nøyaktig hvilke enheter (via IP) og porter som skal bruke VPN. All annen trafikk går via din vanlige internettforbindelse for maksimal hastighet.
*   **Offisiell NordVPN-klient:** Bruker den raske og sikre **NordLynx**-protokollen (WireGuard) for optimal ytelse.
*   **Pi-hole Integrasjon:** All DNS-trafikk håndteres av Pi-hole for nettverksdekkende annonse- og sporingsblokkering.
*   **Robust og Selvreparerende:** En `systemd`-tjeneste sørger for automatisk oppstart og omstart ved feil. Skriptet verifiserer aktivt at VPN-tilkoblingen fungerer og gjenoppretter den om nødvendig.
*   **Sikker Oppstart:** Tjenesten venter på at nettverket og ruteren er tilgjengelig før den starter, for å unngå feiltilstander etter en omstart.
*   **(Valgfritt) Home Assistant Integrasjon:** Send sanntidsdata om VPN-status, tilkoblet server og CPU-temperatur til din MQTT-broker for full overvåkning.
*   **Enkel Feilsøking:** Inkluderer et verifiseringsskript for å se live at den selektive rutingen fungerer som forventet.

---

## 📦 Krav

*   Raspberry Pi 3, 4 eller 5 (kablet nettverk er sterkt anbefalt).
*   Raspberry Pi OS Lite (64-bit), Bookworm eller nyere.
*   En aktiv NordVPN-konto.
*   (Valgfritt) En MQTT-broker for Home Assistant-integrasjon.

---

## 🔧 Steg-for-steg-oppsett

### 0. Systemoppsett

1.  Installer Raspberry Pi OS Lite (64-bit).
2.  Koble til via SSH.
3.  Oppdater systemet:
    
    sudo apt update && sudo apt full-upgrade -y
    sudo reboot
    
4.  **Sett statisk IP-adresse:**
    På nyere versjoner av Raspberry Pi OS brukes NetworkManager. **Tilpass IP-adresser til ditt eget nettverk.**

    # Bytt ut "Wired connection 1" med navnet på din tilkobling (sjekk med 'nmcli con show')
    # Bytt ut IP-adresser, gateway (din ruters IP) og DNS-servere
    sudo nmcli con mod "Wired connection 1" ipv4.method manual
    sudo nmcli con mod "Wired connection 1" ipv4.addresses 192.168.1.102/24
    sudo nmcli con mod "Wired connection 1" ipv4.gateway 192.168.1.1
    sudo nmcli con mod "Wired connection 1" ipv4.dns "1.1.1.1,8.8.8.8"
    
    # Aktiver endringene
    sudo nmcli con up "Wired connection 1"
    sudo reboot

### 1. Installer Pi-hole

    curl -sSL https://install.pi-hole.net | bash

Følg instruksjonene. Velg `eth0` som grensesnitt og velg en upstream DNS-provider (f.eks. Cloudflare). Noter ned administratorpassordet.

### 2. Aktiver IP Forwarding og installer `iptables-persistent`

Dette lar Pi-en videresende trafikk og sørger for at brannmurreglene overlever en omstart.

    sudo apt install iptables-persistent -y

Aktiver IP forwarding ved å redigere `/etc/sysctl.conf`:

    sudo nano /etc/sysctl.conf

Finn linjen `#net.ipv4.ip_forward=1` og fjern `#` foran. Lagre filen (Ctrl+X, Y, Enter) og aktiver endringen:

    sudo sysctl -p

### 3. Installer og konfigurer NordVPN

Installer den offisielle NordVPN-klienten:

    sh <(curl -sSf https://downloads.nordcdn.com/apps/linux/install.sh)

Gi din bruker tilgang til NordVPN og start på nytt:

    sudo usmod -aG nordvpn $USER
    sudo reboot

Etter omstart, logg inn og konfigurer klienten. Vi deaktiverer alle funksjoner som kan forstyrre vår manuelle ruting:
    
    nordvpn login
    nordvpn set killswitch disabled
    nordvpn set dns off
    nordvpn set autoconnect disabled
    nordvpn set firewall disabled
    nordvpn set routing disabled
    nordvpn set technology NordLynx
    nordvpn set analytics disabled

### 4. Opprett egen routing-tabell for VPN

    echo "200 nordvpntabell" | sudo tee -a /etc/iproute2/rt_tables

### 5. Konfigurer Brannmur og Selektiv Ruting

Disse `iptables`-reglene setter opp en sikker brannmur og implementerer den selektive rutingen.

    # --- STEG 1: Tøm alt for en ren start ---
    sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
    sudo iptables -X && sudo iptables -t nat -X && sudo iptables -t mangle -X

    # --- STEG 2: Sett en sikker standard policy ---
    sudo iptables -P INPUT DROP
    sudo iptables -P FORWARD DROP
    sudo iptables -P OUTPUT ACCEPT

    # --- STEG 3: INPUT-regler (Nødvendige unntak for Pi-en selv) ---
    sudo iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A INPUT -i lo -j ACCEPT
    sudo iptables -A INPUT -p icmp -j ACCEPT
    sudo iptables -A INPUT -p tcp --dport 22 -j ACCEPT # SSH
    sudo iptables -A INPUT -p udp --dport 53 -j ACCEPT # Pi-hole DNS
    sudo iptables -A INPUT -p tcp --dport 53 -j ACCEPT # Pi-hole DNS
    sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT # Pi-hole Web

    # --- STEG 4: MANGLE-regler (Marker den spesifikke trafikken for VPN) ---
    # TILPASS: Legg til IP-adressene til klientene som skal bruke VPN.
    CLIENT_IPS_TO_VPN="192.168.1.128 192.168.1.129 192.168.1.130"
    for ip in $CLIENT_IPS_TO_VPN; do
        echo "Legger til MARK-regel for $ip (kun TCP port 8080)"
        # TILPASS: Endre portnummeret hvis du trenger noe annet enn 8080.
        sudo iptables -t mangle -A PREROUTING -s "$ip" -p tcp --dport 8080 -j MARK --set-mark 1
    done

    # --- STEG 5: FORWARD-regler (Korrekt logikk for selektiv ruting) ---
    sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # Regel 1: Tillat merket trafikk å gå ut VPN-tunnelen.
    sudo iptables -A FORWARD -i eth0 -o nordlynx -m mark --mark 1 -j ACCEPT
    # Regel 2: Tillat all annen trafikk fra LAN å gå ut den vanlige veien.
    sudo iptables -A FORWARD -i eth0 -o eth0 -j ACCEPT

    # --- STEG 6: NAT-regler (Kritisk for at begge trafikktyper skal virke) ---
    sudo iptables -t nat -A POSTROUTING -o nordlynx -j MASQUERADE
    sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

    # --- STEG 7: Lagre reglene permanent ---
    sudo netfilter-persistent save
    echo "Brannmurregler er satt og lagret."

### 6. Opprett hovedskriptet `nordvpn-gateway.sh`

I stedet for å lime inn skriptet her, kan brukere nå laste det ned direkte fra repositoriet.

    # Last ned skriptet fra GitHub (husk å endre brukernavn/repo hvis nødvendig)
    sudo wget -O /usr/local/bin/nordvpn-gateway.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-nordvpn-gateway/main/nordvpn-gateway.sh

    # Gjør det kjørbart
    sudo chmod +x /usr/local/bin/nordvpn-gateway.sh

    # Åpne filen for å tilpasse dine personlige variabler (spesielt MQTT)
    sudo nano /usr/local/bin/nordvpn-gateway.sh

### 7. Opprett `systemd`-tjeneste

Dette sikrer at skriptet starter automatisk.

1.  Opprett tjenestefilen:
    
    sudo nano /etc/systemd/system/nordvpn-gateway.service
    
2.  Lim inn innholdet under:
    
    [Unit]
    Description=NordVPN Gateway Service
    After=network-online.target pihole-FTL.service
    Wants=network-online.target

    [Service]
    Type=simple
    User=root

    # Venter til den kan pinge gatewayen før hovedscriptet starter.
    ExecStartPre=/bin/bash -c 'GATEWAY_IP=$(grep -oP "CORRECT_GATEWAY=\K\S+" /usr/local/bin/nordvpn-gateway.sh | tr -d "\""); echo "Venter på at gateway ($GATEWAY_IP) skal svare..."; while ! ping -c 1 -W 2 $GATEWAY_IP &>/dev/null; do sleep 5; done; echo "Gateway svarer, starter hovedscript."'

    ExecStart=/usr/local/bin/nordvpn-gateway.sh

    Restart=always
    RestartSec=30

    StandardOutput=file:/var/log/nordvpn-gateway.log
    StandardError=file:/var/log/nordvpn-gateway.log

    [Install]
    WantedBy=multi-user.target
    
3.  Lagre og lukk filen.
4.  Aktiver og start tjenesten:
    
    sudo systemctl daemon-reload
    sudo systemctl enable nordvpn-gateway.service
    sudo systemctl start nordvpn-gateway.service

### 8. Konfigurer ruteren din

Logg inn på ruteren din og gjør følgende endringer i DHCP-innstillingene for ditt lokale nettverk:
*   Sett **Default Gateway** til din Raspberry Pis IP (f.eks. `192.168.1.102`).
*   Sett **DNS Server** til din Raspberry Pis IP (f.eks. `192.168.1.102`).

Start enhetene på nettverket ditt på nytt for at de skal få de nye innstillingene.

---

## Anerkjennelser
Prosjektet er skrevet og vedlikeholdt av @Howard0000. En KI-assistent har hjulpet til med å forenkle forklaringer, rydde i README-en og pusse på skript. Alle forslag er manuelt vurdert før de ble tatt inn, og all konfigurasjon og testing er gjort av meg.


## 📝 Lisens
MIT — se `LICENSE`.


## 🔬 Testing og Verifisering

Bruk disse kommandoene for å sjekke at alt fungerer:

*   **Sjekk tjenestestatus:** `sudo systemctl status nordvpn-gateway.service`
*   **Se på loggen live:** `tail -f /var/log/nordvpn-gateway.log`
*   **Sjekk VPN-status:** `nordvpn status`
*   **Sjekk rutingregler:** `ip rule show` og `ip route show table nordvpntabell`

### Verifiseringsskript

For å få et endelig bevis på at den selektive rutingen fungerer, last ned og kjør `verify_traffic.sh` fra dette repositoriet.

    wget https://raw.githubusercontent.com/Howard0000/raspberrypi-nordvpn-gateway/main/verify_traffic.sh
    chmod +x verify_traffic.sh
    sudo ./verify_traffic.sh
