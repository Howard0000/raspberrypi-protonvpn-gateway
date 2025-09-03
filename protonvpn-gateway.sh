#!/bin/bash

# ==============================================================================
# NordVPN Gateway Script
# ==============================================================================
# Dette scriptet administrerer NordVPN-tilkoblingen for en Raspberry Pi gateway.
# Det sikrer at VPN er tilkoblet, gjenoppretter tilkoblingen ved feil,
# og setter opp dynamisk ruting for trafikk som skal gå via VPN.
#
# ANSVAR:
# - Håndtere livssyklusen til NordVPN-tilkoblingen.
# - Sikre at Pi-ens egen nettverkstilgang er korrekt.
# - Sette opp og vedlikeholde dynamiske IP-ruter for VPN-trafikk.
# - (Valgfritt) Sende status til en MQTT-broker.
#
# FORUTSETNINGER:
# - Statiske brannmurregler (iptables MARK, MASQUERADE etc.) settes
#   og lagres ved hjelp av `iptables-persistent` som en del av
#   systemoppsettet (se README).
# ==============================================================================

# --- Konfigurasjon ---
VPN_CHECK_HOST="1.1.1.1"         # Ping-mål for å sjekke generell internett-tilgang
NORDVPN_HOST_CHECK="nordvpn.com" # Ping-mål for å sjekke VPN-tilkobling (pinges via VPN-grensesnitt)
MAX_PING_RETRIES=12              # Antall forsøk for ping-sjekker (12 * 5s = 1 minutt)
RETRY_DELAY=5                    # Sekunder mellom ping-forsøk
CORRECT_GATEWAY="192.168.1.1"    # TILPASS: Din hovedrouters IP
VPN_TABLE="nordvpntabell"        # Navn på routing-tabell (må matche /etc/iproute2/rt_tables)
VPN_IFACE="nordlynx"             # Grensesnittnavn for NordLynx
LAN_IFACE="eth0"                 # Pi-ens fysiske LAN-grensesnitt
LOG_FILE="/var/log/nordvpn-gateway.log"

# NordVPN tilkoblingspreferanse
NORDVPN_CONNECT_TARGET="Norway"  # TILPASS: Land, by, gruppe (f.eks. P2P), eller spesifikk server.
                                 # La stå tom ("") for å la NordVPN velge beste server.
# MQTT Innstillinger
MQTT_ENABLED=true                # TILPASS: Sett til true hvis du bruker MQTT, ellers false
MQTT_BROKER="XXX.XXX.X.XXX"      # TILPASS: Din MQTT broker IP
MQTT_USER="XXXXXXX"              # TILPASS: MQTT bruker (kan være tom)
MQTT_PASS="XXXXXXXXXX"           # TILPASS: MQTT passord (kan være tom)
MQTT_CLIENT_ID="nordvpn_gateway_pi"
HA_DISCOVERY_PREFIX="homeassistant"

# --- Funksjoner ---

log_msg() {
  # Sender melding til både stdout og loggfilen.
  echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOG_FILE"
}

