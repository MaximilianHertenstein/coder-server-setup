#!/bin/bash
# B2-003 / Hex-Migration: Setup-Gate bleibt fail-closed; .env-Werte werden
# per Guards geschuetzt (Newline/NUL, Hex, Vollstaendigkeit).
# Beweist (nur /tmp, kein Docker, keine Produktion):
#  1. Setup-Gate: POSTGRES-Nicht-Hex -> ROT mit woertlichem Reparaturtext
#     (kein Pingpong); GRAFANA_ADMIN_PASSWORD ist vom Hex-Zwang ausgenommen.
#  2. Newline/NUL-Guard und Vollstaendigkeits-Check der .env greifen.
#  3. Das Erstkonto-Passwort geht per stdin an den Container, nicht in docker-argv.
#  4. Die .env traegt kein DOCKER_GID mehr; die GID steht fest in der Compose-Datei.
#  5. setup.conf-Parser: CRLF/Quotes strippen, Domain hart pruefen,
#     Env vor conf.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ---------- STATIK ----------
if grep -qF -- 'Fehler: /opt/coder/.env: POSTGRES_PASSWORD ist nicht-hex.' "${SETUP}" \
  && grep -qF -- 'Reparatur: siehe TROUBLESHOOTING.md (A4), danach Setup erneut.' "${SETUP}"; then
  pass "Setup-Gate Ersatztext woertlich (fail-closed + A4-Verweis)"
else
  fail "Setup-Gate Ersatztext fehlt/abweichend"
fi

if grep -qF -- 'Sonderzeichen/Quotes brechen Reset/URL' "${SETUP}"; then
  fail "alter Setup-Gate-Text noch vorhanden"
else
  pass "alter Setup-Gate-Text entfernt"
fi

if grep -qF -- 'Vollstaendigkeits-Check' "${SETUP}" \
  || grep -qF -- "grep -qE '^POSTGRES_PASSWORD=[^[:space:]]+' /opt/coder/.env" "${SETUP}"; then
  pass "Setup-Elif prueft beide Passwort-Schluessele (Tausch kann .env nie leeren)"
else
  fail "Setup-Vollstaendigkeits-Check fehlt"
fi

