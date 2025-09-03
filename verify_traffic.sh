#!/bin/bash
set -u

# ===========================================================
# Verifiseringsscript for selektiv VPN-ruting
# Endre disse tre verdiene for å tilpasse:
# ===========================================================
PORT=8080        # Porten du vil teste
IFACE="tun0"     # VPN-grensesnitt (f.eks. tun0 eller wg0)
PROTO="tcp"      # Protokoll (tcp eller udp)
# ===========================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
clear
echo -e "${CYAN}--- Verifiseringsscript for selektiv VPN-ruting ---${NC}\n"

echo -e "${YELLOW}STEG 1: Sjekker om brannmurregelen for ${PROTO^^} port ${PORT} blir truffet...${NC}"

# Hent regler fra mangle/PREROUTING og summer pakkekolonnen
MATCH_RE="$PROTO dpt:$PORT"
LIST=$(sudo iptables -t mangle -L PREROUTING -v -n --line-numbers | grep -F "$MATCH_RE" || true)

if [[ -z "$LIST" ]]; then
  echo "FEIL: Fant ingen iptables-regel for ${PROTO^^} port ${PORT}."
  exit 1
fi

echo "Fant følgende regel(er) som matcher ${PROTO^^} port ${PORT}:"
echo "$LIST" | sed "s/$MATCH_RE/\x1b[32m&\x1b[0m/g"

PACKET_COUNT=$(echo "$LIST" | awk '{sum+=$1} END{print sum+0}')
echo -e "\nNåværende pakketeller (summert): ${GREEN}${PACKET_COUNT}${NC}"
read -p $'\nTrykk [Enter] for å starte live-analysen av VPN-trafikken...'

echo -e "\n${CYAN}--------------------------------------------------------------${NC}"
echo -e "${YELLOW}STEG 2: Lytter på live trafikk på vei UT av VPN-tunnelen...${NC}\n"

if ! command -v tcpdump >/dev/null 2>&1; then
  echo "FEIL: 'tcpdump' er ikke installert. Kjør:  sudo apt install tcpdump"
  exit 1
fi

if ! ip addr show "$IFACE" &>/dev/null; then
  echo "FEIL: Grensesnittet '$IFACE' er nede."
  exit 1
fi

echo -e "Lytter på grensesnitt ${GREEN}${IFACE}${NC} etter trafikk til ${PROTO^^} port ${PORT}."
echo -e "Trykk ${CYAN}Ctrl+C${NC} for å stoppe.\n${CYAN}--------------------------------------------------------------${NC}"
sleep 1

sudo tcpdump -i "$IFACE" -n "$PROTO and port $PORT"
echo -e "\n${GREEN}Verifisering fullført.${NC}"
