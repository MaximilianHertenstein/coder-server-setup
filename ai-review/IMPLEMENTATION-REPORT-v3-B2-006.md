# IMPLEMENTATION-REPORT-v3-B2-006

Stand: 2026-09-28. Branch: `ai/implementation-v3` (Basis-Commit `2eaf95a`).
Umfang: ausschliesslich B2-006 (Reset-Pre-Check hinter `down`).

Grundlagen: `ai-review/PLAN-v3.md` (B2-006, Z.344-374),
`ai-review/PLAN-v3-FINAL-CHECK.md`, `ai-review/FINAL-BREAKER-v2.md` (B2-006).

## Aktuelles Verhalten (vor dem Fix)

Eingebettetes `reset-coder.sh` in `setup-coder.sh`:

1. Inventar (lesend)
2. Backup + Bestaetigung
3. `docker compose down --remove-orphans`
4. Volume-Ermittlung (Label-Filter, Allowlist, Leer-Guard)
5. Belegungs-Pre-Check (`docker ps -aq --filter volume=`)
6. `docker volume rm`, dann `rm -f .env`

## Problem (CONFIRMED)

Bei Treffer in Schritt 5 (fremder Workspace haelt ein zu loeschendes Volume)
war der Stack bereits in Schritt 3 halb zerlegt: Container weg, Netz weg,
Cron-Backup im Fenster rot. Daten und `.env` waren intakt, aber die
Wiederherstellung lief nur noch ueber den dokumentierten Einzeiler
(`docker compose up -d`). Versprochen war "Abbruch VOR Zerstoerung".

## Umgesetzte Aenderung (PLAN-v3 Z.358-374, Reihenfolge lesender Checks)

1. Volume-Ermittlung + Leer-Guard + Belegungs-Pre-Check ziehen VOR
   `docker compose down`. `down` laeuft erst nach gruenem Pre-Check.
2. Beide Schritte sind lesend – keine neue Mechanik, nur Ortswechsel.
3. Meldungen wahrheitsgezaeh: "nichts angefasst" statt "Stack ist gestoppt"
   bzw. "nichts geloescht, .env intakt (up -d stellt wieder her)".
4. Leer-Guard, Allowlist, `--force`-Zweitphrase, TTY-Guard,
   Zertifikats-/Backup-Schutz unveraendert (per Test-Token abgesichert).

## Abweichungen vom Planwortlaut (2 Stellen, gleiche Funktion)

