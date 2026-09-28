#!/bin/bash
# T-062 / B2-004: Re-Run-Downgrade nur explizit.
# Geprueft: der DETEKTOR aus setup-coder.sh (zwei Stufen wörtlich aus der
# Quelle extrahiert) gegen die Pflicht-Fixtures aus PLAN-v3 Z.287-299, und
# das ECHTE Gate/Restore-Stueck aus setup-coder.sh (nach Zeilen extrahiert,
# mit sudo-Shim + Fake-ufw in /tmp, ohne Root, ohne Produktion):
#   Pfad A weltweit -> kein Abort, kein Restore
#   Pfad C inaktiv/fehlt -> kein Abort, Hinweis
#   Pfad B restriktiv -> Exit 1 vor jedem Loeschen, Anleitung im Text
#   Pfad B + exakt "yes" -> Weiterlauf mit Quelle/Aktion aus before.log
#   Restore -> quellengetreu (allow/limit), Verifikation, sonst Exit 1
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
LOGDIR="${WORK}/log"
BIN="${WORK}/bin"
mkdir -p "${LOGDIR}" "${BIN}"

# --- Extraktion der echten Fragmente aus setup-coder.sh ---------------------
RE1="$(sed -n "s/.*| grep -Ei '\([^']*\)'.*/\1/p" "${SETUP}")"
RE2="$(sed -n "s/.*| grep -Ev '\([^']*\)'.*/\1/p" "${SETUP}")"
RE_INACTIVE="$(sed -n "s/.*grep -qi '\(Status[^']*\)'.*/\1/p" "${SETUP}" | head -n1)"
RE_ACTION="$(sed -n "s/.*grep -Eio '\([^']*\)'.*/\1/p" "${SETUP}")"

[ -n "${RE1}" ] && pass "Stufe-1-Detektor aus Quelle gelesen" || fail "Stufe-1-Detektor fehlt"
[ -n "${RE2}" ] && pass "Stufe-2-Filter aus Quelle gelesen" || fail "Stufe-2-Filter fehlt"
[ -n "${RE_INACTIVE}" ] && pass "Pfad-C-Muster aus Quelle gelesen" || fail "Pfad-C-Muster fehlt"
[ -n "${RE_ACTION}" ] && pass "Aktions-Muster aus Quelle gelesen" || fail "Aktions-Muster fehlt"

