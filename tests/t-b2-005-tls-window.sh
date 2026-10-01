#!/bin/bash
# T/B2-005: Zählung gegen Log-Rotation.
# check-tls.sh zählt "obtaining certificate" in `docker logs --since 168h`;
# der Puffer ist 10 MB x 3 und kann kürzer als 7 Tage sein. Geprüft wird:
#   - extrahiertes check-tls.sh syntaktisch gültig
#   - Fensterlänge und Truncation werden als Metrik abgelegt
#   - Rotation-Verlust erzeugt eine WARNUNG (Zahl = Untergrenze)
#   - frischer Container erzeugt nur einen HINWEIS, keine Warnung
#   - Alert TlsLogTruncated existiert auf derselben Metrik
# Nur /tmp, keine Produktion: Pfad und PATH im extrahierten Kopf umgebogen,
# docker/logger als Fakes.
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

# --- Produktions-Skript als echte Datei unter scripts/ ----------------------
if cp "${REPO_ROOT}/scripts/check-tls.sh" "${WORK}/check-tls.raw" 2>/dev/null; then
  pass "scripts/check-tls.sh vorhanden"
else
  fail "scripts/check-tls.sh nicht lesbar"
fi
if grep -qF 'scripts/check-tls.sh' "${SETUP}"; then
  pass "Setup installiert check-tls.sh aus scripts/"
else
  fail "Setup installiert scripts/check-tls.sh nicht"
fi
bash -n "${WORK}/check-tls.raw" && pass "check-tls.sh ist syntaktisch gueltig" || fail "Syntax check-tls.sh"

# --- Fakes ------------------------------------------------------------------
cat > "${BIN}/docker" <<'FAKE'
#!/usr/bin/env bash
# FAKE_LOG_LINES: Body für --since (COUNT), FAKE_TS_LINES: --timestamps,
# FAKE_STARTED_AT: Ausgabe von inspect -f '{{.State.StartedAt}}'.
cmd="${1:-}"; shift || true
case "${cmd}" in
  logs)
    case "${1:-}" in
      --since)      printf '%s\n' "${FAKE_LOG_LINES}" ;;
      --timestamps) printf '%s\n' "${FAKE_TS_LINES}" ;;
      *) exit 1 ;;
    esac ;;
  inspect) printf '%s\n' "${FAKE_STARTED_AT}" ;;
  *) exit 1 ;;
esac
FAKE
cat > "${BIN}/logger" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LOGGER_OUT}"
FAKE
chmod 755 "${BIN}/docker" "${BIN}/logger"

# --- Statische Prüfung: Metrik + Alert --------------------------------------
for needle in 'coder_tls_log_window_seconds ${WINDOW}' 'coder_tls_log_truncated ${TRUNCATED}'; do
  grep -qF "${needle}" "${WORK}/check-tls.raw" \
    && pass "Metrik im Skript: ${needle}" || fail "Metrik fehlt: ${needle}"
done
if grep -qF -- '- alert: TlsLogTruncated' "${SETUP}" \
  && grep -qF -- 'expr: coder_tls_log_truncated == 1' "${SETUP}"; then
  pass "Alert TlsLogTruncated auf coder_tls_log_truncated == 1"
else
  fail "Alert TlsLogTruncated fehlt oder prueft etwas anderes"
fi
grep -qF 'coder_tls_log_truncated' "${SETUP}" \
  && pass "Alert-Name und Metrik stimmen ueberein" || fail "Alert ohne Metrik"

# --- Lauf-Szenarien ----------------------------------------------------------
ts() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }
BODY='2026-09-30T10:00:00Z info: obtaining certificate
2026-09-30T10:00:01Z error: something
2026-09-30T10:00:02Z info: obtaining certificate
2026-09-30T10:00:03Z info: obtaining certificate
2026-09-30T10:00:04Z info: served'

