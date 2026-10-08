#!/bin/bash
# T-026-Delta / B2-007: zentraler atomarer Schreibhelfer write_managed.
# Geprueft: alle verwalteten Dateien nutzen genau ihn (ein Schreibaufruf je
# Pfad), Temp-Datei im Zielverzeichnis, Validierer vor dem Austausch,
# bash -n-Guard fuer *.sh; Hash-/Drift-Infrastruktur (Hashstore, note_drift,
# remember_hash) ist tote Komplexitaet ohne Operator-Workflow und gehoert
# nicht in den Quelltext.
# Verhalten der ECHTEN write_managed-Funktion (ausextrahiert aus
# setup-coder.sh, Ziele in /tmp):
#   (a) identischer Inhalt -> Ziel-Inode unangetastet, Modus nachgezogen
#   (b) anderer Inhalt -> atomarer Ersatz mit neuem Inhalt
#   (c) syntaktisch falsches *.sh -> Abbruch, Live-Datei unangetastet, kein Temp
#   (d) fehlschlagender Validierer -> Abbruch, Live-Datei unangetastet
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
# 12 direkte write_managed-Adressen (B3b: coder-egress-firewall.service).
# SSH-Drop-In und versions.env adressieren ueber Variablen und stehen nicht
# in dieser Liste (unten separat geprueft).
EXPECTED="/opt/coder/docker-compose.yml
/opt/coder/caddy/Caddyfile
/opt/coder/prometheus/rules/coder-alerts.yml
/opt/coder/prometheus/prometheus.yml
/opt/coder/grafana/provisioning/datasources/prometheus.yml
/opt/coder/grafana/provisioning/dashboards/dashboards.yml
/opt/coder/grafana/provisioning/dashboards/server-load.json
/etc/fail2ban/jail.d/10-coder-sshd.local
/etc/apt/apt.conf.d/52-coder-reboot
/etc/cron.d/coder-backup
/etc/logrotate.d/coder-backup
/etc/systemd/system/coder-egress-firewall.service"

N_MANAGED=$(grep -c '^write_managed "/' "${SETUP}")
echo "INFO: write_managed=${N_MANAGED}"
[ "${N_MANAGED}" -eq 12 ] && pass "alle 12 direkt adressierten Dateien nutzen write_managed" || fail "write_managed-Anzahl=${N_MANAGED} (erwartet 12)"
grep -qF 'write_managed "${VERSIONS_FILE}"' "${SETUP}" && pass "versions.env nutzt ebenfalls write_managed" || fail "versions.env nutzt write_managed nicht"

# SSH-Drop-In: eigene Policy-Datei,
# per write_managed verwaltet, damit sie beim Setup-Lauf konsistent bleibt.
grep -qF 'SSHD_DROPIN="/etc/ssh/sshd_config.d/01-coder.conf"' "${SETUP}" \
  && grep -qF 'write_managed "${SSHD_DROPIN}"' "${SETUP}" \
  && pass "sshd-Drop-In wird per write_managed verwaltet" \
  || fail "sshd-Drop-In (01-coder.conf) fehlt oder nutzt write_managed nicht"

# 2.1: die Wartungsskripte kommen ueber eine Schleife (inkl. bash -n),
# nicht ueber Einzel-Aufrufe oder install(1).
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

grep -qF 'mv -f -- "${MANAGED_TMP}" "${file}"' "${SETUP}" \
  && pass "atomarer Austausch per mv im Schreibhelfer" \
  || fail "mv-Atomaritaet fehlt"
grep -qF 'mktemp "${dir}/.${base}.tmp.XXXXXX"' "${SETUP}" && pass "Temp-Datei wird im Zielverzeichnis angelegt" || fail "Temp-Datei liegt nicht im Zielverzeichnis"
grep -qF 'if ! bash -n "${MANAGED_TMP}"' "${SETUP}" \
  && pass "bash -n-Guard fuer generierte *.sh vorhanden" \
  || fail "bash -n-Guard fehlt"

