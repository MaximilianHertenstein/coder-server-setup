#!/bin/bash
# T-102-Delta / B2-006: reset-coder.sh Pre-Check VOR 'docker compose down'.
# Geprueft: Reihenfolge im eingebetteten reset-coder.sh (Belegungs-Check vor
# down), Projekt-Container-Ausschluss (sonst breche jeder Re-Run auf
# laufendem Stack ab), wahrheitsgemaeße Meldungen (kein "Stack ist gestoppt"),
# Verhalten des Ausschluss-Filters als Verhaltensfixture.
# Review-Set 2026-10-03, §3: ausserdem kleine CLI (nur [] und --force,
# Tippfehler abgelehnt) und harte Regel "keine Nicht-Compose-Container"
# VOR jedem destruktiven Schritt (--force hebt sie nicht auf).
# Nur /tmp, kein Docker, keine Produktion.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# reset-coder.sh als echte Datei unter scripts/ (das Setup spielt sie ein).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cp "${REPO_ROOT}/scripts/reset-coder.sh" "${WORK}/reset-coder.sh" \
  || fail "scripts/reset-coder.sh nicht lesbar"
LINES=$(wc -l < "${WORK}/reset-coder.sh")
echo "INFO: scripts/reset-coder.sh = ${LINES} Zeilen"
[ "${LINES}" -gt 50 ] || fail "reset-coder.sh zu kurz (nicht extrahierbar?)"
# B10/2.1: das Setup schreibt alle scripts/*.sh (inkl. reset-coder.sh) per
# write_managed-Schleife (Hash + bash -n + atomar), frueher per install-Zeile.
if grep -qF 'for _src in "${SETUP_DIR}"/scripts/*.sh' "${SETUP}"; then
  pass "Setup schreibt scripts/*.sh (inkl. reset-coder.sh) per Schleife"
else
  fail "Setup schreibt scripts/*.sh nicht (Schleife fehlt)"
fi
if grep -qF 'install -m 755 -t /opt/coder' "${SETUP}"; then
  fail "doppelte Installation per install(1) ist noch im Setup"
else
  pass "keine doppelte install(1)-Zeile mehr"
fi

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

