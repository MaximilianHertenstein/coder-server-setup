# IMPLEMENTATION-REPORT-v3-B2-001

Stand: 2026-09-27. Branch: `ai/implementation-v3` (Basis-Commit `9f97a09`).
Umfang: ausschliesslich B2-001 (Backup-Headercheck / SIGPIPE / pipefail).

## Aktuelles Verhalten (vor dem Fix)

Der Headercheck im eingebetteten `backup.sh` (`setup-coder.sh`, Backup-Block)
lief als Einzeiler-Pipeline unter `set -euo pipefail`:

```bash
if ! zcat "${TMP}" 2>/dev/null | head -c 4000 | grep -q "PostgreSQL database dump"; then
```

## Problem (CONFIRMED per Repro, kein Lesungsbefund)

`head -c 4000` schliesst die Pipe nach 4000 Bytes. Sobald der unkomprimierte
Dump den Pipe-Puffer (~64 KB) uebersteigt, erhaelt `zcat` SIGPIPE (Exit 141).
Unter `pipefail` ist der Pipeline-Exit damit 141 ≠ 0, `! 141` ist wahr – der
Fail-Zweig feuert fuer einen gueltigen Dump. Kleine Fixtures passen in den
Puffer (`zcat` exitt 0) und bleiben gruen; deshalb fiel der Fehler mit kleinen
Fixtures nie auf. Folge: ab realer DB-Groesse kein Backup mehr, kein
Update-Pre-Backup, kein Reset-Vorab-Backup (jeweils Exit 1 mit irrefuehrender
SQL-Diagnose). Alte Backups altern still, Rotation greift nicht.

Repro-Beleg (lokal, nur /tmp, Commit `9f97a09`, bash 5.3.15, gzip 1.14):

- Fixture `big.sql`: Header `-- PostgreSQL database dump` + Fuelldaten,
  unkomprimiert 1200029 Bytes (> 1 MB), gzip 1239 Bytes.
- Alte Pipeline dagegen unter `set -o pipefail`: `rc=141`,
  `pipestatus=(141 0 0)` → Fail-Zweig (falsch).
- Kleine Fixture (33 Bytes, gleicher Header): OK (gruen) – erklaert, warum
  bisherige Proben den Fehler verdeckten.

## Vorgeschlagene / umgesetzte Aenderung (PLAN-v3 Variante 1, wörtlich)

SIGPIPE-Ursache entfernen, keine Schwelle raten, kein `pipefail`-Toggle,
Headercheck nicht entfernt, `gzip -t`/df-Gate/atomares `mv`/flock/Retention/
Mindestbestand/Fehlerbehandlung unveraendert:

```bash
# B2-001: Kopf in Variable lesen – direkte Pipe (zcat|head|grep) gäbe unter
# pipefail Exit 141 (SIGPIPE) bei Dumps > ~64 KB und damit falschen Fail.
HEADER="$(zcat "${TMP}" 2>/dev/null | head -c 4000 || true)"
if ! printf '%s' "${HEADER}" | grep -q "PostgreSQL database dump"; then
```

Begruendung: `|| true` maskiert den 141-Exit der Fuell-Pipeline; das Urteil
faellt auf der Variablen. `printf` schreibt hoechstens 4000 Bytes (passt in
den Pipe-Puffer), daher kein neues SIGPIPE-Risiko im Urteil. Ein korrupter
Dump liefert weiterhin leeren/falschen `HEADER` → Fail (fail-closed bleibt).

## Moegliche Regressionen (geprueft, keine offen)

- Korrupter/leerer Dump koennte fälschlich OK werden: ausgeschlossen –
  `gzip -t` davor bleibt hart; `zcat`-Fehlertext ohne Header faellt im
  `grep` durch (Negativfaelle im Test belegt).
- `set -e`-Abbruch durch `|| true`-Konstrukt: ausgeschlossen – Pipeline exitt
  0, Zuweisung erfolgreich; Isolations-Syntaxcheck + ShellCheck des
  extrahierten `backup.sh` sauber.
- Teil-Finaldatei bei Fehlschlag: unveraendert – `trap cleanup EXIT` + `mv`
  erst nach Verifikation bleiben bestehen (Code unberuehrt).

## Testdefinition (T-071b)

`tests/t-071b-headercheck.sh` (ausfuehrbar, nur /tmp): grosser gueltiger Dump
(≥ 1 MB, Groesse wird protokolliert) muss HEADER_OK liefern; leer / ungueltig /
ohne Header muessen HEADER_FAIL liefern; der grosse Dump darf nicht mit 141
scheitern; alte Pipeline muss am selben Dump scheitern (Repro-Beleg mit
`rc`-/PIPESTATUS-Protokoll); statischer Guard gegen Wiedereinfuehrung des
Einzeilers in `setup-coder.sh`.

# Changed