# --- 2. Hash-/Drift-Infrastruktur ist entfernt -------------------------------
for tok in 'note_drift()' 'remember_hash()' 'forget_hash()' 'HASHSTORE=' 'JAIL_CHANGED=1'; do
  if grep -qF "${tok}" "${SETUP}"; then
    fail "Hash-/Drift-Reste noch im Setup: ${tok}"
  else
    pass "kein Hash-/Drift-Rest: ${tok}"
  fi
done
# Das alte Heil-Aueraeumen bleibt als idempotenter No-Op (Bereinigung
# produzierter Altbestaende), die Hash-Pflege selbst ist aber entfallen.
grep -qF 'rm -f /opt/coder/.generated-hashes' "${SETUP}" \
  && pass "Altbestands-Hashstore wird noch still aufgeraeumt" \
  || fail "Aufraeumen von .generated-hashes fehlt (Altbestand auf Upgrade-Hosts)"
# Schritt-10-Heilschleife und gebuendelte remember_hash-Nachzuege sind weg.
if grep -qF 'for _f in /opt/coder/docker-compose.yml' "${SETUP}"; then
  fail "Schritt-10-Hashschleife ist noch vorhanden"
else
  pass "Schritt-10-Hashschleife ist entfernt"
fi

# TLS-Check-Bestand (Altbestand):
# weder Skript noch Cron noch Logrotate werden weiter geschrieben; die
# stillen rm -f fuer Altbestand sind ausdruecklich erlaubt.
for tok in \
  'write_managed "/etc/cron.d/coder-tlscheck"' \
  'write_managed "/etc/logrotate.d/coder-logs"' \
  'write_managed "/opt/coder/check-tls.sh"' \
  'TlsIssuanceBudgetHigh' \
  'TlsCheckStale'; do
  if grep -qF "${tok}" "${SETUP}"; then
    fail "TLS-Check-Ära schreibt noch: ${tok}"
  else
    pass "TLS-Check-Ära entfernt: ${tok}"
  fi
done
grep -qF 'rm -f /etc/cron.d/coder-tlscheck' "${SETUP}" \
  && pass "Altbestand coder-tlscheck wird entfernt" \
  || fail "rm coder-tlscheck (Altbestand) fehlt"

# --- 3. Verhalten der ECHTEN write_managed-Funktion (aus setup-coder.sh) -----
awk '/^write_managed\(\)/{f=1} f{print} f&&/^}$/{exit}' \
  "${SETUP}" > "${WORK}/write_managed.sh"
W_LINES=$(wc -l < "${WORK}/write_managed.sh")
echo "INFO: extrahierte write_managed-Funktion = ${W_LINES} Zeilen"
grep -q '^write_managed()' "${WORK}/write_managed.sh" || fail "write_managed nicht extrahiert"
[ "${W_LINES}" -ge 30 ] || fail "Extraktion zu kurz (${W_LINES} Zeilen) – Brueche im Funktionskoerper?"

MANAGED_TMP=""
# shellcheck disable=SC1091
. "${WORK}/write_managed.sh"

T="${WORK}/probe.conf"

# (a) erster Schreibvorgang: Ziel entsteht mit gefordertem Modus.
rm -f "${T}"
write_managed "${T}" 600 - <<'WMEOF'
a=1
WMEOF
I1=$(stat -c %i "${T}")
M1=$(stat -c %a "${T}")
if [ "${M1}" = "600" ]; then
  pass "(a) Modus 600 wird gesetzt"
else
  fail "(a) Modus=${M1} (erwartet 600)"
fi

# (a) identischer Inhalt: Inode bleibt, Modus wird nachgezogen.
write_managed "${T}" 644 - <<'WMEOF'
a=1
WMEOF
I2=$(stat -c %i "${T}")
M2=$(stat -c %a "${T}")
if [ "${I2}" = "${I1}" ]; then
  pass "(a) identischer Inhalt -> Ziel-Inode unangetastet"
else
  fail "(a) Inode wurde ersetzt trotz identischem Inhalt"
