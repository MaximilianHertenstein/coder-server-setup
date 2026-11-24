#!/bin/bash
# Workspace-Egress-Sperre für die DOCKER-USER-Kette (B3b, 2026-10-08):
# kompromittierte Workspace-Container sollen Schul-/Interne Netze (RFC1918)
# nicht erreichen. Offen bleibt alles andere: Internet-Ausgang, die Docker-
# eigenen Netze (Coder-Stack UND Workspace-Netze – darin laufen auch die
# Wege über publizierte Ports, die DOCKER-FORWARD bedient) und Rückverkehr.
#
# B3c (2026-11-24): Rückverkehr explizit freigeben. Die DROP-Regeln matchen
# nur das Ziel und trafen deshalb auch die Antworten publizierter Ports an
# Clients im Schulnetz (10/8) und an den IServ-Proxy (10.0.0.1): Port 80/443
# war aus dem Schulnetz nicht erreichbar, Ping und SSH schon. Die
# RETURN-Regel steht VOR den DROPs und lässt nur ESTABLISHED,RELATED durch;
# neue Verbindungen aus Containern nach 10/8 bleiben gesperrt.
#
# Aufruf: systemd-Unit coder-egress-firewall.service (nach docker.service,
# auch nach jedem Reboot) und jeder setup-coder.sh-Lauf (Schritt 4).
# Idempotent: -C prüft, -I setzt; die RETURN-Regel wird auf Position 1
# gehalten (eine neu eingefügte DROP-Regel würde sie sonst nach unten
# schieben). Ohne Docker legt -N die Kette an; Docker stellt seinen
# FORWARD-Sprung selbst wieder her und räumt den Inhalt nicht.
set -euo pipefail

iptables -N DOCKER-USER 2>/dev/null || true

for _net in 10.0.0.0/8 192.168.0.0/16; do
  if ! iptables -C DOCKER-USER -d "${_net}" -j DROP 2>/dev/null; then
    iptables -I DOCKER-USER 1 -d "${_net}" -j DROP
  fi
done

# Position prüfen, nicht nur Existenz: die erste Regel der Kette muss der
# RETURN für Rückverkehr sein. Sonst (Altbestand, manueller Eingriff) alle
# vorhandenen RETURN-Regeln entfernen und neu auf Position 1 setzen.
_first_rule="$(iptables -S DOCKER-USER | sed -n '2p')"
case "${_first_rule}" in
  *"-m conntrack --ctstate "*ESTABLISHED*"-j RETURN"*) ;;
  *)
    while iptables -D DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN 2>/dev/null; do :; done
    iptables -I DOCKER-USER 1 -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    ;;
esac

# IPv6 bewusst aus: die Compose-Netze laufen mit EnableIPv6=false, Container
# haben damit keinen v6-Pfad ins Schulnetz.
exit 0
