#!/bin/bash
# T/B2-005 (Stand: Review A6 – Zählung aus dem caddy_data-Volume statt aus
# docker logs). check-tls.sh zählt im Volume geänderte *.crt der letzten
# 7 Tage (robust gegen Container-Recreate) und schreibt zwei Metriken.
# Geprüft wird:
#   - extrahiertes check-tls.sh syntaktisch gültig
#   - Zählung per find -mtime -7 (kein docker logs, kein WINDOW/TRUNCATED)
#   - coder_tls_issuances_7d und last_success werden abgelegt
#   - Lesefehler -> Exit 1 OHNE Metrik-Aktualisierung (TlsCheckStale feuert)
#   - fehlendes certificates-Verzeichnis = frische Installation = Metrik 0
#     mit Erfolgszeitpunkt (KEIN TlsCheckStale-False-Positive bis zum
#     ersten Zertifikat), Container weg = Exit 1
#   - Alert TlsLogTruncated existiert NICHT mehr; Budget-/Stale-Alerts liegen
#     auf den beiden neuen/bleibenden Metriken
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
if grep -qF 'for _src in "${SETUP_DIR}"/scripts/*.sh' "${SETUP}"; then
  pass "Setup schreibt check-tls.sh per scripts/*.sh-Write-Managed-Schleife"
else
  fail "Setup schreibt scripts/*.sh nicht (Schleife fehlt)"
fi
bash -n "${WORK}/check-tls.raw" && pass "check-tls.sh ist syntaktisch gueltig" || fail "Syntax check-tls.sh"

# --- Statische Prüfung: Zählweg + Metriken ----------------------------------
grep -qF 'find /data/caddy/certificates -name "*.crt" -mtime -7' "${WORK}/check-tls.raw" \
  && pass "Zählung per find -mtime -7 im caddy_data-Volume" \
  || fail "find -mtime-7-Zählung fehlt"
# Kommentarzeilen dürfen "docker logs" noch erklären (warum NICHT), nur
# ausführter Code zählt.
if grep -F 'docker logs' "${WORK}/check-tls.raw" | grep -qvE '^[[:space:]]*#'; then
  fail "docker logs wird noch verwendet (A6: Reset bei Recreate)"
else
  pass "kein docker logs im Code (A6)"
fi
grep -qF 'coder_tls_log_window_seconds' "${WORK}/check-tls.raw" \
  && fail "WINDOW-Metrik ist noch im Skript" || pass "keine WINDOW-Metrik"
grep -qF 'coder_tls_log_truncated' "${WORK}/check-tls.raw" \
  && fail "TRUNCATED-Metrik ist noch im Skript" || pass "keine TRUNCATED-Metrik"
grep -qF 'coder_tls_issuances_7d ${COUNT}' "${WORK}/check-tls.raw" \
  && pass "Metrik coder_tls_issuances_7d wird geschrieben" \
  || fail "coder_tls_issuances_7d fehlt"
grep -qF 'coder_tls_check_last_success_timestamp_seconds $(date +%s)' "${WORK}/check-tls.raw" \
  && pass "last_success-Timestamp wird geschrieben" \
  || fail "last_success-Timestamp fehlt"

# Alerts in setup-coder.sh: Budget + Stale ja, TlsLogTruncated nein.
grep -qF -- '- alert: TlsIssuanceBudgetHigh' "${SETUP}" \
  && grep -qF -- 'expr: coder_tls_issuances_7d > 20' "${SETUP}" \
  && pass "Alert TlsIssuanceBudgetHigh auf coder_tls_issuances_7d" \
  || fail "TlsIssuanceBudgetHigh fehlt oder prueft etwas anderes"
grep -qF -- '- alert: TlsCheckStale' "${SETUP}" \
  && grep -qF -- 'absent(coder_tls_check_last_success_timestamp_seconds)' "${SETUP}" \
  && pass "Alert TlsCheckStale auf last_success-Metrik" \
  || fail "TlsCheckStale fehlt oder prueft etwas anderes"
grep -qF -- '- alert: TlsLogTruncated' "${SETUP}" \
  && fail "Alert TlsLogTruncated ist noch im Setup (Metrik entfiel mit A6)" \
  || pass "Alert TlsLogTruncated entfernt (A6)"

# --- Fakes ------------------------------------------------------------------
cat > "${BIN}/docker" <<'FAKE'
#!/usr/bin/env bash
# FAKE_FIND_OUT: Ausgabe von "find" (zeilenweise Dateien, "" = keine);
# FAKE_CERTDIR: certificates-Verzeichnis vorhanden ("yes"/"no", Default yes);
# FAKE_DOCKER_RC: Fehlschlag.
rc="${FAKE_DOCKER_RC:-0}"
if [ "${rc}" -ne 0 ]; then
  echo "Error: no such container" >&2
  exit "${rc}"
fi
cmd="${1:-}"; shift || true
case "${cmd}" in
  exec)
    case " $* " in
      *" sh -c "*) printf '%s\n' "${FAKE_CERTDIR:-yes}" ;;
      *) printf '%s\n' "${FAKE_FIND_OUT-0}" ;;
    esac
    ;;
  *) exit 1 ;;
esac
FAKE
cat > "${BIN}/logger" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_LOGGER_OUT}"
FAKE
chmod 755 "${BIN}/docker" "${BIN}/logger"

