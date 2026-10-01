#!/bin/bash
# T-062 / B2-004 (Stand: Review 0.1/2.4 – schmaler Regelpfad, kein
# Delete/Restore von SSH-Regeln).
# Geprueft: der DETEKTOR aus setup-coder.sh (zwei Stufen wörtlich aus der
# Quelle extrahiert) gegen die Pflicht-Fixtures, und die echten Stuecke aus
# setup-coder.sh (nach Zeilen extrahiert, mit sudo-Shim + Fake-ufw in /tmp,
# ohne Root, ohne Produktion):
#   Gate: ohne lesbaren ufw-Status = harter Abbruch, ohne lesbare
#         gespeicherte Regeln = harter Abbruch; inaktiv + gespeicherte
#         Quellregeln = Abbruch VOR jeder Aenderung; Beschaenkung erkannt
#   Regelanwendung: bei Beschränkung KEINE 22-Regel anfassen (kein limit
#         daneben, keine Quellregel geloescht, Coexistenz wird gemeldet);
#         sonst die drei weltweiten allow-Schreibweisen loeschen UND den
#         Erfolg verifizieren (sonst Exit 1), dann limit 22/tcp
#   Abschlusscheck: pfadabhaengig (Beschraenkung = keine weltweite 22-Regel
#         daneben, sonst muss die rate-limitierte Regel existieren)
#   Statisch: kein Bypass, kein Restore, kein Quellregel-Delete
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

# --- Extraktion der echten Fragmente aus setup-coder.sh ---------------------
RE1="$(sed -n "s/.*| grep -Ei '\([^']*\)'.*/\1/p" "${SETUP}" | head -n1)"
RE2="$(sed -n "s/.*| grep -Ev '\([^']*\)'.*/\1/p" "${SETUP}")"
RE_INACTIVE="$(sed -n "s/.*grep -qi '\(Status[^']*\)'.*/\1/p" "${SETUP}" | head -n1)"

[ -n "${RE1}" ] && pass "Stufe-1-Detektor aus Quelle gelesen" || fail "Stufe-1-Detektor fehlt"
[ -n "${RE2}" ] && pass "Stufe-2-Filter aus Quelle gelesen" || fail "Stufe-2-Filter fehlt"
[ -n "${RE_INACTIVE}" ] && pass "Pfad-C-Muster aus Quelle gelesen" || fail "Pfad-C-Muster fehlt"

# Beide Anker muessen EINDEUTIG sein: "ufw status numbered" steht auch im
# SSH-Port-Preflight, und ein "bis zur ersten fi" wuerde schon am
# Status-Block enden – daher feste Bereiche bis zum naechsten Kommentaranker.
GATE_ANCHOR='if ! UFW_OUT="$(ufw status numbered 2>/dev/null)"; then'
GATE_END='# Regelanwendung (Review 0.1/2.4): einfache feste Folge. Reihenfolge erst'
APPLY_START='# Regelanwendung (Review 0.1/2.4): einfache feste Folge. Reihenfolge erst'
APPLY_END='# backend=systemd explizit setzen'
CHECK_START='UFW_STATUS="$(ufw status)"'
CHECK_END='# A4: Beim ersten Start kann systemd'

extract() {  # $1=Startanker $2=Endeanker $3=Ausgabedatei
  local s e hc ec
  hc="$(grep -cF "$1" "${SETUP}" || true)"
  ec="$(grep -cF "$2" "${SETUP}" || true)"
  s="$(grep -nF "$1" "${SETUP}" | cut -d: -f1 || true)"
  e="$(grep -nF "$2" "${SETUP}" | cut -d: -f1 || true)"
  if [ "${hc}" -eq 1 ] && [ "${ec}" -eq 1 ] && [ -n "${s}" ] && [ -n "${e}" ] && [ "${s}" -lt "${e}" ]; then
    awk -v a="${s}" -v b="${e}" 'NR>=a && NR<b {print}' "${SETUP}" > "$3"
    pass "Anker eindeutig ($(basename "$3"): Z.${s}-Z.${e})"
    return 0
  fi
  fail "Anker nicht eindeutig/ungeordnet fuer $(basename "$3"): Start=${hc}/${s} Ende=${ec}/${e}"
  return 1
}

extract "${GATE_ANCHOR}" "${GATE_END}" "${WORK}/gate.sh" || true
extract "${APPLY_START}" "${APPLY_END}" "${WORK}/apply.sh" || true
extract "${CHECK_START}" "${CHECK_END}" "${WORK}/check.sh" || true