1. **Projekt-Container-Ausschluss (funktional zwingend).** Der Plan
   schreibt den Check `docker ps -aq --filter volume=` wörtlich vor und
   notiert, die Containerliste vor `down` sehe "ggf. anders aus ... gewollt
   (konservativ)". Gemessen (Docker 29.7.2-ce, lokale Throwaway-Container):
   `docker ps -a --filter volume=<name>` findet auch laufende
   Projekt-Container. Wuerde der Check unabgeaendert vor `down` greifen,
   hielte `coder-postgres` `postgres_data` und JEDER Reset-Run auf
   laufendem Stack braeche ab – T-100 (Reset durchfuehren) waere tot.
   Umgesetzt: Projekt-Container werden ueber
   `{{.Label "com.docker.compose.project"}}` gegen `PROJECT` ausgeschlossen
   (derselbe Abgleich wie das bestehende Inventar, Z.1433). Beleg: fremder
   Container ohne Label bleibt Trefferguend, eigener `coder`-Container nicht
   (reale Docker-Probe, s. u.). Erwartungsverhalten des Plans ("belegtes
   Volume -> Abbruch vor down, alle Container laufen weiter") ist genau damit
   erfuellt; ohne den Ausschluss nicht.
2. **`-q` entfällt neben `--format`.** Erst gemessen, dann gefixt:
   `docker ps -aq --format '...'` antwortet mit
   `WARNING: Ignoring custom format, because both --format and --quiet are set.`
   und liefert nur IDs – das Label kaeme nie an, der Filter wuerde auch
   Projekt-Container zaehlen. Umgesetzt als `docker ps -a --format ...`.
   Wächter im Test (Regression gegen Rueckfall auf `-q`).

Keine der beiden Aenderungen aendert die Secret-Architektur, die
Destruktions-Reihenfolge oder einen Bestandsschutz.

## Moegliche Regressionen (geprueft)

- Fremd-Container haelt Volume: Abbruch VOR down, alle Container laufen
  weiter, Volumes + `.env` intakt (Erwartung Plan Z.365-366).
- Kein fremder Container: Pre-Check gruen -> down -> Volume rm -> rm .env
  (Reset-Pfad unveraendert).
- Kein einziges Volume (Label-Mismatch): Abbruch vor down, Stack laeuft
  weiter (Meldung korrigiert).
- Projekt-Container mit eigenem Label: kein Abbruch (sonst Reset unbenutzbar).
- Container ohne Compose-Label (fremd/unlabelled): Abbruch (konservativ).
- Anderes Compose-Projekt auf demselben Volume: Label weicht ab -> Abbruch.
- Keine Auswirkung auf backup/update/reset-passwords/Gates.

## Testdefinition

`tests/t-b2-006-reset-precheck.sh` (neu, ausfuehrbar, nur /tmp, kein
Docker, keine Produktion) – STATIC + UNIT-LIKE, 16 Checks:

- Reihenfolge im extrahierten `reset-coder.sh`:
  Ermittlung < Belegungs-Check < `down` < `volume rm`; genau eine
  `down`-Stelle; Abbruch-Exit vor `down`.
- Projekt-Container-Ausschluss vorhanden (`--format`-Label + awk-Filter);
  `-q`-Regressionswaechter.
- Meldungen wahrheitsgezaeh, alte falsche Meldungen entfernt.
- Bestandsschutz-Tokens (Allowlist, Leer-Guard, `--force`, TTY-Guard,
  Projekt-Label-Volumen-Filter) vorhanden.
- Verhaltensfixture des awk-Filters (Projekt raus, Fremd + Unlabelled rein).

Nicht Teil dieses Tests (Plan Z.372-374, Kategorie VM DESTRUCTIVE):
T-102-Szenario mit echtem Fremd-Container auf Test-VM (Snapshot + Revert,
nie Produktion).

# Changed

1. `setup-coder.sh` (reset-coder.sh-Heredoc, 2 Hunks): Volume-Ermittlung +
   Leer-Guard + Belegungs-Pre-Check vor `docker compose down` verschoben;
   Projekt-Container-Ausschluss; 2 Abbruchmeldungen auf "nichts angefasst".
2. `tests/t-b2-006-reset-precheck.sh` (neu, ausfuehrbar, 16 Checks).
3. `ai-review/IMPLEMENTATION-REPORT-v3-B2-006.md` (neu, diese Datei).

Diff-Kontrolle: nur Zone Z.1486-1545 (eingebettetes `reset-coder.sh`), keine
Aenderung ausserhalb. Keine neuen Abstraktionen, keine Abhaengigkeiten,
kein `lib.sh`, kein Helper ueber Heredoc-Grenzen.

# Tests Actually Run

Ausgefuehrt am 2026-09-28 auf dem Arbeitsrechner (kein Produktionsserver),
Basis-Commit `2eaf95a` + Arbeitskopie:

1. `bash -n setup-coder.sh` -> ok (PASS, Exit 0).
2. `bash -n tests/t-b2-006-reset-precheck.sh` -> ok (PASS, Exit 0).
3. `shellcheck -S warning setup-coder.sh` -> einziger Befund SC2034
   (`for i in $(seq 1 30)`, Postgres-Wait-Loop, unberuehrte Zeile), identisch
   zur Baseline (B2-003-Report, Z.1043): kein neuer Befund.
4. `shellcheck -S warning tests/t-b2-006-reset-precheck.sh` -> keine Befunde
   (Exit 0).
5. `./tests/t-b2-006-reset-precheck.sh` -> Exit 0, 16x PASS,
   `T-B2-006: ALLE PRUEFUNGEN BESTANDEN`.
6. Regressionslauf aller bisherigen Artefakte -> je Exit 0:
   `./tests/t-071b-headercheck.sh` (B2-001),
   `./tests/t-090-b2-002-tls-gate.sh` (B2-002),
   `./tests/t-b2-003-hex-migration.sh` (B2-003).
7. Reale Docker-Probe (lokal, Throwaway-Container, ohne sudo, keine
   Produktion): `docker ps -a --filter volume=b2006proof --format ...`
   -> Projekt-Container mit Label `coder` + fremder Container ohne Label
   gefunden; awk-Filter -> nur der fremde Container; nach `rm` des fremden
   Containers -> 0 Treffer. Zusaetzlich belegt: `docker ps -aq --format ...`
   verwirft das Format (WARNING) – Ursache der `-q`-Entscheidung.

Tool-Versionen: bash 5.3.15, ShellCheck 0.11.0, Docker 29.7.2-ce,
Git-Basis `2eaf95a`.

# Results

- Belegtes Volume (fremder Container) -> Abbruch VOR `down`, alle Container
  laufen weiter, Volumes + `.env` intakt (Code-Reihenfolge + Test belegt).
- Eigene Projekt-Container blockieren den Reset nicht (sonst unbenutzbar).
- Leer-Fall -> Abbruch vor down, Stack laeuft weiter.
- Bestandsschutz (Allowlist, Leer-Guard, --force, TTY-Guard,
  Zertifikats-/Backup-Schutz) unveraendert vorhanden.
- Regressionsstand: B2-001/B2-002/B2-003-Artefakte weiterhin Exit 0.

# Remaining Risk

- VM-Pflicht offen (Plan Z.372-374): T-102-Szenario (Fremd-Container haelt
  Volume) mit echtem Stack auf Test-VM, Kategorie VM DESTRUCTIVE
  (Snapshot + Revert, nie Produktion). Stop-Regel: kein Production-Lauf davor.
- Label-Verifikation der echten Compose-Topologie (`B-11`) bleibt offen:
  der Ausschluss vertraut auf `com.docker.compose.project` – dass Compose
  dieses Label setzt, ist lokal an Throwaway-Containern belegt, an der
  produktiven Topologie noch nicht (VM).
- Wenn ein fremder Container SELBST das Label `com.docker.compose.project=coder`
  traegt, gilt er als Projekt-Container. Annahme: kein Szenario im Schulbetrieb.

# Files Changed

- `setup-coder.sh` (M, 2 Hunks, nur reset-coder.sh-Zone)
- `tests/t-b2-006-reset-precheck.sh` (neu, ausfuehrbar, 16 Checks)
- `ai-review/IMPLEMENTATION-REPORT-v3-B2-006.md` (neu, diese Datei)

# Related Finding

B2-006