if grep -vE '^[[:space:]]*#' "${SETUP}" "${REPO_ROOT}"/scripts/*.sh 2>/dev/null | grep -qF -- 'docker exec -e'; then
  fail "docker exec -e als Kommando vorhanden (inspect-Leak)"
else
  pass "kein docker exec -e in setup oder scripts (kein inspect-Leak)"
fi

if grep -qF -- 'DOCKER_GID=${DOCKER_GID}' "${SETUP}"; then
  fail "Setup schreibt noch DOCKER_GID in die .env (2.7 entfernt)"
else
  pass "Setup schreibt kein DOCKER_GID mehr in die .env"
fi

if grep -qF -- '- "${DOCKER_GID}"' "${SETUP}" && ! grep -qF -- '- "\${DOCKER_GID}"' "${SETUP}"; then
  pass "Compose group_add traegt die GID als Literal (kein .env-Umweg)"
else
  fail "Compose group_add nutzt nicht das GID-Literal"
fi

if grep -qF -- 'Fehler: .env-Wert enthält Newline/NUL – wird nicht still getrimmt.' "${SETUP}"; then
  pass "Newline/NUL-Guard woertlich vorhanden"
else
  fail "Newline/NUL-Guard fehlt/abweichend"
fi

if grep -q 'read -rs -p "Erstkonto' "${SETUP}"; then
  pass "A4: Erstkonto-Passwort wird per read -rs abgefragt (nicht auf der Kommandozeile)"
else
  fail "A4: read -rs-Prompt fuer das Erstkonto-Passwort fehlt"
fi

if grep -qF -- 'CODER_FIRST_USER_PASSWORD_FILE' "${SETUP}"; then
  pass "A4: nicht-interaktiv per root-only Datei (CODER_FIRST_USER_PASSWORD_FILE)"
else
  fail "CODER_FIRST_USER_PASSWORD_FILE fehlt (nicht-interaktiv nur per argv?)"
fi

if grep -qF -- 'HUMAN_USERS=1' "${SETUP}"; then
  pass "Erstkontosanlage setzt HUMAN_USERS (danach kein 'Noch kein Konto')"
else
  fail "HUMAN_USERS=1 nach der Anlage fehlt (case meldet falsch 'Noch kein Konto')"
fi

# ---------- VERHALTEN (Gate-Logik = Produktionsausdruecke auf Fixture-.env) ----------
setup_gate_green() { # 0 = GRUEN (POSTGRES hex; Grafana-Wert egal)
  grep -qE '^POSTGRES_PASSWORD=[0-9a-f]+$' "$1"
}
setup_complete() { # 0 = beide Schluessel da (Elif-Zweig)
  grep -qE '^POSTGRES_PASSWORD=[^[:space:]]+' "$1" \
    && grep -qE '^GRAFANA_ADMIN_PASSWORD=[^[:space:]]+' "$1"
}
newline_guard_clean() { # 0 = sauber, 1 = schlaegt an (Produktionsausdruck)
  ! { [ "$(LC_ALL=C tr -d -c '\000' < "$1" | wc -c)" -ne 0 ] || grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=|^#|^$' "$1"; }
}

FIXT="${WORK}/fixtures.txt"
printf '%s\n' 'Legacy$Pass!23' 'a b' 'a"b' "a'b" 'a$b' 'a`b' '-lead-dash9' > "${FIXT}"
NEWHEX="0123456789abcdef0123456789abcdef0123456789abcdef"
GFHEX="abcdef0123456789abcdef0123456789"

while IFS= read -r V; do
  ENV="${WORK}/env-legacy"
  printf 'POSTGRES_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\n' "${V}" "${GFHEX}" > "${ENV}"
  TAG="Legacy-Wert [${V}]"
  if setup_gate_green "${ENV}"; then fail "${TAG}: Setup-Gate GRUEN (muss ROT)"; else pass "${TAG}: Setup-Gate ROT (fail-closed)"; fi
  if setup_complete "${ENV}"; then pass "${TAG}: Vollstaendigkeits-Check gruen (beide Schluessel da)"; else fail "${TAG}: Vollstaendigkeits-Check ohne beide Schluessel"; fi
  if newline_guard_clean "${ENV}"; then pass "${TAG}: Newline/NUL-Guard still"; else fail "${TAG}: Guard feuert faelschlich"; fi
  if printf '%s\n' "${V}" | grep -F -q -- "${V}"; then pass "${TAG}: Leak-Grep mit -- + -F findet Vollwert"; else fail "${TAG}: Leak-Grep-Mechanik defekt"; fi
done < "${FIXT}"

# Genau ein gruener Weg ueber hex: migrierte Hex-.env -> Gate GRUEN.
ENV_NEW="${WORK}/env-new"
printf 'POSTGRES_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\n' "${NEWHEX}" "${GFHEX}" > "${ENV_NEW}"
if setup_gate_green "${ENV_NEW}" && setup_complete "${ENV_NEW}" && newline_guard_clean "${ENV_NEW}"; then
  pass "migrierte Hex-.env: Gate GRUEN + vollstaendig"
else
  fail "migrierte Hex-.env: Gate nicht GRUEN"
fi

# Hexes POSTGRES + beliebiges (nicht-hexes) Grafana-Passwort -> GRUEN.
# B2-003-Revidierung: Hex-Zwang nur noch fuer die Postgres-Connection-URL.
ENV_GFNEW="${WORK}/env-grafana-frei"
printf 'POSTGRES_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\n' "${NEWHEX}" 'Mein-Grafana-Pass! 42' > "${ENV_GFNEW}"
if setup_gate_green "${ENV_GFNEW}" && setup_complete "${ENV_GFNEW}" && newline_guard_clean "${ENV_GFNEW}"; then
  pass "Grafana-Passwort darf vom Hex-Zwang abweichen (nur POSTGRES ist zwingend)"
else
  fail "nicht-hexes Grafana-Passwort wird zu Unrecht abgelehnt"
fi

# Nicht-hexes POSTGRES auch bei hexem Grafana -> ROT (Gate-Logik trennt sauber).
ENV_PGROT="${WORK}/env-postgres-rot"
printf 'POSTGRES_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\n' 'Legacy$Pass!23' "${GFHEX}" > "${ENV_PGROT}"
if setup_gate_green "${ENV_PGROT}"; then
  fail "nicht-hexes POSTGRES mit hexem Grafana: Gate GRUEN (muss ROT)"
else
  pass "nicht-hexes POSTGRES mit hexem Grafana: Gate ROT"
fi

# Alte .env-Gestalt (mit DOCKER_GID-Zeile) bleibt weiterhin bedienbar.
ENV_ALT="${WORK}/env-alt"
printf 'POSTGRES_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\nDOCKER_GID=999\n' "${NEWHEX}" "${GFHEX}" > "${ENV_ALT}"
if setup_gate_green "${ENV_ALT}" && setup_complete "${ENV_ALT}"; then
  pass "alte .env mit DOCKER_GID-Zeile: Gate weiterhin gruen"
else
  fail "alte .env mit DOCKER_GID-Zeile wird abgelehnt"
fi

# Negativ: Newline im Wert -> Guard feuert, kein stilles Trimmen.
ENV_NL="${WORK}/env-newline"
printf 'POSTGRES_PASSWORD=%s\n%s\nGRAFANA_ADMIN_PASSWORD=%s\n' "abc" "def" "${GFHEX}" > "${ENV_NL}"
if newline_guard_clean "${ENV_NL}"; then
  fail "Newline-Wert passiert Guard (stilles Trimmen moeglich)"
else
  pass "Newline-Wert -> Guard ROT mit Reparaturtext"
fi

# Negativ: NUL im Wert -> Guard feuert.
ENV_NUL="${WORK}/env-nul"
if command -v python3 >/dev/null 2>&1; then
  python3 -c "open('${ENV_NUL}','wb').write(b'POSTGRES_PASSWORD=ab\x00cd\nGRAFANA_ADMIN_PASSWORD=${GFHEX}\n')"
elif [ -x /usr/bin/printf ] && /usr/bin/printf 'a\x00b' | LC_ALL=C tr -d -c '\000' | grep -q .; then
  { /usr/bin/printf 'POSTGRES_PASSWORD=ab\x00cd\nGRAFANA_ADMIN_PASSWORD=%s\n' "${GFHEX}"; } > "${ENV_NUL}"
else
  fail "kein NUL-faehiger Writer (python3//usr/bin/printf)"; ENV_NUL=""
fi
if [ -n "${ENV_NUL}" ]; then
  if newline_guard_clean "${ENV_NUL}"; then
    fail "NUL-Wert passiert Guard"
  else
    pass "NUL-Wert -> Guard ROT mit Reparaturtext"
  fi
fi

# ---------- LIVE (Produktionszeilen, Docker stubbed: argv + stdin) ----------
# Extraktion: Zeilenbereich vom Zuweisungs-Anfang bis 2>&1); then – "if " und
# "; then" werden entfernt, damit der Rest eine auswertbare Zuweisung ist.
STMT_FIRST="$(awk '/FIRST_OUT=\$\(printf/,/2>&1\); then/' "${SETUP}" \
  | sed 's/^  if FIRST_OUT=/FIRST_OUT=/; s/); then$/)/')"
if [ -z "${STMT_FIRST}" ]; then
  fail "Erstkonto-Produktions-Statement nicht extrahierbar"
else
  pass "Erstkonto-Produktions-Statement extrahierbar"
fi

run_stmt() {
  local argv="${WORK}/$2.argv" stdin="${WORK}/$2.stdin"
  rm -f "${argv}" "${stdin}"
  # shellcheck disable=SC2034  # Variablen werden im eval'd Statement genutzt
  ( CODER_FIRST_USER_PASSWORD="$3";
    CODER_FIRST_USER_EMAIL="max@example.org"
    CODER_FIRST_USER_USERNAME="max"
    docker() { printf '%s\n' "$@" >> "${argv}"; cat > "${stdin}"; }
    eval "$(cat "$1")" )
}
check_argv_clean() {
  local tag="$1"; shift
  local secret
  for secret in "$@"; do
    if grep -F -q -- "${secret}" "${WORK}/${tag}.argv" 2>/dev/null; then
      fail "${tag}: Secret in docker-argv"
      return
    fi
  done
  pass "${tag}: docker-argv secret-frei"
}

run_stmt <(printf '%s\n' "${STMT_FIRST}") "firstuser" "${GFHEX}"
check_argv_clean "firstuser" "${GFHEX}" "${GFHEX:0:8}"
grep -F -q -- "${GFHEX}" "${WORK}/firstuser.stdin" && pass "Erstkonto-Passwort geht per stdin" || fail "Erstkonto-Passwort fehlt in stdin"

# ---------- PARSER (setup.conf CRLF/Quotes, Domain-Guard) -------------------
# Der echte Parser-Block aus setup-coder.sh wird extrahiert und gegen echte
# setup.conf-Fixtures ausgefuehrt: CRLF + umschliessende Quotes muessen
# weg, eine ungueltige Domain muss hart abbrechen, Env gewinnt vor conf.
P_START='if [ -f "${SETUP_DIR}/setup.conf" ]; then'
P_END='# Pin-Regeln: CODER/PROMETHEUS/GRAFANA/NODE_EXPORTER exakt'
P_S="$(grep -nF "${P_START}" "${SETUP}" | cut -d: -f1 || true)"
P_E="$(grep -nF "${P_END}" "${SETUP}" | cut -d: -f1 || true)"
if [ -n "${P_S}" ] && [ -n "${P_E}" ] && [ "${P_S}" -lt "${P_E}" ]; then
  awk -v a="${P_S}" -v b="${P_E}" 'NR>=a && NR<b' "${SETUP}" > "${WORK}/parser.sh"
  pass "Parser-Block extrahierbar (Z.${P_S}-Z.${P_E})"
else
  fail "Parser-Anker fehlen/ungeordnet (${P_S}/${P_E})"
fi
bash -n "${WORK}/parser.sh" && pass "Parser-Block syntaktisch gueltig" || fail "Parser-Syntax"

run_parser() {  # $1=conf (leer = keine Datei) $2=erwarteter rc; Env DOMAIN optional als $3
  local d="${WORK}/pconf" rc=0 out="" envarg=(env)
  rm -rf "${d}"; mkdir -p "${d}"
  [ -n "$1" ] && printf '%s' "$1" > "${d}/setup.conf"
  [ "$#" -ge 3 ] && envarg=(env "DOMAIN_CODER=$3")
  out=$("${envarg[@]}" SETUP_DIR="${d}" bash -c \
    'set -euo pipefail; . "$0"; printf "D=%s|E=%s|I=%s\n" "${DOMAIN_CODER}" "${ACME_EMAIL}" "${FAIL2BAN_IGNORE_IP:-}"' \
    "${WORK}/parser.sh" 2>&1) || rc=$?
  RC="${rc}"; OUT="${out}"
}

# (a) CRLF + doppelte/single Quotes + Kommentar + unbekannter Schluessel:
# Werte kommen sauber an, Lauf geht weiter.
run_parser $'DOMAIN_CODER="coder.beispiel.de"\r\nACME_EMAIL=\'ops@beispiel.de\'\r\nFAIL2BAN_IGNORE_IP=192.168.7.1\r\n# Kommentar\r\nUNBEKANNT=x\r\n' 0
[ "${RC}" -eq 0 ] && pass "Parser: CRLF/Quotes-Conf wird gelesen" || fail "Parser: rc=${RC} (erwartet 0)"
[ "${OUT}" = "D=coder.beispiel.de|E=ops@beispiel.de|I=192.168.7.1" ] \
  && pass "Parser: CR und Quotes strippen, Wert exakt" \
  || fail "Parser: Ausgabe=${OUT}"

# (b) Grossbuchstaben in der Domain -> harter Abbruch mit Klartext.
run_parser $'DOMAIN_CODER=Coder.Beispiel.de\r\n' 1
[ "${RC}" -eq 1 ] && pass "Parser: ungueltige Domain -> Exit 1" || fail "Parser: rc=${RC} (erwartet 1)"
case "${OUT}" in *"keine gültige Domain"*) pass "Parser: Klartext zur Domain" ;; *) fail "Parser: Domain-Fehlertext fehlt (${OUT})" ;; esac

# (c) Leerzeichen in der Domain -> ebenfalls hart abbrechen.
run_parser $'DOMAIN_CODER=coder beispiel.de\r\n' 1
[ "${RC}" -eq 1 ] && pass "Parser: Domain mit Leerzeichen -> Exit 1" || fail "Parser: rc=${RC} (erwartet 1)"

# (d) Umgebungsvariable gewinnt vor setup.conf.
run_parser $'DOMAIN_CODER=from-conf.example.de\r\n' 0 from-env.example.de
case "${OUT}" in D=from-env.example.de\|*) pass "Parser: Env gewinnt vor conf" ;; *) fail "Parser: Env-Vorrang fehlt (${OUT})" ;; esac

# (e) keine setup.conf -> eingebauter Default greift.
run_parser "" 0
case "${OUT}" in D=coder.ghse-unterricht.de\|*) pass "Parser: Default-Domain ohne conf" ;; *) fail "Parser: Default fehlt (${OUT})" ;; esac

if [ "${FAIL}" = "0" ]; then
  echo "B2-003: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "B2-003: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
