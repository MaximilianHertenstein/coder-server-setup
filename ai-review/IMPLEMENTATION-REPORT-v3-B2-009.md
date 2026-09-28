# IMPLEMENTATION-REPORT-v3-B2-009

Stand: 2026-09-28. Branch: `ai/implementation-v3` (Basis-Commit `b29c2a4`).
Umfang: ausschliesslich B2-009 (`RESTORE.md` Pfad A ohne `ON_ERROR_STOP`,
Verifikation nur Liveness).

Grundlagen: `ai-review/PLAN-v3.md` (B2-009, Z.462–502), DoD/Doku-Gate
Z.1059–1063 (`psql -v ON_ERROR_STOP=1` + Datensicht-Verifikation),
`ai-review/PLAN-v3-FINAL-CHECK.md`.

## Aktuelles Verhalten (vor dem Fix)

`RESTORE.md` Pfad A Schritt 4 (alt, Z.32–34):

```bash
zcat coder_<TS>.sql.gz | sudo docker exec -i coder-postgres psql -U coder -d coder
```

Ohne `-v ON_ERROR_STOP=1`. Verifikation (alt, Z.38–40) war ausschliesslich
`up -d` + `/healthz` 200 + Dashboard-Login – also Liveness, kein Datenbeweis.

## Problem (LIKELY, Code-Fakt CONFIRMED)

`psql` liest den Dump im Skriptmodus von stdin. Ohne `ON_ERROR_STOP` springt
`psql` bei einem SQL-Fehler (fehlerhafte `CREATE TABLE`-Zeile, fehlende
Extension, Versionsdrift) zur nächsten Anweisung weiter und quittiert am Ende
der Datei; die Runbook-Kette und die Liveness-Verifikation bleiben davon
unberührt. Ergebnis: ein auf lückenhaftem Schema restaurierter Stack, der
wie ein erfolgreicher Restore aussieht – RTO-Zahl für einen kaputten Restore.

Stelle: `RESTORE.md` Z.32–34 (Import), Z.38–40 (Verifikation).

## Umgesetzte Aenderung (Plan Z.477–491)

1. **Pfad A Schritt 4** (Importzeile): `-v ON_ERROR_STOP=1` als `psql`-Option
   **vor** `-U`. Die `dropdb`/`createdb`-Vorkette und die `&&`-Verkettung
   bleiben unverändert. Zusätzlich dokumentiert: **STOPP bei Exit ≠ 0**,
   Schritt 5 nicht ausführen, kein `up -d`, kein grüner Restore; für
   automatisierte Kette `set -o pipefail`, weil ein fehlschlagendes `zcat`
   sonst still durchläuft und `psql` einen leeren Stdin-Eingang als Erfolg
   quittiert.
2. **Pfad A Schritt 5** ist jetzt zweistufig:
   - **Datenprobe (hart):**
     `psql -v ON_ERROR_STOP=1 -U coder -d coder -tAc "SELECT count(*) FROM restore_probe WHERE marker='RTO-PROBE-AAAA-MM-JJ'"`
     muss `1` liefern. `0`, `>1` oder psql-Fehler (Relation fehlt) ⇒
     **Restore NICHT anerkennen**, rot bleiben.
   - **Liveness** (`/healthz` 200, `SELECT 1`) und **Inhalt**
     (Dashboard-Login zeigt wiederhergestellte Bestandsdaten) sind
     ausdrücklich als *keine* alleinige Bestätigung markiert.
3. **Voraussetzung 4 (neu): Restore-Sonde vor dem zu probenden Backup** –
   `restore_probe(id serial primary key, marker text)` anlegen,
   `DELETE` + `INSERT` mit `marker='RTO-PROBE-AAAA-MM-JJ'` (genau eine Zeile
   je Datum, doppelte Ausführung desselben Tages überschreibt), erst danach
   das Backup anstoßen. Auch diese psql-Aufrufe laufen mit `ON_ERROR_STOP=1`.
4. **RTO-Tabelle** bekam die Spalte `Datenprobe = 1`, damit der Datennachweis
   mit protokolliert wird; Pfad A Schritt 6 nennt ihn.
5. Kopf-Datum auf 2026-09-28.

## Abweichungen vom Planwortlaut

