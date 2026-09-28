# IMPLEMENTATION-REPORT-v3-B2-007

Stand: 2026-09-28. Branch: `ai/implementation-v3` (Basis-Commit `7373bd2`).
Umfang: ausschliesslich B2-007 (Drift-Hashes erst in Schritt 10).

Grundlagen: `ai-review/PLAN-v3.md` (B2-007, Z.376-417; C-011),
`ai-review/PLAN-v3-FINAL-CHECK.md` (PV-003),
`ai-review/FINAL-BREAKER-v2.md` (B2-007).

## Aktuelles Verhalten (vor dem Fix)

Einziger `remember_hash`-Ort war die Schleife in Schritt 10
(`for _f in <15 Pfade>; do remember_hash "${_f}"; done`). Alle
`note_drift`-Aufrufe stehen VOR dem jeweiligen `tee`.

## Problem (CONFIRMED)

Jeder `exit 1`-Pfad vor Schritt 10 (Hex-Gate, Daemon-Preflight,
`set -e`-Abbrueche) liess veraltete Hashes zurueck. Ablauf: Lauf 1 gruen ->
Datei-Template aendert sich -> Lauf 2 schreibt neu (Schritt 2), bricht vor
Schritt 10 ab -> Lauf 3 (Heilung) meldet "Operator-Drift" fuer
setup-eigene Residuen. Folge: Warnmuedigkeit, auch fuer die
B-007-Downgrade-Warnung. Zweite Kante: waere `remember_hash` wörtlich an die
`note_drift`-Zeile davor gesetzt worden, haette der Hash der ALTEN Datei
gecommittet.

## Umgesetzte Aenderung (PLAN-v3 Z.392-404, reiner Ortswechsel)

1. `remember_hash "<Pfad>"` unmittelbar NACH der erfolgreichen
   Schreib-/Chmod-Sequenz jeder der 15 ueberwachten Dateien:
   - ohne `chmod`: direkt nach `EOF` des `tee` (docker-compose.yml,
     Caddyfile, prometheus.yml, jail.local, 52-coder-reboot);
   - mit `chmod`: direkt nach `sudo chmod ...` (boot-check.sh,
     coder-bootcheck-Cron, check-tls.sh, coder-tlscheck-Cron, backup.sh,
     coder-backup-Cron, coder-backup-logrotate, update.sh,
     reset-passwords.sh, reset-coder.sh).
2. Schritt-10-Schleife entfernt (Zeilenblock ersetzt durch 7 Kommentar-
   zeilen, die den neuen Commit-Ort und den dokumentierten Restpfad benennen).
3. Kommentar am `HASHSTORE`-Block: Commit-Ort dokumentiert.
4. Deterministische Regeneration, WARN-Semantik (nie interaktiv), 600-Modus
   und Abdeckung aller 15 Dateien unveraendert – nur der Ort verschoben.

Hash erst nach erfolgreich geschriebenem Zustand: unter `set -euo pipefail`
erreicht `remember_hash` nur, wenn `tee` (und falls vorhanden `chmod`)
Exit 0 lieferten. `note_drift` bleibt an seinem Platz VOR dem Schreiben –
sonst waere der Vorher-Zustand nicht mehr beobachtbar.

## Abweichungen vom Planwortlaut

Keine funktional. Kommentare an den drei beruehrten Stellen (B-012-Block,
Schritt-10-Block) sind aktualisiert, damit der Kommentar nicht laenger das
alte Verhalten behauptet (Doku-Gate: Kommentare synchron halten).

## Moegliche Regressionen (geprueft, keine offen)

- Abbruch nach Schritt 2: Hash der neuen Datei ist bereits committet ->
  Folgelauf ohne Fehl-WARN (war: Fehl-WARN).
- Hand-Drift (Operator-Tuning): `note_drift` lauft weiter VOR dem
  Schreiben und sieht die abweichende Datei -> WARN bleibt.
- Residualpfad (Kill zwischen Schreiben und `remember_hash`): genau einmal
  Fehl-WARN im Folgelauf, kein Datenverlust, der naechste gruene Lauf heilt
  (dokumentiert, Plan Z.401-404).
- Hashstore-Integritaet: atomare Ersetzung + 600 unveraendert (Test).
- Kein zweiter/entfernter Hash-Ort: 15/15 Einzelaufrufe, keine Schleife.
- Auswirkung auf B2-006 (Pre-Check) und fruehere Fixes: keine.

## Testdefinition

`tests/t-b2-007-drift-hash.sh` (neu, ausfuehrbar, nur /tmp, kein Docker,
keine Produktion) – STATIC + UNIT-LIKE, 37 Checks:

- Struktur: 15 `note_drift` + 15 `remember_hash`, je Pfad
  `note_drift < tee < remember_hash`, `chmod < remember_hash` wo vorhanden,
  kein unerwarteter Pfad, Schritt-10-Schleife entfernt, keine gebuendelte
  Nachzugs-Schleife.