L_START="$(grep -nF 'UFW_OUT="$(sudo ufw status numbered' "${SETUP}" | cut -d: -f1 || true)"
GATE="$(awk -v s="${L_START}" 'NR>=s{print} NR>s && $0=="fi"{exit}' "${SETUP}")"
L_RES="$(grep -nF 'if [ -n "${UFW_RESTORE_SRC}" ]; then' "${SETUP}" | cut -d: -f1 || true)"
RESTORE="$(awk -v s="${L_RES}" 'NR>=s{print} NR>s && $0=="fi"{exit}' "${SETUP}")"
printf '%s\n' "${GATE}" > "${WORK}/gate.sh"
printf '%s\n' "${RESTORE}" > "${WORK}/restore.sh"
bash -n "${WORK}/gate.sh" && pass "extrahiertes Gate ist syntaktisch gueltig" || fail "Gate-Syntax"
bash -n "${WORK}/restore.sh" && pass "extrahiertes Restore ist syntaktisch gueltig" || fail "Restore-Syntax"

# --- Pflicht-Fixtures (PLAN-v3 Z.287-299) gegen beide Stufen ---------------
stage2() { printf '%s\n' "$1" | grep -Ei "${RE1}" | grep -Ev "${RE2}" 2>/dev/null || true; }

POSITIVE='22/tcp                     ALLOW       10.16.0.0/12
22                         ALLOW       192.168.1.0/24
OpenSSH                    ALLOW       10.0.0.0/8
[ 1] 22/tcp                 ALLOW IN    10.16.0.0/12
22/tcp (v6)                ALLOW IN    fd00::/8
ufw allow from 10.16.0.0/12 to any port 22 proto tcp
22/tcp                     LIMIT       192.168.1.5'

while IFS= read -r line; do
  [ -n "${line}" ] || continue
  if [ -n "$(stage2 "${line}")" ]; then
    pass "restriktiv erkannt: ${line}"
  else
    fail "nicht erkannt (Pflicht-Fixtue): ${line}"
  fi
done <<< "${POSITIVE}"

WORLDWIDE='22/tcp                     LIMIT       Anywhere
22/tcp (v6)                LIMIT       Anywhere (v6)
22                         ALLOW       Anywhere
OpenSSH                    ALLOW       Anywhere'
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  if [ -z "$(stage2 "${line}")" ]; then
    pass "weltweit erkannt -> kein Treffer: ${line}"
  else
    fail "weltweit fälschlich als restriktiv: ${line}"
  fi
done <<< "${WORLDWIDE}"

NEGATIVE='80/tcp                     ALLOW       10.16.0.0/12
443/tcp                    ALLOW       10.16.0.0/12
2222/tcp                   ALLOW       10.16.0.0/12
122/tcp                    ALLOW       10.16.0.0/12'
while IFS= read -r line; do
  [ -n "${line}" ] || continue
  if [ -z "$(printf '%s\n' "${line}" | grep -Ei "${RE1}")" ]; then
    pass "Negativ in Stufe 1 gar nicht gematcht: ${line}"
  else
    fail "Negativ wurde in Stufe 1 gematcht: ${line}"
  fi
done <<< "${NEGATIVE}"

# --- Fake-ufw + sudo-Shim ---------------------------------------------------
cat > "${BIN}/ufw" <<'FAKE'
#!/usr/bin/env bash
rc="${FAKE_UFW_RC:-0}"
if [ "${rc}" -ne 0 ]; then
  echo "ERROR: fake ufw ${*} failed" >&2
  exit "${rc}"
fi
if [ -n "${FAKE_UFW_CALLS:-}" ]; then
  printf '%s\n' "${*}" >> "${FAKE_UFW_CALLS}"
fi
case " $* " in
  *" status "*) printf '%s\n' "${FAKE_UFW_STATUS:-Status: inactive}" ;;
  *) printf 'Rule added to rule set\n' ;;
esac
FAKE
chmod +x "${BIN}/ufw"

export PATH="${BIN}:${PATH}"
export FAKE_UFW_CALLS="${WORK}/ufw.calls"

# --- Helfer: echtes Gate/Stueck im Subshell laufen lassen -------------------
run_block() {  # $1=Datei $2=Status $3=RC $4=Bypass ("-" = nicht gesetzt) $5=Markerdatei
  if [ "$#" -ne 5 ]; then
    echo "run_block: 5 Argumente erwartet, bekommen: $#" >&2
    return 2
  fi
  local file="$1" status="$2" rc="$3" bypass="$4" marker="$5"
  (
    set -euo pipefail
    sudo() {
      if [ "${1:-}" = "tee" ]; then
        shift
        command tee "${LOGDIR}/$(basename "$1")"
      else
        "$@"
      fi
    }
    warn() { echo "WARN: $1"; }
    ok()   { echo "OK: $1"; }
    fail() { echo "FEHLER: $1"; }
    export FAKE_UFW_STATUS="${status}"
    export FAKE_UFW_RC="${rc}"
    if [ "${bypass}" != "-" ]; then
      export CODER_ALLOW_SSH_DOWNGRADE="${bypass}"
    else
      unset CODER_ALLOW_SSH_DOWNGRADE || true
    fi
    # shellcheck source=/dev/null
    . "${file}"
    _line="GATE_CONTINUE SRC=[${UFW_RESTORE_SRC-}] ACTION=[${UFW_RESTORE_ACTION-}] BEFORE=[${UFW_BEFORE_LOG-}]"
    echo "${_line}" > "${marker}" 2>/dev/null || true
    echo "${_line}"
  )
}

capture() {  # run_block ins File, Exit-Code setzen
  local out="${WORK}/out.txt" mk="${WORK}/marker.txt"
  rm -f "${mk}"
  RC=0
  run_block "$@" "${mk}" > "${out}" 2>&1 || RC=$?
  OUT="$(cat "${out}")"
}