fi
if [ "${M2}" = "644" ]; then
  pass "(a) Modus wird beim unveraenderten Inhalt nachgezogen"
else
  fail "(a) Modus=${M2} (erwartet 644)"
fi

# (b) anderer Inhalt -> atomarer Ersatz.
write_managed "${T}" 600 - <<'WMEOF'
b=2
WMEOF
if [ "$(cat "${T}")" = "b=2" ] && [ "$(stat -c %a "${T}")" = "600" ]; then
  pass "(b) neuer Inhalt atomar ersetzt, Modus gesetzt"
else
  fail "(b) Inhalt/Modus falsch: [$(cat "${T}")] / $(stat -c %a "${T}")"
fi

# (c) syntaktisch falsches *.sh -> return 1, Live-Datei unangetastet, Temp weg.
SH="${WORK}/bad.sh"
printf 'if true\n' > "${SH}"
RC=0
write_managed "${SH}" 755 - <<'WMEOF' || RC=$?
if true
WMEOF
if [ "${RC}" -ne 0 ]; then
  pass "(c) fehlerhaftes *.sh -> Abbruch (rc=${RC})"
else
  fail "(c) fehlerhaftes *.sh wurde geschrieben (kein bash -n-Guard?)"
fi
if [ "$(cat "${SH}")" = "if true" ]; then
  pass "(c) Live-Datei unangetastet"
else
  fail "(c) Live-Datei wurde ueberschrieben"
fi
if [ -z "$(ls -A "${WORK}"/.bad.sh.tmp.* 2>/dev/null || true)" ]; then
  pass "(c) keine Temp-Datei zurueckgelassen"
else
  fail "(c) Temp-Datei liegt noch im Zielverzeichnis"
fi
if [ -z "${MANAGED_TMP}" ]; then
  pass "(c) MANAGED_TMP wird geleert"
else
  fail "(c) MANAGED_TMP steht noch auf '${MANAGED_TMP}'"
fi

# (d) fehlschlagender Validierer -> return 1, Live-Datei unangetastet.
bad_validator() { return 1; }
RC=0
write_managed "${T}" 600 - bad_validator <<'WMEOF' || RC=$?
x=1
WMEOF
if [ "${RC}" -ne 0 ]; then
  pass "(d) fehlschlagender Validierer -> Abbruch (rc=${RC})"
else
  fail "(d) Validiererfehler wurde ignoriert"
fi
if [ "$(cat "${T}")" = "b=2" ]; then
  pass "(d) Live-Datei unangetastet (Validierer vor Austausch)"
else
  fail "(d) Live-Datei wurde trotz Validiererfehler ersetzt"
fi
if [ -z "$(ls -A "${WORK}"/.probe.conf.tmp.* 2>/dev/null || true)" ]; then
  pass "(d) keine Temp-Datei zurueckgelassen"
else
  fail "(d) Temp-Datei liegt noch im Zielverzeichnis"
fi

# --- 4. B7: Drop-In statt jail.local, Warnung statt stiller Entfernung ------
if grep -qF 'tee /etc/fail2ban/jail.local ' "${SETUP}"; then
  fail "B7: eigene jail.local wird noch beschrieben (Ueberschreibt Operator-Jails)"
else
  pass "B7: jail.local wird nicht beschrieben"
fi
grep -qF 'JAIL_DROPIN="/etc/fail2ban/jail.d/10-coder-sshd.local"' "${SETUP}" \
  && pass "B7: eigene Jails liegen in jail.d/10-coder-sshd.local" \
  || fail "B7: Drop-In-Pfad fehlt"
# Eine vorgefundene jail.local wird nie angefasst (ohne Produktion gibt es
# keine setup-eigene Alt-Datei). Was zaehlt, ist die WARNUNG.
grep -qF '[ -f /etc/fail2ban/jail.local ]; then' "${SETUP}" \
  && pass "B7: vorhandene jail.local wird erkannt (Pflicht: Warnung)" \
  || fail "B7: Erkennung vorhandener jail.local fehlt"