# --- Lauf-Szenarien ----------------------------------------------------------
run_case() { # $1=Name $2=wc-Ausgabe $3=docker-rc $4=erwarteter Exit
  local name="$1" findout="$2" drc="$3" wantrc="$4"
  local dir="${WORK}/${name}" out="${WORK}/${name}.out"
  mkdir -p "${dir}/textfile"
  sed -e "s|export PATH=\"/usr/local/sbin|export PATH=\"${BIN}:/usr/local/sbin|" \
      -e "s|/opt/coder/node-textfile|${dir}/textfile|g" \
      "${WORK}/check-tls.raw" > "${dir}/check-tls.sh"
  : > "${dir}/logger.out"
  local rc=0
  FAKE_FIND_OUT="${findout}" \
  FAKE_DOCKER_RC="${drc}" \
  FAKE_LOGGER_OUT="${dir}/logger.out" \
    bash "${dir}/check-tls.sh" > "${out}" 2>&1 || rc=$?
  [ "${rc}" -eq "${wantrc}" ] && pass "${name}: Exit ${wantrc}" \
    || fail "${name}: rc=${rc} (erwartet ${wantrc})"
}

# A: drei Zertifikate in 7 Tagen -> Metrik 3, Timestamp aktuell, logger-Zeile
run_case drei $'a.crt\nb.crt\nc.crt' 0 0
P="${WORK}/drei/textfile/coder_tls.prom"
grep -qxF 'coder_tls_issuances_7d 3' "${P}" \
  && pass "drei: coder_tls_issuances_7d 3" || fail "drei: issuances != 3"
grep -qE '^coder_tls_check_last_success_timestamp_seconds [0-9]{9,}$' "${P}" \
  && pass "drei: last_success numerisch" || fail "drei: last_success fehlt/falsch"
grep -qF 'Ausstellungen/7d: 3' "${WORK}/drei/logger.out" \
  && pass "drei: syslog-Zeile vorhanden" || fail "drei: syslog-Zeile fehlt"
grep -qF 'TLS-Ausstellungen letzte 7 Tage' "${WORK}/drei.out" \
  && pass "drei:stdout nennt die 7-Tage-Zahl" || fail "drei: stdout-Zeile fehlt"

# B: null Zertifikate (frische Installation) -> Metrik 0, Exit 0
run_case null "" 0 0
grep -qxF 'coder_tls_issuances_7d 0' "${WORK}/null/textfile/coder_tls.prom" \
  && pass "null: coder_tls_issuances_7d 0" || fail "null: issuances != 0"

# C: docker exec schlaegt fehl (Container tot) -> Exit 1, KEINE Metrik
# (sonst wuerde der Erfolgszeitpunkt trotzdem weiterlaufen)
run_case kaputt 0 1 1
[ ! -f "${WORK}/kaputt/textfile/coder_tls.prom" ] \
  && pass "kaputt: keine Metrikdatei geschrieben" \
  || fail "kaputt: Metrikdatei wurde trotz Fehler geschrieben"
grep -qF 'TLS-Metrik bleibt unveraendert' "${WORK}/kaputt.out" \
  && pass "kaputt: Klartext-Fehlermeldung" || fail "kaputt: Fehlermeldung fehlt"

# D: Textfile-Verzeichnis fehlt -> Exit 1
dir="${WORK}/ohne"
mkdir -p "${dir}"
sed -e "s|export PATH=\"/usr/local/sbin|export PATH=\"${BIN}:/usr/local/sbin|" \
    -e "s|/opt/coder/node-textfile|${dir}/textfile|g" \
    "${WORK}/check-tls.raw" > "${dir}/check-tls.sh"
rc=0
FAKE_FIND_OUT=2 FAKE_LOGGER_OUT="${dir}/logger.out" \
  bash "${dir}/check-tls.sh" > "${dir}/out" 2>&1 || rc=$?
[ "${rc}" -eq 1 ] && pass "ohne Textfile-Dir: Exit 1" || fail "ohne Textfile-Dir: rc=${rc}"

# E: certificates-Verzeichnis fehlt (frische Installation) -> Metrik 0 +
# Erfolgszeitpunkt, Exit 0. Sonst feuert TlsCheckStale bis zum ersten
# Zertifikat waehrend DNS/Portweiterleitung noch warten.
dir="${WORK}/frisch"
mkdir -p "${dir}/textfile"
sed -e "s|export PATH=\"/usr/local/sbin|export PATH=\"${BIN}:/usr/local/sbin|" \
    -e "s|/opt/coder/node-textfile|${dir}/textfile|g" \
    "${WORK}/check-tls.raw" > "${dir}/check-tls.sh"
rc=0
FAKE_CERTDIR=no FAKE_LOGGER_OUT="${dir}/logger.out" \
  bash "${dir}/check-tls.sh" > "${dir}/out" 2>&1 || rc=$?
[ "${rc}" -eq 0 ] && pass "frisch (kein certificates-Dir): Exit 0" || fail "frisch: rc=${rc} (erwartet 0)"
grep -qxF 'coder_tls_issuances_7d 0' "${dir}/textfile/coder_tls.prom" \
  && pass "frisch: Metrik 0 geschrieben" || fail "frisch: Metrik fehlt/falsch"
grep -qE '^coder_tls_check_last_success_timestamp_seconds [0-9]{9,}$' "${dir}/textfile/coder_tls.prom" \
  && pass "frisch: Erfolgszeitpunkt gesetzt" || fail "frisch: Erfolgszeitpunkt fehlt"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-005: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-005: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