for f in gate apply check; do
  bash -n "${WORK}/${f}.sh" && pass "extrahiertes ${f} ist syntaktisch gueltig" || fail "${f}-Syntax"
done

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
    fail "weltweit faelschlich als restriktiv: ${line}"
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

# --- Fake-ufw ---------------------------------------------------------------
# Der Zustand liegt in einer Datei: "delete"/"limit"/"allow"/"enable"
# schreiben FAKE_UFW_STATUS_AFTER, "status" liest den aktuellen Stand. Damit
# ist die Verifikation nach der allow->limit-Umwandlung testbar, ohne echtes
# ufw. "show added" liefert FAKE_UFW_ADDED (sonst eine harmlose Leerzeile),
# damit der Abbruch "inaktiv + gespeicherte Quellregeln" testbar ist. Jeder
# Aufruf wird protokolliert (FAKE_UFW_CALLS).
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
  *" status "*)
    if [ -n "${FAKE_UFW_STATE:-}" ] && [ -f "${FAKE_UFW_STATE}" ]; then
      cat "${FAKE_UFW_STATE}"
    else
      printf '%s\n' "${FAKE_UFW_STATUS:-Status: inactive}"
    fi
    ;;
  *" show added"*)
    printf '%s\n' "${FAKE_UFW_ADDED:-Added user rules (see 'ufw status' for running firewall):}"
    ;;
  *" delete "*|*" limit "*|*" allow "*|*" enable "*)
    if [ -n "${FAKE_UFW_STATE:-}" ]; then
      printf '%s\n' "${FAKE_UFW_STATUS_AFTER:-${FAKE_UFW_STATUS:-Status: inactive}}" > "${FAKE_UFW_STATE}"
    fi
    printf 'Rule added to rule set\n'
    ;;
  *)
    printf 'Rule added to rule set\n'
    ;;
esac
FAKE
chmod +x "${BIN}/ufw"

export PATH="${BIN}:${PATH}"
export FAKE_UFW_CALLS="${WORK}/ufw.calls"
export FAKE_UFW_STATE="${WORK}/ufw.state"

# --- Helfer: Gate + Regelanwendung + Abschlusscheck im Subshell laufen ------
run_all() {  # $1=Status $2=Status nach Aenderung $3=RC $4=Markerdatei
  if [ "$#" -ne 4 ]; then
    echo "run_all: 4 Argumente erwartet, bekommen: $#" >&2
    return 2
  fi
  local status="$1" after="$2" rc="$3" marker="$4"
  (
    set -euo pipefail
    sudo() { "$@"; }
    warn() { echo "WARN: $1"; }
    ok()   { echo "OK: $1"; }
    fail() { echo "FEHLER: $1"; }
    export FAKE_UFW_STATUS="${status}"
    export FAKE_UFW_STATUS_AFTER="${after}"
    export FAKE_UFW_RC="${rc}"
    printf '%s\n' "${status}" > "${FAKE_UFW_STATE}"
    # shellcheck source=/dev/null
    . "${WORK}/gate.sh"
    . "${WORK}/apply.sh"
    . "${WORK}/check.sh"
    echo "CHECK_CONTINUE" > "${marker}" 2>/dev/null || true
    echo "CHECK_CONTINUE"
  )
}

capture() {  # run_all ins File, Exit-Code setzen, ufw-Protokoll zuruecksetzen
  local out="${WORK}/out.txt" mk="${WORK}/marker.txt"
  rm -f "${mk}" "${FAKE_UFW_CALLS}"
  RC=0
  run_all "$@" "${mk}" > "${out}" 2>&1 || RC=$?
  OUT="$(cat "${out}")"
}

calls() { [ -f "${FAKE_UFW_CALLS}" ] && cat "${FAKE_UFW_CALLS}" || true; }
assert_rc() { [ "${RC}" = "$1" ] && pass "$2" || fail "$2 (rc=${RC}, erwartet $1)"; }
assert_out() { printf '%s' "${OUT}" | grep -qF -- "$1" && pass "$2" || fail "$2 (fehlt: $1)"; }
assert_no_out() { printf '%s' "${OUT}" | grep -qF -- "$1" && fail "$2 (unerwartet: $1)" || pass "$2"; }
assert_calls() { calls | grep -qF -- "$1" && pass "$2" || fail "$2 (fehlt im ufw-Protokoll: $1)"; }
assert_no_calls() { calls | grep -qF -- "$1" && fail "$2 (unerwartet im ufw-Protokoll: $1)" || pass "$2"; }

