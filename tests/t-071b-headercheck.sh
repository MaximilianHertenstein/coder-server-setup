#!/bin/bash
# T-071b / B2-001: Backup-Headercheck (SIGPIPE + pipefail).
# Ein gueltiger SQL-Dump mit PostgreSQL-Header und >= 1 MB unkomprimiert muss
# HEADER_OK liefern; leer/ungueltig/ohne Header muss HEADER_FAIL liefern.
# Der grosse gueltige Dump darf insbesondere NICHT mit Exit 141 (SIGPIPE)
# fehlschlagen. Nur /tmp, keine Produktion.
set -euo pipefail

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Exakt die zwei Headercheck-Zeilen aus setup-coder.sh (backup.sh-Block).
headercheck_fixed() {
  local TMP="$1" HEADER
  HEADER="$(zcat "${TMP}" 2>/dev/null | head -c 4000 || true)"
  printf '%s' "${HEADER}" | grep -q "PostgreSQL database dump"
}

# Fixture 1: gueltiger Dump, unkomprimiert > 1 MB (Header in den ersten Bytes).
BIG_SQL="${WORK}/big.sql"
echo "-- PostgreSQL database dump" > "${BIG_SQL}"
head -c 1200000 /dev/zero | tr '\0' 'a' >> "${BIG_SQL}"
echo "" >> "${BIG_SQL}"
gzip -c "${BIG_SQL}" > "${BIG_SQL}.gz"
BIG_BYTES="$(stat -c %s "${BIG_SQL}")"
BIG_GZ_BYTES="$(stat -c %s "${BIG_SQL}.gz")"
echo "INFO: Fixture big.sql unkomprimiert=${BIG_BYTES} Bytes komprimiert=${BIG_GZ_BYTES} Bytes"
[ "${BIG_BYTES}" -ge 1048576 ] || { fail "Fixture kleiner als 1 MB"; }

# 1. Grosser gueltiger Dump muss OK sein (kein SIGPIPE-Fehlurteil, kein 141).
if headercheck_fixed "${BIG_SQL}.gz"; then
  pass "grosser gueltiger Dump (${BIG_BYTES} Bytes) = HEADER_OK"
else
  RC=$?
  [ "${RC}" -ne 141 ] || echo "INFO: Fehlschlag mit 141 (SIGPIPE) – B2-001 offen"
  fail "grosser gueltiger Dump (${BIG_BYTES} Bytes) abgewiesen (rc=${RC})"
fi

# 2. Repro-Beleg: die alte Einzeiler-Pipeline verwirft denselben Dump (141).
zcat "${BIG_SQL}.gz" 2>/dev/null | head -c 4000 | grep -q "PostgreSQL database dump" || OLD_RC=$?
OLD_RC="${OLD_RC:-0}"
# Hinweis: PIPESTATUS muss als ERSTES nach der Pipeline gelesen werden –
# schon "rc=$?" setzt es auf ein Element zurueck.
OLD_PS="$(bash -c 'zcat "$1" 2>/dev/null | head -c 4000 | grep -q "PostgreSQL database dump"; ps=("${PIPESTATUS[@]}"); echo "${ps[*]}"' _ "${BIG_SQL}.gz")"
echo "INFO: alte Pipeline gegen grossen Dump -> rc=${OLD_RC} pipestatus=(${OLD_PS}) (Erwartung: rc!=0, ein Element 141)"
if [ "${OLD_RC}" -ne 0 ]; then
  pass "alte Pipeline scheitert am grossen Dump (Repro bestaetigt, rc=${OLD_RC})"
else
  fail "alte Pipeline akzeptiert grossen Dump – Repro unguelig"
fi

# 3. Leerer Dump muss FAIL liefern.
printf '' | gzip > "${WORK}/empty.sql.gz"
if headercheck_fixed "${WORK}/empty.sql.gz"; then
  fail "leerer Dump akzeptiert"
else
  pass "leerer Dump = HEADER_FAIL"
fi

# 4. Ungueltiger Inhalt muss FAIL liefern.
printf 'das ist kein dump\n' | gzip > "${WORK}/invalid.sql.gz"
if headercheck_fixed "${WORK}/invalid.sql.gz"; then
  fail "ungueltiger Dump akzeptiert"
else
  pass "ungueltiger Dump = HEADER_FAIL"
fi

# 5. Fehlender Header (gross, aber ohne Headerzeile) muss FAIL liefern.
NOHEAD_SQL="${WORK}/nohead.sql"
head -c 1200000 /dev/zero | tr '\0' 'b' > "${NOHEAD_SQL}"
gzip -c "${NOHEAD_SQL}" > "${NOHEAD_SQL}.gz"
if headercheck_fixed "${NOHEAD_SQL}.gz"; then
  fail "Dump ohne Header akzeptiert"
else
  pass "Dump ohne Header = HEADER_FAIL"
fi

# 6. Statischer Guard: Fix in setup-coder.sh vorhanden, alte Einzeiler-Form weg.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if grep -qF 'HEADER="$(zcat "${TMP}"' "${REPO_ROOT}/setup-coder.sh" \
  && grep -qF 'printf '"'"'%s'"'"' "${HEADER}" | grep -q "PostgreSQL database dump"' "${REPO_ROOT}/setup-coder.sh" \
  && ! grep -qF 'if ! zcat "${TMP}" 2>/dev/null | head -c 4000 | grep -q' "${REPO_ROOT}/setup-coder.sh"; then
  pass "setup-coder.sh enthaelt B2-001-Fix (kein Einzeiler-Headercheck)"
else
  fail "setup-coder.sh enthaelt B2-001-Fix nicht (oder Einzeiler noch vorhanden)"
fi

if [ "${FAIL}" -eq 0 ]; then
  echo "T-071b: ALLE PRUEFUNGEN BESTANDEN"
else
  echo "T-071b: FEHLGESCHLAGEN"
fi
exit "${FAIL}"