# --- 2. Inventar-Format: Projekt-Container erkennen, Fremde melden ----------
# Format 3 Spalten: Name \t Status \t com.docker.compose.project; awk meldet
# alles, dessen Projekt NICHT ${PROJECT} ist (inkl. ungelabelter Container).
if grep -qF -- '--format '\''{{.Names}}\t{{.Status}}\t{{.Label "com.docker.compose.project"}}'\''' "${WORK}/reset-coder.sh" \
  && grep -qF -- 'awk -v p="${PROJECT}" -F'\''\t'\'' '\''$3 != p {print "  fremd: "' "${WORK}/reset-coder.sh"; then
  pass "Inventar-Format: Fremd-/Unlabelled-Container werden erkannt"
else
  fail "Inventar-Format fehlt (Nicht-Compose-Container-Meldung unbrauchbar)"
fi

# Belegungs-Check (Volume): Projekt-Container muessen draussen bleiben, sonst
# breche jeder Re-Run auf laufendem Stack ab. Zweites, anderes Format als im
# Inventar oben (2 Spalten: ID + Projekt-Label).
if grep -qF -- '--format '\''{{.ID}} {{.Label "com.docker.compose.project"}}'\''' "${WORK}/reset-coder.sh" \
  && grep -qF -- 'awk -v p="${PROJECT}" '\''$2 != p {print $1}'\''' "${WORK}/reset-coder.sh"; then
  pass "Belegungs-Check schliesst Projekt-Container aus"
else
  fail "Projekt-Container-Ausschluss im Belegungs-Check fehlt (ohne ihn bricht jeder laufende Re-Run ab)"
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

# --- 5. Verhaltensfixture: Inventar-Filter (awk-Teil identisch zum Code) ----
own=$'compose1\tRunning\tcoder\ncompose2\tRunning\tcoder\nfremd1\tExited\t\nfremd2\tRunning\totherstack'
filtered="$(printf '%s\n' "${own}" | awk -v p="coder" -F'\t' '$3 != p {print "  fremd: " $1 " (" $2 ")"}')"
if [ "${filtered}" = "  fremd: fremd1 (Exited)
  fremd: fremd2 (Running)" ]; then
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

# --- 7. Kleine CLI + harte Regel "keine Nicht-Compose-Container" ------------
# Review-Set 2026-10-03, §3: nur [] und --force sind erlaubt; fremde
# Container brechen VOR jedem destruktiven Schritt ab, --force hebt das
# Gate nicht auf (es schuetzt vor verwaisten Containern, nicht vor Backup-
# Problemen).
if grep -qF -- '[ "$#" -gt 1 ] || { [ "$#" -ge 1 ] && [ "$1" != "--force" ]; }' "${WORK}/reset-coder.sh" \
  && grep -qF 'unbekanntes Argument' "${WORK}/reset-coder.sh"; then
  pass "Argument-Pruefung vorhanden (nur [] und --force)"
else
  fail "Argument-Pruefung fehlt (Tippfehler laufen still als 'ohne --force')"
fi
# Verhaltensfixture: dieselbe Bedingung wie im Skript.
arg_reject() { [ "$#" -gt 1 ] || { [ "$#" -ge 1 ] && [ "$1" != "--force" ]; }; }
if arg_reject foo; then pass "Fixture: 'foo' abgelehnt"; else fail "Fixture: 'foo' wurde NICHT abgelehnt"; fi
if arg_reject --force; then fail "Fixture: '--force' wurde abgelehnt"; else pass "Fixture: '--force' akzeptiert"; fi
if arg_reject; then fail "Fixture: leere Argumentliste wurde abgelehnt"; else pass "Fixture: ohne Argumente akzeptiert"; fi
if arg_reject --force extra; then pass "Fixture: '--force' plus Extra-Argument abgelehnt"; else fail "Fixture: Extra-Argument wurde geschluckt"; fi

L_FOREIGN=$(line_of 'Fehler: Nicht-Compose-Container vorhanden' || true)
if [ -n "${L_FOREIGN}" ]; then
  pass "harter Abbruch bei Nicht-Compose-Containern vorhanden"
else
  fail "harter Abbruch bei Nicht-Compose-Containern fehlt (nur Warnung waere zu schwach)"
fi
if [ -n "${L_FOREIGN}" ] && [ "${L_FOREIGN}" -lt "${L_VOLDET}" ]; then
  pass "Fremd-Container-Gate steht vor Volume-Ermittlung/down (vor Backup/Confirm)"
else
  fail "Fremd-Container-Gate steht nicht vor den destruktiven Schritten"
fi
# --force darf das Gate NICHT umgehen: innerhalb des Abbruchblocks kein FORCE.
GATE_BLOCK=$(awk '/Fehler: Nicht-Compose-Container vorhanden/{f=1} f{print} f&&/exit 1/{exit}' "${WORK}/reset-coder.sh")
if printf '%s\n' "${GATE_BLOCK}" | grep -q 'FORCE'; then
  fail "--force umgeht das Fremd-Container-Gate"
else
  pass "--force hebt das Fremd-Container-Gate NICHT auf"
fi
# Weiche Alt-Meldungen sind entfallen (jetzt harte Klemme).
for gone in \
  'B-020: Falls im Inventar oben fremde Container standen' \
  'Verwaiste Workspace-Container (Inventar vor '\''down'\'', B-020)'; do
  if grep -qF -- "${gone}" "${WORK}/reset-coder.sh"; then
    fail "weiche Alt-Meldung noch vorhanden: ${gone}"
  else
    pass "weiche Alt-Meldung entfernt: ${gone}"
  fi
done

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-006: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-006: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
