#!/bin/bash

# ANSI Fargekoder for penere output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

clear
echo -e "${CYAN}--- Verifiseringsscript for selektiv VPN-ruting ---${NC}"
echo

# --- SJEKK 1: IPTABLES-TELLERE ---
echo -e "${YELLOW}STEG 1: Sjekker om brannmurregelen for port 8080 blir truffet...${NC}"

PACKET_COUNT=$(sudo iptables -t mangle -L PREROUTING -v -n | grep 'tcp dpt:8080' | awk '{print $1}')

if [[ -z "$PACKET_COUNT" ]]; then
  echo "FEIL: Fant ingen iptables-regel for TCP port 8080 i mangle-tabellen."
  exit 1
fi

echo "Fant følgende regel(er) som matcher port 8080:"
sudo iptables -t mangle -L PREROUTING -v -n --line-numbers | grep --color=always '8080'
echo
echo -e "Nåværende pakketeller (pkts): ${GREEN}${PACKET_COUNT}${NC}"
echo "Dette tallet viser hvor mange pakker som hittil er blitt merket for VPN."
echo
read -p "Trykk [Enter] for å starte live-analysen av VPN-trafikken..."

# --- SJEKK 2: LIVE TRAFIKK-ANALYSE ---
echo
echo -e "${CYAN}--------------------------------------------------------------${NC}"
echo -e "${YELLOW}STEG 2: Lytter på live trafikk på vei UT av VPN-tunnelen...${NC}"
echo

if ! command -v tcpdump &> /dev/null; then
    echo "FEIL: 'tcpdump' er ikke installert. Kjør: sudo apt install tcpdump"
    exit 1
fi

if ! ip addr show tun0 &> /dev/null; then
    echo "FEIL: VPN-grensesnittet 'tun0' er nede. Sjekk at VPN er tilkoblet."
    echo "Kjør: systemctl status protonvpn-gateway.service"
    exit 1
fi

echo -e "Jeg vil nå lytte på grensesnittet ${GREEN}tun0${NC} etter trafikk til port 8080."
echo -e "All trafikk du ser her, går garantert gjennom VPN-tunnelen."
echo
echo -e "${YELLOW}*** DIN OPPGAVE NÅ: ***${NC}"
echo "1. Gå til en av dine VPN-klienter (f.eks. 192.168.1.128)."
echo "2. Start appen eller tjenesten som bruker port 8080."
echo "3. Se på dette terminalvinduet. Hvis alt virker, skal du se trafikk her."
echo
echo -e "Trykk ${CYAN}Ctrl+C${NC} for å stoppe lyttingen."
echo -e "${CYAN}--------------------------------------------------------------${NC}"
sleep 2

sudo tcpdump -i tun0 -n 'tcp and port 8080'

echo
echo -e "${GREEN}Verifisering fullført.${NC}"