1. **Sonde als dokumentierte Voraussetzung statt automatisiert in
   `backup.sh`.** Der Plan nennt die Sonde unter „Verifikation nach Restore"
   mit „vor Backup Testdatensatz anlegen" und legt die Stelle auf
   `RESTORE.md` Z.32–34 / Z.38–40 fest. Deshalb steht der Anlegeschritt in
   `RESTORE.md` Voraussetzung 4 und `backup.sh` blieb unverändert – kein
   neuer Schreibzugriff auf die Produktions-DB in jedem Tageslauf, kein
   Änderungsbereich ausserhalb der benannten Stelle. Konsequenz (fail-safe):
   Backups, die vor Einführung der Sonde entstanden sind, liefern in der
   Datenprobe `0` bzw. einen Fehlertext und werden nach B2-009 **nicht** als
   Erfolg anerkannt. Für den ersten T-080-Lauf ist daher zwingend erst
   Sonde anlegen, dann Backup erzeugen – genau die Reihenfolge, die jetzt
   in Voraussetzung 4 steht.
2. **`ON_ERROR_STOP=1` zusätzlich auf die Datenprobe.** Der Plan nennt das
   Flag nur für den Import. Ohne Flag würde eine fehlende Relation
   `restore_probe` als Fehlermeldung ohne Ausgabewert erscheinen; mit Flag
   bricht auch die Prüfung hart ab. Gleiche Fehlerklasse, gleicher Fix, ein
   Token.
3. **„Dashboard-Login zeigt Test-Datensatz"** ist als „Dashboard-Login zeigt
   die wiederhergestellten Bestandsdaten aus dem Dump (Nutzer/Workspaces),
   nicht nur HTTP 200" formuliert: die `restore_probe`-Zeile selbst rendert
   das Coder-Dashboard nicht. Der harte Gate bleibt die Zählung `1`.
4. **`set -o pipefail`-Hinweis** ergänzt (ohne ihn ist die `&&`-Kette gegen
   einen fehlschlagenden `zcat` blind). Der Plan fordert den Abbruch „hart";
   in einem manuellen Runbook ist der Abbruch deshalb als STOPP-Anweisung
   plus Exit-Code-Signal dokumentiert, nicht als Skriptzweig.

## Moegliche Regressionen (geprueft, keine offen)

- Pfad B (nur Dump, `.env` verloren) verweist weiter auf Pfad A Schritt 4
  und damit automatisch auf Flag + Datenprobe (Z.63 und Z.85 geprüft).
- `dropdb`/`createdb`-Vorkette, `&&`-Kette und `pg_restore`-Alternative
  bleiben unverändert erhalten.
- Legitimer Restore mit SQL-Warnungen (nicht Fehlern) wird von
  `ON_ERROR_STOP` nicht betroffen: es stoppt auf Fehlern, nicht auf
  Warnungen; die Verifikation ist ohnehin bewusst als Datensicht (Zählung +
  Login) und nicht als Log-String-Match gebaut – genau die vom Plan
  genannte Regressionsgefahr „zu strikte Verifikation".
- Liveness-Prüfung und RTO-Messung bleiben erhalten, nur ergänzt.
- Bestehende Backups ohne Sonde melden künftig rot (bewusst, siehe
  Abweichung 1).

## Testdefinition

`tests/t-b2-009-restore-on-error-stop.sh` (neu, ausführbar, nur `/tmp`, kein
Root, keine Produktion) – STATIC + UNIT-LIKE, **25 Checks**:

**(1) STATIC gegen `RESTORE.md` (8):** Importzeile enthält
`psql -v ON_ERROR_STOP=1 -U coder -d coder`, enthält *nicht* mehr die
flagfreie Form; Flag steht vor `-U` (Position innerhalb des psql-Teils
verglichen, damit `dropdb -U` nicht fälschlich als Treffer zählt);
`dropdb --if-exists`, `createdb` und `&&`-Kette erhalten; STOPP-Antwort vor
Schritt 5/`up -d` dokumentiert; `set -o pipefail`-Hinweis vorhanden.

