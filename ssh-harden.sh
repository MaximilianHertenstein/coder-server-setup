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

# PermitRootLogin wird deaktiviert. Deshalb erfordert der Helfer einen
# getesteten, nicht-root-Sudo-Login und dessen tatsächlich konfigurierte
# AuthorizedKeysFile. Die Flags bleiben die Betreiberbestätigung, dass genau
# dieser Login von einem zweiten Zugang aus erfolgreich getestet wurde.
SUDO_USER_NAME="${SUDO_USER:-}"
if [ -z "${SUDO_USER_NAME}" ] || [ "${SUDO_USER_NAME}" = root ]; then
  echo "Abbruch: ssh-harden.sh muss per sudo von einem nicht-root SSH-Benutzer ausgeführt werden." >&2
  echo "PermitRootLogin no würde einen reinen Root-Key unbrauchbar machen." >&2
  exit 1
fi
USER_ENTRY=$(getent passwd "${SUDO_USER_NAME}" || true)
if [ -z "${USER_ENTRY}" ]; then
  echo "Abbruch: sudo-Aufrufer '${SUDO_USER_NAME}' ist nicht in der lokalen Benutzerverwaltung auffindbar." >&2
  exit 1
fi
IFS=: read -r _ _ USER_UID _ _ USER_HOME _ <<< "${USER_ENTRY}"
if [ "${USER_UID}" -eq 0 ] || [ -z "${USER_HOME}" ]; then
  echo "Abbruch: '${SUDO_USER_NAME}' hat keine gültige Nicht-root-UID/Home-Zuordnung." >&2
  exit 1
fi

SSHD_EFFECTIVE=$(sudo sshd -T -C "user=${SUDO_USER_NAME},host=localhost,addr=127.0.0.1" 2>/dev/null || true)
AUTHORIZED_KEY_PATHS=$(printf '%s\n' "${SSHD_EFFECTIVE}" | awk '$1 == "authorizedkeysfile" { for (i = 2; i <= NF; i++) print $i }')
if [ -z "${AUTHORIZED_KEY_PATHS}" ]; then
  echo "Abbruch: sshd -T lieferte keine AuthorizedKeysFile-Pfade für '${SUDO_USER_NAME}'." >&2
  exit 1
fi
KEY_OK=false
KEY_FILE=""
while IFS= read -r keys; do
  [ -n "${keys}" ] || continue
  [ "${keys}" = none ] && continue
  keys="${keys//%%/%}"
  keys="${keys//%h/${USER_HOME}}"
  keys="${keys//%u/${SUDO_USER_NAME}}"
  keys="${keys//%U/${USER_UID}}"
  case "${keys}" in
    /*) ;;
    *) keys="${USER_HOME%/}/${keys}" ;;
  esac
  if [ -s "${keys}" ]; then
    KEY_OK=true
    KEY_FILE="${keys}"
    break
  fi
done <<< "${AUTHORIZED_KEY_PATHS}"
if [ "${KEY_OK}" != "true" ]; then
  echo "Abbruch: keine nicht-leere AuthorizedKeysFile-Datei für '${SUDO_USER_NAME}' gefunden." >&2
  echo "Effektive sshd-Pfade: ${AUTHORIZED_KEY_PATHS//$'\n'/, }" >&2
  exit 1
fi
echo "Key-Datei für den getesteten Nicht-root-Login gefunden: ${KEY_FILE}"

# Ausgangslage prüfen (sshd muss die Drop-In-Verzeichnisdirektive kennen).
if ! sudo sshd -T 2>/dev/null | grep -qi '^passwordauthentication'; then
  echo "Warnung: 'sshd -T' liefert keine PasswordAuthentication-Zeile – weiter auf eigenes Risiko." >&2
fi

DROPIN="/etc/ssh/sshd_config.d/60-coder-hardening.conf"
DROPIN_TMP="${DROPIN}.tmp.$$"
ROLLBACK_COPY="${DROPIN}.rollback.$$"
HAD_ORIGINAL=false
CHANGE_ATTEMPTED=false
HARDENING_COMMITTED=false
if sudo test -L "${DROPIN}" || sudo test -d "${DROPIN}"; then
  echo "Abbruch: ${DROPIN} ist ein Symlink oder Verzeichnis; es wird nichts überschrieben." >&2
  exit 1
fi
if sudo test -e "${DROPIN}"; then
  sudo cp -a "${DROPIN}" "${ROLLBACK_COPY}"
  HAD_ORIGINAL=true
fi

rollback_on_exit() {
  local rc=$?
  trap - EXIT
  if [ "${HARDENING_COMMITTED}" != true ]; then
    if [ "${CHANGE_ATTEMPTED}" = true ]; then
      if [ "${HAD_ORIGINAL}" = true ]; then
        if ! sudo mv -f "${ROLLBACK_COPY}" "${DROPIN}"; then
          echo "KRITISCH: vorheriges Drop-In konnte nicht zurückgespielt werden; Sicherung liegt unter ${ROLLBACK_COPY}." >&2
          exit "${rc:-1}"
        fi
      elif ! sudo rm -f "${DROPIN}"; then
        echo "KRITISCH: neues Drop-In konnte nicht entfernt werden: ${DROPIN}" >&2
        exit "${rc:-1}"
      fi
      if ! sudo systemctl reload ssh; then
        echo "KRITISCH: vorherige SSH-Konfiguration liegt wieder auf Platte, ssh konnte aber nicht neu geladen werden." >&2
        exit "${rc:-1}"
      fi
      echo "SSH-Härtung wurde zurückgerollt; bisherige Konfiguration ist wieder aktiv." >&2
    fi
    sudo rm -f "${DROPIN_TMP}" "${ROLLBACK_COPY}" 2>/dev/null || true
  else
    sudo rm -f "${DROPIN_TMP}" "${ROLLBACK_COPY}" 2>/dev/null || true
  fi
  exit "${rc}"
}
trap rollback_on_exit EXIT

sudo install -m 600 -o root -g root /dev/null "${DROPIN_TMP}"
sudo tee "${DROPIN_TMP}" > /dev/null <<'EOF'
# Erzeugt von ssh-harden.sh (P-003). Entfernen + "systemctl reload ssh" zum Zurückrollen.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
CHANGE_ATTEMPTED=true
sudo mv "${DROPIN_TMP}" "${DROPIN}"

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
  echo "Effektive Config ist unerwartet; das Skript stellt beim Beenden die vorherige Konfiguration wieder her." >&2
  exit 1
fi
HARDENING_COMMITTED=true
trap - EXIT
sudo rm -f "${DROPIN_TMP}" "${ROLLBACK_COPY}"
echo "Härtung aktiv. Rückweg: sudo rm ${DROPIN} && sudo systemctl reload ssh"