S_ACTIVE='Status: active
To                         Action      From
--                         ------      ----
22/tcp                     LIMIT       Anywhere
22/tcp (v6)                LIMIT       Anywhere (v6)'
S_ALLOW_WORLD='Status: active
OpenSSH                    ALLOW       Anywhere'
S_ALLOW_22_WORLD='Status: active
22/tcp                     ALLOW       Anywhere'
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
S_ONLY_80_LIMIT='Status: active
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere
22/tcp                     LIMIT       Anywhere'

# --- Pfad A: weltweit vorhanden ---------------------------------------------
# Unbeschraenkt: die drei allow-Schreibweisen werden idempotent geloescht
# (No-Op, wenn nichts vorhanden) und limit 22/tcp (ebenfalls idempotent)
# gesetzt. Nie darf eine Quellregel ("delete allow from") beruehrt werden.
capture "${S_ACTIVE}" "${S_ACTIVE}" 0
assert_rc 0 "Pfad A (weltweit limit) laeuft weiter"
assert_out "CHECK_CONTINUE" "Pfad A: Lauf geht weiter"
assert_no_out "WARN:" "Pfad A: keine WARNung"
assert_calls "delete allow 22/tcp" "Pfad A: allow-Loeschversuch (idempotenter No-Op)"
assert_calls "limit 22/tcp" "Pfad A: limit wird idempotent gesetzt"
assert_no_calls "delete allow from" "Pfad A: keine Quellregel wird geloescht"

# Pfad A ohne SSH-Regel: fehlende Regel setzen, Loeschversuche sind No-Op.
capture "${S_ONLY_80}" "${S_ONLY_80_LIMIT}" 0
assert_rc 0 "Pfad A (nur 80/443) laeuft weiter"
assert_calls "limit 22/tcp" "Pfad A: fehlende SSH-Regel wird gesetzt"
assert_no_calls "delete allow from" "Pfad A (nur 80/443): keine Quellregel geloescht"

# --- Pfad C: UFW inaktiv ----------------------------------------------------
capture "Status: inactive" "${S_ACTIVE}" 0
assert_rc 0 "Pfad C (inactive) laeuft weiter"
assert_out "WARN:" "Pfad C: Hinweis ausgegeben"
assert_no_calls "delete allow from" "Pfad C: keine Quellregel wird geloescht"

# Pfad C: inaktiv + gespeicherte SSH-Quellregeln -> Abbruch VOR jeder
# Aenderung (sonst wuerde "ufw enable" die Beschraenkung aktivieren, ohne
# dass sie bewusst geprueft wurde – und Policy-Aenderungen laufen mit).
export FAKE_UFW_ADDED='Added user rules (see '"'"'ufw status'"'"' for running firewall):
ufw allow from 192.168.1.0/24 to any port 22 proto tcp'
capture "Status: inactive" "${S_ACTIVE}" 0
assert_rc 1 "Pfad C (inaktiv + Quellregeln): Abbruch vor jeder Aenderung"
assert_out "gespeicherte SSH-Quellregeln" "Pfad C: Klartext-Meldung"
assert_no_calls "default deny incoming" "Pfad C: keine Policy-Aenderung"
assert_no_calls "enable" "Pfad C: ufw wird nicht aktiviert"
unset FAKE_UFW_ADDED

# Pfad C: ufw-Befehl fehlt (rc=127) -> harter Abbruch. Ohne lesbaren Status
# ist keine Regel-/Policy-Aenderung sicher (B6/A1).
capture "" "" 127
assert_rc 1 "Pfad C (ufw fehlt): Abbruch vor jeder Aenderung"
assert_out "ufw-Status nicht lesbar" "Pfad C (ufw fehlt): Klartext-Meldung"