send_mqtt_ha_discovery() {
  if [ "$MQTT_ENABLED" = false ]; then return; fi
  if ! command -v mosquitto_pub &> /dev/null; then log_msg "ADVARSEL: mosquitto_pub ikke funnet. Kan ikke sende HA discovery."; return; fi

  local DEVICE_JSON='{ "identifiers": ["nordvpn_gateway_pi_device"], "name": "NordVPN Gateway", "model": "Raspberry Pi", "manufacturer": "Custom Script" }'
  local MQTT_AUTH_ARGS=()
  [[ -n "$MQTT_USER" ]] && MQTT_AUTH_ARGS+=(-u "$MQTT_USER")
  [[ -n "$MQTT_PASS" ]] && MQTT_AUTH_ARGS+=(-P "$MQTT_PASS")

  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "$HA_DISCOVERY_PREFIX/sensor/nordvpn_gateway_pi/status/config" \
  -m "{ \"name\": \"NordVPN Status\", \"state_topic\": \"nordvpn/gateway/status\", \"unique_id\": \"nordvpn_gateway_pi_status\", \"icon\": \"mdi:vpn\", \"device\": $DEVICE_JSON }"

  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "$HA_DISCOVERY_PREFIX/sensor/nordvpn_gateway_pi/server/config" \
  -m "{ \"name\": \"NordVPN Server\", \"state_topic\": \"nordvpn/gateway/server\", \"unique_id\": \"nordvpn_gateway_pi_server\", \"icon\": \"mdi:server-network\", \"device\": $DEVICE_JSON }"

  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "$HA_DISCOVERY_PREFIX/sensor/nordvpn_gateway_pi/last_seen/config" \
  -m "{ \"name\": \"NordVPN Sist Sett\", \"state_topic\": \"nordvpn/gateway/last_seen\", \"unique_id\": \"nordvpn_gateway_pi_last_seen\", \"icon\": \"mdi:clock-outline\", \"device\": $DEVICE_JSON }"

   mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "$HA_DISCOVERY_PREFIX/sensor/nordvpn_gateway_pi/cpu_temp/config" \
  -m "{ \"name\": \"NordVPN Gateway Pi CPU Temperatur\", \"state_topic\": \"nordvpn/gateway/cpu_temp\", \"unique_id\": \"nordvpn_gateway_pi_cpu_temp\", \"icon\": \"mdi:thermometer\", \"device_class\": \"temperature\", \"unit_of_measurement\": \"°C\", \"device\": $DEVICE_JSON }"
}

send_mqtt_status() {
  if [ "$MQTT_ENABLED" = false ]; then return; fi
  if ! command -v mosquitto_pub &> /dev/null; then log_msg "ADVARSEL: mosquitto_pub ikke funnet."; return; fi

  local status_message="$1"
  local server_name
  server_name=$(nordvpn status | awk -F': ' '/Server:/ {print $2}')
  [[ -z "$server_name" ]] && server_name="N/A"

  local MQTT_AUTH_ARGS=()
  [[ -n "$MQTT_USER" ]] && MQTT_AUTH_ARGS+=(-u "$MQTT_USER")
  [[ -n "$MQTT_PASS" ]] && MQTT_AUTH_ARGS+=(-P "$MQTT_PASS")

  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "nordvpn/gateway/status" -m "$status_message"
  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "nordvpn/gateway/last_seen" -m "$(date +'%Y-%m-%d %H:%M:%S')"
  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -r -t "nordvpn/gateway/server" -m "$server_name"
}

send_cpu_temp() {
  if [ "$MQTT_ENABLED" = false ]; then return; fi
  if ! command -v vcgencmd &> /dev/null; then return; fi # Finnes ikke på alle systemer

  local cpu_temp_raw
  local cpu_temp
  cpu_temp_raw=$(vcgencmd measure_temp)
  cpu_temp=$(echo "$cpu_temp_raw" | egrep -o '[0-9.]+')

  if [[ -n "$cpu_temp" ]]; then
      local MQTT_AUTH_ARGS=()
      [[ -n "$MQTT_USER" ]] && MQTT_AUTH_ARGS+=(-u "$MQTT_USER")
      [[ -n "$MQTT_PASS" ]] && MQTT_AUTH_ARGS+=(-P "$MQTT_PASS")
      mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${MQTT_AUTH_ARGS[@]}" -t "nordvpn/gateway/cpu_temp" -m "$cpu_temp"
  fi
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
  local host_to_ping="$1"
  local interface_to_use="$2"
  local retries=0
  local ping_command="ping -c1 -w3"

  if [[ -n "$interface_to_use" ]]; then
    ping_command="ping -I $interface_to_use -c1 -w3"
  fi

  while [ $retries -lt $MAX_PING_RETRIES ]; do
    if $ping_command "$host_to_ping" &>/dev/null; then
      return 0 # Suksess
    fi
    retries=$((retries + 1))
    log_msg "Ping til $host_to_ping via ${interface_to_use:-default} feilet (forsøk $retries/$MAX_PING_RETRIES). Venter $RETRY_DELAY sek..."
    sleep $RETRY_DELAY
  done
  log_msg "KRITISK: Klarte ikke å pinge $host_to_ping via ${interface_to_use:-default} etter $MAX_PING_RETRIES forsøk."
  return 1 # Feil
}

