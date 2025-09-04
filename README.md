# Raspberry Pi: Pi-hole + ProtonVPN Gateway

🇳🇴 [Norsk](README.md) · 🇬🇧 [English](README.en.md)

Dette prosjektet setter opp en Raspberry Pi som en kombinert DNS-filtreringsserver (Pi-hole) og ProtonVPN-gateway med selektiv ruting basert på IP og/eller porter. Det inkluderer robust oppstart og overvåkning via MQTT og systemd.

---

## 🧭 Mål

- Raspberry Pi med statisk IP-adresse.
- Pi-hole for lokal DNS-blokkering på hele nettverket.
- ProtonVPN-tilkobling via OpenVPN for trafikk fra utvalgte enheter og/eller porter.
- Automatisk gjenoppretting av VPN-tilkobling ved ruter-/nettverksfeil.
- (Valgfritt) Integrasjon med Home Assistant via MQTT for overvåkning.

---

## 📦 Krav

- Raspberry Pi 3, 4 eller 5 (kablet nettverk er sterkt anbefalt).
- Raspberry Pi OS Lite (64-bit), Bookworm eller nyere.
- ProtonVPN-konto.
- MQTT-broker (valgfritt, kun for Home Assistant-integrasjon).

---

## ⚠️ Viktig før du starter
- **IPv6**: Oppsettet er IPv4-basert. Hvis du har IPv6 aktivt i nettverket ditt, kan trafikk lekke utenom VPN. Slå av IPv6 på Pi og klientene dine, eller legg til tilsvarende IPv6-regler.  
- **CORRECT_GATEWAY**: I `protonvpn-gateway.sh` må du sette variabelen `CORRECT_GATEWAY` til IP-adressen til din egen ruter (f.eks. `192.168.1.1`).  
- **CPU-temp**: Publisering av CPU-temperatur til MQTT er **av som standard** (`ENABLE_CPU_TEMP=false`). Skru på om du vil bruke den.

---

## 🔧 Steg-for-steg-oppsett

1. Installer Raspberry Pi OS Lite (64-bit).
2. Koble til via SSH.
3. Oppdater systemet:

   ```bash
   sudo apt update && sudo apt full-upgrade -y
   sudo reboot
   ```
4. **Sett statisk IP-adresse:**
   På nyere versjoner av Raspberry Pi OS (Bookworm og nyere) brukes NetworkManager. Følgende kommandoer setter statisk IP. **Tilpass IP-adresser til ditt eget nettverk.**

   ```bash
   # Bytt ut "Wired connection 1" med navnet på din tilkobling om nødvendig (sjekk med 'nmcli con show')
   # Bytt ut IP-adresser, gateway (din ruters IP) og DNS-servere
   sudo nmcli con mod "Wired connection 1" ipv4.method manual
   sudo nmcli con mod "Wired connection 1" ipv4.addresses 192.168.1.102/24
   sudo nmcli con mod "Wired connection 1" ipv4.gateway 192.168.1.1
   sudo nmcli con mod "Wired connection 1" ipv4.dns "1.1.1.1,8.8.8.8"

   # Aktiver endringene
   sudo nmcli con up "Wired connection 1"
   ```

   Etter endringene, ta en omstart for å være sikker på at alt er i orden:

   ```bash
   sudo reboot
   ```

> ℹ️ På eldre images uten NetworkManager kan du bruke `dhcpcd.conf` eller `systemd-networkd` i stedet.

---

### 1. Installer Pi-hole

```bash
curl -sSL https://install.pi-hole.net | bash
```

Følg instruksjonene. Velg eth0 som grensesnitt og velg en upstream DNS-provider (f.eks. Cloudflare eller Google). Noter ned administratorpassordet.

### 2. Installer iptables-persistent og aktiver IP forwarding

```bash
sudo apt install iptables-persistent -y
```

Rediger `/etc/sysctl.conf` og sørg for at følgende linje er aktiv:

```ini
net.ipv4.ip_forward=1
```

Aktiver:

```bash
sudo sysctl -p
```

### 3. Installer og konfigurer ProtonVPN (OpenVPN)

Følg ProtonVPNs dokumentasjon og last ned `.ovpn`-konfigurasjon + auth-fil. Plasser disse i `/etc/openvpn/client/`.

### 4. Opprett egen routing-tabell for VPN

```bash
grep -qE '^\s*200\s+vpn_table\b' /etc/iproute2/rt_tables || \
  echo "200 vpn_table" | sudo tee -a /etc/iproute2/rt_tables
```

### 5. Konfigurer Brannmur og Selektiv Ruting (iptables)