assert_rc() { [ "${RC}" = "$1" ] && pass "$2" || fail "$2 (rc=${RC}, erwartet $1)"; }
assert_out() { printf '%s' "${OUT}" | grep -qF -- "$1" && pass "$2" || fail "$2 (fehlt: $1)"; }

S_ACTIVE='Status: active
To                         Action      From
--                         ------      ----
22/tcp                     LIMIT       Anywhere
22/tcp (v6)                LIMIT       Anywhere (v6)'
S_RESTRICT_OLD='Status: active
To                         Action      From
--                         ------      ----
22                         ALLOW       192.168.1.0/24
22/tcp                     ALLOW       Anywhere'
S_RESTRICT_LIMIT='Status: active
[ 1] 22/tcp                 LIMIT IN    192.168.1.5'
S_RESTRICT_V6='Status: active
22/tcp (v6)                ALLOW IN    fd00::/8'
S_ONLY_80='Status: active
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere'

# Pfad A: weltweit offen -> kein Abort, kein Restore, keine Warnung.
capture "${WORK}/gate.sh" "${S_ACTIVE}" 0 "-"
assert_rc 0 "Pfad A (weltweit) laeuft weiter"
assert_out "GATE_CONTINUE SRC=[]" "Pfad A: keine Wiederherstellung angehaengt"
printf '%s' "${OUT}" | grep -q "WARN:" && fail "Pfad A: unerwartete WARNung" || pass "Pfad A: keine WARNung"

# Pfad A: nur 80/443 -> kein Fehltreffer.
capture "${WORK}/gate.sh" "${S_ONLY_80}" 0 "-"
assert_rc 0 "Pfad A (nur 80/443) laeuft weiter"

# Pfad C: UFW inaktiv.
capture "${WORK}/gate.sh" "Status: inactive" 0 "-"
assert_rc 0 "Pfad C (inactive) laeuft weiter"
assert_out "WARN:" "Pfad C: Hinweis ausgegeben"
assert_out "GATE_CONTINUE SRC=[]" "Pfad C: keine Wiederherstellung angehaengt"

# Pfad C: ufw-Befehl fehlt (rc=127, keine Ausgabe).
capture "${WORK}/gate.sh" "" 127 "-"
assert_rc 0 "Pfad C (ufw fehlt) laeuft weiter"
assert_out "WARN:" "Pfad C (ufw fehlt): Hinweis ausgegeben"

# Pfad B ohne Bypass -> harter Abbruch vor dem Loeschen.
capture "${WORK}/gate.sh" "${S_RESTRICT_OLD}" 0 "-"
assert_rc 1 "Pfad B ohne Bypass: Exit 1"
assert_out "22                         ALLOW       192.168.1.0/24" "Pfad B: betroffene Regel steht im Abbruchtext"
assert_out "CODER_ALLOW_SSH_DOWNGRADE=yes" "Pfad B: Anleitung im Abbruchtext"
assert_out "nichts gelöscht" "Pfad B: verspricht, nichts geloescht zu haben"
printf '%s' "${OUT}" | grep -qF "GATE_CONTINUE" && fail "Pfad B ohne Bypass: darf nicht weiterlaufen" || pass "Pfad B ohne Bypass: kein Weiterlauf"
ls "${LOGDIR}"/coder-ssh-downgrade-*.before.log >/dev/null 2>&1 \
  && pass "Pfad B: before.log geschrieben" || fail "Pfad B: before.log fehlt"

