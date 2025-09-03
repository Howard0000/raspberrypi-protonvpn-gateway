#!/bin/bash

# ==============================================================================
# OpenVPN Gateway Script (for Proton VPN)
# ==============================================================================
# Dette scriptet administrerer en OpenVPN-tilkobling for en Raspberry Pi gateway.
# Det sikrer at VPN er tilkoblet, gjenoppretter tilkoblingen ved feil,
# og setter opp dynamisk ruting for trafikk som skal gå via VPN.
#
# ANSVAR:
# - Håndtere livssyklusen til OpenVPN-tilkoblingen.
# - Sikre at Pi-ens egen nettverkstilgang er korrekt.
# - Sette opp og vedlikeholde dynamiske IP-ruter for VPN-trafikk.
# - (Valgfritt) Sende status til en MQTT-broker.
# ==============================================================================

# --- Konfigurasjon ---
VPN_CHECK_HOST="1.1.1.1"         # Ping-mål for å sjekke generell internett-tilgang
VPN_ROBUST_CHECK="google.com"    # Ping-mål for å sjekke VPN-tilkobling (pinges via VPN-grensesnitt)
MAX_PING_RETRIES=12              # Antall forsøk for ping-sjekker (12 * 5s = 1 minutt)
RETRY_DELAY=5                    # Sekunder mellom ping-forsøk
CORRECT_GATEWAY="192.168.1.1"    # TILPASS: Din hovedrouters IP
VPN_TABLE="vpn_table"            # Navn på routing-tabell (må matche /etc/iproute2/rt_tables)
VPN_IFACE="tun0"                 # Grensesnittnavn for OpenVPN
LAN_IFACE="eth0"                 # Pi-ens fysiske LAN-grensesnitt
LOG_FILE="/var/log/protonvpn-gateway.log"
OPENVPN_LOG_FILE="/var/log/openvpn.log"

# --- OpenVPN Innstillinger ---
OPENVPN_CONFIG="/etc/openvpn/client/proton.ovpn"      # TILPASS: Sti til din .ovpn-fil
OPENVPN_AUTH="/etc/openvpn/client/proton_auth.txt" # TILPASS: Sti til din auth-fil

# --- MQTT Innstillinger ---
MQTT_ENABLED=true                # TILPASS: Sett til true hvis du bruker MQTT, ellers false
MQTT_BROKER="XXX.XXX.X.XXX"      # TILPASS: Din MQTT broker IP
MQTT_USER="XXXXXXX"              # TILPASS: MQTT bruker (kan være tom)
MQTT_PASS="XXXXXXXXXX"           # TILPASS: MQTT passord (kan være tom)
MQTT_CLIENT_ID="protonvpn_gateway_pi"
HA_DISCOVERY_PREFIX="homeassistant"

# --- Funksjoner ---

log_msg() {
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOG_FILE"
}

send_mqtt_ha_discovery() {
  if [ "$MQTT_ENABLED" = false ]; then return; fi
  if ! command -v mosquitto_pub &> /dev/null; then log_msg "ADVARSEL: mosquitto_pub ikke funnet."; return; fi

  local DEVICE_JSON='{ "identifiers": ["protonvpn_gateway_pi_device"], "name": "ProtonVPN Gateway", "model": "Raspberry Pi", "manufacturer": "Custom Script" }'
  local MQTT_AUTH_ARGS=()
  [[ -n "$MQTT_USER" ]] && MQTT_AUTH_ARGS+=(-u "$MQTT_USER")
  [[ -n "$MQTT_PASS" ]] && MQTT_AUTH_ARGS+=(-P "$MQTT_PASS")

  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "$HA_DISCOVERY_PREFIX/sensor/protonvpn_gateway_pi/status/config" \
  -m "{ \"name\": \"ProtonVPN Status\", \"state_topic\": \"protonvpn/gateway/status\", \"unique_id\": \"protonvpn_gateway_pi_status\", \"icon\": \"mdi:vpn\", \"device\": $DEVICE_JSON }"
  
  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "$HA_DISCOVERY_PREFIX/sensor/protonvpn_gateway_pi/last_seen/config" \
  -m "{ \"name\": \"ProtonVPN Sist Sett\", \"state_topic\": \"protonvpn/gateway/last_seen\", \"unique_id\": \"protonvpn_gateway_pi_last_seen\", \"icon\": \"mdi:clock-outline\", \"device\": $DEVICE_JSON }"

  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "$HA_DISCOVERY_PREFIX/sensor/protonvpn_gateway_pi/cpu_temp/config" \
  -m "{ \"name\": \"ProtonVPN Gateway CPU Temperatur\", \"state_topic\": \"protonvpn/gateway/cpu_temp\", \"unique_id\": \"protonvpn_gateway_pi_cpu_temp\", \"icon\": \"mdi:thermometer\", \"device_class\": \"temperature\", \"unit_of_measurement\": \"°C\", \"device\": $DEVICE_JSON }"
}