**(2) STATIC Datenprobe (11):** Sonde wird angelegt (exakte Tabellendefinition),
idempotent je Datum, Anlegezeile steht **vor** `## Pfad A` (Voraussetzung,
nicht erst im Restore), Zählung nach Restore, Ergebnis muss `1` sein,
`0`/`>1`/Fehler ⇒ „Restore NICHT anerkennen"/rot, Zählung ebenfalls mit
`ON_ERROR_STOP=1`, Liveness von Datenprobe getrennt und als alleinig
ungenügend markiert, alte Liveness-only-Formulierung entfernt, Pfad-B-Verweis
erhalten, RTO-Tabelle mit Spalte `Datenprobe = 1`.

**(3) UNIT-LIKE – der dokumentierte Befehl selbst (6):** Der Importbefehl
wird mit `awk` als logische Zeile (inkl. `\`-Fortsetzung) aus `RESTORE.md`
extrahiert, `<TS>` substituiert und mit Fake-`zcat`, Fake-`sudo`, Fake-`docker`,
Fake-`dropdb`/`createdb` und Fake-`psql` ausgeführt (Fake-`psql` protokolliert
seine argv und liest stdin):

- A: Dump in Ordnung → Exit 0, argv enthält `ON_ERROR_STOP=1` **vor** `-U`,
  Pipeline hat tatsächlich `zcat | docker exec -i psql` geliefert (stdin
  gelesen, zcat aufgerufen).
- B: defekter Dump (`BROKEN_DUMP=1`) → Exit ≠ 0 (Abbruch vor Schritt 5).
- C: Negativkontrolle – dieselbe Pipeline **ohne** das Flag → Exit 0.
  Der Test schlägt also fehl, wenn das Flag aus der Runbook-Zeile verschwindet
  oder seine Position sich verschiebt.

Nicht Teil dieses Tests (Plan Z.501–502, Kategorie **VM + RECOVERY**):
T-080 mit echtem `psql` und Wegwerf-Postgres – defekter Dump muss rot
abbrechen, Voll-Restore muss `count = 1` liefern. Nie auf Produktion.

# Changed

1. `RESTORE.md` (M, 43/8): Kopf-Datum, neue Voraussetzung 4 (Restore-Sonde),
   Pfad A Schritt 4 mit `-v ON_ERROR_STOP=1` + STOPP-Regel + pipefail-Hinweis,
   Pfad A Schritt 5 zweistufig (Datenprobe hart, Liveness und Inhalt
   getrennt), Pfad A Schritt 6 nennt die Datenprobe, RTO-Tabelle mit neuer
   Spalte.
2. `tests/t-b2-009-restore-on-error-stop.sh` (neu, ausführbar, 25 Checks).
3. `ai-review/IMPLEMENTATION-REPORT-v3-B2-009.md` (neu, diese Datei).

Diff-Kontrolle: `git diff --numstat RESTORE.md` = 43/8, ausschliesslich die
B2-009-Zonen. `setup-coder.sh`, `reset-coder.sh`, `backup.sh`-Generierung und
alle früheren Fixes unverändert.

# Tests Actually Run

Ausgeführt am 2026-09-28 auf dem Arbeitsrechner (kein Produktionsserver),
Basis-Commit `b29c2a4` + Arbeitskopie:

1. `bash -n setup-coder.sh` → ok (PASS, Exit 0).
2. `bash -n tests/t-b2-009-restore-on-error-stop.sh` → ok (PASS, Exit 0).
3. `shellcheck -S warning setup-coder.sh` → einziger Befund SC2034
   (`for i in $(seq 1 30)`, Postgres-Wait-Loop, Z.1247, unberührte Zeile),
   identisch zur Baseline: kein neuer Befund.
4. `shellcheck -S warning tests/*.sh` → keine Befunde (Exit 0).
5. `./tests/t-b2-009-restore-on-error-stop.sh` → Exit 0, **25x PASS**,
   `T-B2-009: ALLE PRUEFUNGEN BESTANDEN`.
6. Gesamt-Testmatrix, je Exit 0:

   | Test | Ergebnis |
   |---|---|
   | `tests/t-071b-headercheck.sh` (B2-001) | T-071b: ALLE PRUEFUNGEN BESTANDEN |
   | `tests/t-090-b2-002-tls-gate.sh` (B2-002) | T-090/B2-002: ALLE PRUEFUNGEN BESTANDEN |
   | `tests/t-b2-003-hex-migration.sh` (B2-003) | B2-003: ALLE PRUEFUNGEN BESTANDEN |
   | `tests/t-b2-004-ufw-downgrade.sh` (B2-004) | T-B2-004: ALLE PRUEFUNGEN BESTANDEN |
   | `tests/t-b2-006-reset-precheck.sh` (B2-006) | T-B2-006: ALLE PRUEFUNGEN BESTANDEN |
   | `tests/t-b2-007-drift-hash.sh` (B2-007) | T-B2-007: ALLE PRUEFUNGEN BESTANDEN |
   | `tests/t-b2-008-port-preflight.sh` (B2-008) | T-B2-008: ALLE PRUEFUNGEN BESTANDEN |
   | `tests/t-b2-009-restore-on-error-stop.sh` (B2-009) | T-B2-009: ALLE PRUEFUNGEN BESTANDEN |

7. `docker compose config -q`: **nicht ausführbar** – das Repo enthält keine
   Compose-Datei und kein Compose-Template (die Datei entsteht erst durch
   `setup-coder.sh` auf dem Zielrechner). Nicht als Test gewertet.

Tool-Versionen: bash 5.3.15, ShellCheck 0.11.0, Docker 29.7.2-ce /
Compose 5.5.1 (Client vorhanden, kein laufender Container), **kein `psql`
installiert**, Git-Basis `b29c2a4`.

# Results

- Pfad A bricht bei SQL-Fehler im Dump mit Exit ≠ 0 ab und dokumentiert den
  Stopp vor `up -d` (belegt: UNIT-LIKE B, extrahierter Originalbefehl).
- Dieselbe Pipeline ohne Flag quittiert denselben defekten Dump mit Exit 0
  (belegt: UNIT-LIKE C, Negativkontrolle).
- Flag sitzt in der argv von `psql` an der geforderten Position vor `-U`
  (belegt: UNIT-LIKE A).
- Verifikation verlangt Datenprobe `count = 1`, meldet `0`/`>1`/Fehler rot
  und trennt das von Liveness; die alte Liveness-only-Formulierung ist
  verschwunden (belegt: STATIC 2, 11 Checks).
- Regressionsstand: alle acht bisherigen Artefakte weiterhin Exit 0.

# Remaining Risk

- **`psql` ist lokal nicht installiert** (geprüft). Das Abbruchverhalten von
  `ON_ERROR_STOP=1` und das Weiterlaufen ohne Flag sind in der UNIT-LIKE
  damit an einem Fake-`psql` belegt, der die dokumentierte psql-Vertragslage
  modelliert (Skriptmodus von stdin: Fehler überspringen und ohne Flag
  normal beenden; mit Flag hart mit Exit ≠ 0 abbrechen). Der **echte** Beleg
  bleibt T-080 mit echtem Postgres auf einer Test-VM (Plan-Z.501–502,
  Kategorie VM + RECOVERY). Als Fakt gilt: Flag ist in der Runbook-Zeile
  vorhanden und richtig positioniert; als Annahme gilt die exakte
  Exit-Code-Nummerierung der installierten psql-Version.
- **Alte Backups ohne Sonde** melden nach diesem Fix rot. Wer sie einspielt,
  braucht zuerst Voraussetzung 4 (Sonde anlegen) und ein Backup, das sie
  enthält – sonst ist keine Abnahme möglich. Bewusste Fail-safe-Entscheidung,
  aber ein operativer Schritt, der im ersten Restore-Drill leicht
  vergessen wird.
- RTO bleibt weiterhin **unbekannt** (Zeile 4: „Noch NICHT geprobt"); die
  Wiederholungspflicht-Tabelle hat weiterhin `_offen_`.

# Files Changed

- `RESTORE.md` (M, 43/8, nur B2-009-Zonen)
- `tests/t-b2-009-restore-on-error-stop.sh` (neu, ausführbar, 25 Checks)
- `ai-review/IMPLEMENTATION-REPORT-v3-B2-009.md` (neu, diese Datei)

# Related Finding

B2-009 (RESTORE Pfad A ohne `ON_ERROR_STOP`: stiller Teil-Restore möglich)
