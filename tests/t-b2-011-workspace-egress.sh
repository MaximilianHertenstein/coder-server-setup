#!/bin/bash
# T-B2-011: Workspace-Egress-Sperre (scripts/workspace-egress.sh) mit
# Fake-iptables, ohne Root und ohne Produktion:
#   - frisch: DOCKER-USER anlegen, genau 10.0.0.0/8 und 192.168.0.0/16 DROP
#   - zweiter Lauf: idempotent (keine doppelte Regel, kein zweites -I)
#   - vorhandene Kette / halb gefuellte Kette: nur die fehlende Regel rein
#   - 172.16.0.0/12 (Docker-eigene Netze) wird NICHT gesperrt, keine
#     hart kodierte Schulnetz-IP
#   - statisch: systemd-Unit im Setup (After=docker.service, ExecStart auf
#     das deployte Skript), enable+restart im Setup, Check-Schleife da
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"
SCRIPT="${REPO_ROOT}/scripts/workspace-egress.sh"

[ -f "${SCRIPT}" ] && pass "Skript existiert" || fail "Skript fehlt: ${SCRIPT}"
bash -n "${SCRIPT}" && pass "Skript syntaktisch gueltig" || fail "Skript-Syntax"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
ST="${WORK}/state"
CALLS="${WORK}/calls"
mkdir -p "${BIN}" "${ST}"

# --- Fake-iptables ----------------------------------------------------------
cat > "${BIN}/iptables" <<'FAKE'
#!/usr/bin/env bash
# Unterstuetzt genau die Aufrufe des Egress-Skripts: -N, -C, -I.
st="${FAKE_IPT_STATE:?FAKE_IPT_STATE fehlt}"
mkdir -p "${st}"
if [ -n "${FAKE_IPT_CALLS:-}" ]; then
  printf '%s\n' "${*}" >> "${FAKE_IPT_CALLS}"
fi
cmd="${1:-}"
shift || true
case "${cmd}" in
  -N)
    [ -f "${st}/$1" ] && exit 1
    : > "${st}/$1"
    ;;
  -C)
    chain="${1:-}"; shift || true
    [ -f "${st}/${chain}" ] || exit 1
    grep -Fxq -- "$*" "${st}/${chain}"
    ;;
  -I)
    chain="${1:-}"; shift || true
    [ "${1:-}" = "1" ] && shift
    rule="$*"
    [ -f "${st}/${chain}" ] || exit 1
    { printf '%s\n' "${rule}"; cat "${st}/${chain}"; } > "${st}/${chain}.n"
    mv "${st}/${chain}.n" "${st}/${chain}"
    ;;
  *)
    exit 0
    ;;
esac
FAKE
chmod +x "${BIN}/iptables"

run_script() {
  rm -f "${CALLS}"
  FAKE_IPT_STATE="${ST}" FAKE_IPT_CALLS="${CALLS}" \
    PATH="${BIN}:${PATH}" bash "${SCRIPT}"
}

# --- Frischer Lauf ----------------------------------------------------------
RC=0
run_script > "${WORK}/out1.txt" 2>&1 || RC=$?
[ "${RC}" -eq 0 ] && pass "Frischer Lauf: rc 0" || fail "Frischer Lauf: rc=${RC} ($(cat "${WORK}/out1.txt"))"
[ -f "${ST}/DOCKER-USER" ] && pass "Kette DOCKER-USER liegt an" || fail "Kette DOCKER-USER fehlt"
RULES="$(cat "${ST}/DOCKER-USER" 2>/dev/null || true)"
[ "$(printf '%s\n' "${RULES}" | grep -c . || true)" -eq 2 ] \
  && pass "genau 2 Regeln angelegt" \
  || fail "Regelanzahl=$(printf '%s\n' "${RULES}" | grep -c . || true) (erwartet 2)"
printf '%s\n' "${RULES}" | grep -Fxq -- "-d 10.0.0.0/8 -j DROP" \
  && pass "10.0.0.0/8 wird gesperrt" || fail "10.0.0.0/8 fehlt"
printf '%s\n' "${RULES}" | grep -Fxq -- "-d 192.168.0.0/16 -j DROP" \
  && pass "192.168.0.0/16 wird gesperrt" || fail "192.168.0.0/16 fehlt"
printf '%s\n' "${RULES}" | grep -q "172.16.0.0/12" \
  && fail "Docker-Netze 172.16.0.0/12 werden blockiert" \
  || pass "Docker-Netze 172.16.0.0/12 bleiben offen"