# --- Pfad B: restriktive Regel ----------------------------------------------
# Weiterlaufen, aber NICHTS loeschen und keine weltweite Regel ergaenzen. Genau
# das war die Schwachstelle: frueher wurden Bestandsregeln geloescht und
# restauriert, jeder Abbruch dazwischen oeffnete SSH weltweit.
capture "${S_RESTRICT_OLD}" "${S_RESTRICT_OLD}" 0
assert_rc 0 "Pfad B (restriktiv) laeuft weiter"
assert_out "quellbeschränkte SSH-Regel bleibt unangetastet" "Pfad B: Meldung, dass nichts angetastet wird"
assert_out "192.168.1.0/24" "Pfad B: betroffene Regel steht in der Meldung"
assert_out "NEBEN der Beschränkung" "Pfad B: Coexistenz mit weltweiter allow-Regel wird gemeldet"
assert_no_calls "delete" "Pfad B: keine Bestandsregel wird geloescht"
assert_no_calls "limit 22/tcp" "Pfad B: keine weltweite limit-Regel ergaenzt"
[ -f "${WORK}/marker.txt" ] && pass "Pfad B: Lauf laeuft weiter (Marker geschrieben)" \
  || fail "Pfad B: Marker fehlt (Lauf abgebrochen?)"

# Pfad B ohne Coexistenz: nur die Warnung, keine Zweitmeldung.
capture "${S_RESTRICT_LIMIT}" "${S_RESTRICT_LIMIT}" 0
assert_rc 0 "Pfad B (nur Beschraenkung) laeuft weiter"
assert_out "quellbeschränkte SSH-Regel bleibt unangetastet" "Pfad B: Beschraenkung gemeldet"
assert_no_out "NEBEN der Beschränkung" "Pfad B: keine Falschmeldung ohne Coexistenz"
assert_no_calls "delete" "Pfad B (nur Beschraenkung): nichts wird geloescht"

# IPv6- und from-...-to-any-port-22-Form werden ebenfalls erkannt.
capture "${S_RESTRICT_V6}" "${S_RESTRICT_V6}" 0
assert_out "fd00::/8" "Pfad B: IPv6-(v6)-Zeile erkannt"
capture 'Status: active
ufw allow from 10.16.0.0/12 to any port 22 proto tcp' 'Status: active
ufw allow from 10.16.0.0/12 to any port 22 proto tcp' 0
assert_out "10.16.0.0/12" "Pfad B: from-...-to-any-port-22-Form erkannt"

# --- Regelanwendung: allow -> limit nur weltweit ----------------------------
capture "${S_ALLOW_WORLD}" "${S_ACTIVE}" 0
assert_rc 0 "Umwandlung (OpenSSH) laeuft weiter"
assert_calls "delete allow OpenSSH" "Umwandlung: vorgefundene OpenSSH-Regel wird entfernt"
assert_calls "limit 22/tcp" "Umwandlung: rate-limitierte Regel wird gesetzt"
assert_out "OK:" "Umwandlung: Erfolgsmeldung"

capture "${S_ALLOW_22_WORLD}" "${S_ONLY_80_LIMIT}" 0
assert_rc 0 "Umwandlung (22/tcp) laeuft weiter"
assert_calls "delete allow 22/tcp" "Umwandlung: 22/tcp-Regel wird entfernt"
assert_calls "limit 22/tcp" "Umwandlung: rate-limitierte Regel wird gesetzt"

# Verifikation: bleibt eine weltweite ALLOW-Zeile stehen, hart abbrechen –
# kein stilles Weiterlaufen mit offenem SSH.
capture "${S_ALLOW_WORLD}" "${S_ALLOW_WORLD}" 0
assert_rc 1 "Umwandlung ohne Wirkung: Exit 1"
assert_out "steht nach dem Löschen noch" "Umwandlung ohne Wirkung: Fehlermeldung"
printf '%s' "${OUT}" | grep -qF "CHECK_CONTINUE" \
  && fail "Umwandlung ohne Wirkung: darf nicht weiterlaufen" \
  || pass "Umwandlung ohne Wirkung: kein Weiterlauf"

# --- Abschlusscheck ---------------------------------------------------------
capture "${S_ACTIVE}" "${S_ACTIVE}" 0
assert_out "per ufw rate-limitiert" "Abschlusscheck: weltweite limit-Regel als ok"

capture "${S_RESTRICT_LIMIT}" "${S_RESTRICT_LIMIT}" 0
assert_out "SSH quellbeschränkt" "Abschlusscheck: Beschraenkung ohne weltweite Regel = ok"

capture "${S_RESTRICT_OLD}" "${S_RESTRICT_OLD}" 0
assert_out "jede IP könnte ohne Beschränkung" "Abschlusscheck: allow neben Beschraenkung = Fehler"

capture "${S_ONLY_80}" "${S_ONLY_80}" 0
assert_out "SSH-Rate-Limit-Regel fehlt" "Abschlusscheck: fehlende Regel = Fehler"

