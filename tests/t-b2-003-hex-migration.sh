#!/bin/bash
# B2-003 / Hex-Migration: Setup-Gate bleibt fail-closed; Rotation braucht das
# bisherige Postgres-Passwort nicht.
# Beweist (nur /tmp, kein Docker, keine Produktion):
#  1. Setup-Gate: Nicht-Hex -> ROT mit woertlichem Reparaturtext (kein Pingpong).
#  2. Das Reset-Gate benötigt nur DOCKER_GID; Newline/NUL -> hart ROT
#     (kein stilles Trimmen).
#  3. Das neue Postgres-Passwort geht per stdin an psql, nicht in docker-argv.
#  4. Legacy-Postgres-Werte werden ersetzt, ohne sie zu lesen oder zu trimmen.
# Diese statische Probe behauptet keinen echten Datenbanklauf. Die
# Postgres-Verifikation muss auf einer isolierten Test-VM erfolgen.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Reset-Block (eingebettetes reset-passwords.sh) zur statischen Pruefung.
awk '/write_managed .*reset-passwords.sh/,/^EOF$/' "${SETUP}" | tail -n +2 | head -n -1 > "${WORK}/reset-block.sh"
[ -s "${WORK}/reset-block.sh" ] || { fail "Reset-Block nicht extrahierbar"; }

# ---------- STATIK ----------
if grep -qF -- 'Fehler: /opt/coder/.env enthält Nicht-Hex-Passwörter.' "${SETUP}" \
  && grep -qF -- 'Reparatur: sudo /opt/coder/reset-passwords.sh setzt Postgres und Grafana neu auf Hex, danach Setup erneut.' "${SETUP}"; then
  pass "Setup-Gate Ersatztext woertlich (fail-closed + Reset-Verweis)"
else
  fail "Setup-Gate Ersatztext fehlt/abweichend"
fi

if grep -qF -- 'Sonderzeichen/Quotes brechen Reset/URL' "${SETUP}"; then
  fail "alter Setup-Gate-Text noch vorhanden"
else
  pass "alter Setup-Gate-Text entfernt"
fi

if grep -qF -- 'Zeilenstruktur manuell korrigieren' "${WORK}/reset-block.sh"; then
  pass "Reset fordert zuerst die manuelle Reparatur der Env-Zeilen"
else
  fail "Reset nennt keine sichere Reparatur für fehlerhafte Env-Zeilen"
fi

if grep -qF -- 'keine gültige DOCKER_GID' "${WORK}/reset-block.sh"; then
  pass "Reset prüft die benötigte DOCKER_GID"
else
  fail "Reset prüft DOCKER_GID nicht"
fi

N_Q="$(grep -cF "<<'INNER_EOF'" "${WORK}/reset-block.sh" || true)"
N_U="$(grep -c '<<INNER_EOF' "${WORK}/reset-block.sh" || true)"
if [ "${N_Q}" = "0" ] && [ "${N_U}" = "2" ]; then
  pass "nur zwei unquotierte Heredocs für TCP-Verifikation und Grafana"
else
  fail "Heredoc-Anzahl falsch (quotiert=${N_Q} unquotiert=${N_U}, erwartet 0/2)"
fi

if grep -vE '^[[:space:]]*#' "${SETUP}" | grep -qF -- 'docker exec -e'; then
  fail "docker exec -e als Kommando vorhanden (inspect-Leak)"
else
  pass "kein docker exec -e (kein inspect-Leak)"
fi

if grep -qF -- "} | docker exec -i coder-postgres psql -v ON_ERROR_STOP=1 -U coder -d coder" "${WORK}/reset-block.sh" && ! grep -qF -- 'OLD_PG_PW' "${WORK}/reset-block.sh"; then
  pass "ALTER USER nutzt lokalen psql-stdin; altes Passwort wird nicht gelesen"
else
  fail "ALTER USER-psql-Aufruf fehlt/abweichend"
fi

if grep -qF -- 'Neuwürfelung lieferte kein Hex' "${WORK}/reset-block.sh"; then
  pass "NEU-Hex-Assert fail-closed vorhanden"
else
  fail "NEU-Hex-Assert fehlt"
