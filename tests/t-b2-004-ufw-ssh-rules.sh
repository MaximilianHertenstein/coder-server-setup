#!/bin/bash
# T-062 / B2-004 (Stand: Review SSH 2026-10-03 – allow statt limit, weil
# ufw limit die geteilte Schul-NAT drosselt; fail2ban bleibt der
# Brute-Force-Schutz, Netzgrenze am Router, D-SSH).
# Geprueft: die echten Stuecke aus setup-coder.sh (nach Zeilen extrahiert,
# mit Fake-ufw in /tmp, ohne Root, ohne Produktion):
#   Gate: ohne lesbaren ufw-Status = harter Abbruch; inaktiv = Warnung,
#         Lauf faehrt fort
#   Regelanwendung: Policy erst, dann allow fuer die erkannten sshd-Ports
#         (Schleife ueber SSHD_PORTS, idempotent), DANACH eigene alte
#         limit-Regel loeschen (kein Fenster ohne SSH-Regel); nie eine
#         Quellregel anfassen, keine fremden Regeln loeschen
#   Abschlusscheck: jede erkannte Portnummer muss als ALLOW (Anywhere)
#         stehen; LIMIT oder fehlende Regel = Fehler
#   Statisch: kein Bypass, kein Restore, kein Quellregel-Delete, keine
#         Detektor-/Beschraenkungs-Zweiglogik, keine "ufw limit"-Zeile
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
RE_INACTIVE="$(sed -n "s/.*grep -qi '\(Status[^']*\)'.*/\1/p" "${SETUP}" | head -n1)"
[ -n "${RE_INACTIVE}" ] && pass "Inaktiv-Muster aus Quelle gelesen" || fail "Inaktiv-Muster fehlt"

GATE_ANCHOR='if ! UFW_OUT="$(ufw status numbered 2>/dev/null)"; then'
GATE_END='# Regelanwendung: einfache feste Folge.'
APPLY_START='# Regelanwendung: einfache feste Folge.'
APPLY_END='# Nur die Nicht-Defaults setzen.'
CHECK_START='UFW_STATUS="$(ufw status)"'
CHECK_END='# B13: ein einziger Check'

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

# --- Fake-ufw ---------------------------------------------------------------
# Der Zustand liegt in einer Datei: "delete"/"limit"/"allow"/"enable"
# schreiben FAKE_UFW_STATUS_AFTER, "status" liest den aktuellen Stand. Damit
# ist testbar, was passiert, ohne echtes ufw. Jeder Aufruf wird protokolliert
# (FAKE_UFW_CALLS).
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
    warn() { echo "WARN: $1"; }
    ok()   { echo "OK: $1"; }
    fail() { echo "FEHLER: $1"; }
    export SSHD_PORTS="${SSHD_PORTS:-22}"
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
22/tcp                     LIMIT       Anywhere'
S_RESTRICT_KEEP='Status: active
To                         Action      From
--                         ------      ----
22                         ALLOW       192.168.1.0/24'
S_ONLY_80='Status: active
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere'
S_ONLY_80_ALLOW='Status: active
80/tcp                     ALLOW       Anywhere
443/tcp                    ALLOW       Anywhere
22/tcp                     ALLOW       Anywhere'

# --- Pfad A: alte limit-Regel vorhanden -------------------------------------
# Die eigene limit-Regel frueherer Laeufe wird nach dem neuen allow entfernt
# (allow zuerst, also nie ein Augenblick ohne SSH-Regel). Quellregeln nie
# anfassen, fremde Regeln nie loeschen.
capture "${S_ACTIVE}" "${S_ACTIVE}" 0
assert_rc 0 "Pfad A (weltweit limit) laeuft weiter"
assert_out "CHECK_CONTINUE" "Pfad A: Lauf geht weiter"
assert_no_out "WARN:" "Pfad A: keine WARNung"
assert_calls "allow 22/tcp" "Pfad A: allow wird gesetzt"
assert_calls "delete limit 22/tcp" "Pfad A: eigene alte limit-Regel wird entfernt"
assert_no_calls "delete allow from" "Pfad A: keine Quellregel wird geloescht"

