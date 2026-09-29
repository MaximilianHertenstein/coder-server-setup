#!/bin/bash
# T-026-Delta / B2-007: zentraler atomarer Schreibhelfer statt wiederholter
# tee/chmod/hash-Sequenzen. Geprueft: alle 16 driftverwalteten Dateien nutzen
# ihn, Drift kommt vor dem Austausch und der Hash danach; keine Schritt-10-Schleife.
# Verhalten der ECHTEN note_drift-/remember_hash-Funktionen aus
# setup-coder.sh (ausextrahiert, sudo-Shim, Hashstore in /tmp):
#   (a) gruener Lauf -> keine WARN
#   (b) echte Hand-Drift -> WARN bleibt
#   (c) Residualpfad (Schreiben ohne remember_hash) -> genau einmal WARN,
#       danach heilt remember_hash ohne Datenverlust
# Nur /tmp, keine Produktion.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- 1. Struktur: verwaltete Dateien nutzen atomaren Schreibhelfer ----------
EXPECTED="/opt/coder/docker-compose.yml
/opt/coder/Caddyfile
/opt/coder/prometheus.yml
/etc/fail2ban/jail.d/10-coder-sshd.local
/etc/apt/apt.conf.d/52-coder-reboot
/opt/coder/boot-check.sh
/etc/cron.d/coder-bootcheck
/opt/coder/check-tls.sh
/etc/cron.d/coder-tlscheck
/opt/coder/backup.sh
/etc/cron.d/coder-backup
/etc/logrotate.d/coder-backup
/etc/logrotate.d/coder-logs
/opt/coder/update.sh
/opt/coder/reset-passwords.sh
/opt/coder/reset-coder.sh"

N_MANAGED=$(grep -c '^write_managed "/' "${SETUP}")
echo "INFO: write_managed=${N_MANAGED}"
[ "${N_MANAGED}" -eq 19 ] && pass "alle 19 direkt adressierten Dateien nutzen write_managed" || fail "write_managed-Anzahl=${N_MANAGED} (erwartet 19)"
grep -qF 'write_managed "${VERSIONS_FILE}"' "${SETUP}" && pass "versions.env nutzt ebenfalls write_managed" || fail "versions.env nutzt write_managed nicht"

nl_idx() { grep -nF "$1" "${SETUP}" | head -n1 | cut -d: -f1; }

while IFS= read -r P; do
  [ -n "${P}" ] || continue
  WM=$(nl_idx "write_managed \"${P}\"")
  if [ -z "${WM}" ]; then
    fail "${P}: kein write_managed-Aufruf gefunden"
    continue
  fi
  WM_COUNT=$(grep -cF "write_managed \"${P}\"" "${SETUP}")
  if [ "${WM_COUNT}" -eq 1 ]; then
    pass "genau ein atomarer Schreibaufruf: ${P}"
  else
    fail "write_managed-Aufrufe für ${P}: ${WM_COUNT} (erwartet 1)"
  fi
done <<< "${EXPECTED}"

HELPER_NOTE=$(nl_idx 'note_drift "${file}" "${label}"')
HELPER_MV=$(nl_idx 'sudo mv -f -- "${MANAGED_TMP}" "${file}"')
HELPER_HASH=$(nl_idx 'remember_hash "${file}"')
if [ -n "${HELPER_NOTE}" ] && [ -n "${HELPER_MV}" ] && [ -n "${HELPER_HASH}" ] && [ "${HELPER_NOTE}" -lt "${HELPER_MV}" ] && [ "${HELPER_MV}" -lt "${HELPER_HASH}" ]; then
  pass "Drift-Prüfung vor atomarem Austausch, Hash danach"
else
  fail "write_managed-Reihenfolge für Drift, Austausch und Hash ist falsch"
fi
grep -qF 'sudo mktemp "${dir}/.${base}.tmp.XXXXXX"' "${SETUP}" && pass "Temp-Datei wird im Zielverzeichnis angelegt" || fail "Temp-Datei liegt nicht im Zielverzeichnis"

# Hash-Commits sollen zentral im Schreibhelfer bleiben.
if grep -q '^remember_hash "' "${SETUP}"; then
  fail "direkter remember_hash-Aufruf außerhalb write_managed"
else
  pass "Hash-Commits sind im Schreibhelfer zentralisiert"
fi

# --- 2. Schritt-10-Schleife weg ---------------------------------------------
if grep -qF 'for _f in /opt/coder/docker-compose.yml' "${SETUP}"; then
  fail "Schritt-10-Hashschleife ist noch vorhanden"
else
  pass "Schritt-10-Hashschleife ist entfernt"
fi

# remember_hash darf an keiner Stelle mehr gebuendelt nachgezogen werden.
if grep -qE 'remember_hash "\$\{_?f\}"' "${SETUP}"; then
  fail "remember_hash wird noch in einer Schleife gebuendelt nachgezogen"
else
  pass "keine gebuendelte remember_hash-Schleife"
fi

# --- 3. Verhalten der ECHTEN Funktionen (aus setup-coder.sh extrahiert) -----
awk '/^HASHSTORE=/{f=1} f{print} f&&/^remember_hash\(\)/{g=1} g&&/^}$/{exit}' \
  "${SETUP}" > "${WORK}/drift_funcs.sh"
