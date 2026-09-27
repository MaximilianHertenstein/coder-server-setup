#!/usr/bin/env bash
# ssh-harden.sh – vorbereiteter SSH-Härtungspfad (P-003).
#
# Status: VORBEREITET, NICHT automatisch. Wird NICHT von setup-coder.sh
# aufgerufen. Erst ausführen, wenn ALLE Voraussetzungen erfüllt sind:
#   1. Ein SSH-Key-Login funktioniert (getestet, nicht nur eingerichtet).
#   2. Ein Zweit-Zugang existiert (Konsole/Proxmox/idrac/...), falls das
#      Key-Login wider Erwarten scheitert.
#   3. Eigentümer + Datum der Härtung sind im IMPLEMENTATION-REPORT bzw.
#      Betriebslog festgehalten (D-SSH-Entscheidung, siehe BLOCKER B-03).
#
# Wirkung: Passwort-/Keyboard-Interactive-Login aus, Root-Login aus – nur noch
# Key-Login. Umsetzung als Drop-In (reversibel: Datei löschen + reload).
#
# Aufruf (interaktiv, als sudo-fähiger Nutzer):
#   sudo ./ssh-harden.sh --i-have-key-access --i-have-second-access
set -euo pipefail

if [ "${1:-}" != "--i-have-key-access" ] || [ "${2:-}" != "--i-have-second-access" ]; then
  echo "Abbruch: beide Flags erforderlich – sie bestätigen getestetes Key-Login UND Zweit-Zugang." >&2
  echo "Aufruf: sudo ./ssh-harden.sh --i-have-key-access --i-have-second-access" >&2
  exit 1
fi

# Mindestens ein Key muss für root oder den aufrufenden sudo-Nutzer vorliegen,
# sonst sperren wir uns mit der Härtung selbst aus. B-006: Regex kennt auch
# FIDO2-SK-Keys (sk-ssh-ed25519@, sk-ecdsa-sha2-...) und -cert-v01@-Zertifikate
# (sonst falscher Abbruch trotz gültigem Key).
SUDO_USER_NAME="${SUDO_USER:-root}"
KEY_OK=false
for keys in "/root/.ssh/authorized_keys" "/home/${SUDO_USER_NAME}/.ssh/authorized_keys"; do
  if [ -s "${keys}" ] && grep -qE '^((sk-)?ssh-(rsa|ed25519|ecdsa)|ecdsa-sha2-nistp[0-9]+|sk-ecdsa-sha2-nistp[0-9]+)[^ ]*(-cert-v01)?[@ ]' "${keys}" 2>/dev/null; then
    KEY_OK=true
  fi
done
if [ "${KEY_OK}" != "true" ]; then
  echo "Abbruch: kein SSH-Key in /root/.ssh/authorized_keys oder /home/${SUDO_USER_NAME}/.ssh/authorized_keys gefunden." >&2
  exit 1
fi

# Ausgangslage prüfen (sshd muss die Drop-In-Verzeichnisdirektive kennen).
if ! sudo sshd -T 2>/dev/null | grep -qi '^passwordauthentication'; then
  echo "Warnung: 'sshd -T' liefert keine PasswordAuthentication-Zeile – weiter auf eigenes Risiko." >&2
fi

DROPIN="/etc/ssh/sshd_config.d/60-coder-hardening.conf"
sudo install -m 600 -o root -g root /dev/null "${DROPIN}.tmp"
sudo tee "${DROPIN}.tmp" > /dev/null <<'EOF'
# Erzeugt von ssh-harden.sh (P-003). Entfernen + "systemctl reload ssh" zum Zurückrollen.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
sudo mv "${DROPIN}.tmp" "${DROPIN}"

if ! sudo sshd -t; then
  echo "Fehler: 'sshd -t' schlägt mit neuer Config fehl – rolle zurück." >&2
  sudo rm -f "${DROPIN}"
  exit 1
fi

sudo systemctl reload ssh

# B-006: Nachbedingung nach reload (statt nur Config ausgeben). Bei ignoriertem
# Drop-In (z. B. Include Direktive fehlt) wäre der Fix wirkungslos bei Exit 0 –
# daher hart: alle drei müssen effektiv "no" sein, sonst Exit 1 + Rollback-Hinweis.
echo "Effektive Config nach Reload:"
sudo sshd -T | grep -iE '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)' || true
HARDEN_OK=true
for key in passwordauthentication kbdinteractiveauthentication permitrootlogin; do
  if ! sudo sshd -T 2>/dev/null | grep -qi "^${key} no"; then
    echo "FEHLER: '${key}' ist effektiv NICHT 'no' – Härtung unwirksam (Drop-In ggf. ignoriert)." >&2
    HARDEN_OK=false
  fi
done
if [ "${HARDEN_OK}" != "true" ]; then
  echo "Rollback-Hinweis: sudo rm ${DROPIN} && sudo systemctl reload ssh – danach Ursache prüfen (Include-Direktive in sshd_config)." >&2
  exit 1
fi
echo "Härtung aktiv. Rückweg: sudo rm ${DROPIN} && sudo systemctl reload ssh"