send_mqtt_status() {
  if [ "$MQTT_ENABLED" = false ]; then return; fi
  if ! command -v mosquitto_pub &> /dev/null; then return; fi

  local status_message="$1"
  local MQTT_AUTH_ARGS=()
  [[ -n "$MQTT_USER" ]] && MQTT_AUTH_ARGS+=(-u "$MQTT_USER")
  [[ -n "$MQTT_PASS" ]] && MQTT_AUTH_ARGS+=(-P "$MQTT_PASS")

  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "protonvpn/gateway/status" -m "$status_message"
  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "protonvpn/gateway/last_seen" -m "$(date +'%Y-%m-%d %H:%M:%S')"
}

# (Funksjonene send_cpu_temp, setup_vpn_routing_rules, og check_internet_robust kan gjenbrukes nesten som de er)

send_cpu_temp() {
  # Denne funksjonen er identisk med NordVPN-versjonen.
}

setup_vpn_routing_rules() {
  log_msg "Setter opp dynamiske rutingregler for tabell $VPN_TABLE..."
  if ! sudo ip rule show | grep -q "fwmark 0x1 lookup $VPN_TABLE"; then
    sudo ip rule add fwmark 1 table "$VPN_TABLE"
    log_msg "Lagt til: ip rule add fwmark 1 table $VPN_TABLE"
  else
    log_msg "Regel 'fwmark 0x1 lookup $VPN_TABLE' eksisterer allerede."
  fi

  sudo ip route replace default dev "$VPN_IFACE" table "$VPN_TABLE"
  log_msg "Satt/erstattet: ip route replace default dev $VPN_IFACE table $VPN_TABLE"
  sudo ip route flush cache
  log_msg "Ruting-cache tømt."
}

check_internet_robust() {
  # Denne funksjonen er identisk med NordVPN-versjonen.
}

disconnect_vpn() {
    log_msg "Stopper alle OpenVPN-prosesser..."
    sudo killall openvpn
    sleep 2
    send_mqtt_status "VPN Frakoblet"
}

connect_vpn() {
  log_msg "Starter prosessen for å koble til OpenVPN..."
  send_mqtt_status "Starter VPN tilkobling..."

  if ip addr show "$VPN_IFACE" &>/dev/null; then
    log_msg "VPN-grensesnitt ($VPN_IFACE) er allerede oppe. Sikrer rutingregler."
    setup_vpn_routing_rules
    send_mqtt_status "VPN Allerede Tilkoblet"
    return 0
  fi

  if ! check_internet_robust "$VPN_CHECK_HOST" "$LAN_IFACE"; then
    log_msg "Ingen generell internettilgang (via $LAN_IFACE). Kan ikke koble til VPN nå. Venter..."
    send_mqtt_status "Venter på nett ($LAN_IFACE)"
    return 1
  fi
  log_msg "Generell internettilgang (via $LAN_IFACE) er OK."

  log_msg "Kobler til OpenVPN i bakgrunnen... Sjekk $OPENVPN_LOG_FILE for detaljer."
  sudo openvpn --daemon --config "$OPENVPN_CONFIG" --auth-user-pass "$OPENVPN_AUTH" --log "$OPENVPN_LOG_FILE"
  
  log_msg "Venter 15 sekunder for at tilkoblingen skal etableres..."
  sleep 15

  if ! ip addr show "$VPN_IFACE" &>/dev/null; then
    log_msg "KRITISK: Klarte ikke å etablere VPN-tilkobling etter 15 sekunder."
    send_mqtt_status "VPN tilkobling feilet"
    disconnect_vpn
    return 1
  fi

  log_msg "OpenVPN tilkoblet og $VPN_IFACE er oppe."
  setup_vpn_routing_rules
  send_mqtt_status "VPN Tilkoblet"
  return 0
}

# --- Hovedlogikk ---

trap 'log_msg "Script stoppet. Kobler fra VPN..."; disconnect_vpn; exit 0' SIGINT SIGTERM

log_msg "--- ProtonVPN Gateway script starter (PID: $$) ---"
sudo touch "$LOG_FILE" && sudo chmod 644 "$LOG_FILE"
sudo touch "$OPENVPN_LOG_FILE" && sudo chmod 644 "$OPENVPN_LOG_FILE"

# (Den selvreparerende logikken for Pi-ens egen gateway er identisk)

send_mqtt_ha_discovery
connect_vpn

log_msg "Starter kontinuerlig overvåkningsløkke..."
while true; do
  if ip addr show "$VPN_IFACE" &>/dev/null; then
    if check_internet_robust "$VPN_ROBUST_CHECK" "$VPN_IFACE"; then
      send_mqtt_status "VPN OK"
    else
      log_msg "VPN-grensesnitt er oppe, men kan ikke pinge gjennom $VPN_IFACE. Prøver å koble til på nytt."
      send_mqtt_status "VPN test feilet"
      disconnect_vpn
      sleep 5
      connect_vpn
    fi
  else
    log_msg "VPN er frakoblet. Forsøker å koble til..."
    send_mqtt_status "VPN Frakoblet"
    connect_vpn
  fi
  # send_cpu_temp
  sleep 60
done