fi

if grep -qF -- 'Fehler: .env-Wert enthält Newline/NUL – wird nicht still getrimmt.' "${WORK}/reset-block.sh"; then
  pass "Newline/NUL-Guard woertlich vorhanden"
else
  fail "Newline/NUL-Guard fehlt/abweichend"
fi

# ---------- VERHALTEN (Gate-Logik = Produktionsausdruecke auf Fixture-.env) ----------
setup_gate_green() { # 0 = GRUEN (Hex), 1 = ROT
  grep -qE '^POSTGRES_PASSWORD=[0-9a-f]+$' "$1" \
    && grep -qE '^GRAFANA_ADMIN_PASSWORD=[0-9a-f]+$' "$1"
}
reset_complete() { # 0 = Reset kann die Werte erneuern
  grep -qE '^DOCKER_GID=[0-9]+$' "$1"
}
newline_guard_clean() { # 0 = sauber, 1 = schlaegt an (Produktionsausdruck)
  ! { [ "$(LC_ALL=C tr -d -c '\000' < "$1" | wc -c)" -ne 0 ] || grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=|^#|^$' "$1"; }
}
new_hex_ok() { # 0 = Hex
  printf '%s' "$1" | grep -qE '^[0-9a-f]+$'
}

FIXT="${WORK}/fixtures.txt"
printf '%s\n' 'Legacy$Pass!23' 'a b' 'a"b' "a'b" 'a$b' 'a`b' '-lead-dash9' > "${FIXT}"
NEWHEX="0123456789abcdef0123456789abcdef0123456789abcdef"
GFHEX="abcdef0123456789abcdef0123456789"

while IFS= read -r V; do
  ENV="${WORK}/env-legacy"
  printf 'POSTGRES_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\nDOCKER_GID=%s\n' "${V}" "${GFHEX}" "999" > "${ENV}"
  TAG="Legacy-Wert [${V}]"
  if setup_gate_green "${ENV}"; then fail "${TAG}: Setup-Gate GRUEN (muss ROT)"; else pass "${TAG}: Setup-Gate ROT (fail-closed)"; fi
  if reset_complete "${ENV}"; then pass "${TAG}: Reset kann den Legacy-Wert ersetzen"; else fail "${TAG}: Reset-Gate braucht eine gültige DOCKER_GID"; fi
  if newline_guard_clean "${ENV}"; then pass "${TAG}: Newline/NUL-Guard still"; else fail "${TAG}: Guard feuert faelschlich"; fi
  if printf '%s\n' "${V}" | grep -F -q -- "${V}"; then pass "${TAG}: Leak-Grep mit -- + -F findet Vollwert"; else fail "${TAG}: Leak-Grep-Mechanik defekt"; fi
done < "${FIXT}"

# Genau ein gruener Weg: migrierte Hex-.env -> beide Gates GRUEN.
ENV_NEW="${WORK}/env-new"
printf 'POSTGRES_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\nDOCKER_GID=%s\n' "${NEWHEX}" "${GFHEX}" "999" > "${ENV_NEW}"
if setup_gate_green "${ENV_NEW}" && reset_complete "${ENV_NEW}" && newline_guard_clean "${ENV_NEW}"; then
  pass "migrierte Hex-.env: Setup GRUEN + Reset GRUEN (genau ein gruener Weg)"
else
  fail "migrierte Hex-.env: Gates nicht beide GRUEN"
fi

# Negativ: Newline im Wert -> Guard feuert, kein stilles Trimmen.
ENV_NL="${WORK}/env-newline"
printf 'POSTGRES_PASSWORD=%s\n%s\nGRAFANA_ADMIN_PASSWORD=%s\nDOCKER_GID=%s\n' "abc" "def" "${GFHEX}" "999" > "${ENV_NL}"
if newline_guard_clean "${ENV_NL}"; then
  fail "Newline-Wert passiert Guard (stilles Trimmen moeglich)"
else
  pass "Newline-Wert -> Guard ROT mit Reparaturtext"
fi

# Negativ: NUL im Wert -> Guard feuert.
ENV_NUL="${WORK}/env-nul"
if command -v python3 >/dev/null 2>&1; then
  python3 -c "open('${ENV_NUL}','wb').write(b'POSTGRES_PASSWORD=ab\x00cd\nGRAFANA_ADMIN_PASSWORD=${GFHEX}\nDOCKER_GID=999\n')"
elif [ -x /usr/bin/printf ] && /usr/bin/printf 'a\x00b' | LC_ALL=C tr -d -c '\000' | grep -q .; then
  { /usr/bin/printf 'POSTGRES_PASSWORD=ab\x00cd\nGRAFANA_ADMIN_PASSWORD=%s\nDOCKER_GID=999\n' "${GFHEX}"; } > "${ENV_NUL}"
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

# NEU-Hex-Assert: Hex OK, leer/defekt ROT.
if new_hex_ok "${NEWHEX}" && new_hex_ok "${GFHEX}"; then pass "NEU-Hex-Assert: Hex OK"; else fail "NEU-Hex-Assert weist Hex ab"; fi
if new_hex_ok ""; then fail "NEU-Hex-Assert: leer passiert"; else pass "NEU-Hex-Assert: leer ROT"; fi
if new_hex_ok 'zz$top'; then fail "NEU-Hex-Assert: Nicht-Hex passiert"; else pass "NEU-Hex-Assert: Nicht-Hex ROT"; fi

# ---------- LIVE (Produktionszeilen, Docker stubbed: argv + stdin) ----------
STMT_PG="$(awk '$0=="{" {p=1} p {print} p && /^} \| docker exec -i coder-postgres psql/ {exit}' "${WORK}/reset-block.sh")"
STMT_VERIFY="$(awk '/docker exec -i coder-postgres sh <<INNER_EOF/,/^INNER_EOF$/' "${WORK}/reset-block.sh")"
STMT_GRAFANA="$(awk '/docker exec -i coder-grafana sh <<INNER_EOF/,/^INNER_EOF$/' "${WORK}/reset-block.sh")"
if [ -z "${STMT_PG}" ] || [ -z "${STMT_VERIFY}" ] || [ -z "${STMT_GRAFANA}" ]; then
  fail "Produktions-Statements nicht extrahierbar (Postgres/Verify/Grafana)"
else
  pass "Produktions-Statements extrahierbar"
fi

run_stmt() {
  local argv="${WORK}/$2.argv" stdin="${WORK}/$2.stdin"
  rm -f "${argv}" "${stdin}"
  ( NEW_PG_PW="$3"; NEW_GF_PW="$4"; PGH="172.18.0.2";
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

NEWHEX="0123456789abcdef0123456789abcdef0123456789abcdef"
GFHEX="abcdef0123456789abcdef0123456789"
run_stmt <(printf '%s\n' "${STMT_PG}") "pg" "${NEWHEX}" "${GFHEX}"
check_argv_clean "pg" "${NEWHEX}" "${NEWHEX:0:8}"
if grep -F -q -- "${NEWHEX}" "${WORK}/pg.stdin" && grep -qF "ALTER USER coder WITH PASSWORD :'new_password';" "${WORK}/pg.stdin"; then
  pass "neues PG-Passwort nur über stdin und als psql-Literal"
else
  fail "PG-stdin enthält Passwort/Literal nicht"
fi

run_stmt <(printf '%s\n' "${STMT_VERIFY}") "verify" "${NEWHEX}" "${GFHEX}"
check_argv_clean "verify" "${NEWHEX}" "${NEWHEX:0:8}"
grep -F -q -- "${NEWHEX}" "${WORK}/verify.stdin" && pass "Verify-Passwort geht per stdin" || fail "Verify-Passwort fehlt in stdin"

run_stmt <(printf '%s\n' "${STMT_GRAFANA}") "grafana" "${NEWHEX}" "${GFHEX}"
check_argv_clean "grafana" "${GFHEX}" "${GFHEX:0:8}"
grep -F -q -- "${GFHEX}" "${WORK}/grafana.stdin" && pass "Grafana-Passwort geht per stdin" || fail "Grafana-Passwort fehlt in stdin"

if [ "${FAIL}" = "0" ]; then
  echo "B2-003: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "B2-003: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
