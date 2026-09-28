#!/bin/bash
# B2-003 / Hex-Migration: Setup-Gate bleibt fail-closed, Reset migriert Legacy lesend.
# Beweist (nur /tmp, kein Docker, keine Produktion):
#  1. Setup-Gate: Nicht-Hex -> ROT mit woertlichem Reparaturtext (kein Pingpong).
#  2. Reset-Gate: Legacy-ALT lesend OK, unvollstaendig weiter ROT (verweist auf
#     Setup, NIEMALS auf sich selbst), Newline/NUL -> hart ROT (kein Trimmen).
#  3. ALT+NEU via STDIN (quotierter Heredoc, kein docker exec -e, kein Secret
#     in docker-argv ~ ps/inspect-sichtbar) – geprueft an den echten
#     Produktionszeilen (eval mit stubbed docker).
#  4. Legacy-Vollvorrat ($, Backtick, Quotes, Space, fuehrendes -) passiert
#     printf/read verlustfrei; danach beide Gates GRUEN (genau ein gruener Weg).
# Lokal belegt (postgres:15-alpine): Container-sh = busybox ash versteht
# `read -rs`, "sh -s" mit Daten auf stdin scheitert mit rc=127 (deshalb sh -c).
# VM-Pflicht (echte DB + ALTER USER + ps/inspect-Grep waehrend Rotation) bleibt
# Phase B/C und ist hier NICHT behauptet.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/setup-coder.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Reset-Block (eingebettetes reset-passwords.sh) zur statischen Pruefung.
awk '/tee \/opt\/coder\/reset-passwords.sh/,/^EOF$/' "${SETUP}" | tail -n +2 | head -n -1 > "${WORK}/reset-block.sh"
[ -s "${WORK}/reset-block.sh" ] || { fail "Reset-Block nicht extrahierbar"; }

# ---------- STATIK ----------
if grep -qF -- 'Fehler: /opt/coder/.env enthält Nicht-Hex-Passwörter.' "${SETUP}" \
  && grep -qF -- 'Reparatur: erst sudo /opt/coder/reset-passwords.sh laufen lassen (migriert Legacy lesend nach Hex), danach Setup erneut.' "${SETUP}"; then
  pass "Setup-Gate Ersatztext woertlich (fail-closed + Reset-Verweis)"
else
  fail "Setup-Gate Ersatztext fehlt/abweichend"
fi

if grep -qF -- 'Sonderzeichen/Quotes brechen Reset/URL' "${SETUP}"; then
  fail "alter Setup-Gate-Text noch vorhanden"
else
  pass "alter Setup-Gate-Text entfernt"
fi

if grep -E 'echo "Reparatur' "${WORK}/reset-block.sh" | grep -qF -- 'reset-passwords.sh'; then
  fail "Reset-Reparatur verweist auf sich selbst (Pingpong)"
else
  pass "Reset-Reparatur ohne Selbstverweis (kein Pingpong)"
fi

if grep -qF -- 'setup-coder.sh meldet wie' "${WORK}/reset-block.sh"; then
  pass "Reset-Unvollstaendig verweist auf Setup-Reparatur"
else
  fail "Reset-Unvollstaendig ohne Setup-Verweis"
fi

N_Q="$(grep -cF "<<'INNER_EOF'" "${WORK}/reset-block.sh" || true)"
N_U="$(grep -c '<<INNER_EOF' "${WORK}/reset-block.sh" || true)"
if [ "${N_Q}" = "1" ] && [ "${N_U}" = "2" ]; then
  pass "Heredoc-Quoting: 1x quotiert (ALT-Auth) + 2x unquotiert (Verify/Grafana, Hex-only)"
else
  fail "Heredoc-Quoting falsch (quotiert=${N_Q} unquotiert=${N_U}, erwartet 1/2)"
fi

if grep -vE '^[[:space:]]*#' "${SETUP}" | grep -qF -- 'docker exec -e'; then
  fail "docker exec -e als Kommando vorhanden (inspect-Leak)"
else
  pass "kein docker exec -e (kein inspect-Leak)"
fi

if grep -qF -- 'read -rs OLD_PG_PW' "${WORK}/reset-block.sh" \
  && grep -qF -- 'read -rs NEW_PG_PW' "${WORK}/reset-block.sh" \
  && grep -qF -- '| docker exec -i coder-postgres sh -c' "${WORK}/reset-block.sh"; then
  pass "ALT+NEU via STDIN (read -rs + sh -c, nie interpoliert/argv)"
