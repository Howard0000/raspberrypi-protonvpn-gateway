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
# - (Valgfritt) Sende status til en MQTT-broker (Home Assistant discovery).
# ==============================================================================

set -euo pipefail

# --- Konfigurasjon ---
VPN_CHECK_HOST="1.1.1.1"         # Ping-mål for å sjekke generell internett-tilgang (via LAN)
VPN_ROBUST_CHECK="google.com"    # Ping-mål for å sjekke VPN-tilkobling (pinges via VPN-grensesnitt)
MAX_PING_RETRIES=12              # Antall forsøk for ping-sjekker (12 * 5s = 1 minutt)
RETRY_DELAY=5                    # Sekunder mellom ping-forsøk
CORRECT_GATEWAY="192.168.1.1"    # TILPASS: Din hovedrouters IP
VPN_TABLE="vpn_table"            # Navn på routing-tabell (må finnes i /etc/iproute2/rt_tables)
VPN_IFACE="tun0"                 # Grensesnittnavn for OpenVPN
LAN_IFACE="eth0"                 # Pi-ens fysiske LAN-grensesnitt
LOG_FILE="/var/log/protonvpn-gateway.log"
OPENVPN_LOG_FILE="/var/log/openvpn.log"
PID_FILE="/run/openvpn-proton.pid"

# --- OpenVPN Innstillinger ---
OPENVPN_CONFIG="/etc/openvpn/client/proton.ovpn"         # TILPASS: Sti til din .ovpn-fil
OPENVPN_AUTH="/etc/openvpn/client/proton_auth.txt"       # TILPASS: Sti til din auth-fil (chmod 600)

# --- MQTT Innstillinger ---
MQTT_ENABLED=false                 # Sett til true hvis du bruker MQTT, ellers false
MQTT_BROKER="XXX.XXX.X.XXX"        # TILPASS: Din MQTT broker IP
MQTT_USER=""                       # TILPASS: MQTT bruker (kan være tom)
MQTT_PASS=""                       # TILPASS: MQTT passord (kan være tom)
MQTT_CLIENT_ID="protonvpn_gateway_pi"
HA_DISCOVERY_PREFIX="homeassistant"

# ==============================================================================
# Funksjoner
# ==============================================================================

log_msg() {
  local ts; ts="$(date +'%Y-%m-%d %H:%M:%S')"
  # Sørg for at loggfil finnes og er skrivbar
  sudo touch "$LOG_FILE" "$OPENVPN_LOG_FILE" >/dev/null 2>&1 || true
  sudo chmod 644 "$LOG_FILE" "$OPENVPN_LOG_FILE" >/dev/null 2>&1 || true
  echo "$ts - $1" | sudo tee -a "$LOG_FILE" >/dev/null
}

send_mqtt() {
  # usage: send_mqtt TOPIC PAYLOAD
  [ "$MQTT_ENABLED" = true ] || return 0
  command -v mosquitto_pub >/dev/null 2>&1 || { log_msg "ADVARSEL: mosquitto_pub ikke funnet."; return 0; }
  local topic="$1"; shift
  local payload="$*"
  local args=()
  [[ -n "$MQTT_USER" ]] && args+=(-u "$MQTT_USER")
  [[ -n "$MQTT_PASS" ]] && args+=(-P "$MQTT_PASS")
  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${args[@]}" -r -t "$topic" -m "$payload" || true
}

send_mqtt_status() {
  local status_message="$1"
  send_mqtt "protonvpn/gateway/status" "$status_message"
  send_mqtt "protonvpn/gateway/last_seen" "$(date +'%Y-%m-%d %H:%M:%S')"
}