# --- Statisch: keine stille Oeffnung, alte Schwachstelle weg ----------------
grep -qF 'CODER_ALLOW_SSH_DOWNGRADE' "${SETUP}" \
  && fail "Bypass-Variable ist noch im Setup" || pass "kein Bypass mehr im Setup"
grep -qF 'UFW_RESTORE' "${SETUP}" \
  && fail "Restore-Logik ist noch im Setup" || pass "kein Restore mehr im Setup"
grep -qF 'coder-ssh-downgrade' "${SETUP}" \
  && fail "Before/After-Protokolle sind noch im Setup" || pass "keine Downgrade-Protokolle mehr"
grep -qF 'delete allow from' "${SETUP}" \
  && fail "Quellregel wird noch geloescht" || pass "kein Delete einer Quellregel"
grep -qF '10.16.0.0/12' "${SETUP}" \
  && fail "harte Schulnetz-IP steht noch im Setup" || pass "keine hart kodierte Schulnetz-IP"
grep -qF 'grep -Eq "22/(tcp|ssh)' "${SETUP}" \
  && fail "alter lueckenhafter Detektor wird noch als Gate benutzt" \
  || pass "alter lueckenhafter Detektor wird nicht mehr benutzt"
grep -qF 'Re-Run weitet SSH auf weltweit+limit aus' "${SETUP}" \
  && fail "alte reine Warnung ohne Gate ist noch im Code" \
  || pass "alte reine Warnung ohne Gate ist entfernt"

# Delete-Zeilen existieren nur in der allow->limit-Umwandlung (Extrakt):
# drei Schreibweisen derselben Regel (OpenSSH-Profil, 22/tcp, 22), sonst nirgends.
DEL_ALL="$(grep -cF 'ufw --force delete' "${SETUP}" || true)"
DEL_APPLY="$(grep -cF 'ufw --force delete' "${WORK}/apply.sh" || true)"
[ "${DEL_ALL}" -eq 3 ] && [ "${DEL_APPLY}" -eq 3 ] \
  && pass "genau die drei Delete-Zeilen der Umwandlung, keine ausserhalb (Anzahl=${DEL_ALL})" \
  || fail "Delete-Zeilen ausserhalb der Umwandlung: gesamt=${DEL_ALL} im Block=${DEL_APPLY}"
grep -qF 'ufw --force delete limit' "${SETUP}" \
  && fail "limit-Regel wird noch geloescht" || pass "limit-Regel wird nicht geloescht"
grep -qF 'quellbeschränkte SSH-Regel bleibt unangetastet' "${WORK}/apply.sh" \
  && pass "Regelanwendung meldet unangetastete Beschraenkung" \
  || fail "Regelanwendung meldet die unangetastete Beschraenkung nicht"
grep -qF 'if [ -n "${UFW_RESTRICTED}" ]; then' "${SETUP}" \
  && pass "Abschlusscheck ist pfadabhaengig (Beschraenkung)" \
  || fail "pfadabhaengiger Abschlusscheck fehlt"
grep -qF "grep -E '(22/tcp|OpenSSH)[[:space:]]+(LIMIT|ALLOW)'" "${SETUP}" \
  && pass "Abschlusscheck filtert SSH-Zeilen (22/tcp|OpenSSH)" \
  || fail "SSH-Zeilenfilter im Abschlusscheck fehlt"
LC="$(grep -nF 'UFW_OUT="$(ufw status numbered' "${SETUP}" | cut -d: -f1 || true)"
LI="$(grep -nF "grep -qi 'Status:" "${SETUP}" | cut -d: -f1 || true)"
LB="$(grep -nF 'elif [ -n "${UFW_RESTRICTED}" ]' "${SETUP}" | cut -d: -f1 || true)"
[ -n "${LC}" ] && [ -n "${LI}" ] && [ -n "${LB}" ] && [ "${LC}" -lt "${LI}" ] && [ "${LI}" -lt "${LB}" ] \
  && pass "Pfad C wird VOR Pfad B geprueft (Z.${LC} < Z.${LI} < Z.${LB})" \
  || fail "Pfad-Reihenfolge falsch (${LC}/${LI}/${LB})"
NT="$(grep -cF '| tee "${UFW_' "${SETUP}" || true)"
[ "${NT}" -eq 0 ] && pass "keine Before/After-Protokolle per tee" || fail "tee-Anzahl=${NT} (erwartet 0)"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-004: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-004: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