```bash
# --- STEG 1: Tøm alt for en ren start ---
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
sudo iptables -X && sudo iptables -t nat -X && sudo iptables -t mangle -X

# --- STEG 2: Sett en sikker standard policy ---
# ⚠️ Sørg for at SSH-regelen er lagt inn før du setter INPUT DROP!
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT

# --- STEG 3: INPUT-regler ---
sudo iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A INPUT -p icmp -j ACCEPT
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 22 -j ACCEPT # SSH
sudo iptables -A INPUT -s 192.168.1.0/24 -p udp --dport 53 -j ACCEPT # Pi-hole DNS
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 53 -j ACCEPT # Pi-hole DNS
sudo iptables -A INPUT -s 192.168.1.0/24 -p tcp --dport 80 -j ACCEPT # Pi-hole Web

# --- STEG 4: MANGLE-regler (Merk trafikk for VPN) ---
CLIENT_IPS_TO_VPN="192.168.1.128 192.168.1.129 192.168.1.130 192.168.1.131"
for ip in $CLIENT_IPS_TO_VPN; do
    sudo iptables -t mangle -A PREROUTING -s "$ip" -p tcp --dport 8080 -j MARK --set-mark 1
    echo "Regel lagt til for $ip"
done

> 💡 Tilpass listen i `CLIENT_IPS_TO_VPN` med de klientene du ønsker skal bruke VPN.  
> Du kan også endre port (`--dport 8080`) om du vil merke trafikk på andre porter.

# --- STEG 5: FORWARD-regler ---
sudo iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o tun0 -m mark --mark 1 -j ACCEPT
sudo iptables -A FORWARD -i eth0 -o eth0 -j ACCEPT

# --- STEG 6: NAT-regler ---
sudo iptables -t nat -A POSTROUTING -o tun0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Merk: MASQUERADE på eth0 trengs kun hvis Pi ruter mellom subnett. På et enkelt LAN kan den fjernes.

# --- STEG 7: Lagre ---
sudo netfilter-persistent save
```

### 6. Last ned og tilpass hovedskriptet

```bash
# Last ned hovedskriptet fra GitHub
sudo wget -O /usr/local/bin/protonvpn-gateway.sh https://raw.githubusercontent.com/Howard0000/raspberrypi-protonvpn-gateway/main/protonvpn-gateway.sh

# Gjør det kjørbart
sudo chmod +x /usr/local/bin/protonvpn-gateway.sh

# Åpne filen for å tilpasse dine personlige variabler
sudo nano /usr/local/bin/protonvpn-gateway.sh
```

### 7. Opprett systemd-tjeneste

Opprett tjenestefilen:

```bash
sudo nano /etc/systemd/system/protonvpn-gateway.service
```

Lim inn innholdet under (justert for journald-logging, eller bruk fil-logging hvis du heller vil ha en loggfil):

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
# Logger til journald; se logg med: journalctl -u protonvpn-gateway -f
# (Hvis du heller vil ha fil: bruk StandardOutput/StandardError til /var/log/protonvpn-gateway.log)

[Install]
WantedBy=multi-user.target
```

Aktiver tjenesten:

```bash
sudo systemctl daemon-reload
sudo systemctl enable protonvpn-gateway.service
sudo systemctl start protonvpn-gateway.service
```

---

### 8. Konfigurer ruteren din

Logg inn på ruteren din og gjør følgende endringer i DHCP-innstillingene for ditt lokale nettverk:

* Sett **Default Gateway** til din Raspberry Pi sin IP (f.eks. `192.168.1.102`).
* Sett **DNS Server** til samme Raspberry Pi IP (f.eks. `192.168.1.102`).

Deretter: start enhetene på nettverket ditt på nytt slik at de får de nye innstillingene.

---

### 9. Testing og Verifisering

* Status på tjenesten: `sudo systemctl status protonvpn-gateway.service`
* Logg: `journalctl -u protonvpn-gateway -f`
* Sjekk ruting: `ip rule show`, `ip route show table vpn_table`
* Installer tcpdump (kreves for verify-scriptet):  
  ```bash
  sudo apt install tcpdump

Last ned og kjør verifiseringsskriptet for å bekrefte at selektiv ruting fungerer:

```bash
wget https://raw.githubusercontent.com/Howard0000/raspberrypi-protonvpn-gateway/main/verify_traffic.sh
chmod +x verify_traffic.sh
sudo ./verify_traffic.sh
```

> Du kan tilpasse `verify_traffic.sh` ved å endre tre variabler i toppen:
>
> ```
> PORT=8080
> IFACE="tun0"
> PROTO="tcp"
> ```
>
> Eksempel: `wg0` + UDP 51820 for WireGuard.

---

## 💾 Backup og Vedlikehold

- Ta backup av: `/etc/iptables/rules.v4`, `protonvpn-gateway.sh`, og systemd-unit-filen.
- Hvis du bruker fil-logging (`/var/log/protonvpn-gateway.log` og `/var/log/openvpn.log`), anbefales å sette opp `logrotate` slik at loggene ikke vokser uendelig.

---

## 📡 MQTT og Home Assistant

MQTT er **av** som standard (`MQTT_ENABLED=false`).  
Sett til `true` og fyll inn broker/bruker/passord i `protonvpn-gateway.sh` for å aktivere.  
CPU-temperatur-sensor (`ENABLE_CPU_TEMP`) er også av som standard.

---

## 🙌 Anerkjennelser

Prosjektet er skrevet og vedlikeholdt av @Howard0000. En KI-assistent har hjulpet til med å forenkle forklaringer, rydde i README-en og pusse på skript. Alle forslag er manuelt vurdert før de ble tatt inn, og all konfigurasjon og testing er gjort av meg.

---

## 📝 Lisens

MIT — se LICENSE.