[ "$(grep -c '^-I DOCKER-USER' "${CALLS}" || true)" -eq 2 ] \
  && pass "genau zwei -I-Aufrufe" || fail "-I-Aufrufe=$(grep -c '^-I' "${CALLS}" || true) (erwartet 2)"

# --- Zweiter Lauf (idempotent) ----------------------------------------------
RC=0
run_script > "${WORK}/out2.txt" 2>&1 || RC=$?
[ "${RC}" -eq 0 ] && pass "Zweiter Lauf: rc 0" || fail "Zweiter Lauf: rc=${RC} ($(cat "${WORK}/out2.txt"))"
RULES2="$(cat "${ST}/DOCKER-USER")"
[ "$(printf '%s\n' "${RULES2}" | grep -c . || true)" -eq 2 ] \
  && pass "Regeln nicht verdoppelt" || fail "Regelanzahl nach 2. Lauf=$(printf '%s\n' "${RULES2}" | grep -c . || true)"
[ "$(grep -c '^-I DOCKER-USER' "${CALLS}" || true)" -eq 0 ] \
  && pass "kein zweites -I (idempotent)" \
  || fail "-I beim zweiten Lauf: $(grep -c '^-I' "${CALLS}" || true)"

# --- Vorhandene Kette, leer -------------------------------------------------
RC=0
rm -f "${ST}/DOCKER-USER"
: > "${ST}/DOCKER-USER"
run_script > "${WORK}/out3.txt" 2>&1 || RC=$?
[ "${RC}" -eq 0 ] && pass "Leere Kette: rc 0" || fail "Leere Kette: rc=${RC}"
[ "$(grep -c . "${ST}/DOCKER-USER" || true)" -eq 2 ] \
  && pass "Leere Kette wird befuellt" || fail "Leere Kette: Regeln=$(grep -c . "${ST}/DOCKER-USER" || true)"

# --- Vorhandene Kette, nur eine der beiden Netze ----------------------------
RC=0
printf '%s\n' "-d 10.0.0.0/8 -j DROP" > "${ST}/DOCKER-USER"
run_script > "${WORK}/out4.txt" 2>&1 || RC=$?
[ "${RC}" -eq 0 ] && pass "Halb gefuellte Kette: rc 0" || fail "Halb gefuellte Kette: rc=${RC}"
[ "$(grep -c . "${ST}/DOCKER-USER" || true)" -eq 2 ] \
  && pass "fehlende Regel wird ergaenzt" \
  || fail "Halb gefuellte Kette: Regeln=$(grep -c . "${ST}/DOCKER-USER" || true) (erwartet 2)"
[ "$(grep -cF -- "-d 10.0.0.0/8 -j DROP" "${ST}/DOCKER-USER" || true)" -eq 1 ] \
  && pass "vorhandene Regel nicht dupliziert" || fail "10/8 doppelt"

# --- Statische Verankerung --------------------------------------------------
grep -qF 'coder-egress-firewall.service' "${SETUP}" \
  && pass "systemd-Unit steht im Setup" || fail "systemd-Unit fehlt im Setup"
grep -qF 'After=docker.service' "${SETUP}" \
  && pass "Unit haengt an docker.service" || fail "After=docker.service fehlt"
grep -qF 'ExecStart=/opt/coder/workspace-egress.sh' "${SETUP}" \
  && pass "ExecStart zeigt auf das deployte Skript" || fail "ExecStart-Pfad fehlt"
grep -qF 'systemctl restart coder-egress-firewall.service' "${SETUP}" \
  && pass "Setup fuehrt restart aus" || fail "systemctl restart fehlt"
grep -qF 'iptables -C DOCKER-USER -d "${_net}" -j DROP' "${SETUP}" \
  && pass "Abschlusscheck prueft beide Netze" || fail "Check-Schleife fehlt im Setup"
grep -qF '172.16.0.0/12' "${SCRIPT}" \
  && fail "Skript sperrt Docker-Netze (172.16.0.0/12)" \
  || pass "Skript laesst Docker-Netze offen"
grep -qF '10.16.0.0/12' "${SCRIPT}" "${SETUP}" \
  && fail "harte Schulnetz-IP im Egress-Pfad" \
  || pass "keine hart kodierte Schulnetz-IP"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-011: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-011: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
