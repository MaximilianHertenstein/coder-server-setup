#!/usr/bin/env bash
# B2-009: RESTORE.md Pfad A – psql mit ON_ERROR_STOP=1 + Datensicht-Verifikation.
# STATIC (Struktur der Runbook-Texte) + UNIT-LIKE (der dokumentierte Importbefehl
# wird aus RESTORE.md extrahiert und mit Fake-zcat/sudo/docker/psql ausgefuehrt).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$REPO_ROOT/RESTORE.md"
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=1; }

[ -f "$DOC" ] || { echo "FAIL: RESTORE.md fehlt"; exit 1; }

echo "== (1) STATIC: Flag, Abbruch, Datensicht =="

IMPORT_LINE="$(awk '
  /sudo docker exec coder-postgres dropdb/ { grab = 1 }
  grab {
    printf "%s", $0
    if (/psql .* -d coder`$/) { print ""; exit }
  }' "$DOC")"
if printf '%s' "$IMPORT_LINE" | grep -qF -- 'psql -v ON_ERROR_STOP=1 -U coder -d coder'; then
  pass "(1) Importzeile enthaelt psql -v ON_ERROR_STOP=1 -U coder -d coder"
else
  fail "(1) Importzeile enthaelt psql -v ON_ERROR_STOP=1 -U coder -d coder"
fi

if printf '%s' "$IMPORT_LINE" | grep -qF -- 'psql -U coder -d coder'; then
  fail "(1) Importzeile enthaelt noch die Flag-freie Form psql -U"
else
  pass "(1) Importzeile enthaelt noch die Flag-freie Form psql -U"
fi

_idx() { printf '%s' "$1" | awk -v n="$2" '{print index($0, n); exit}'; }
_PSQL="${IMPORT_LINE##*psql }"   # nur der psql-Teil (dropdb/createdb haben eigene -U)
_vpos="$(_idx "$_PSQL" '-v ON_ERROR_STOP=1')"
_upos="$(_idx "$_PSQL" '-U')"
if [ "$_vpos" -gt 0 ] && [ "$_upos" -gt 0 ] && [ "$_vpos" -lt "$_upos" ]; then
  pass "(1) ON_ERROR_STOP steht vor -U (Position exakt)"
else
  fail "(1) ON_ERROR_STOP steht vor -U (Position exakt) v=$_vpos u=$_upos"
fi

if printf '%s' "$IMPORT_LINE" | grep -qF -- 'dropdb -U coder --if-exists'; then
  pass "(1) dropdb --if-exists bleibt Teil von Pfad A Schritt 4"
else
  fail "(1) dropdb --if-exists bleibt Teil von Pfad A Schritt 4"
fi

if printf '%s' "$IMPORT_LINE" | grep -qF -- 'createdb -U coder -O coder coder'; then
  pass "(1) createdb bleibt Teil von Pfad A Schritt 4"
else
  fail "(1) createdb bleibt Teil von Pfad A Schritt 4"
fi

if printf '%s' "$IMPORT_LINE" | grep -qF -- '&&'; then
  pass "(1) &&-Kette bleibt erhalten"
else
  fail "(1) &&-Kette bleibt erhalten"
fi

if grep -qF -- '**STOPP bei Exit ≠ 0**' "$DOC" \
  && grep -qF -- 'Schritt 5 NICHT ausführen' "$DOC" \
  && grep -qF -- 'kein `up -d`' "$DOC"; then
  pass "(1) harter Abbruch vor Schritt 5 / up -d dokumentiert"
else
  fail "(1) harter Abbruch vor Schritt 5 / up -d dokumentiert"
fi

if grep -qF -- 'set -o pipefail' "$DOC"; then
  pass "(1) pipefail-Hinweis fuer automatisierte Kette"
else
  fail "(1) pipefail-Hinweis fuer automatisierte Kette"
fi

echo "== (2) STATIC: Datenprobe statt Liveness-only =="

if grep -qF -- 'CREATE TABLE IF NOT EXISTS restore_probe(id serial primary key, marker text)' "$DOC"; then
  pass "(2) Restore-Sonde wird angelegt (restore_probe, marker)"
else
  fail "(2) Restore-Sonde wird angelegt (restore_probe, marker)"
fi

if grep -qF -- "DELETE FROM restore_probe WHERE marker='RTO-PROBE-AAAA-MM-JJ'" "$DOC" \
  && grep -qF -- "INSERT INTO restore_probe(marker) VALUES ('RTO-PROBE-AAAA-MM-JJ')" "$DOC"; then
  pass "(2) Sonde ist idempotent (genau eine Zeile je Datum)"
else
  fail "(2) Sonde ist idempotent (genau eine Zeile je Datum)"
fi

_line_probe="$(grep -nF 'CREATE TABLE IF NOT EXISTS restore_probe' "$DOC" | head -1 | cut -d: -f1 || true)"
_line_pfada="$(grep -nF '## Pfad A' "$DOC" | head -1 | cut -d: -f1 || true)"
if [ -n "$_line_probe" ] && [ -n "$_line_pfada" ] && [ "$_line_probe" -lt "$_line_pfada" ]; then
  pass "(2) Sonde wird VOR dem Backup-Pfad dokumentiert (Voraussetzung)"
else
  fail "(2) Sonde wird VOR dem Backup-Pfad dokumentiert (Voraussetzung)"
fi

if grep -qF -- "SELECT count(*) FROM restore_probe WHERE marker='RTO-PROBE-AAAA-MM-JJ'" "$DOC"; then
  pass "(2) Zaehlung der Sonde nach Restore"
else
  fail "(2) Zaehlung der Sonde nach Restore"
fi

if grep -qF -- 'muss `1` liefern' "$DOC"; then
  pass "(2) Zaehlung muss 1 liefern"
else
  fail "(2) Zaehlung muss 1 liefern"
fi

if grep -qF -- 'psql -v ON_ERROR_STOP=1 -U coder -d coder -tAc "SELECT count(*) FROM restore_probe' "$DOC"; then
  pass "(2) Datenprobe laeuft ebenfalls mit ON_ERROR_STOP=1"
else
  fail "(2) Datenprobe laeuft ebenfalls mit ON_ERROR_STOP=1"
fi

if grep -qF -- '**Restore NICHT anerkennen**' "$DOC" && grep -qF -- 'rot bleiben' "$DOC"; then
  pass "(2) Zaehlung 0/>1/psql-Fehler wird NICHT als Erfolg akzeptiert"
else
  fail "(2) Zaehlung 0/>1/psql-Fehler wird NICHT als Erfolg akzeptiert"
fi

if grep -qF -- 'Liveness ≠ wiederhergestellte' "$DOC" \
  && grep -qF -- '`SELECT 1`/`/healthz` allein sind **keine** Restore-Bestätigung' "$DOC"; then
  pass "(2) Liveness und Datenprobe sind getrennt"
else
  fail "(2) Liveness und Datenprobe sind getrennt"
fi

if grep -qF -- 'Coder-Login prüfen (`/healthz` 200 + Dashboard-Login)' "$DOC"; then
  fail "(2) alte Liveness-only-Verifikation entfernt"
else
  pass "(2) alte Liveness-only-Verifikation entfernt"
fi

if grep -qF -- 'Verifikation + RTO wie Pfad A Schritt 5–6' "$DOC"; then
  pass "(2) Pfad B verweist auf dieselbe Verifikation"
else
  fail "(2) Pfad B verweist auf dieselbe Verifikation"
fi

if grep -qF -- '| Datum | Coder-Version | RTO | Datenprobe = 1 | Login ok |' "$DOC"; then
  pass "(2) RTO-Tabelle dokumentiert die Datenprobe"
else
  fail "(2) RTO-Tabelle dokumentiert die Datenprobe"
fi

echo "== (3) UNIT-LIKE: dokumentierter Importbefehl mit Fakes =="

WORK="$(mktemp -d /tmp/t-b2-009.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"
ARGS="$WORK/psql.args"
STDIN_N="$WORK/psql.stdin"
ZCAT_LOG="$WORK/zcat.log"

cat > "$BIN/zcat" <<'FAKE'
#!/usr/bin/env bash
printf 'ran\n' >> "${ZCAT_LOG:?}"
printf 'CREATE TABLE restore_probe(id serial primary key, marker text);\n'
printf 'INSERT INTO restore_probe(marker) VALUES (0);\n'
FAKE

cat > "$BIN/sudo" <<'FAKE'
#!/usr/bin/env bash
exec "$@"
FAKE

cat > "$BIN/docker" <<'FAKE'
#!/usr/bin/env bash
# unterstuetzt nur: exec [-i] <container> <cmd ...>
[ "${1:-}" = "exec" ] || { printf 'docker-ungueltig: %s\n' "$*" >&2; exit 91; }
shift
[ "${1:-}" = "-i" ] && shift
shift
exec "$@"
FAKE

cat > "$BIN/dropdb" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

cat > "$BIN/createdb" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

cat > "$BIN/psql" <<'FAKE'
#!/usr/bin/env bash
: > "${ARGS:?}"
for a in "$@"; do printf '%s\n' "$a" >> "$ARGS"; done
_n=0
while IFS= read -r _l; do _n=$((_n + ${#_l})); done
printf '%s' "$_n" > "${STDIN_N:?}"
_has=0
for a in "$@"; do [ "$a" = "ON_ERROR_STOP=1" ] && _has=1; done
if [ "${BROKEN_DUMP:-0}" = "1" ]; then
  if [ "$_has" = "1" ]; then exit 3; fi   # Skriptmodus ohne ON_ERROR_STOP: Fehler ueberspringen, Exit 0
fi
exit 0
FAKE

chmod +x "$BIN"/*
export ZCAT_LOG ARGS STDIN_N

# Importbefehl aus RESTORE.md extrahieren (logische Zeile mit \-Fortsetzung)
RUN="$(printf '%s' "$IMPORT_LINE" | tr -d '`\\' | tr -s '[:space:]' ' ')"
RUN="${RUN//<TS>/20260928}"   # Platzhalter ersetzen, sonst parse- `<` als Redirektion

if [ -n "$RUN" ] && printf '%s' "$RUN" | grep -qF -- 'psql -v ON_ERROR_STOP=1'; then
  pass "(3) Importbefehl aus RESTORE.md extrahiert"
else
  fail "(3) Importbefehl aus RESTORE.md extrahiert"
  echo "T-B2-009: FEHLGESCHLAGEN (kein Befehl)"; exit 1
fi

# Fall A: Dump in Ordnung -> Exit 0, Flag an erwarteter Position, stdin gelesen
rm -f "$ZCAT_LOG" "$ARGS" "$STDIN_N"
set +e
( PATH="$BIN:$PATH" BROKEN_DUMP=0 bash -c "$RUN" ) >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  pass "(3) A: gueltiger Dump -> Exit 0"
else
  fail "(3) A: gueltiger Dump -> Exit 0 (rc=$rc)"
fi
if [ -f "$ZCAT_LOG" ] && [ -s "$ARGS" ]; then
  pass "(3) A: Pipeline lief zcat | docker exec -i psql (stdin gelesen)"
else
  fail "(3) A: Pipeline lief zcat | docker exec -i psql (stdin gelesen)"
fi
_v="$(awk '/ON_ERROR_STOP=1/ { print NR }' "$ARGS" | head -1)"
_u="$(awk '/^-U$/ { print NR }' "$ARGS" | head -1)"
if [ -n "$_v" ] && [ -n "$_u" ] && [ "$_v" -lt "$_u" ]; then
  pass "(3) A: ON_ERROR_STOP=1 in psql-argv, Position vor -U"
else
  fail "(3) A: ON_ERROR_STOP=1 in psql-argv, Position vor -U (v=${_v:-none} u=${_u:-none})"
fi

# Fall B: defekter Dump -> Exit != 0 (Abbruch vor Schritt 5)
set +e
( PATH="$BIN:$PATH" BROKEN_DUMP=1 bash -c "$RUN" ) >/dev/null 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
  pass "(3) B: defekter Dump -> Exit != 0 (kein gruener Restore)"
else
  fail "(3) B: defekter Dump -> Exit != 0 (rc=$rc)"
fi

# Negativkontrolle: dieselbe Pipeline OHNE das Flag waere still gruen
OLD_RUN="${RUN/ -v ON_ERROR_STOP=1/}"
if [ "$OLD_RUN" != "$RUN" ]; then
  set +e
  ( PATH="$BIN:$PATH" BROKEN_DUMP=1 bash -c "$OLD_RUN" ) >/dev/null 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass "(3) C: ohne Flag waere derselbe defekte Dump still Exit 0"
  else
    fail "(3) C: ohne Flag waere derselbe defekte Dump still Exit 0 (rc=$rc)"
  fi
else
  fail "(3) C: Negativkontrolle ohne Flag konnte nicht gebaut werden"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "T-B2-009: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-B2-009: FEHLGESCHLAGEN"
fi
exit "$FAIL"
