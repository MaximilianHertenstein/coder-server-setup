#!/bin/bash
# T-102-Delta / B2-006: reset-coder.sh Pre-Check VOR 'docker compose down'.
# Geprueft: Reihenfolge im eingebetteten reset-coder.sh (Belegungs-Check vor
# down), Projekt-Container-Ausschluss (sonst breche jeder Re-Run auf
# laufendem Stack ab), wahrheitsgemaeße Meldungen (kein "Stack ist gestoppt"),
# Verhalten des Ausschluss-Filters als Verhaltensfixture.
# Nur /tmp, kein Docker, keine Produktion.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# reset-coder.sh-Heredoc extrahieren (genau der eingebettete Block).
awk '/^write_managed .*reset-coder.sh/ {f=1;next} f&&/^EOF$/{f=0} f' \
  "${SETUP}" > "${WORK}/reset-coder.sh"
LINES=$(wc -l < "${WORK}/reset-coder.sh")
echo "INFO: extrahiertes reset-coder.sh = ${LINES} Zeilen"
[ "${LINES}" -gt 50 ] || fail "reset-coder.sh-Heredoc nicht extrahiert"

line_of() { grep -nF -- "$1" "${WORK}/reset-coder.sh" | head -n1 | cut -d: -f1; }

# --- 1. Reihenfolge: Belegungs-Check vor 'docker compose down' ---------------
L_CHECK=$(line_of 'docker ps -a --filter "volume=${VOL_NAME}"' || true)
L_DOWN=$(line_of 'docker compose down --remove-orphans' || true)
L_VOLDET=$(line_of 'Ermittle Datenbank-, Grafana- und Prometheus-Volumes' || true)
L_RM=$(line_of 'docker volume rm "${VOL_NAME}"' || true)
echo "INFO: Positionen ermitteln=${L_VOLDET} check=${L_CHECK} down=${L_DOWN} rm=${L_RM}"

[ -n "${L_CHECK}" ] || fail "Belegungs-Check (docker ps -aq --filter volume=) fehlt"
[ -n "${L_DOWN}" ] || fail "'docker compose down --remove-orphans' fehlt"
[ -n "${L_VOLDET}" ] || fail "Volume-Ermittlung fehlt"

if [ -n "${L_CHECK}" ] && [ -n "${L_DOWN}" ] && [ "${L_CHECK}" -lt "${L_DOWN}" ]; then
  pass "Belegungs-Check steht VOR 'docker compose down' (B2-006)"
else
  fail "Belegungs-Check steht NICHT vor 'docker compose down'"
fi

if [ -n "${L_VOLDET}" ] && [ -n "${L_CHECK}" ] && [ "${L_VOLDET}" -lt "${L_CHECK}" ]; then
  pass "Volume-Ermittlung steht VOR dem Belegungs-Check"
else
  fail "Volume-Ermittlung steht nicht vor dem Belegungs-Check"
fi

if [ -n "${L_DOWN}" ] && [ -n "${L_RM}" ] && [ "${L_DOWN}" -lt "${L_RM}" ]; then
  pass "'down' steht vor der Volume-Löschung"
else
  fail "'down' steht nicht vor der Volume-Löschung"
fi

# Keine zweite (alte) down-Stelle vor dem Check.
DOWN_COUNT=$(grep -cF 'docker compose down --remove-orphans' "${WORK}/reset-coder.sh" || true)
if [ "${DOWN_COUNT}" -eq 1 ]; then
  pass "genau EINE 'docker compose down'-Stelle"
else
  fail "unerwartete Anzahl 'docker compose down'-Stellen: ${DOWN_COUNT}"
fi

# --- 2. Projekt-Container-Ausschluss vorhanden ------------------------------
if grep -qF -- '--format '\''{{.ID}} {{.Label "com.docker.compose.project"}}'\''' "${WORK}/reset-coder.sh" \
  && grep -qF -- 'awk -v p="${PROJECT}" '\''$2 != p {print $1}'\''' "${WORK}/reset-coder.sh"; then
  pass "Projekt-Container werden aus dem Belegungs-Check ausgeschlossen"