send_mqtt_ha_discovery() {
  [ "$MQTT_ENABLED" = true ] || return 0
  command -v mosquitto_pub >/dev/null 2>&1 || { log_msg "ADVARSEL: mosquitto_pub ikke funnet."; return 0; }

  local DEVICE_JSON='{ "identifiers": ["protonvpn_gateway_pi_device"], "name": "ProtonVPN Gateway", "model": "Raspberry Pi", "manufacturer": "Custom Script" }'
  local args=()
  [[ -n "$MQTT_USER" ]] && args+=(-u "$MQTT_USER")
  [[ -n "$MQTT_PASS" ]] && args+=(-P "$MQTT_PASS")

  # Status-sensor
  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${args[@]}" -r \
    -t "$HA_DISCOVERY_PREFIX/sensor/protonvpn_gateway_pi/status/config" \
    -m "{ \"name\": \"ProtonVPN Status\", \"state_topic\": \"protonvpn/gateway/status\", \"unique_id\": \"protonvpn_gateway_pi_status\", \"icon\": \"mdi:vpn\", \"device\": $DEVICE_JSON }" || true

  # Last seen
  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${args[@]}" -r \
    -t "$HA_DISCOVERY_PREFIX/sensor/protonvpn_gateway_pi/last_seen/config" \
    -m "{ \"name\": \"ProtonVPN Sist Sett\", \"state_topic\": \"protonvpn/gateway/last_seen\", \"unique_id\": \"protonvpn_gateway_pi_last_seen\", \"icon\": \"mdi:clock-outline\", \"device\": $DEVICE_JSON }" || true

  # CPU temp
  mosquitto_pub -h "$MQTT_BROKER" -i "$MQTT_CLIENT_ID" "${args[@]}" -r \
    -t "$HA_DISCOVERY_PREFIX/sensor/protonvpn_gateway_pi/cpu_temp/config" \
    -m "{ \"name\": \"ProtonVPN Gateway CPU Temperatur\", \"state_topic\": \"protonvpn/gateway/cpu_temp\", \"unique_id\": \"protonvpn_gateway_pi_cpu_temp\", \"icon\": \"mdi:thermometer\", \"device_class\": \"temperature\", \"unit_of_measurement\": \"°C\", \"device\": $DEVICE_JSON }" || true
}

send_cpu_temp() {
  [ "$MQTT_ENABLED" = true ] || return 0
  command -v mosquitto_pub >/dev/null 2>&1 || return 0
  local temp_file="/sys/class/thermal/thermal_zone0/temp"
  [ -r "$temp_file" ] || return 0
  local t_raw t_c
  t_raw="$(cat "$temp_file" 2>/dev/null)" || return 0
  t_c="$(awk "BEGIN { printf \"%.1f\", $t_raw/1000 }")"
  send_mqtt "protonvpn/gateway/cpu_temp" "$t_c"
}

check_internet_iface_once() {
  # usage: check_internet_iface_once HOST IFACE
  local host="$1"; local iface="$2"
  ping -I "$iface" -c 1 -W 2 "$host" >/dev/null 2>&1
}

check_internet_robust() {
  # usage: check_internet_robust HOST IFACE
  local host="$1"; local iface="$2"
  local i
  for ((i=1; i<=MAX_PING_RETRIES; i++)); do
    if check_internet_iface_once "$host" "$iface"; then
      return 0
    fi
    sleep "$RETRY_DELAY"
  done
  return 1
}

setup_vpn_routing_rules() {
  log_msg "Setter opp dynamiske rutingregler for tabell $VPN_TABLE..."
  if ! sudo ip rule show | grep -q "fwmark 0x1 lookup $VPN_TABLE"; then
    sudo ip rule add fwmark 1 table "$VPN_TABLE"
    log_msg "Lagt til: ip rule add fwmark 1 table $VPN_TABLE"
  else
    log_msg "Regel 'fwmark 0x1 lookup $VPN_TABLE' eksisterer allerede."
  fi

  # Sett/erstatt default route i vpn_table via VPN_IFACE
  sudo ip route replace default dev "$VPN_IFACE" table "$VPN_TABLE"
  log_msg "Satt/erstattet: ip route replace default dev $VPN_IFACE table $VPN_TABLE"

  sudo ip route flush cache
  log_msg "Ruting-cache tømt."
}

disconnect_vpn() {
  log_msg "Kobler fra OpenVPN..."
  if [[ -f "$PID_FILE" ]]; then
    if sudo kill "$(cat "$PID_FILE")" 2>/dev/null; then
      sleep 1
    fi
    sudo rm -f "$PID_FILE" || true
  else
    sudo killall openvpn >/dev/null 2>&1 || true
  fi
  send_mqtt_status "VPN Frakoblet"
}

connect_vpn() {
  log_msg "Starter prosessen for å koble til OpenVPN..."
  send_mqtt_status "Starter VPN tilkobling..."

  # Allerede oppe?
  if ip addr show "$VPN_IFACE" &>/dev/null; then
    log_msg "VPN-grensesnitt ($VPN_IFACE) er allerede oppe. Sikrer rutingregler."
    setup_vpn_routing_rules
    send_mqtt_status "VPN Allerede Tilkoblet"
    return 0
  fi

  # Pre-flight
  if ! check_internet_robust "$VPN_CHECK_HOST" "$LAN_IFACE"; then
    log_msg "Ingen generell internettilgang (via $LAN_IFACE). Venter..."
    send_mqtt_status "Venter på nett ($LAN_IFACE)"
    return 1
  fi
  [ -r "$OPENVPN_CONFIG" ] || { log_msg "KRITISK: Mangler $OPENVPN_CONFIG"; send_mqtt_status "Manglende config"; return 1; }
  [ -r "$OPENVPN_AUTH" ]   || { log_msg "KRITISK: Mangler $OPENVPN_AUTH";   send_mqtt_status "Manglende auth";   return 1; }

  # Start OpenVPN i bakgrunnen
  log_msg "Kobler til OpenVPN i bakgrunnen... (logg: $OPENVPN_LOG_FILE)"
  sudo openvpn --daemon --config "$OPENVPN_CONFIG" --auth-user-pass "$OPENVPN_AUTH" \
               --writepid "$PID_FILE" --log "$OPENVPN_LOG_FILE" || {
    log_msg "KRITISK: OpenVPN oppstart feilet."
    send_mqtt_status "OpenVPN start feilet"
    return 1
  }

  # Poll for at tun0 kommer opp + at vi faktisk når VPN_ROBUST_CHECK via VPN_IFACE
  local i
  for ((i=1; i<=MAX_PING_RETRIES; i++)); do
    if ip addr show "$VPN_IFACE" &>/dev/null; then
      # Interface oppe – test trafikk gjennom VPN_IFACE
      if check_internet_robust "$VPN_ROBUST_CHECK" "$VPN_IFACE"; then
        log_msg "OpenVPN tilkoblet og $VPN_IFACE er oppe."
        setup_vpn_routing_rules
        send_mqtt_status "VPN Tilkoblet"
        return 0
      fi
    fi
    sleep "$RETRY_DELAY"
  done

  log_msg "KRITISK: Klarte ikke å etablere fungerende VPN-tilkobling innen tidsfristen."
  send_mqtt_status "VPN tilkobling feilet"
  disconnect_vpn
  return 1
}

# ==============================================================================
# Hovedlogikk
# ==============================================================================

trap 'log_msg "Avslutter script. Kobler fra VPN..."; disconnect_vpn; exit 0' SIGINT SIGTERM

log_msg "--- ProtonVPN Gateway script starter (PID: $$) ---"

# (Valgfritt) Home Assistant discovery for MQTT-entities
send_mqtt_ha_discovery

# Første tilkoblingsforsøk
connect_vpn || true

log_msg "Starter kontinuerlig overvåkningsløkke..."
while true; do
  if ip addr show "$VPN_IFACE" &>/dev/null; then
    if check_internet_robust "$VPN_ROBUST_CHECK" "$VPN_IFACE"; then
      send_mqtt_status "VPN OK"
    else
      log_msg "VPN-grensesnitt er oppe, men ping via $VPN_IFACE feiler. Re-etablerer..."
      send_mqtt_status "VPN test feilet"
      disconnect_vpn
      sleep 5
      connect_vpn || true
    fi
  else
    log_msg "VPN er frakoblet. Forsøker å koble til..."
    send_mqtt_status "VPN Frakoblet"
    connect_vpn || true
  fi

  # Publiser CPU-temperatur (valgfritt). Kommentér inn hvis ønskelig:
  # send_cpu_temp

  sleep 60
done