# Pflicht: Abbruch steht VOR den delete-Zeilen (kein stilles Oeffnen).
LG="$(grep -nF 'CODER_ALLOW_SSH_DOWNGRADE:-}" != "yes"' "${SETUP}" | cut -d: -f1 || true)"
LX="$(awk -v s="${LG}" 'NR>s && $0 ~ /^ *exit 1$/ {print NR; exit}' "${SETUP}" || true)"
LD="$(grep -nF 'sudo ufw --force delete allow OpenSSH' "${SETUP}" | cut -d: -f1 || true)"
[ -n "${LG}" ] && [ -n "${LX}" ] && [ "${LX}" -lt "${LD}" ] \
  && pass "Exit 1 (Bypass-Gate) steht vor den delete-Zeilen (Z.${LX} < Z.${LD})" \
  || fail "Abbruch steht nicht vor dem Loeschen (Gate=${LG} exit=${LX} delete=${LD})"

# Pfad B mit Bypass exakt "yes" -> Weiterlauf, Quelle aus before.log.
rm -f "${LOGDIR}"/*.before.log
capture "${WORK}/gate.sh" "${S_RESTRICT_OLD}" 0 "yes"
assert_rc 0 "Pfad B + Bypass yes: laeuft weiter"
assert_out "GATE_CONTINUE SRC=[192.168.1.0/24] ACTION=[allow]" "Bypass: Quelle wörtlich aus before.log (alte False-Negative-Form)"
assert_out "WARN:" "Bypass: Warnung in SUMMARY"
ls "${LOGDIR}"/coder-ssh-downgrade-*.before.log >/dev/null 2>&1 \
  && pass "Bypass: before.log geschrieben" || fail "Bypass: before.log fehlt"

# Bypass-Syntax: nur exakt "yes".
capture "${WORK}/gate.sh" "${S_RESTRICT_OLD}" 0 "YES"
assert_rc 1 "Bypass YES (gross) -> Exit 1"
capture "${WORK}/gate.sh" "${S_RESTRICT_OLD}" 0 "yes "
assert_rc 1 "Bypass 'yes ' (Leerzeichen) -> Exit 1"
capture "${WORK}/gate.sh" "${S_RESTRICT_OLD}" 0 "true"
assert_rc 1 "Bypass true -> Exit 1"

# PV-009: Aktion quellengetreu (limit statt allow).
capture "${WORK}/gate.sh" "${S_RESTRICT_LIMIT}" 0 "yes"
assert_rc 0 "Bypass LIMIT-Regel: laeuft weiter"
assert_out "GATE_CONTINUE SRC=[192.168.1.5] ACTION=[limit]" "PV-009: limit wird als Aktion notiert"

# IPv6-(v6)-Zeile.
capture "${WORK}/gate.sh" "${S_RESTRICT_V6}" 0 "yes"
assert_out "GATE_CONTINUE SRC=[fd00::/8] ACTION=[allow]" "IPv6-(v6)-Form: Quelle fd00::/8"

# from-...-to-any-port-22-Form.
capture "${WORK}/gate.sh" 'Status: active
ufw allow from 10.16.0.0/12 to any port 22 proto tcp' 0 "yes"
assert_out "GATE_CONTINUE SRC=[10.16.0.0/12] ACTION=[allow]" "from-...-to-any-port-22: Quelle extrahiert"

# --- Restore-Stueck ---------------------------------------------------------
: > "${FAKE_UFW_CALLS}"
RC=0
( set -euo pipefail
  sudo() {
    if [ "${1:-}" = "tee" ]; then
      shift
      command tee "${LOGDIR}/$(basename "$1")"
    else
      "$@"
    fi
  }
  warn() { echo "WARN: $1"; }
  ok()   { echo "OK: $1"; }
  fail() { echo "FEHLER: $1"; }
  export FAKE_UFW_STATUS='Status: active
22/tcp                     LIMIT       Anywhere
22/tcp                     ALLOW       192.168.1.0/24'
  export FAKE_UFW_RC=0
  export UFW_RESTORE_SRC="192.168.1.0/24"
  export UFW_RESTORE_ACTION="allow"
  export UFW_AFTER_LOG="${LOGDIR}/restore.after.log"
  . "${WORK}/restore.sh"
  echo "RESTORE_CONTINUE"
) > "${WORK}/out2.txt" 2>&1 || RC=$?
OUT="$(cat "${WORK}/out2.txt")"
assert_rc 0 "Restore: Verifikation erfolgreich"
assert_out "RESTORE_CONTINUE" "Restore: Lauf geht weiter"
assert_out "OK:" "Restore: Meldung in SUMMARY"
grep -qF -- 'allow from 192.168.1.0/24 to any port 22 proto tcp' "${FAKE_UFW_CALLS}" \
  && pass "Restore: quellengetreuer ufw-Aufruf protokolliert" || fail "Restore: ufw-Aufruf fehlt/anders: $(cat "${FAKE_UFW_CALLS}")"

# Verifikation fehlschlagen -> Exit 1, kein stilles Grün.
RC=0
( set -euo pipefail
  sudo() {
    if [ "${1:-}" = "tee" ]; then
      shift
      command tee "${LOGDIR}/$(basename "$1")"
    else
      "$@"
    fi
  }
  warn() { echo "WARN: $1"; }
  ok()   { echo "OK: $1"; }
  fail() { echo "FEHLER: $1"; }
  export FAKE_UFW_STATUS='Status: active
22/tcp                     LIMIT       Anywhere'
  export FAKE_UFW_RC=0
  export UFW_RESTORE_SRC="192.168.1.0/24"
  export UFW_RESTORE_ACTION="allow"
  export UFW_AFTER_LOG="${LOGDIR}/restore2.after.log"
  . "${WORK}/restore.sh"
  echo "RESTORE_CONTINUE"
) > "${WORK}/out3.txt" 2>&1 || RC=$?
OUT="$(cat "${WORK}/out3.txt")"
assert_rc 1 "Restore ohne Treffer in after.log: Exit 1"
assert_out "FEHLER:" "Restore ohne Treffer: Fehlermeldung"
printf '%s' "${OUT}" | grep -qF "RESTORE_CONTINUE" && fail "Restore ohne Treffer: darf nicht weiterlaufen" || pass "Restore ohne Treffer: kein Weiterlauf"

# --- Struktur: keine stille Oeffnung mehr, alte Schwachstelle weg -----------
grep -qF 'grep -Eq "22/(tcp|ssh)' "${SETUP}" \
  && fail "alter lueckenhafter Detektor wird noch als Gate benutzt" \
  || pass "alter lueckenhafter Detektor wird nicht mehr benutzt"
grep -qF 'Re-Run weitet SSH auf weltweit+limit aus' "${SETUP}" \
  && fail "alte reine Warnung ohne Gate ist noch im Code" \
  || pass "alte reine Warnung ohne Gate ist entfernt"
LC="$(grep -nF 'UFW_OUT="$(sudo ufw status numbered' "${SETUP}" | cut -d: -f1 || true)"
LI="$(grep -nF "grep -qi 'Status:" "${SETUP}" | cut -d: -f1 || true)"
LB="$(grep -nF 'elif [ -n "${UFW_RESTRICTED}" ]' "${SETUP}" | cut -d: -f1 || true)"
[ "${LC}" -lt "${LI}" ] && [ "${LI}" -lt "${LB}" ] \
  && pass "Pfad C wird VOR Pfad B geprueft (Z.${LC} < Z.${LI} < Z.${LB})" \
  || fail "Pfad-Reihenfolge falsch (${LC}/${LI}/${LB})"
NT="$(grep -cF '| sudo tee "${UFW_' "${SETUP}" || true)"
[ "${NT}" -eq 2 ] && pass "beide Protokolle per sudo tee (root-Rechte)" || fail "sudo tee-Anzahl=${NT} (erwartet 2)"
grep -qF 'sudo ufw "${UFW_RESTORE_ACTION}" from "${UFW_RESTORE_SRC}"' "${SETUP}" \
  && pass "Restore verwendet die notierte Aktion (nicht hart kodiert 'allow')" \
  || fail "Restore-Aktion hart kodiert"
grep -qF '[ "${CODER_ALLOW_SSH_DOWNGRADE:-}" != "yes" ]' "${SETUP}" \
  && pass "Bypass-Pruefung exakt gegen 'yes'" || fail "Bypass-Pruefung nicht exakt"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-004: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-004: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
