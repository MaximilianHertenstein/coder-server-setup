# IMPLEMENTATION-REPORT-v3-B2-003

Stand: 2026-09-28. Branch: `ai/implementation-v3` (Basis-Commit `1b040e7`).
Umfang: ausschliesslich B2-003 (Hex-Gate-Pingpong / Legacy-.env-Migration).

Grundlagen: `ai-review/PLAN-v3.md` (B2-003, Z.167-249),
`ai-review/PLAN-v3-FINAL-CHECK.md` (PV-002), `ai-review/FINAL-BREAKER-v2.md`
(B2-003), `ai-review/07-complexity.md`.

## Aktuelles Verhalten (vor dem Fix)

Zwei Stellen in `setup-coder.sh`:

- Setup-Gate (Z.248-253): Nicht-Hex in `/opt/coder/.env` -> fail-closed,
  Reparaturtext verweist auf `sudo /opt/coder/reset-passwords.sh`.
- Reset-Gate (eingebettetes `reset-passwords.sh`, Z.1210-1214): Nicht-Hex in
  `.env` -> fail-closed, Reparaturtext verweist auf sich selbst.

Zusaetzlich wurde das Alt-Passwort in unquotiertem Heredoc interpoliert
(`<<INNER_EOF` mit `"${OLD_PG_PW}"`).

## Problem (CONFIRMED)

Beide Gates verweigern denselben Zustand, der Reparaturweg ist ein
Zirkularschluss: Setup sagt "lauf Reset", Reset sagt "lass es sein" (bzw.
verweist auf Reset). Ein Alt-System mit `Legacy$Pass!23` kann weder
Setup-Re-Run noch Rotation durchlaufen; ein dokumentierter Ausweg existiert
nicht. Zweite Kante: im unquotierten Heredoc wird Legacy als Shell-Code
ausgewertet (`$Pass` weg, Backtick ausgefuehrt, eingebrochenes Quote zerlegt
die `export`-/`psql`-Zeile) - das alte Passwort kommt nie als reiner
Env-Wert an.

## Umgesetzte Aenderung (Variante (a), wörtlich nach PLAN-v3 Z.184-232)

Genau EINE Strategie, keine Wahl offen gelassen:

1. Setup-Gate bleibt fail-closed fuer Nicht-Hex, Ersatztext wörtlich:
   `Fehler: /opt/coder/.env enthält Nicht-Hex-Passwörter.` +
   `Reparatur: erst sudo /opt/coder/reset-passwords.sh laufen lassen
   (migriert Legacy lesend nach Hex), danach Setup erneut.`
   Kein Pingpong, weil Reset nach diesem Fix Legacy lesend akzeptiert.
2. Reset-Gate aufgespalten in ALT lesend vs. NEU Hex:
   - unvollstaendige `.env` -> weiterhin Exit 1, Text verweist auf
     `setup-coder.sh meldet wie`, NIEMALS auf `reset-passwords.sh` selbst;
   - ALT (`OLD_PG_PW` aus `.env`) darf Legacy sein, kein Fehler;
   - NEU -> Exit 1, geprueft VOR DB/Grafana/.env (siehe 4).
3. Newline/NUL im `.env`-wert -> harter Exit 1 mit dem wörtlichen Text
   `Fehler: .env-Wert enthält Newline/NUL – wird nicht still getrimmt.`
   Reparaturtext wörtlich. Kein Trimmen, kein Neuwuerfeln (P-011).
   Erkennung: NUL-Byte-Zaehlung (`tr -d -c '\000' | wc -c`) ODER jede Zeile,
   die nicht `KEY=`/`#`/leer ist (Fortsetzungszeile eines Hand-Edits).
   Beide Gates (Setup + Reset) identisch.
4. NEU-Hex-Assert (`case ... *[!0-9a-f]*` -> Exit 1) vor der ersten
   Aenderung an DB/Grafana/.env.
5. ALT-Auth (Postgres): Heredoc QUOTIERT (`<<'INNER_EOF'` gegen aussen
   `<<'EOF'`), beide Passwoerter ausschliesslich als Env-Wert ueber STDIN
   (`printf '%s\n' ALT NEU | docker exec -i ... sh -c 'read -rs; export
   PGPASSWORD'`), nie in SQL/URL interpoliert, nie als `docker exec`-Argument.
   `ALTER USER` benutzt nur das Hex-NEU aus der Container-Variable.
   Kein `docker exec -e PGPASSWORD` (kein `inspect`-Leak, 02/F-015).
6. Verifikation (Z.1271) und Grafana-Teil (Z.1281) bleiben unquotiert
   (ausschliesslich Hex-NEU aus `openssl rand -hex`), ebenfalls ohne
   `docker exec -e`.

