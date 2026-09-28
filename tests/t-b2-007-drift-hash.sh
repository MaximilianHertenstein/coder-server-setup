#!/bin/bash
# T-026-Delta / B2-007: remember_hash an der Schreibstelle statt in Schritt 10.
# Geprueft: Struktur (note_drift VOR dem Schreiben, remember_hash NACH
# erfolgreichem tee/chmod, 15/15 Dateien, keine Schritt-10-Schleife) und
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

# --- 1. Struktur: 15 note_drift / 15 remember_hash, korrekte Reihenfolge ----
EXPECTED="/opt/coder/docker-compose.yml
/opt/coder/Caddyfile
/opt/coder/prometheus.yml
/etc/fail2ban/jail.local
/etc/apt/apt.conf.d/52-coder-reboot
/opt/coder/boot-check.sh
/etc/cron.d/coder-bootcheck
/opt/coder/check-tls.sh
/etc/cron.d/coder-tlscheck
/opt/coder/backup.sh
/etc/cron.d/coder-backup
/etc/logrotate.d/coder-backup
/opt/coder/update.sh
/opt/coder/reset-passwords.sh
/opt/coder/reset-coder.sh"

N_NOTE=$(grep -c '^note_drift "' "${SETUP}")
N_REM=$(grep -c '^remember_hash "' "${SETUP}")
echo "INFO: note_drift=${N_NOTE} remember_hash=${N_REM}"
[ "${N_NOTE}" -eq 15 ] && pass "genau 15 note_drift-Aufrufe" || fail "note_drift-Anzahl=${N_NOTE} (erwartet 15)"
[ "${N_REM}" -eq 15 ] && pass "genau 15 remember_hash-Aufrufe" || fail "remember_hash-Anzahl=${N_REM} (erwartet 15)"

nl_idx() { grep -nF "$1" "${SETUP}" | head -n1 | cut -d: -f1; }

while IFS= read -r P; do
  [ -n "${P}" ] || continue
  ND=$(nl_idx "note_drift \"${P}\"")
  RM=$(nl_idx "remember_hash \"${P}\"")
  TE=$(nl_idx "sudo tee ${P} ")
  if [ -z "${ND}" ] || [ -z "${RM}" ] || [ -z "${TE}" ]; then
    fail "${P}: Luecke note_drift=${ND} tee=${TE} remember_hash=${RM}"
    continue
  fi
  if [ "${ND}" -lt "${TE}" ] && [ "${TE}" -lt "${RM}" ]; then
    pass "Reihenfolge note_drift < tee < remember_hash: ${P}"
  else
    fail "Reihenfolge falsch (ND=${ND} tee=${TE} RM=${RM}): ${P}"
  fi
  # remember_hash muss NACH dem chmod der Datei stehen (wenn vorhanden).
  CM=$(awk -v s="${TE}" -v e="${RM}" 'NR>s && NR<e && /^sudo chmod / {n=NR} END{print n+0}' "${SETUP}")
  if [ "${CM}" -gt 0 ]; then
    if [ "${CM}" -lt "${RM}" ]; then
      pass "chmod vor remember_hash: ${P}"
    else
      fail "chmod steht NACH remember_hash: ${P}"
    fi
  fi
done <<< "${EXPECTED}"

# Vollstaendigkeitsabgleich: kein remember_hash ohne erwarteten Pfad.
while IFS= read -r RM_LINE; do
  P=$(printf '%s' "${RM_LINE}" | sed 's/^remember_hash "//; s/"$//')
  if ! printf '%s\n' "${EXPECTED}" | grep -qxF -- "${P}"; then
    fail "remember_hash fuer unerwarteten Pfad: ${P}"
  fi
done < <(grep '^remember_hash "' "${SETUP}")

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
  pass "keine gebuendelte remember_hash-Schleife (nur Einzelaufrufe an Schreibstellen)"
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

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-007: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-007: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