connect_nordvpn() {
  log_msg "Starter prosessen for å koble til NordVPN..."
  send_mqtt_status "Starter VPN tilkobling..."

  if nordvpn status | grep -q "Status: Connected" && ip addr show "$VPN_IFACE" &>/dev/null; then
    log_msg "NordVPN er allerede tilkoblet. Sikrer rutingregler."
    setup_vpn_routing_rules
    send_mqtt_status "VPN Allerede Tilkoblet"
    return 0
  fi

  if ! check_internet_robust "$VPN_CHECK_HOST" "$LAN_IFACE"; then
    log_msg "Ingen generell internettilgang (via $LAN_IFACE). Kan ikke koble til NordVPN nå. Venter..."
    send_mqtt_status "Venter på nett ($LAN_IFACE)"
    return 1
  fi
  log_msg "Generell internettilgang (via $LAN_IFACE) er OK."

  log_msg "Kobler til NordVPN ($NORDVPN_CONNECT_TARGET)..."
  if [ -z "$NORDVPN_CONNECT_TARGET" ]; then
      nordvpn connect
  else
      nordvpn connect "$NORDVPN_CONNECT_TARGET"
  fi

  sleep 8

  local connect_tries=0
  while ( ! nordvpn status | grep -q "Status: Connected" || ! ip addr show "$VPN_IFACE" &>/dev/null ); do
    connect_tries=$((connect_tries + 1))
    if [ $connect_tries -gt 10 ]; then
      log_msg "TIDSAVBRUDD: NordVPN tilkobling feilet etter flere forsøk."
      nordvpn disconnect >/dev/null 2>&1
      send_mqtt_status "VPN tilkobling feilet"
      return 1
    fi
    log_msg "Venter på status 'Connected' OG at $VPN_IFACE er oppe... (forsøk $connect_tries)"
    sleep 6
  done

  log_msg "NordVPN tilkoblet og $VPN_IFACE er oppe."
  setup_vpn_routing_rules
  send_mqtt_status "VPN Tilkoblet"
  return 0
}

# --- Hovedlogikk ---

trap 'log_msg "Script stoppet. Kobler fra VPN..."; nordvpn disconnect; send_mqtt_status "VPN Frakoblet"; exit 0' SIGINT SIGTERM

log_msg "--- NordVPN Gateway script starter (PID: $$) ---"
sudo touch "$LOG_FILE" && sudo chmod 644 "$LOG_FILE"

log_msg "Sjekker Pi-ens default gateway..."
DEFAULT_GW_IP=$(ip -4 route show default 0.0.0.0/0 | grep -Po 'via \K[^ ]+' | head -n 1)
DEFAULT_GW_IFACE=$(ip -4 route show default 0.0.0.0/0 | grep -Po 'dev \K[^ ]+' | head -n 1)

if [[ "$DEFAULT_GW_IFACE" == "$VPN_IFACE" ]] || [[ "$DEFAULT_GW_IP" != "$CORRECT_GATEWAY" ]]; then
    log_msg "ADVARSEL: Pi-ens default gateway er feil ($DEFAULT_GW_IP via $DEFAULT_GW_IFACE). Korrigerer..."
    sudo ip route replace default via "$CORRECT_GATEWAY" dev "$LAN_IFACE"
    sudo ip route flush cache
    log_msg "Pi-ens default gateway er nå: $(ip -4 route show default 0.0.0.0/0)"
else
    log_msg "Pi-ens default gateway ser OK ut."
fi

send_mqtt_ha_discovery
connect_nordvpn

log_msg "Starter kontinuerlig overvåkningsløkke..."
while true; do
  if nordvpn status | grep -q "Status: Connected" && ip addr show "$VPN_IFACE" &>/dev/null; then
    if check_internet_robust "$NORDVPN_HOST_CHECK" "$VPN_IFACE"; then
      send_mqtt_status "VPN OK"
    else
      log_msg "VPN er 'Connected', men kan ikke pinge gjennom $VPN_IFACE. Prøver å koble til på nytt."
      send_mqtt_status "VPN test feilet"
      nordvpn disconnect >/dev/null 2>&1
      sleep 5
      connect_nordvpn
    fi
  else
    log_msg "VPN er frakoblet. Forsøker å koble til..."
    send_mqtt_status "VPN Frakoblet"
    connect_nordvpn
  fi
  send_cpu_temp
  sleep 60
done
