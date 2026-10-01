#!/bin/bash
# B2-010: Boot-Gate muss auf den ersten Health-Probe von Postgres warten.
# Fund 2026-09-28 (Test-Host, echter Reboot): boot-check.sh startete per
# @reboot, las den Health-Status sofort (T+0 s => "starting") und meldete
# "ROT: Postgres nicht healthy nach Boot", obwohl der Stack gesund war
# (healthy ab T+4 s). Jeder Reboot erzeugte damit ein falsches ROT.
# Der ECHTE boot-check.sh liegt als Datei unter scripts/ und wird mit
# Fake-docker/Fake-sleep in /tmp gefahren (kein Root, keine Produktion).
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
mkdir -p "${BIN}"

# ---------- boot-check.sh als echte Datei unter scripts/ ----------
BOOT="${WORK}/boot-check.sh"
if cp "${REPO_ROOT}/scripts/boot-check.sh" "${BOOT}" 2>/dev/null; then
  pass "scripts/boot-check.sh vorhanden"
else
  fail "scripts/boot-check.sh nicht lesbar"
  echo "T-B2-010: FEHLGESCHLAGEN"; exit 1
fi
if grep -qF 'scripts/boot-check.sh' "${SETUP}"; then
  pass "Setup installiert boot-check.sh aus scripts/"
else
  fail "Setup installiert scripts/boot-check.sh nicht"
fi
bash -n "${BOOT}" && pass "boot-check.sh ist syntaktisch gueltig" || fail "Syntax"

# Erwartete Warteschleife vorhanden, alter Kurz-Check ohne Wartezeit weg.
grep -qF 'for _ in $(seq 1 24); do' "${BOOT}" \
  && pass "Warteschleife vorhanden (seq 1 24, max 120 s)" || fail "Warteschleife fehlt"
grep -qF 'PG_HEALTH="$(docker inspect -f' "${BOOT}" \
  && pass "Status wird in der Schleife gelesen (PG_HEALTH)" || fail "PG_HEALTH-Lesung fehlt"
if grep -qF "if [ \"\$(docker inspect -f '{{.State.Health.Status}}' coder-postgres 2>/dev/null || echo none)\" != \"healthy\" ]; then" "${BOOT}"; then
  fail "alter Sofort-Check ohne Wartezeit ist noch vorhanden"
else
  pass "alter Sofort-Check ohne Wartezeit entfernt"
fi

# ---------- Fakes -----------------------------------------------------------
cat > "${BIN}/docker" <<'FAKE'
#!/usr/bin/env bash
case "${1:-}" in
  inspect)
    fmt="${3:-}"
    case "${fmt}" in
      '{{.State.Running}}') echo true ;;
      '{{.State.Health.Status}}')
        f="${FAKE_DIR}/health.seq"
        if [ -s "${f}" ]; then
          line="$(head -n1 "${f}")"
          tail -n +2 "${f}" > "${f}.n" && mv "${f}.n" "${f}"
          printf '%s\n' "${line}" > "${f}.last"
        else
          line="$(head -n1 "${f}.last" 2>/dev/null || echo starting)"
        fi
        printf '%s\n' "${line}"
        ;;
      *) exit 1 ;;
    esac
    exit 0
    ;;
esac
exit 1
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "${BIN}/sleep"
chmod +x "${BIN}/docker" "${BIN}/sleep"

# boot-check.sh setzt am Anfang eine harte PATH-Liste – Fake-Verzeichnis
# davorhaengen, sonst greifen die Shims nicht. Der Logpfad zeigt nach /var/log
# (als Normalbenutzer nicht schreibbar) – fuer den Test nach /tmp umbiegen.
sed -i "s|^export PATH=.*|export PATH=\"${BIN}:\$PATH\"|" "${BOOT}"
sed -i "s|^LOG=\"/var/log/coder-boot.log\"|LOG=\"${WORK}/coder-boot.log\"|" "${BOOT}"

run_boot() {  # $1=Sequenzdatei (eine Zeile pro Aufruf); Ergebnis in $LOGFILE
  printf '%s\n' $1 > "${WORK}/health.seq"
  rm -f "${WORK}/health.seq.last" "${WORK}/coder-boot.log"
  local rc=0
  ( export FAKE_DIR="${WORK}"; export PATH="${BIN}:${PATH}"; bash "${BOOT}" ) \
    >> "${WORK}/run.out" 2>&1 || rc=$?
  return "${rc}"
}
LOGFILE="${WORK}/coder-boot.log"

# ---------- (1) starting -> healthy: GRUEN -----------------------------------
RC=0; run_boot "starting healthy" || RC=$?
grep -qF "OK: Postgres healthy nach Boot" "${LOGFILE}" \
  && pass "(1) Health wird abgewartet -> 'OK: Postgres healthy nach Boot'" \
  || fail "(1) OK-Zeile fehlt: $(tr '\n' '|' < "${LOGFILE}" 2>/dev/null)"
grep -qF "ROT: Postgres" "${LOGFILE}" \
  && fail "(1) trotz healthy eine ROT-Zeile: $(tr '\n' '|' < "${LOGFILE}")" \
  || pass "(1) keine ROT-Zeile bei healthy"
grep -qF "BOOT-GATE GRÜN" "${LOGFILE}" \
  && pass "(1) Gesamturteil BOOT-GATE GRUEN" || fail "(1) Urteil fehlt"
[ "${RC}" -eq 0 ] && pass "(1) Exit 0" || fail "(1) Exit ${RC} statt 0"

# ---------- (2) dauerhaft starting: echtes ROT -------------------------------
RC=0; run_boot "starting" || RC=$?
grep -qF "ROT: Postgres nach Boot 'starting' (120 s gewartet)" "${LOGFILE}" \
  && pass "(2) nach 120 s weiterhin starting -> echtes ROT" \
  || fail "(2) ROT-Zeile fehlt: $(tr '\n' '|' < "${LOGFILE}" 2>/dev/null)"
grep -qF "BOOT-GATE ROT" "${LOGFILE}" \
  && pass "(2) Gesamturteil BOOT-GATE ROT" || fail "(2) Urteil fehlt"
[ "${RC}" -eq 1 ] && pass "(2) Exit 1" || fail "(2) Exit ${RC} statt 1"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-010: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-010: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