## Abweichung vom Planwortlaut (1 Stelle, gleiche Secret-Architektur)

Plan Z.204 nennt `sh -s`; das ist mit Daten auf stdin nicht ausfuehrbar - die
Datenzeilen werden als Kommandos geparst. Lokal in `postgres:15-alpine`
(busybox ash) gemessen: `printf 'A\nB\n' | docker exec -i ... sh -s` ->
`sh: A: not found`, rc=127; ein Heredoc als stdin laesst die Daten gar nicht
erst ankommen. Umgesetzt: `sh -c "$(cat <<'INNER_EOF' ... )"`. Geaendert ist
nur der Transport des (geheimnisfreien) Skripttexts; die im Plan geforderte
Secret-Architektur bleibt exakt: STDIN als einziger Kanal fuer Geheimnisse,
kein argv, kein `-e`, quotierter Heredoc, ALT nie in SQL/URL. Im Code
kommentiert (setup-coder.sh, ALT-Heredoc-Bloeck).

Ebenfalls lokal belegt: `read -rs` funktioniert in busybox ash (vorher im
Test als Annahme notiert, jetzt Korrektur der Kommentare auf Basis Messung).

## Moegliche Regressionen (geprueft, keine offen)

- Legacy-Wert mit fuehrendem `-` wird zur Option: ausgeschlossen -
  Verarbeitung nur via `printf '%s\n'`, `grep '^POSTGRES_PASSWORD='` (Muster
  beginnt mit `^`, nicht `-`), `cut -d= -f2-`, Leak-Greps mit `-F --`.
- `!` als History-Expansion: greift in nicht-interaktiven Skripten nicht
  (Plan Z.217, dokumentiert).
- Fail-closed verloren: nein - Setup-Gate prueft weiter Hex, Reset prueft
  Unvollstaendigkeit + NEU-Hex + Newline/NUL.
- NEU-Hex-Assert tot? `openssl rand -hex` liefert immer Hex; die Pruefung ist
  die harte Grenze fuer kuenftige Zeichensatz-Aenderungen (kommentiert).
- Quoting-Bruch durch ALT: ausgeschlossen - Heredoc quotiert, Wert kommt per
  STDIN in `read -rs`, nie in die SQL-Zeile.
- Re-Run nach Migration: ALT ist dann Hex, identischer Pfad (im Live-Beleg
  zweite Rotation gruen).
- `grep -qvE`-Guard trifft legitime `.env`: Setup schreibt ausschliesslich
  `KEY=value`/`#`/leer; Regex ist nicht rechtsverankert, also auch
  `KEY=value # Kommentar` und `KEY="x"` zulaessig.

## Testdefinition

`tests/t-b2-003-hex-migration.sh` (neu, ausfuehrbar, nur /tmp, kein Docker,
keine Produktion) - STATIC + UNIT-LIKE, 64 Checks:

- Setup-Gate-Ersatztext wörtlich vorhanden, alter Text entfernt;
- Reset-Reparatur ohne Selbstverweis, Unvollstaendig-Text mit Setup-Verweis;
- Heredoc-Quoting-Zaehlung (1x quotiert = ALT-Auth, 2x unquotiert =
  Verify/Grafana, Hex-only) gegen den echten eingebetteten Block;