# Pfad A ohne SSH-Regel: allow ist idempotent, delete limit = No-Op.
capture "${S_ONLY_80}" "${S_ONLY_80_ALLOW}" 0
assert_rc 0 "Pfad A (nur 80/443) laeuft weiter"
assert_calls "allow 22/tcp" "Pfad A: fehlende SSH-Regel wird als allow gesetzt"
assert_no_calls "delete allow from" "Pfad A (nur 80/443): keine Quellregel geloescht"

# --- Pfad C: UFW inaktiv ----------------------------------------------------
capture "Status: inactive" "${S_ALLOW_22_WORLD}" 0
assert_rc 0 "Pfad C (inactive) laeuft weiter"
assert_out "WARN:" "Pfad C: Hinweis ausgegeben"
assert_no_calls "delete allow from" "Pfad C: keine Quellregel wird geloescht"
assert_no_calls "show added" "Pfad C: kein show added (keine Quellregel-Detektion)"

# Pfad C: ufw-Befehl fehlt (rc=127) -> harter Abbruch. Ohne lesbaren Status
# ist keine Regel-/Policy-Aenderung sicher (B6/A1).
capture "" "" 127
assert_rc 1 "Pfad C (ufw fehlt): Abbruch vor jeder Aenderung"
assert_out "ufw-Status nicht lesbar" "Pfad C (ufw fehlt): Klartext-Meldung"

# --- Pfad B: Quellregeln bleiben unberuehrt ---------------------------------
# B11/D-SSH: keine Beschaenkungs-Zweiglogik; die Quellregel wird nie
# geloescht, allow + delete-eigene-limit laufen idempotent daneben.
capture "${S_RESTRICT_OLD}" "${S_RESTRICT_KEEP}" 0
assert_rc 0 "Pfad B (Quellregel + alte limit) laeuft weiter"
assert_calls "allow 22/tcp" "Pfad B: allow wird gesetzt"
assert_calls "delete limit 22/tcp" "Pfad B: eigene limit-Regel wird entfernt"
assert_no_calls "delete allow from" "Pfad B: Quellregel wird nie geloescht"

# Quellregel allein (keine 22-Regel): idempotenter Lauf.
capture "${S_RESTRICT_KEEP}" "${S_RESTRICT_KEEP}" 0
assert_rc 0 "Pfad B (nur Quellregel) laeuft weiter"
assert_calls "allow 22/tcp" "Pfad B: allow wird auch neben der Quellregel gesetzt"

# --- Pfad D: fremde allow-Regeln bleiben unangetastet -----------------------
# Frueher wurden drei allow-Schreibweisen geloescht und limit gesetzt; jetzt
# wird nichts geloescht ausser der eigenen limit-Regel.
capture "${S_ALLOW_WORLD}" "${S_ALLOW_WORLD}" 0
assert_rc 0 "Pfad D (OpenSSH-allow) laeuft weiter"
assert_no_calls "delete allow OpenSSH" "Pfad D: fremde/vorgefundene allow wird NICHT geloescht"
assert_calls "allow 22/tcp" "Pfad D: eigene allow-Regel wird gesetzt"

capture "${S_ALLOW_22_WORLD}" "${S_ALLOW_22_WORLD}" 0
assert_rc 0 "Pfad D (22/tcp-allow) laeuft weiter"
assert_no_calls "delete allow 22/tcp" "Pfad D: vorhandene 22/tcp-allow bleibt (idempotentes Skipping)"
assert_calls "allow 22/tcp" "Pfad D: allow wird idempotent aufgerufen"

# --- Abschlusscheck ---------------------------------------------------------
capture "${S_ALLOW_22_WORLD}" "${S_ALLOW_22_WORLD}" 0
assert_out "SSH-Port 22/tcp steht als ALLOW" "Abschlusscheck: weltweite ALLOW-Regel als ok"
assert_out "ufw ist aktiv" "Abschlusscheck: Aktivitaet bestaetigt"