else
  fail "STDIN-Uebergabe fehlt/abweichend"
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
reset_complete() { # 0 = vollständig
  grep -qE '^POSTGRES_PASSWORD=[^[:space:]]+' "$1" && grep -qE '^DOCKER_GID=[0-9]+$' "$1"
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
  if reset_complete "${ENV}"; then pass "${TAG}: Reset-Vollstaendigkeit OK (ALT lesend)"; else fail "${TAG}: Reset weist Legacy ab"; fi
  if newline_guard_clean "${ENV}"; then pass "${TAG}: Newline/NUL-Guard still"; else fail "${TAG}: Guard feuert faelschlich"; fi
  OLD_GOT="$(grep '^POSTGRES_PASSWORD=' "${ENV}" | cut -d= -f2-)"
  if [ "${OLD_GOT}" = "${V}" ]; then pass "${TAG}: Extraktion verlustfrei (cut -d= -f2-)"; else fail "${TAG}: Extraktion korrupt"; fi
  if printf '%s\n%s\n' "${V}" "${NEWHEX}" | { read -rs A; read -rs B; [ "${A}" = "${V}" ] && [ "${B}" = "${NEWHEX}" ]; }; then
    pass "${TAG}: printf/read-Roundtrip verlustfrei"
  else
    fail "${TAG}: printf/read-Roundtrip korrupt"
  fi
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

# ---------- LIVE (Produktionszeilen, docker stubbed: argv ~ ps, STDIN = Transport) ----------
# ALT-Statement per Zeilennummern (kein $-Pattern: gawk matcht das nicht).
ALT_START="$(grep -nF '| docker exec -i coder-postgres sh -c' "${WORK}/reset-block.sh" | head -n 1 | cut -d: -f1)"
ALT_END="$(awk -v s="${ALT_START}" 'NR>=s && /^\)"$/ {print NR; exit}' "${WORK}/reset-block.sh")"
STMT_ALT="$(sed -n "${ALT_START},${ALT_END}p" "${WORK}/reset-block.sh")"
STMT_VERIFY="$(awk '/docker exec -i coder-postgres sh <<INNER_EOF/,/^INNER_EOF$/' "${WORK}/reset-block.sh")"
STMT_GRAFANA="$(awk '/docker exec -i coder-grafana sh <<INNER_EOF/,/^INNER_EOF$/' "${WORK}/reset-block.sh")"
if [ -z "${STMT_ALT}" ] || [ -z "${STMT_VERIFY}" ] || [ -z "${STMT_GRAFANA}" ]; then
  fail "Produktions-Statements nicht extrahierbar (ALT/Verify/Grafana)"
else
  pass "Produktions-Statements extrahierbar (kein Test-Drift)"
fi

run_stmt() { # $1=stmt-file $2=tag $3=alt $4=neu(pg) $5=neu(gf)
  local argv="${WORK}/$2.argv" stdin="${WORK}/$2.stdin"
  rm -f "${argv}" "${stdin}"
  # shellcheck disable=SC2034
  # OLD_/NEW_-Vars werden im eval'd Produktions-Statement verwendet.
  ( OLD_PG_PW="$3"; NEW_PG_PW="$4"; NEW_GF_PW="$5";
    docker() { printf '%s\n' "$@" >> "${argv}"; cat > "${stdin}"; }
    eval "$(cat "$1")" )
}
check_argv_clean() { # $1=tag, rest=Secrets (Vollwert + 8er-Praefix muessen fehlen)
  local tag="$1"; shift
  local s
  for s in "$@"; do
    if grep -F -q -- "${s}" "${WORK}/${tag}.argv" 2>/dev/null; then
      fail "${tag}: Secret-Fragment [${s}] in docker-argv (ps/inspect-sichtbar)"
      return
    fi
  done
  pass "${tag}: docker-argv secret-frei (kein ps-/inspect-Leak)"
}

V_PROBE='Legacy$Pass!23'
run_stmt <(printf '%s\n' "${STMT_ALT}") "alt" "${V_PROBE}" "${NEWHEX}" "${GFHEX}"
check_argv_clean "alt" "${V_PROBE}" "${V_PROBE:0:8}" "${NEWHEX}" "${NEWHEX:0:8}"
if [ "$(cat "${WORK}/alt.stdin")" = "$(printf '%s\n%s' "${V_PROBE}" "${NEWHEX}")" ]; then
  pass "alt: ALT+NEU vollständig via STDIN transportiert"
else
  fail "alt: STDIN-Transport unvollständig"
fi

run_stmt <(printf '%s\n' "${STMT_VERIFY}") "verify" "${V_PROBE}" "${NEWHEX}" "${GFHEX}"
check_argv_clean "verify" "${NEWHEX}" "${NEWHEX:0:8}"
if grep -F -q -- "${NEWHEX}" "${WORK}/verify.stdin"; then
  pass "verify: NEU via STDIN-Skript (argv-frei)"
else
  fail "verify: STDIN enthaelt NEU nicht"
fi

run_stmt <(printf '%s\n' "${STMT_GRAFANA}") "grafana" "${V_PROBE}" "${NEWHEX}" "${GFHEX}"
check_argv_clean "grafana" "${GFHEX}" "${GFHEX:0:8}"
if grep -F -q -- "${GFHEX}" "${WORK}/grafana.stdin"; then
  pass "grafana: NEU via STDIN-Skript (argv-frei)"
else
  fail "grafana: STDIN enthaelt NEU nicht"
fi

if [ "${FAIL}" = "0" ]; then
  echo "B2-003: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "B2-003: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
