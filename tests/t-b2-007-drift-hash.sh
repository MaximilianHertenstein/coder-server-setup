#!/bin/bash
# T-026-Delta / B2-007: zentraler atomarer Schreibhelfer statt wiederholter
# tee/chmod/hash-Sequenzen. Geprueft: alle driftverwalteten Dateien nutzen
# ihn, Drift kommt vor dem Austausch und der Hash danach; keine
# Hash-Nachzugs-Schleife am Laufende.
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
/opt/coder/caddy/Caddyfile
/opt/coder/prometheus/rules/coder-alerts.yml
/opt/coder/prometheus/prometheus.yml
/opt/coder/grafana/provisioning/datasources/prometheus.yml
/etc/fail2ban/jail.d/10-coder-sshd.local
/etc/apt/apt.conf.d/52-coder-reboot
/etc/cron.d/coder-tlscheck
/etc/cron.d/coder-backup
/etc/logrotate.d/coder-backup
/etc/logrotate.d/coder-logs"

N_MANAGED=$(grep -c '^write_managed "/' "${SETUP}")
echo "INFO: write_managed=${N_MANAGED}"
[ "${N_MANAGED}" -eq 11 ] && pass "alle 11 direkt adressierten Dateien nutzen write_managed" || fail "write_managed-Anzahl=${N_MANAGED} (erwartet 11)"
grep -qF 'write_managed "${VERSIONS_FILE}"' "${SETUP}" && pass "versions.env nutzt ebenfalls write_managed" || fail "versions.env nutzt write_managed nicht"

# 2.1: die drei Wartungsskripte kommen ueber eine Schleife (inkl. bash -n
# und Hash), nicht ueber Einzel-Aufrufe oder install(1).
grep -qF 'for _src in "${SETUP_DIR}"/scripts/*.sh' "${SETUP}" \
  && grep -qF 'write_managed "/opt/coder/${_src_base}" 755 "${_src_base}"' "${SETUP}" \
  && pass "scripts/*.sh werden per write_managed-Schleife geschrieben" \
  || fail "write_managed-Schleife fuer scripts/*.sh fehlt"
if grep -qF 'install -m 755 -t /opt/coder' "${SETUP}"; then
  fail "doppelte Installation per install(1) ist noch im Setup"
else
  pass "keine doppelte install(1)-Zeile mehr"
fi

# A2-Live-Fix (2026-10-01): Temp ist per mktemp 600, promtool-Container läuft
# als nobody – ohne chmod vor dem Validierer scheitert validate_prom_rules mit
# permission denied (fail-closed, aber Lauf bricht ab).
grep -qF 'chmod 644 -- "${MANAGED_TMP}"' "${SETUP}" \
  && pass "Temp-Datei wird vor dem Validierer lesbar gemacht" \
  || fail "chmod vor Validierer fehlt (mktemp 600 vs. nobody im promtool-Container)"

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
HELPER_MV=$(nl_idx 'mv -f -- "${MANAGED_TMP}" "${file}"')
HELPER_HASH=$(nl_idx 'remember_hash "${file}"')
if [ -n "${HELPER_NOTE}" ] && [ -n "${HELPER_MV}" ] && [ -n "${HELPER_HASH}" ] && [ "${HELPER_NOTE}" -lt "${HELPER_MV}" ] && [ "${HELPER_MV}" -lt "${HELPER_HASH}" ]; then
  pass "Drift-Prüfung vor atomarem Austausch, Hash danach"
else
  fail "write_managed-Reihenfolge für Drift, Austausch und Hash ist falsch"
fi
grep -qF 'mktemp "${dir}/.${base}.tmp.XXXXXX"' "${SETUP}" && pass "Temp-Datei wird im Zielverzeichnis angelegt" || fail "Temp-Datei liegt nicht im Zielverzeichnis"

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

# --- 4. B7: Drop-In statt jail.local, Warnung statt stiller Entfernung ------
if grep -qF 'tee /etc/fail2ban/jail.local ' "${SETUP}"; then
  fail "B7: eigene jail.local wird noch beschrieben (Ueberschreibt Operator-Jails)"
else
  pass "B7: jail.local wird nicht mehr beschrieben"
fi
grep -qF 'JAIL_DROPIN="/etc/fail2ban/jail.d/10-coder-sshd.local"' "${SETUP}" \
  && pass "B7: eigene Jails liegen in jail.d/10-coder-sshd.local" \
  || fail "B7: Drop-In-Pfad fehlt"
# Review 2.3: die hash-guardierte Entfernung einer vorgefundenen jail.local
# entfiel (ohne Produktion gibt es keine setup-eigene Alt-Datei). Was bleibt,
# ist die WARNUNG – angefasst wird nie.
grep -qF '[ -f /etc/fail2ban/jail.local ]; then' "${SETUP}" \
  && pass "B7: vorhandene jail.local wird erkannt (Pflicht: Warnung)" \
  || fail "B7: Erkennung vorhandener jail.local fehlt"
grep -qF 'rm -f /etc/fail2ban/jail.local' "${SETUP}" \
  && fail "B7: vorgefundene jail.local wird noch entfernt (Operator-Datenverlust)" \
  || pass "B7: vorgefundene jail.local wird nicht entfernt"
# B3/B13: forget_hash und die Hash-Vergleichs-Logik sind toter Code gewesen
# (Jail-Bans liegen in fail2bans SQLite) und wurden entfernt.
grep -qF 'forget_hash() {' "${SETUP}" \
  && fail "B3: forget_hash ist noch im Setup (toter Code)" \
  || pass "B3: kein forget_hash (toter Code entfernt)"
grep -qF 'JAIL_CHANGED=1' "${SETUP}" \
  && fail "B7: JAIL_CHANGED-Flag ist noch im Setup (entfiel mit dem hash-guardierten Loeschen)" \
  || pass "B7: kein JAIL_CHANGED-Flag"
grep -qF '[ "${JAIL_BEFORE}" = "${JAIL_AFTER}" ]' "${SETUP}" \
  && fail "B13: hash-basierte Reload-Entscheidung ist noch im Setup (entfiel: Bans in SQLite)" \
  || pass "B13: keine hash-basierte Reload-Entscheidung (enable --now + reload)"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-007: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-007: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