# Alte limit-Regel allein zaehlt NICHT mehr als erfuellt (D-SSH).
capture "${S_ACTIVE}" "${S_ACTIVE}" 0
assert_out "SSH-ALLOW-Regel fehlt" "Abschlusscheck: LIMIT ohne ALLOW = Fehler"
printf '%s' "${OUT}" | grep -qF "CHECK_CONTINUE" \
  && pass "Abschlusscheck: Lauf bricht bei fehlender ALLOW-Regel ab" \
  || fail "Abschlusscheck: bricht nicht ab"

capture "${S_ONLY_80}" "${S_ONLY_80}" 0
assert_out "SSH-ALLOW-Regel fehlt" "Abschlusscheck: fehlende Regel = Fehler"

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
grep -qF 'UFW_RESTRICTED' "${SETUP}" \
  && fail "Beschraenkungs-Zweiglogik (UFW_RESTRICTED) ist noch im Setup" \
  || pass "keine Beschraenkungs-Zweiglogik mehr"
grep -qF 'quellbeschränkte SSH-Regel bleibt unangetastet' "${SETUP}" \
  && fail "alte Beschraenkungs-Meldung ist noch im Setup" \
  || pass "alte Beschraenkungs-Meldung entfernt"
grep -qF 'ufw show added' "${SETUP}" \
  && fail "ufw show added wird noch abgefragt (Quellregel-Detektion)" \
  || pass "kein ufw show added (kein Quellregel-Detektor)"
grep -qF 'ufw limit 22/tcp' "${SETUP}" \
  && fail "harte 'ufw limit 22/tcp'-Zeile ist noch im Setup" \
  || pass "keine 'ufw limit 22/tcp'-Zeile (allow statt limit)"

# Genau eine Delete-Zeile: die eigene alte limit-Regel, nirgends sonst.
DEL_ALL="$(grep -cF 'ufw --force delete' "${SETUP}" || true)"
DEL_APPLY="$(grep -cF 'ufw --force delete' "${WORK}/apply.sh" || true)"
[ "${DEL_ALL}" -eq 1 ] && [ "${DEL_APPLY}" -eq 1 ] \
  && pass "genau die eine Delete-Zeile (eigene limit) in der Anwendung (Anzahl=${DEL_ALL})" \
  || fail "Delete-Zeilen: gesamt=${DEL_ALL} im Block=${DEL_APPLY} (erwartet 1/1)"
grep -qF 'ufw --force delete limit 22/tcp' "${SETUP}" \
  && pass "Delete trifft nur die eigene limit-Regel" \
  || fail "eigene limit-Regel wird nicht geloescht"

# SSH-Regel kommt aus der erkannten Portliste, nicht aus einer Festzahl.
grep -qF 'ufw allow "${_ssh_p}/tcp"' "${SETUP}" \
  && pass "allow in der Schleife ueber SSHD_PORTS" \
  || fail "allow-Schleife ueber SSHD_PORTS fehlt"
grep -qF '^${_p}/tcp[[:space:]]+ALLOW[[:space:]]+Anywhere' "${SETUP}" \
  && pass "Abschlusscheck filtert ALLOW-Zeilen der erkannten Ports" \
  || fail "ALLOW-Filter im Abschlusscheck fehlt"
LC="$(grep -nF 'UFW_OUT="$(ufw status numbered' "${SETUP}" | cut -d: -f1 || true)"
LI="$(grep -nF "grep -qi 'Status:" "${SETUP}" | cut -d: -f1 || true)"
LA="$(grep -nF '# Regelanwendung: einfache feste Folge.' "${SETUP}" | cut -d: -f1 || true)"
[ -n "${LC}" ] && [ -n "${LI}" ] && [ -n "${LA}" ] && [ "${LC}" -lt "${LI}" ] && [ "${LI}" -lt "${LA}" ] \
  && pass "Status-Gate VOR Inaktiv-Hinweis VOR Anwendung (Z.${LC} < Z.${LI} < Z.${LA})" \
  || fail "Reihenfolge falsch (${LC}/${LI}/${LA})"
NT="$(grep -cF '| tee "${UFW_' "${SETUP}" || true)"
[ "${NT}" -eq 0 ] && pass "keine Before/After-Protokolle per tee" || fail "tee-Anzahl=${NT} (erwartet 0)"

if [ "${FAIL}" -eq 0 ]; then
  echo "T-B2-004: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-004: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