run_case() { # $1=Name $2=Logalter $3=Containeralter $4=erwartet-trunc
  local name="$1" age="$2" start="$3" want="$4"
  local dir="${WORK}/${name}" out="${WORK}/${name}.out"
  mkdir -p "${dir}/textfile"
  sed -e "s|export PATH=\"/usr/local/sbin|export PATH=\"${BIN}:/usr/local/sbin|" \
      -e "s|/opt/coder/node-textfile|${dir}/textfile|g" \
      "${WORK}/check-tls.raw" > "${dir}/check-tls.sh"
  : > "${dir}/logger.out"
  local rc=0
  FAKE_LOG_LINES="${BODY}" \
  FAKE_TS_LINES="$(ts "${age}") obtaining certificate
$(ts "${age}") info: served" \
  FAKE_STARTED_AT="$(ts "${start}")" \
  FAKE_LOGGER_OUT="${dir}/logger.out" \
    bash "${dir}/check-tls.sh" > "${out}" 2>&1 || rc=$?
  [ "${rc}" -eq 0 ] && pass "${name}: Exit 0" || fail "${name}: rc=${rc}"
  grep -qxF "coder_tls_log_truncated ${want}" "${dir}/textfile/coder_tls.prom" \
    && pass "${name}: coder_tls_log_truncated ${want}" \
    || fail "${name}: coder_tls_log_truncated falsch ($(grep -c 'coder_tls_log_truncated' "${dir}/textfile/coder_tls.prom" 2>/dev/null || echo 0) Zeilen)"
  grep -qxF 'coder_tls_issuances_7d 3' "${dir}/textfile/coder_tls.prom" \
    && pass "${name}: Zaehler steht auf 3" || fail "${name}: coder_tls_issuances_7d != 3"
  grep -qE '^coder_tls_log_window_seconds [0-9]+$' "${dir}/textfile/coder_tls.prom" \
    && pass "${name}: Logfenster als Metrik abgelegt" || fail "${name}: coder_tls_log_window_seconds fehlt"
  if [ "${want}" = "1" ]; then
    grep -q 'WARNUNG: Caddy-Log reicht nur' "${out}" \
      && pass "${name}: WARNUNG wegen Rotation" || fail "${name}: WARNUNG fehlt: $(tail -n1 "${out}")"
    grep -q 'trunc=1' "${dir}/logger.out" \
      && pass "${name}: syslog-Meldung mit trunc=1" || fail "${name}: syslog-Meldung ohne trunc=1"
    grep -q 'HINWEIS: Caddy-Logfenster' "${out}" \
      && fail "${name}: HINWEIS trotz Rotation-Warnung" || pass "${name}: kein widerspruechlicher HINWEIS"
  else
    grep -q 'WARNUNG: Caddy-Log reicht nur' "${out}" \
      && fail "${name}: WARNUNG ohne Verlust: $(grep 'WARNUNG' "${out}")" || pass "${name}: keine WARNUNG"
  fi
}

# A: Puffer reicht (10 Tage alt) -> volles Fenster, keine Meldung
run_case voll "10 days ago" "30 days ago" 0
grep -qxF 'coder_tls_log_window_seconds 604800' "${WORK}/voll/textfile/coder_tls.prom" \
  && pass "voll: Fenster auf 7 Tage gedeckelt (604800)" || fail "voll: Fenster nicht gedeckelt"
grep -q 'HINWEIS: Caddy-Logfenster' "${WORK}/voll.out" \
  && fail "voll: HINWEIS obwohl Fenster voll" || pass "voll: keine Meldung"
grep -q 'Logfenster: 168 Std.' "${WORK}/voll.out" \
  && pass "voll: Ausgabe nennt 168 Std." || fail "voll: Logfenster-Zeile fehlt"

# B: Rotation hat Eintraege verworfen (Log 2 Tage, Container 30 Tage)
run_case rotation "2 days ago" "30 days ago" 1
grep -qxF 'coder_tls_log_window_seconds 172800' "${WORK}/rotation/textfile/coder_tls.prom" \
  && pass "rotation: Fenster 172800 s (2 Tage)" || fail "rotation: Fensterwert falsch"

# C: frischer Container (Log und Start 1 Tag) -> nur HINWEIS
run_case frisch "1 day ago" "1 day ago" 0
grep -q 'HINWEIS: Caddy-Logfenster' "${WORK}/frisch.out" \
  && pass "frisch: HINWEIS statt Warnung" || fail "frisch: HINWEIS fehlt"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-005: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-005: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