- Verhalten der ECHTEN Funktionen (ausextrahiert aus `setup-coder.sh`,
  `sudo`-Shim, Hashstore in `/tmp`):
  (a) frisch geschriebene Datei + Hash -> keine WARN;
  (b) echte Hand-Drift -> WARN bleibt, `remember_hash` heilt;
  (c) Residualpfad (Schreiben ohne Hash-Commit) -> genau einmal WARN je Lauf,
  Folgelauf heilt ohne Datenverlust;
  Hashstore-Modus 600, keine Dubletten, genau ein Eintrag.

Nicht Teil dieses Tests (Plan Z.412-417, Kategorie VM): T-026 mit echtem
Setup-Abbruch auf Test-VM (a) Abbruch nach Schritt 2, (b) Hand-Drift,
(c) Kill-zwischen-Write-und-Hash am laufenden Skript.

# Changed

1. `setup-coder.sh` (15 Stellen): `remember_hash "<Pfad>"` nach
   `EOF` bzw. `sudo chmod` der jeweiligen Datei eingefuegt.
2. `setup-coder.sh` (Schritt 10): Hash-Schleife entfernt, durch
   Kommentar zum neuen Commit-Ort ersetzt.
3. `setup-coder.sh` (B-012-Kommentar): Commit-Ort dokumentiert.
4. `tests/t-b2-007-drift-hash.sh` (neu, ausfuehrbar, 37 Checks).
5. `ai-review/IMPLEMENTATION-REPORT-v3-B2-007.md` (neu, diese Datei).

Diff-Kontrolle: `git diff --numstat setup-coder.sh` = 28/10, ausschliesslich
die B2-007-Zonen (B-012-Kommentar, 15 Schreibstellen, Schritt-10-Block).
Keine Aenderung an `note_drift`/`remember_hash`-Logik, keine neuen
Abstraktionen, kein `lib.sh`, kein Helper ueber Heredoc-Grenzen.

# Tests Actually Run

Ausgefuehrt am 2026-09-28 auf dem Arbeitsrechner (kein Produktionsserver),
Basis-Commit `7373bd2` + Arbeitskopie:

1. `bash -n setup-coder.sh` -> ok (PASS, Exit 0).
2. `bash -n tests/t-b2-007-drift-hash.sh` -> ok (PASS, Exit 0).
3. `shellcheck -S warning setup-coder.sh` -> einziger Befund SC2034
   (`for i in $(seq 1 30)`, Postgres-Wait-Loop, Z.1060, unberuehrte Zeile),
   identisch zur Baseline: kein neuer Befund.
4. `shellcheck -S warning tests/t-b2-007-drift-hash.sh` -> keine Befunde
   (Exit 0).
5. `./tests/t-b2-007-drift-hash.sh` -> Exit 0, 37x PASS,
   `T-B2-007: ALLE PRUEFUNGEN BESTANDEN`.
6. Regressionslauf aller bisherigen Artefakte -> je Exit 0:
   `./tests/t-071b-headercheck.sh` (B2-001),
   `./tests/t-090-b2-002-tls-gate.sh` (B2-002),
   `./tests/t-b2-003-hex-migration.sh` (B2-003),
   `./tests/t-b2-006-reset-precheck.sh` (B2-006).

Tool-Versionen: bash 5.3.15, ShellCheck 0.11.0, Git-Basis `7373bd2`.

# Results

- Abbruch nach Schritt 2 -> Heilungslauf ohne Drift-WARN fuer
  setup-eigene Residuen (belegt ueber die echten Funktionen).
- Echte Hand-Drift -> WARN bleibt (belegt).
- Residualpfad Kill-zwischen-Write-und-Hash -> genau einmal Fehl-WARN,
  danach gruener Lauf heilt ohne Datenverlust (belegt).
- Hashstore 600, atomar, ohne Dubletten, Abdeckung 15/15 (belegt).
- Regressionsstand: B2-001/B2-002/B2-003/B2-006-Artefakte weiterhin Exit 0.

# Remaining Risk

- VM-Pflicht offen (Plan Z.412-417): T-026 mit echtem Setup-Lauf
  (Abbruch nach Schritt 2, Hand-Drift, Kill-Pfad) auf Test-VM.
- Der dokumentierte Restpfad (Kill genau zwischen `tee` und
  `remember_hash`) bleibt bestehen – einmalige Fehl-WARN, keine
  Datenkorruption, naechster gruener Lauf heilt (Plan Z.401-404).

# Files Changed

- `setup-coder.sh` (M, 28/10, nur B2-007-Zonen)
- `tests/t-b2-007-drift-hash.sh` (neu, ausfuehrbar, 37 Checks)
- `ai-review/IMPLEMENTATION-REPORT-v3-B2-007.md` (neu, diese Datei)

# Related Finding

B2-007 (C-011)
