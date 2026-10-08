#!/bin/bash
# Workspace-Egress-Sperre für die DOCKER-USER-Kette (B3b, 2026-10-08):
# kompromittierte Workspace-Container sollen Schul-/Interne Netze (RFC1918)
# nicht erreichen. Offen bleibt alles andere: Internet-Ausgang, die Docker-
# eigenen Netze (Coder-Stack UND Workspace-Netze – darin laufen auch die
# Wege über publizierte Ports, die DOCKER-FORWARD bedient) und Rückverkehr.
#
# Aufruf: systemd-Unit coder-egress-firewall.service (nach docker.service,
# auch nach jedem Reboot) und jeder setup-coder.sh-Lauf (Schritt 4).
# Idempotent: -C prüft, -I setzt. Ohne Docker legt -N die Kette an; Docker
# stellt seinen FORWARD-Sprung selbst wieder her und räumt den Inhalt nicht.
set -euo pipefail

iptables -N DOCKER-USER 2>/dev/null || true

for _net in 10.0.0.0/8 192.168.0.0/16; do
  if ! iptables -C DOCKER-USER -d "${_net}" -j DROP 2>/dev/null; then
    iptables -I DOCKER-USER 1 -d "${_net}" -j DROP
  fi
done

# IPv6 bewusst aus: die Compose-Netze laufen mit EnableIPv6=false, Container
# haben damit keinen v6-Pfad ins Schulnetz.
exit 0