- kein `docker exec -e` im gesamten Setup (inkl. Kommentaren);
- STDIN-Muster + NEU-Hex-Assert + Newline/NUL-Guard wörtlich vorhanden;
- Verhaltensfixture mit den Werten `Legacy$Pass!23`, `a b`, `a"b`, `a'b`,
  `a$b`, `` a`b ``, `-lead-dash9`: Setup-Gate ROT, Reset-Vollstaendigkeit
  OK, Guard still, `cut`-Extraktion verlustfrei, `printf`/`read`-Roundtrip
  verlustfrei, Leak-Grep-Mechanik mit `-F --`;
- migrierte Hex-.env: beide Gates GRUEN (genau ein gruener Weg);
- Negativfall Newline im Wert -> Guard ROT (kein stilles Trimmen);
- Negativfall NUL im Wert -> Guard ROT;
- Ausfuehrung der PRODUKTIONSStatements (aus dem Skript extrahiert, kein
  Test-Drift) mit gestubtem `docker`: argv-Log darf weder Vollwert noch
  8-Zeichen-Praefix enthalten, STDIN muss ALT+NEU vollstaendig tragen.

Fixture-Hinweis: der Plan nennt `-führend`; der Test verwendet
`-lead-dash9` (gleicher Fall, fuehrendes `-`). UTF-8 ist laut Plan Z.219-220
nicht garantiert und wird als ungetestet abgewiesen - eine UTF-8-Fixture
wuerde das Gegenteil behaupten.

Nicht Teil dieses Tests (Plan Z.241-249, Kategorie VM): echte DB mit
`ALTER USER`, `ps aux | grep -F` + `docker inspect ... | grep -F` waehrend
der Rotation. Laut Plan Phase B/C, hier nicht behauptet.

# Changed

1. `setup-coder.sh` (Setup-Gate, +14/-2): Newline/NUL-Guard, Ersatztext
   wörtlich, Kommentar zur ehrlichen Reset-Verweisung.
2. `setup-coder.sh` (Reset-Gate, +5/-5): Hex-Pruefung der gesamten `.env`
   entfernt (ALT darf Legacy), Newline/NUL-Guard, Kommentar zum
   Migrationspfad.
3. `setup-coder.sh` (NEU-Hex-Assert, +10): `case`-Fail-closed vor der ersten
   Aenderung.
4. `setup-coder.sh` (ALT-Auth, +23/-8): quotierter Heredoc + STDIN-Transport
   beider Passwoerter, Dokumentation der `sh -c`-Messung.
5. `tests/t-b2-003-hex-migration.sh` (neu): T-B2-003-Harness (s. o.).
6. `ai-review/IMPLEMENTATION-REPORT-v3-B2-003.md` (neu, diese Datei).

Diff-Kontrolle: `git diff --numstat setup-coder.sh` = 62/20, 6 Hunks,
alle in den B2-003-Zonen (Setup-Gate Z.245-262, Reset-Gate Z.1210-1234,
NEU-Hex Z.1275, ALT-Heredoc Z.1288-1312). Keine kosmetischen oder
ungewollten Aenderungen, keine neuen Abstraktionen, keine Abhaengigkeiten,
kein `lib.sh`, kein Helper ueber Heredoc-Grenzen (PLAN-v3-FINAL-CHECK
"Neue Widersprueche", Punkt 1).

# Tests Actually Run

Ausgefuehrt am 2026-09-28 auf dem Arbeitsrechner (kein Produktionsserver),
Basis-Commit `1b040e7` + Arbeitskopie:

1. `bash -n setup-coder.sh` -> ok (PASS, Exit 0).
2. `bash -n tests/t-b2-003-hex-migration.sh` -> ok (PASS, Exit 0).
3. Extrahiertes `reset-passwords.sh` (161 Zeilen): `bash -n` -> ok (PASS).
4. `shellcheck -S warning setup-coder.sh` -> einziger Befund SC2034
   (`for i in $(seq 1 30)`, Postgres-Wait-Loop, unberuehrte Zeile).
   Baseline-Vergleich (`git show HEAD:setup-coder.sh`, gleicher Befund,
   Zeile 1032 -> 1043 nur Verschiebung): kein neuer Befund.
5. `shellcheck -S warning tests/t-b2-003-hex-migration.sh` -> keine Befunde
   (Exit 0).
6. `shellcheck -S warning` auf extrahiertem `reset-passwords.sh` -> einzig
   SC2154 (`rc` in der F-010-Trap-Zeile), ebenfalls im Baseline-Extrakt
   vorhanden (Zeile 56 -> 61): kein neuer Befund.
7. `./tests/t-b2-003-hex-migration.sh` -> Exit 0, 64x PASS,
   `B2-003: ALLE PRUEFUNGEN BESTANDEN`.
8. `./tests/t-071b-headercheck.sh` -> Exit 0 (B2-001 nicht rueckgaengig).
9. `./tests/t-090-b2-002-tls-gate.sh` -> Exit 0 (B2-002 nicht rueckgaengig).

Tool-Versionen: bash 5.3.15, ShellCheck 0.11.0, Docker 29.7.2-ce,
Image `postgres:15-alpine` (sha256:319d040b5d68...), Git-Basis `1b040e7`.

## Zusatz-Beleg: Live-Probe gegen echte DB (lokal, Throwaway)

Nicht committet (gehoert laut Plan in die VM-Phase), aber ausgefuehrt, weil
die zentrale Behauptung sonst nur auf Regex-Behauptung beruht: zwei
weggeworfene Container in eigener User-Definition-Netzwerk, `docker rm -f`
im Trap, keine Volumes, keine Produktion. Die Statements wurden mit demselben
`awk`-Extrakt wie im Test aus `setup-coder.sh` genommen (nur Containername
`coder-postgres` -> `b2003-pg`), `docker` ueberschrieben, um argv mitzuschreiben:

1. `postgres:15-alpine` mit Init-Passwort `Legacy$Pass!23`,
   `rolpassword` = `SCRAM-SHA-256$...` (OK).
2. ALT-Statement mit `OLD_PG_PW='Legacy$Pass!23'` -> `ALTER ROLE`, rc=0 (OK).
3. argv-Log: weder Vollwert noch 8-Zeichen-Praefix von ALT noch NEU
   (OK - kein ps-/inspect-Leak ueber die Kommandozeile).
4. Produktions-Verifikationsstatement -> rc=0 (OK).
5. `rolpassword` geaendert, scram-Verifier fuer NEU vorhanden (OK).
6. Echtes scram-Login ueber TCP von einem zweiten Container
   (`host all all all scram-sha-256`): NEU -> `111`, ALT -> abgelehnt (OK).
7. `docker inspect` enthaelt NEU nicht; ALT nur als Init-Env des
   Throwaway-Containers (`docker run -e`), nicht durch B2-003.
8. Re-Run: ALT ist jetzt Hex, zweite Rotation rc=0, Login mit NEU2 -> `111`
   (OK - Migrationspfad fuehrt zu zwei gruenen Gates, kein Pingpong).

Zusaetzlich gemessen (kommentiert im Code): `sh -s` mit Daten auf stdin ->
rc=127 in busybox ash; `sh -c` uebernimmt die Daten korrekt.

Nicht ausgefuehrt (ausserhalb B2-003-Umfang / VM-Pflicht):
`ps aux | grep -F` und `docker inspect ... | grep -F` waehrend der echten
Rotation, Newline-Abweisung auf der VM, Setup-Re-Run der VM gegen die
produktive Compose-Stack-Topologie, Grafana-Teil gegen echten
`grafana/grafana`-Container (lokal kein Image, Statement ist
Hex-only-Stdin und identisch im Muster zum Verify-Statement). Kein
"bestanden" dafuer behauptet.

# Results

- Legacy-`.env` (Vollvorrat Sonderzeichen) -> genau ein definierter Weg:
  `reset-passwords.sh` liest ALT lesend, wuerfelt Hex, schreibt `.env`
  atomar; Setup-Re-Run und Reset-Re-Run sind danach gruen (ein gruener Weg,
  kein Reset->Reset-Verweis, Endlosschleife ausgeschlossen).
- Setup-Gate bleibt fuer Nicht-Hex fail-closed (Test: 7x ROT).
- Fail-closed bleibt fuer unvollstaendige `.env` (Text -> Setup-Reparatur)
  und fuer nicht-Hex NEU (vor der ersten Aenderung).
- Newline/NUL -> Exit 1 mit wörtlichem Text, kein stilles Trimmen, kein
  stilles Neuwuerfeln.
- ALT+NEU ausschliesslich ueber STDIN; weder Vollwert noch Praefix in der
  docker-argv (lokal und gegen echte DB belegt).
- Alter USER wird mit Legacy-ALT authentifiziert und trifft
  `ALTER USER ... PASSWORD '<Hex>'`; scram-Verifier fuer NEU gueltig,
  ALT danach abgelehnt (echte DB, TCP).
- Kein `docker exec -e` im Skript; kein neuer `inspect`-Eintrag mit NEU.
- Regressionsstand: `t-071b` und `t-090` weiterhin Exit 0; ShellCheck-Befunde
  identisch zur Baseline.

# Remaining Risk

- VM-Pflicht offen (Plan Phase B/C): Hex-Migrations-Test mit echter DB +
  `ALTER USER` + `ps aux`/`docker inspect`-Grep waehrend der Rotation,
  inkl. Newline-Negativfall. Stop-Regel: kein Production-Gedanke davor.
- Grafana-Statement nicht gegen einen echten Grafana-Container geprueft
  (lokal kein Image); Muster identisch zum geprueften Verify-Statement,
  Wert ist Hex-only.
- Vorhandene, nicht in B2-003 geaenderte Kante: die
  "Verifikation mit dem NEUEN Passwort" laeuft ueber den lokalen Socket,
  der in `postgres:15-alpine` auf `trust` steht (`local all all trust`) -
  sie beweist Erreichbarkeit und Existenz des Users, aber kein
  Passwort. Preisgabe erst bei echtem scram-Login ueber TCP (VM-Test).
  Kein Rueckgang durch B2-003, Aenderung ausserhalb des freigegebenen
  Umfangs (Plan Z.210-214 laesst Z.1271 unveraendert).
- UTF-8-Werte in `.env` bleiben wie geplant ungetestet/ungarantiert.
- Offene B2-Fixes (B2-006, B2-007, B2-004, B2-008, B2-009), Offsite/RTO
  (B-008) und D-Entscheidungen sind ausserhalb dieses Scopes.

# Files Changed

- `setup-coder.sh` (M, +62/-20, 6 Hunks, nur B2-003-Zonen)
- `tests/t-b2-003-hex-migration.sh` (neu, ausfuehrbar, 64 Checks)
- `ai-review/IMPLEMENTATION-REPORT-v3-B2-003.md` (neu, diese Datei)

# Related Finding

B2-003