F_LINES=$(wc -l < "${WORK}/drift_funcs.sh")
echo "INFO: extrahierte Drift-Funktionen = ${F_LINES} Zeilen"
grep -q '^note_drift()' "${WORK}/drift_funcs.sh" || fail "note_drift nicht extrahiert"
grep -q '^remember_hash()' "${WORK}/drift_funcs.sh" || fail "remember_hash nicht extrahiert"

# sudo-Shim + eigener Hashstore + WARN-Capture.
sudo() { "$@"; }
warn() { printf 'WARN\n'; }
HASHSTORE="${WORK}/.generated-hashes"
# shellcheck disable=SC1091
. "${WORK}/drift_funcs.sh"
HASHSTORE="${WORK}/.generated-hashes"

F="${WORK}/probe.conf"
rm -f "${HASHSTORE}"

# (a) erster Schreibvorgang: Hash sofort committet -> kein Drift-WARN.
printf 'a=1\n' > "${F}"
remember_hash "${F}"
OUT=$(note_drift "${F}" "probe.conf" || true)
if [ -z "${OUT}" ]; then
  pass "(a) frisch geschriebene Datei mit Hash -> keine WARN"
else
  fail "(a) unerwartete WARN: ${OUT}"
fi

# (b) echte Operator-Drift (Hand-Zeile) -> WARN bleibt.
printf 'a=1\noperator=hand\n' > "${F}"
OUT=$(note_drift "${F}" "probe.conf" || true)
if [ -n "${OUT}" ]; then
  pass "(b) echte Hand-Drift -> WARN bleibt"
else
  fail "(b) Hand-Drift wurde NICHT gemeldet"
fi
# Heilung: erneuter gruener Lauf.
remember_hash "${F}"
OUT=$(note_drift "${F}" "probe.conf" || true)
if [ -z "${OUT}" ]; then
  pass "(b) Heilung nach remember_hash -> keine WARN"
else
  fail "(b) Heilung fehlgeschlagen: ${OUT}"
fi

# (c) Residualpfad: Datei neu geschrieben, Hash nicht committet (Kill zwischen
# Schreiben und remember_hash) -> genau einmal Fehl-WARN, danach Heilung.
printf 'b=2\n' > "${F}"
W1=$(note_drift "${F}" "probe.conf" || true)
W2=$(note_drift "${F}" "probe.conf" || true)
if [ -n "${W1}" ] && [ -n "${W2}" ]; then
  pass "(c) Residualpfad -> genau einmal Fehl-WARN pro Lauf"
else
  fail "(c) Residualpfad gemeldet=${W1}/${W2} (erwartet nicht-leer, wiederholbar)"
fi
remember_hash "${F}"
OUT=$(note_drift "${F}" "probe.conf" || true)
if [ -z "${OUT}" ]; then
  pass "(c) Folgelauf heilt den Hashstore ohne Datenverlust"
else
  fail "(c) Heilung fehlgeschlagen: ${OUT}"
fi

# Hashstore-Modus 600 + keine Dubletten.
MODE=$(stat -c %a "${HASHSTORE}")
if [ "${MODE}" = "600" ]; then
  pass "Hashstore-Modus 600"
else
  fail "Hashstore-Modus=${MODE} (erwartet 600)"
fi
DUPES=$(cut -d' ' -f3- "${HASHSTORE}" | sort | uniq -d)
if [ -z "${DUPES}" ]; then
  pass "Hashstore ohne Dubletten (atomare Ersetzung)"
else
  fail "Hashstore-Dubletten: ${DUPES}"
fi
N_ENTRIES=$(grep -c . "${HASHSTORE}")
[ "${N_ENTRIES}" -eq 1 ] && pass "Hashstore genau 1 Eintrag" || fail "Hashstore-Eintraege=${N_ENTRIES}"

# --- 4. B7: Drop-In statt jail.local, hash-guarded Entfernung ---------------
if grep -qF 'sudo tee /etc/fail2ban/jail.local ' "${SETUP}"; then
  fail "B7: eigene jail.local wird noch beschrieben (Ueberschreibt Operator-Jails)"
else
  pass "B7: jail.local wird nicht mehr beschrieben"
fi
grep -qF 'JAIL_DROPIN="/etc/fail2ban/jail.d/10-coder-sshd.local"' "${SETUP}" \
  && pass "B7: eigene Jails liegen in jail.d/10-coder-sshd.local" \
  || fail "B7: Drop-In-Pfad fehlt"
grep -qF '[ -n "${_jl_exp}" ] && [ "${_jl_cur}" = "${_jl_exp}" ]' "${SETUP}" \
  && pass "B7: Entfernen der alten jail.local ist hash-guarded (Hand-Aenderungen bleiben)" \
  || fail "B7: Hash-Guard fehlt"
grep -qF 'forget_hash() {' "${SETUP}" \
  && pass "B7: forget_hash vorhanden (kein Rest-Hash nach dem Loeschen)" \
  || fail "B7: forget_hash fehlt"
grep -qF 'JAIL_CHANGED=1' "${SETUP}" \
  && pass "B7: Loeschen der alten jail.local loest Reload aus (P-025)" \
  || fail "B7: Reload-Flag fehlt"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-007: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-007: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
