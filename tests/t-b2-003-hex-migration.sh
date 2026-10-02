#!/bin/bash
# B2-003 / Hex-Migration: Setup-Gate bleibt fail-closed; .env-Werte werden
# per Guards geschuetzt (Newline/NUL, Hex, Vollstaendigkeit).
# Beweist (nur /tmp, kein Docker, keine Produktion):
#  1. Setup-Gate: Nicht-Hex -> ROT mit woertlichem Reparaturtext (kein Pingpong).
#  2. Newline/NUL-Guard und Vollstaendigkeits-Check der .env greifen.
#  3. Das Erstkonto-Passwort geht per stdin an den Container, nicht in docker-argv.
#  4. Die .env traegt kein DOCKER_GID mehr; die GID steht fest in der Compose-Datei.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ---------- STATIK ----------
if grep -qF -- 'Fehler: /opt/coder/.env enthält Nicht-Hex-Passwörter.' "${SETUP}" \
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

# ---------- VERHALTEN (Gate-Logik = Produktionsausdruecke auf Fixture-.env) ----------
setup_gate_green() { # 0 = GRUEN (Hex), 1 = ROT
  grep -qE '^POSTGRES_PASSWORD=[0-9a-f]+$' "$1" \
    && grep -qE '^GRAFANA_ADMIN_PASSWORD=[0-9a-f]+$' "$1"
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

# Genau ein gruener Weg: migrierte Hex-.env -> Gate GRUEN.
ENV_NEW="${WORK}/env-new"
printf 'POSTGRES_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\n' "${NEWHEX}" "${GFHEX}" > "${ENV_NEW}"
if setup_gate_green "${ENV_NEW}" && setup_complete "${ENV_NEW}" && newline_guard_clean "${ENV_NEW}"; then
  pass "migrierte Hex-.env: Gate GRUEN + vollstaendig (genau ein gruener Weg)"
else
  fail "migrierte Hex-.env: Gate nicht GRUEN"
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

if [ "${FAIL}" = "0" ]; then
  echo "B2-003: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "B2-003: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