grep -qF 'rm -f /etc/fail2ban/jail.local' "${SETUP}" \
  && fail "B7: vorgefundene jail.local wird noch entfernt (Operator-Datenverlust)" \
  || pass "B7: vorgefundene jail.local wird nicht entfernt"
grep -qF '[ "${JAIL_BEFORE}" = "${JAIL_AFTER}" ]' "${SETUP}" \
  && fail "B13: hash-basierte Reload-Entscheidung ist noch im Setup" \
  || pass "B13: keine hash-basierte Reload-Entscheidung (enable --now + reload)"

# --- C3/Erstlauf: Provisioning-Hash darf pipefail nicht killen ---------------
# Ohne Verzeichnisse liefert find Exit 1; mit pipefail+set -e endet die
# Zuweisung in einem stillen Abbruch vor Schritt 3 (Review-Fund, Erstlauf).
PRE_LINE=$(grep -nF 'install -d -m 0755 /opt/coder/grafana/provisioning/datasources' "${SETUP}" | head -n1 | cut -d: -f1)
BEFORE_LINE=$(grep -nF 'GRAFANA_PROV_BEFORE=' "${SETUP}" | head -n1 | cut -d: -f1)
if [ -n "${PRE_LINE}" ] && [ -n "${BEFORE_LINE}" ] && [ "${PRE_LINE}" -lt "${BEFORE_LINE}" ]; then
  pass "C3: Provisioning-Verzeichnisse werden VOR GRAFANA_PROV_BEFORE angelegt"
else
  fail "C3: Anlage der Provisioning-Verzeichnisse fehlt vor GRAFANA_PROV_BEFORE (${PRE_LINE:-keine} vs ${BEFORE_LINE:-keine})"
fi
HAIRNET=$(grep -cF "cut -d' ' -f1 || true)" "${SETUP}" || true)
if [ "${HAIRNET}" -eq 2 ]; then
  pass "C3: beide Provisioning-Hashes mit ||-true (kein stiller pipefail-Abbruch)"
else
  fail "C3: || true an den Provisioning-Hashes: ${HAIRNET} statt 2"
fi

# --- Review-Runde: Crash-Loop, Projektlabel, Lock-Reihenfolge, Kommentar -----
grep -qF -- "docker inspect --type container -f '{{.State.Status}}'" "${SETUP}" \
  && pass "Abschlusscheck fragt State.Status ab (Restart-Loop kein fälschliches [OK])" \
  || fail "check_container_running nutzt nicht State.Status + --type container"
grep -qF -- 'label=com.docker.compose.project=coder' "${SETUP}" \
  && pass "postgres_data-Filter traegt Projektlabel (fremdes Projekt trifft nicht)" \
  || fail "Projektlabel am postgres_data-Filter fehlt"
L_SSHD=$(grep -nF 'sshd -T lieferte keinen Port' "${SETUP}" | head -n1 | cut -d: -f1)
L_LOCK=$(grep -nF 'exec 8>>/opt/coder/.maintenance.lock' "${SETUP}" | head -n1 | cut -d: -f1)
L_S1=$(grep -nF '[1/7] Docker Engine installieren' "${SETUP}" | head -n1 | cut -d: -f1)
if [ -n "${L_SSHD}" ] && [ -n "${L_LOCK}" ] && [ -n "${L_S1}" ] \
  && [ "${L_SSHD}" -lt "${L_LOCK}" ] && [ "${L_LOCK}" -lt "${L_S1}" ]; then
  pass "Wartungs-Lock nach sshd-Preflight und vor Schritt 1 (Meldungen sind wahr)"
else
  fail "Lock-Reihenfolge: sshd=${L_SSHD:-keine} lock=${L_LOCK:-keine} Schritt1=${L_S1:-keine}"
fi
grep -qF -- 'P-025 betrifft nur fail2ban' "${SETUP}" \
  && fail "P-025-Kommentar widerspricht P-025 (Verbot von Restarts, nicht fail2ban)" \
  || pass "kein widerspruechlicher P-025-Kommentar"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-007: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-007: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