else
  fail "Projekt-Container-Ausschluss fehlt (ohne ihn bricht jeder laufende Re-Run ab)"
fi

# Regressionswächter: "-q" UND "--format" an derselben docker-ps-Aufrufkette
# sind unvereinbar – docker verwirft --format dann ("Ignoring custom format"),
# das Label fehlt und der Filter zählt auch Projekt-Container als Beleg.
if grep -qF -- 'docker ps -aq --filter "volume=${VOL_NAME}"' "${WORK}/reset-coder.sh"; then
  fail "-q in der docker-ps-Aufrufkette – --format würde von docker verworfen"
elif grep -qF -- 'docker ps -a --filter "volume=${VOL_NAME}"' "${WORK}/reset-coder.sh"; then
  pass "kein -q neben --format in der docker-ps-Aufrufkette"
else
  fail "docker ps -a --filter volume= fehlt"
fi

# --- 3. Meldungen wahrheitsgezaeh (B2-006: "nichts angefasst") -------------
if grep -qF 'nichts angefasst' "${WORK}/reset-coder.sh"; then
  pass "Abbruchmeldungen sagen 'nichts angefasst'"
else
  fail "'nichts angefasst' fehlt in den Abbruchmeldungen"
fi

if grep -qF "Abbruch VOR '.env'-Löschung – Stack ist gestoppt" "${WORK}/reset-coder.sh"; then
  fail "alte falsche Meldung 'Stack ist gestoppt' noch vorhanden (vor down gestoppt)"
else
  pass "alte Meldung 'Stack ist gestoppt' ist entfernt"
fi

if grep -qF "nichts gelöscht, .env intakt" "${WORK}/reset-coder.sh"; then
  fail "alte Meldung 'nichts gelöscht, .env intakt' noch vorhanden"
else
  pass "alte Meldung 'nichts gelöscht, .env intakt' ist entfernt"
fi

if grep -qF "Abbruch VOR 'docker compose down'" "${WORK}/reset-coder.sh"; then
  pass "Abbruchtext nennt den exakten Abbruchpunkt (vor down)"
else
  fail "Abbruchtext nennt 'docker compose down' nicht"
fi

# --- 4. Bestandsschutz: Leer-Guard, Allowlist, --force, TTY-Guard -----------
for token in \
  'postgres_data|grafana_data|prometheus_data) ;;' \
  'RESET-OHNE-BACKUP' \
  'stdin ist kein Terminal' \
  'docker volume ls -q --filter "label=com.docker.compose.project=${PROJECT}"'; do
  if grep -qF -- "${token}" "${WORK}/reset-coder.sh"; then
    pass "Bestandsschutz vorhanden: ${token}"
  else
    fail "Bestandsschutz fehlt: ${token}"
  fi
done

# --- 5. Verhaltensfixture: Ausschluss-Filter (awk-Teil identisch zum Code) ---
own='ab12cd34 coder
cd56ef78 coder
deadbeef
9f8e7d6c otherstack'
filtered="$(printf '%s\n' "${own}" | awk -v p="coder" '$2 != p {print $1}')"
if [ "${filtered}" = "deadbeef
9f8e7d6c" ]; then
  pass "Filter: Projekt-Container raus, Fremd- und Unlabelled-Container rein"
else
  fail "Filterverhalten falsch: [$(printf '%s' "${filtered}" | tr '\n' '|')]"
fi

# --- 6. Statischer Guard: Abbruch vor jedem destruktiven Schritt ------------
L_ABORT=$(grep -nF 'Abbruch VOR '\''docker compose down'\''' "${WORK}/reset-coder.sh" | head -n1 | cut -d: -f1)
if [ -n "${L_ABORT}" ] && [ "${L_ABORT}" -lt "${L_DOWN}" ]; then
  pass "Abbruch-Exit steht vor dem down"
else
  fail "Abbruch-Exit steht nicht vor dem down"
fi

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-006: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-006: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
