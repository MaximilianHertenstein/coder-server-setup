#!/bin/bash
# Root-Guard + Wartungs-Lock (Lock am Deskriptor 8 statt coproc-Wächter).
# Geprueft:
#   - der Guard steht vor der ersten Systemaenderung (Zeilenreihenfolge)
#   - der alte coproc-Wächter ist weg, der fd-Lock ist da
#   - ohne root bricht der echte Aufruf VOR Schritt 1 ab (nur wenn die
#     Tests selbst nicht als root laufen – sonst wuerde das Skript echt
#     ausgefuehrt und duerfte nicht gestartet werden)
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"

GUARD='if [ "$(id -u)" -ne 0 ]; then'
n="$(grep -cF "${GUARD}" "${SETUP}" || true)"
[ "${n}" -eq 1 ] && pass "Guard-Anker genau einmal" || fail "Guard-Anker-Anzahl=${n} (erwartet 1)"

# fd-Lock vorhanden (die Stelle selbst mehrfach: die Wartungsskripte nutzen
# dieselbe Idiom), coproc-Wächter weg, Lock-Datei weiter root:root 600.
for anchor in 'exec 8>>/opt/coder/.maintenance.lock' 'flock -w 300 8'; do
  n="$(grep -cF "${anchor}" "${SETUP}" || true)"
  [ "${n}" -ge 1 ] && pass "fd-Lock vorhanden (${n}x): ${anchor}" || fail "fd-Lock fehlt: ${anchor}"
done
n="$(grep -cF 'chown root:root /opt/coder/.maintenance.lock' "${SETUP}" || true)"
[ "${n}" -ge 1 ] && pass "Lock-Datei wird root:root angelegt (${n}x, Setup-Block inkl.)" \
  || fail "Lock-Datei-Anlage fehlt"

line() { grep -nF "$1" "${SETUP}" | head -n1 | cut -d: -f1; }
LG="$(line "${GUARD}")"
for after in 'exec 8>>/opt/coder/.maintenance.lock' 'mkdir -p /opt/coder' 'apt_install ca-certificates curl'; do
  LA="$(line "${after}")"
  [ -n "${LG}" ] && [ -n "${LA}" ] && [ "${LG}" -lt "${LA}" ] \
    && pass "Guard steht vor der ersten Aenderung (Z.${LG} < Z.${LA}: ${after})" \
    || fail "Guard nicht vor: ${after} (Guard=${LG} Ziel=${LA})"
done

grep -qF 'coproc SETUP_LOCKER' "${SETUP}" \
  && fail "alter coproc-Wächter ist noch im Code" || pass "kein coproc-Wächter mehr"
grep -qF 'CODER_MAINTENANCE_LOCK_HELD=1' "${SETUP}" \
  && pass "Lock-Flag wird weitergesetzt (Wartungsskripte ueberspringen ihren Lock)" \
  || fail "CODER_MAINTENANCE_LOCK_HELD fehlt"

if [ "$(id -u)" -eq 0 ]; then
  echo "INFO: Tests laufen als root – Ausfuehrungsprobe uebersprungen (Guard-Probe nur strukturell)"
else
  OUT="$(bash "${SETUP}" 2>&1)" && RC=0 || RC=$?
  [ "${RC}" = 1 ] && pass "Aufruf ohne root: Exit 1" || fail "Aufruf ohne root: rc=${RC} (erwartet 1)"
  printf '%s' "${OUT}" | grep -qF "muss als root laufen" \
    && pass "Klartext-Meldung im Abbruch" || fail "Guard-Meldung fehlt: ${OUT}"
  printf '%s' "${OUT}" | grep -qF "[1/10]" \
    && fail "Skript ist über Schritt 1 hinausgekommen (Guard greift zu spaet)" \
    || pass "Abbruch vor Schritt 1"
fi

if [ "${FAIL}" -eq 0 ]; then
  echo "T-ROOT-GUARD: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-ROOT-GUARD: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