1. `setup-coder.sh` (Backup-Block, +4/−1): Headercheck von Einzeiler-Pipeline
   auf Variablen-Urteil umgestellt (s. o.). Keine andere Zeile geaendert.
2. `tests/t-071b-headercheck.sh` (neu): reproduzierbarer T-071b-Harness (s. o.).

# Tests Actually Run

Ausgefuehrt am 2026-09-27 auf dem Arbeitsrechner (kein Produktionsserver,
kein Docker noetig, nur /tmp), Commit `9f97a09` + Arbeitskopie-Aenderung:

1. `bash -n setup-coder.sh` → `SETUP_SYNTAX_OK` (PASS).
2. `bash -n tests/t-071b-headercheck.sh` → ok (PASS).
3. `shellcheck -S warning setup-coder.sh` → einziger Befund SC2034
   (`for i in $(seq 1 30)`, Postgres-Wait-Loop). Per `git stash` verifiziert:
   identischer Befund auf unveraendertem Basis-Stand (dort Z.1029, nach Fix
   Z.1032, reine Zeilenverschiebung). Kein neuer Befund durch B2-001 (PASS
   mit dokumentiertem Vorbestand).
4. Extrahierter Backup-Block (`awk`-Extrakt des `backup.sh`-Heredocs, 116
   Zeilen): `bash -n` → ok; `shellcheck -S warning` → keine Befunde (PASS).
5. `./tests/t-071b-headercheck.sh` (3× laeufe, deterministisch) → Exit 0
   (PASS). Ausgabe (ein Lauf):
   `Fixture big.sql unkomprimiert=1200029 Bytes komprimiert=1239 Bytes`;
   `PASS: grosser gueltiger Dump (1200029 Bytes) = HEADER_OK`;
   `alte Pipeline ... rc=141 pipestatus=(141 0 0)`, `PASS: ... Repro bestaetigt`;
   `PASS: leerer Dump = HEADER_FAIL`; `PASS: ungueltiger Dump = HEADER_FAIL`;
   `PASS: Dump ohne Header = HEADER_FAIL`;
   `PASS: setup-coder.sh enthaelt B2-001-Fix ...`;
   `T-071b: ALLE PRUEFUNGEN BESTANDEN`.
6. Repro der alten Pipeline separat (s. „Problem“): grosser Dump → FAIL,
   kleiner Dump → OK (Bestaetigung der Fehler­mechanik).

Tool-Versionen: bash 5.3.15, gzip 1.14, ShellCheck 0.11.0.

Nicht ausgefuehrt (ausserhalb B2-001-Umfang / Test-VM-Pflicht):
Full-`backup.sh`-Lauf mit echtem `pg_dump`/Docker, Cron-, Update-, Reset-,
Restore- und VM-Tests (PLAN-v3 Phase C). Kein „bestanden“ dafuer behauptet.

# Results

- Grosser Dump > 1 MB (1200029 Bytes) = PASS (HEADER_OK, kein 141).
- Leerer Dump = FAIL. Ungueltiger Dump = FAIL. Dump ohne Header = FAIL.
- Keine SIGPIPE-Fehlinterpretation mehr (Urteil ohne Pipe-Exit).
- Bestehendes Backup-Verhalten sonst unveraendert (flock, Temp-Datei,
  atomares `mv`, `gzip -t`, Fehlerbehandlung, Retention, Mindestbestand,
  keine partielle Finaldatei – alle Codepfade unberuehrt, Diff belegt).
- Diff-Kontrolle: `git diff` zeigt nur den Headercheck-Hunk in
  `setup-coder.sh`; keine ungeplanten/kosmetischen Aenderungen, keine neuen
  Abstraktionen, keine Abhaengigkeiten.

# Remaining Risk

- Echter `backup.sh`-End-to-End-Lauf (Docker/`pg_dump`, Cron, Update- und
  Reset-Pre-Backup, ENOSPC-/Abbruch-Pfade T-072/T-073, Mini-Restore T-080)
  ist nur auf isolierter Test-VM moeglich – dort vor Production-Freigabe
  nachholen (PLAN-v3 Phase C, Stop-Regel).
- Offsite/RTO (B-008), Restore-Runbook (B2-009) und übrige B2-Fixes sind
  ausserhalb dieses B2-001-Scopes und bleiben offen.
- Kein Blocker durch diese Aenderung verursacht; keiner noetig ausserhalb
  des erlaubten Umfangs (keine Erweiterung vorgenommen).

# Files Changed

- `setup-coder.sh` (M, +4/−1, nur B2-001-Headercheck im `backup.sh`-Block)
- `tests/t-071b-headercheck.sh` (neu, ausfuehrbar)
- `ai-review/IMPLEMENTATION-REPORT-v3-B2-001.md` (neu, diese Datei)

# Related Finding

B2-001
