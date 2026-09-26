# PLAN.md – Lead-Engineer-Triage über `setup-coder.sh`

Stand: 2026-09-26. Geprüft: `setup-coder.sh` (845 Zeilen) plus
`ai-review/01-bash.md`, `02-security.md`, `03-debian-docker.md`,
`04-coder-caddy.md`, `05-backup-recovery.md`, `06-architecture.md`.

Es wurde keine andere Datei verändert. Keine Implementierung.

## Arbeitsweise

1. Jeden Befund der sechs Reviews gegen den tatsächlichen Code geprüft
   (Lesung + gezielte Reproduktion: Pipefail-Mechanik, `bash -n`,
   `shellcheck`, `grep`-Abwesenheitsnachweise für `flock`, `logrotate`,
   `Origins-Pattern`, `restore`, `mem_limit`, `retention.size`).
2. Zusammengeführt, was denselben Code betrifft (ca. 60 Rohbefunde →
   26 übernommene Findings).
3. Entfernt: Duplikate, unbelegte Behauptungen (reine `ASSUMPTION`s ohne
   Code-Fakt), Stilpräferenzen, Refactorings ohne Ausfallnutzen
   (siehe „Verworfene Befunde").
4. Priorisiert nach tatsächlichem Risiko auf diesem Single-Host-Schulserver,
   nicht nach theoretischer Schwere.

## Review-Konflikte (geprüft und entschieden)

- **K1 – Image-Pinning (02/F-013 vs. Skriptkopf L46–53):** 02 fordert
  Digest-Pins (`@sha256:`). Der Skriptkopf pinnt Caddy (`2.10`) und
  Postgres (`15-alpine`) bewusst beweglich, damit TLS-/DB-Patchfixes per
  `pull` ankommen. Beide Positionen sind technisch korrekt, sie
  widersprechen sich im Ziel (Reproduzierbarkeit vs. automatische
  Patchversorgung). Technische Grundlage: Tags sind mutabel, Digests sind
  es nicht – das ist der gesamte Konflikt. Entscheidung: kein
  automatischer Fix, siehe D4. Übernommen wird nur die billige Hälfte
  (GPG-Fingerprint-Prüfung, F-018).
- **K2 – Reset-Volume-Filter (01: MEDIUM vs. 05: CRITICAL):** Derselbe Code
  (L747–752). 05 bewertet Fremd-Volume-Löschung als CRITICAL, 01 als
  MEDIUM. Fakt: Auf diesem Single-Purpose-Host existiert heute kein
  zweites Compose-Projekt (Annahme, aber plausibel); der
  Abbruch-nach-Teillöschung ist dagegen deterministisch, sobald zwei
  Treffer existieren. Entscheidung: HIGH (F-004), nicht CRITICAL.
- **K3 – `pid: host` (02: HIGH vs. 03: MEDIUM vs. 06: Hygiene):**
  Fakt: `pid: host` (L240) ist gesetzt, `--collector.processes` ist nicht
  aktiviert, Mounts sind read-only, Ports sind loopback-gebunden
  (L254–255). Lesender Host-Einblick ja, bestätigter Escape nein.
  Entscheidung: LOW (F-023), reine Hygiene.
- **K4 – Speicherlimits (03/F-005):** 03 empfiehlt `mem_limit`, warnt
  selbst vor Exit-137 bei zu engen Limits. RAM-Ausstattung des Zielhosts
  ist unbekannt, kein Messwert liegt vor. Entscheidung: kein Limit ohne
  Messung → Non-Goal mit Messauftrag unter D8.
- **K5 – Update-Aufspaltung (06/F-004 vs. Minimalprinzip):** 06 will
  `update.sh` in `app`/`db` teilen. Fakt: Der akute Schaden (stilles
  Fehl-Update, falsches Rollback-Vertrauen) wird bereits durch
  Health-Gate + Kommentar-Korrektur behoben. Die Aufspaltung ist ein
  Verhaltens-Refactoring mit neuem Bedienvertrag. Entscheidung:
  Minimal-Fix jetzt (F-012), Aufspaltung Non-Goal bis D7 entschieden ist.
- **K6 – `--converge`-Modus / Config-Templates (06/F-001, F-003):**
  Architektonisch begründet, aber neue CLI-Verträge und eine
  Escaping-Migration (`\$` vs. `$`, L160–162) mit eigenem Fehlerrisiko.
  Kein akuter Ausfall wird dadurch verhindert. Entscheidung: Non-Goals.
- **K7 – Docker-Engine-Auto-Updates (03/F-003):** Automatik schließt die
  Sicherheitslücke, riskiert aber Destabilisierung des Stacks durch
  Major-Sprünge. Fakt: Standard-`unattended-upgrades` deckt `origin=Docker`
  nicht ab (kein `Origins-Pattern` im Skript, verifiziert). Entscheidung:
  kein automatischer Fix, siehe D7; F-013 verlangt nur, dass *eine* der
  beiden Optionen nachweisbar gilt.
- **K8 – On-Demand-TLS (04 vs. 02/F-011):** Kein Widerspruch im Befund
  (beide belegen wirkungslosen `ask`), aber 04 belegt zusätzlich, dass das
  Muster exakt dem offiziellen Coder-Caddy-Tutorial entspricht – also
  keine Fehlkonfiguration, sondern eine übernommene Tutorial-Schwäche.
  Entscheidung: Kurzfristig nur Doku + Erkennung (F-016), echter Fix nur
  per D5.

## Verworfene Befunde (bewusst nicht übernommen)

| Quelle | Grund der Verwerfung |
|---|---|
| 01/F-006 (SC2034, SC2012, fehlender End-Newline), 01/F-008 (7× `ufw status`) | Reine Stil-/Kosmetik-Hinweise ohne Ausfallnutzen; `shellcheck`-Lauf vom 26.09.2026 bestätigt nur diese drei Meldungen, kein funktionaler Fehler. Siehe Non-Goals. |
| 01/F-007 (OLD_PW-Heredoc mit Sonderzeichen) | Hypothetisch: beide Passwörter sind `openssl rand -hex` (nur `0-9a-f`, L138–139, L638–639); Bruch nur bei manueller `.env`-Editierung mit Quotes. Kein praktischer Nutzen. |
| 02/F-002 (Workspace-Socket direkt), 02/F-004 (Workspace→Postgres lateral) | `ASSUMPTION`: Templates/Netzwerke sind nicht im Repo; kein Code-Fakt. Ersetzt durch prüfbare Template-Allowlist (F-019-Testschritt) statt unbelegter Behauptung. |
| 02/F-003 (doppelt zu F-001), 02/F-017 (generisch „Skripte sind destruktiv") | Duplikate ohne eigenen Code-Fakt; abgedeckt durch F-004/F-011/F-015. |
| 02/F-005 (Monitoring-Zugriff), 02/F-009 (Port-Inventar), 02/F-010 (IPv6), 02/F-012 (DNS-Takeover), 02/F-019 (externe Injection) | Korrekte Beobachtungen, aber kein Code-Defekt: Loopback-Bindungen (L233, L255, L269) verifiziert korrekt; Rest ist `ASSUMPTION` ohne Repo-Beleg. IPv6/DNS fließen als Testschritte in D9 ein, nicht als Finding. |
| 03/F-009 (`depends_on` ohne `condition` für Caddy/Grafana), 03/F-010 (`stop_grace_period`) | Selbstheilend (Caddy-Retry) bzw. bei kleiner Schul-DB selten wirksam (WAL-sicher). Kein praktischer Nutzen pro Änderung. Non-Goals. |
| 04/F-003 (`example.com`-Abhängigkeit isoliert), 04/F-004 (CAA), 04/F-005 (`PROXY_TRUSTED_ORIGINS` korrekt abwesend), 03/F-011 (trixie-Repo ok), 03/F-012 (UFW-Kommentar korrekt) | Kein Defekt: F-003 entfällt automatisch mit D5; CAA liegt außerhalb des Skripts (DNS); die drei Bestätigungen erfordern keine Änderung. |
| 05/F-018 (`pg_hba`-Trust-Annahme) | Latente Upstream-Annahme ohne Beleg für Änderungsbedarf; bricht nicht von selbst. Non-Goal. |
| 06/F-001 (`--converge`), 06/F-002 (STATE-Inventar als Selbstzweck), 06/F-003 (Template-Extraktion), 06/F-015 (Testharnisch als Architektur-Finding) | Refactorings ohne akuten Ausfallnutzen (K6). Der verwertbare Kern (Allowlist für Reset) steckt in F-004; ShellCheck/Compose-Checks stecken als Testschritte in den Findings, nicht als eigenes Finding. |

---

## F-001 – Crontab-Migration bricht unter `set -e`/`pipefail` lautlos ab

Severity: CRITICAL

Category: CORRECTNESS

Location: `setup-coder.sh` L68 (`set -euo pipefail`), L522–524 (Backup-Migration), L593–594 (Update-Migration)

Problem: `(crontab -l | grep -vF X) | crontab -` liefert Exit 1, wenn X die
einzige Zeile ist (`grep -v` ohne Treffer). Unter `pipefail` bestimmt das
den Pipeline-Status, unter `set -e` beendet das das Setup mitten im Lauf
ohne Meldung. Genau der Altlast-Fall, den der Code behandeln soll,
verhindert Schritte 7–10 bzw. 8–10.

Evidence: Am 26.09.2026 mit identischem Muster reproduziert – `echo "after"`
wird nie erreicht, Exit 1. Zwei Stellen im Code mit wörtlich demselben Muster.

Impact: Stiller Abbruch des Setup-Laufs; dokumentierte Idempotenz
(„einfach erneut laufen lassen", L25) gilt für diese Konstellation nicht.

Proposed change: `|| true` am `grep -vF`-Glied beider Stellen tolerieren
(z. B. `... | grep -vF "..." || true) | sudo crontab -`). Keine sonstige
Logikänderung.

Regression risk: Gering – nur der 0-Zeilen-Fall ändert sich (Abbruch →
leere Crontab geschrieben, wie beabsichtigt).

Dependencies: Keine. Muss zuerst umgesetzt werden, weil der Abbruch alle
späteren Fixes im selben Lauf verhindert.

Test: In isolierter Test-VM Root-Crontab mit genau einer Alt-Zeile befüllen,
betreffenden Block mit `bash -x` ausführen, danach prüfen: Exit 0 und
nachfolgende Schritte laufen. Nie auf Produktion testen.

Status: TODO

## F-002 – Backups existieren nur auf derselben Platte (kein Offsite)

Severity: CRITICAL

Category: RECOVERY

Location: `setup-coder.sh` L128–129 (`/opt/coder/backups`), L507–511
(`BACKUP_DIR` lokal), keine `rsync`/`scp`/`rclone`-Zeile im gesamten Skript
(verifiziert per Suche)

Problem: Quelle (Docker-Volumes) und Ziel (Backup-Verzeichnis) teilen sich
das Fehlerszenario Platte/Host. Plattenverlust = Datenbank + alle Backups
weg. Die Wiederherstellungsfrage („frische VM aus Backups?") ist mit Nein
beantwortet, solange das gilt.

Evidence: Einziger Schreibpfad ist `${BACKUP_DIR}` unter `/opt`; kein
Transport, keine Verschlüsselung, keine Offsite-Policy im Code.

Impact: Totaler, irreversibler Datenverlust bei Platten-/Host-Verlust. Alle
anderen Backup-Verbesserungen sind nachrangig, solange dieser Punkt gilt.

Proposed change: Tägliche Kopie auf separates Medium/Konto einführen –
Ziel, Transportweg und Verifikation hängen von D6 ab. Skriptseitig nur:
nach erfolgreichem lokalem Backup (F-005-Gate bestanden) einen
konfigurierbaren Copy-Hook (`OFFSITE_DEST`, leer = nur dokumentiert
überspringen mit Warnung) aufrufen und dessen Exit-Code protokollieren.
Getrennt vom lokalen Backup einführen, damit Transportfehler nie das lokale
Backup beschädigen.

Regression risk: Mittel – Transport braucht Secrets/Netz; falsch
konfiguriert exponiert Secrets. Deshalb Default leer + Warnung, nie
stiller Fehlschlag.

Dependencies: D6 (Ziel, Verschlüsselung, Schlüsselverwahrung). F-005 (nur
verifizierte Backups kopieren).

Test: Test-VM-Snapshot verwerfen, prüfen ob außerhalb der VM eine lesbare,
aktuelle, entschlüsselbare Sicherung existiert. Restore daraus nach F-003.

Status: TODO

## F-003 – Kein Restore-Verfahren (kein Skript, keine Doku, kein Test)

Severity: CRITICAL

Category: RECOVERY

Location: Gesamtes Skript – `grep` nach `restore|pg_restore` liefert nur den
Reset-Kommentar (L689–704) und das `ALTER USER`-`psql` (L649); kein
Einspiel-Befehl, kein Runbook.

Problem: Reihenfolge (`.env`? Stack? Dump?), `psql`-Befehl bei abweichendem
Passwort, Schema-Migrationen, Zertifikate, Workspace-Reste – alles
improvisiert im Ernstfall. AGENTS.md verlangt Restore-Tests; es gibt null.

Evidence: Abwesenheit per Code-Lesung und Suche bestätigt.

Impact: RTO unbekannt/maximal (Recherche unter Druck). Backup ohne geprobten
Restore ist Dekoration.

Proposed change: `RESTORE.md` (Repo, versioniert) schreiben: Voraussetzungen
(Dump + `.env`/Ersatz + D6-Offsite-Zugang), Schrittfolge (Stack per Setup
hoch, Coder stoppen, Dump einspielen, Passwort-Abgleich, Login-Verifikation),
Umgang mit bereits angelegtem Leer-Schema und Coder-Migrationen. Einmal in
isolierter VM durchspielen, gemessene RTO und Ergebnis protokollieren
(Protokoll ins Repo). Kein neues Produktiv-Feature.

Regression risk: Keins – nur Dokumentation + Test-VM.

Dependencies: F-005 (verifizierte Dumps), F-021 (`.env`/Configs verfügbar),
D6 (Offsite-Zugang), D8-anteilig (RTO-Ziel aus D8).

Test: Isolierte Test-VM: Stack hoch, Testdaten anlegen, Backup ziehen, VM
verwerfen, nur aus Offsite + Runbook wiederherstellen, Zeit stoppen
(= gemessene RTO), Coder-Login prüfen. Nie Produktion.

Status: TODO

## F-004 – `reset-coder.sh`: Volume-Filter nicht projektgebunden, Mehrfachtreffer = Abbruch nach Teillöschung

Severity: HIGH

Category: CORRECTNESS

Location: `setup-coder.sh` L747–752 (eingebettetes `reset-coder.sh`)

Problem: Filter nur `label=com.docker.compose.volume=<name>` (Compose
vergibt das pro Compose-Datei, unabhängig vom Projektnamen). Generische
Namen (`postgres_data`, `grafana_data`, `prometheus_data`) kollidieren mit
jedem künftigen zweiten Stack. Bei mehreren Treffern wird der mehrzeilige
String quotiert als *ein* Argument an `docker volume rm` übergeben →
Fehlschlag → `set -e` bricht nach `compose down` und ggf. Teil-Löschung ab.

Evidence: Filterzeile per Lesung bestätigt; Quoting-Mechanik am 26.09.2026
in 01-bash reproduziert (ein mehrzeiliger String = ein Argument).

Impact: Worst case Fremd-Volume-Löschung (heute unwahrscheinlich,
Single-Host); wahrscheinlicher: halbzerstörter Stack ohne definierten
Folgezustand.

Proposed change: Filter um `label=com.docker.compose.project=coder`
einschränken (Projektname entspricht Verzeichnis `/opt/coder`; falls der
Projektname je abweicht, aus `docker compose config` ableiten statt zu
raten), Treffer vor dem Löschen anzeigen, zeilenweise löschen
(`while IFS= read -r`). Zusätzlich Allowlist der drei erwarteten
logischen Namen als Guard.

Regression risk: Gering – Normalfall (genau ein Treffer) unverändert.

Dependencies: Keine.

Test: Test-VM mit zwei Volumes gleichen `volume`-Labels aber
unterschiedlichen `project`-Labels: Trockenlauf darf nur das
`project=coder`-Volume anzeigen/löschen. Mehrzeilen-Fall simulieren:
Skript darf nicht abbrechen. Nie Produktion.

Status: TODO

## F-005 – Backup weder atomar noch verifiziert

Severity: HIGH

Category: RELIABILITY

Location: `setup-coder.sh` L510 (`pg_dump | gzip > finaler Name`), L548
(Testlauf prüft nur Existenz), kein `gzip -t`/Größenprüfung/Restore im Code

Problem: Abbruch mitten im Stream hinterlässt defekte Datei unter gültigem
Namen; `pipefail` lässt das Skript fehlschlagen, räumt die Datei aber nicht
weg. Cron-Läufe validieren gar nichts. Leeres stdin ergibt trotzdem ein
„gültiges" kleines Archiv. Widerspruch zu AGENTS.md (Restore-Test-Pflicht).

Evidence: Code-Fakt per Lesung; Abwesenheit von `gzip -t`/Größenprüfung per
Suche bestätigt.

Impact: Stille Unbrauchbarkeit der einzigen Sicherung; Ernstfall ist der
erste Integritätstest.

Proposed change: In Temp-Datei im selben Verzeichnis schreiben, danach
`gzip -t` + Mindestgröße (> leer-Archiv, z. B. > 1 KiB oder > 50 % der
letzten Größe – großen Wert vermeiden, klein und robust wählen), erst dann
atomar per `mv` umbenennen; bei Fehlschlag Temp-Datei löschen, Exit ≠ 0.
Periodischer Test-Restore (wöchentlich, Wegwerf-Postgres) als
Runbook-Pflicht in F-003 aufnehmen.

Regression risk: Gering – Erfolgsfall plus Sekunden Prüfzeit.

Dependencies: F-009 (flock/Timestamp verhindern parallele Schreiber).

Test: `pg_dump` durch nach N Bytes abbrechendes Fake ersetzen → keine Datei
unter finalem Namen. Leeres stdin → Größenprüfung schlägt an. `gzip -t`
auf gültigen Dump → Exit 0.

Status: TODO

## F-006 – `.env` weder atomar geschrieben noch auf Vollständigkeit geprüft

Severity: HIGH

Category: SECURITY

Location: `setup-coder.sh` L134–157 (`if [ ! -f .env ]`, `tee` direkt ins
Ziel L141, `chmod 600` erst L146)

Problem: Abbruch während `tee` hinterlässt leere/unvollständige `.env`;
Re-Run akzeptiert sie („existiert bereits", L156). Zwischen Erzeugung
(umask-abhängig, Standard 022 → 644) und `chmod 600` sind Klartext-Passwörter
breiter lesbar als beabsichtigt.

Evidence: Code-Fakt per Lesung; umask-Mechanismus (022 → 644 vor `chmod`)
allgemein verifiziert.

Impact: Dauerhaft kaputte, aber „vorhandene" `.env`; Compose startet mit
leeren Variablen. Kurzes Secret-Exposure-Fenster auf Platte.

Proposed change: Mit `umask 077` schreiben (Backup-Skript L505 nutzt das
bereits – Muster übernehmen), in Temp-Datei im selben Verzeichnis + atomarer
`mv`; Idempotenz-Check auf Vollständigkeit umstellen (alle drei Schlüssel
`POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `DOCKER_GID` nicht-leer),
sonst neu erzeugen.

Regression risk: Gering – Erfolgsfall unverändert.

Dependencies: Keine.

Test: Test-VM: `.env` halbieren/leeren → Re-Run muss neu erzeugen statt
akzeptieren. `stat -c %a` direkt nach Erzeugung muss `600` zeigen (kein
644-Fenster). Nie Produktion.

Status: TODO

## F-007 – `DOCKER_GID` veraltet nach Docker-Neuinstallation (stale)

Severity: HIGH

Category: IDEMPOTENCY

Location: `setup-coder.sh` L119 (jedes Mal neu gelesen), L144 (nur im
Erstlauf nach `.env` geschrieben), L191 (`group_add: ${DOCKER_GID}`)

Problem: Nur der Erstlauf persistiert die GID. Nach Docker-Neuinstallation,
Debian-Upgrade oder Hardwarewechsel mit anderer `docker`-GID bekommt der
Coder-Container per `group_add` die falsche GID → `Permission denied` auf
`/var/run/docker.sock` → keine Workspace-Provisionierung. Abschlusscheck
prüft nur „Container läuft" (L782), nicht Socket-Zugriff.

Evidence: Code-Fakt per Lesung (einzige Schreibstelle innerhalb
`if [ ! -f .env ]`).

Impact: Totalausfall der Kernfunktion (Provisionierung) ohne Fehlermeldung
im Abschlusscheck.

Proposed change: Bei jedem Lauf GID in `.env` auffrischen (`sed -i`-Muster
wie in `reset-passwords.sh` L662 bereits verwendet); bei Abweichung
`docker compose up -d --no-deps coder` recreaten (sonst wirkungslos).
Abschlusscheck um Socket-Probe ergänzen
(`docker exec coder ... stat /var/run/docker.sock`-Zugriff bzw.
`docker info`-Probe aus dem Coder-Container).

Regression risk: Gering – mit Recreate als Einheit testen.

Dependencies: F-006 (atomares `.env`-Schreiben wiederverwenden).

Test: Test-VM: `groupmod -g <neu> docker` → Re-Run → Coder-Container hat
wieder Socket-Zugriff (Probe grün). Nie Produktion.

Status: TODO

## F-008 – Rotation löscht nach Alter statt Stückzahl (Retention-Cliff)

Severity: HIGH

Category: RELIABILITY

Location: `setup-coder.sh` L513–514 (`find … -mtime +14 -delete`),
Kommentar L513 („Nur die letzten 14 Backups")

Problem: Kommentar verspricht 14 Backups (Stückzahl), Code löscht nach Alter
(> 14×24 h). Nach > 14-tägiger Cron-Lücke löscht der nächste erfolgreiche
Lauf den gesamten Altbestand – genau dann, wenn Historie am wertvollsten wäre.

Evidence: `find -mtime +14 -delete` ohne Zähler/Mindestbestand, per Lesung.

Impact: Schleichender Historienverlust nach Ausfallphasen; im Extremfall ein
einziges Backup ohne Historie, ohne Warnung.

Proposed change: Stückzahlbasiert rotieren (neueste 14 `coder_*.sql.gz`
behalten, Rest löschen) ODER altersbasiert mit Mindestbestand (nur löschen,
wenn mehr als 14 gültige Backups existieren). Kommentar ans Verhalten
anpassen. „Zu viel behalten kostet nur Platte" – im Zweifel behalten.

Regression risk: Gering – nur Löschtiefe.

Dependencies: F-005 (nur gültige Dateien zählen – sonst schützt der
Mindestbestand defekte Dateien).

Test: Testverzeichnis mit 20 Dateien unterschiedlichen Alters + einem
frischen Backup → es bleiben 14 neueste. Lückenszenario (nur Dateien > 14
Tage + ein neues) → Altbestand darf nicht komplett verschwinden.

Status: TODO

## F-009 – Cron weder installiert noch verifiziert; parallele Läufe ungeschützt; Timestamp kollidiert

Severity: HIGH

Category: RELIABILITY

Location: `setup-coder.sh` L507 (`date +%Y-%m-%d_%H%M`, ohne Sekunden),
L510 (`>` trunkierend), L530–534 (Cron-Zeile ohne `flock`), Paketlisten
L104/L115/L359/L466 (kein `cron`-Paket), Abschlusscheck ohne Cron-Prüfung

Problem: (a) Kein `cron`-Paket installiert/verifiziert – auf Minimal-Images
läuft nie ein Backup, Setup meldet trotzdem `[OK]` (L534). (b) Kein
`flock`: Cron- (01:00), `update.sh`-Pre-Backup und manueller Lauf schreiben
bei Minutengleichheit per `>` in dieselbe Datei und trunkieren einander.
(c) Cron-Umgebung (`PATH` minimal) mit bloßen `docker`/`gzip`-Aufrufen
ungeprüft vorausgesetzt.

Evidence: Paketlisten und Cron-Zeile per Lesung; Timestamp-Format
deterministisch; `flock`-Abwesenheit per Suche bestätigt.

Impact: Totalausfall der Sicherung ohne Fehlermeldung (a) bzw. korruptes
Pre-Update-Backup exakt im schützenswerten Moment (b).

Proposed change: `cron`-Paket installieren + enablen, im Abschlusscheck
verifizieren (`systemctl is-active cron`, Datei vorhanden). Cron-Zeile mit
`flock -n /opt/coder/backups/.lock` schützen. Timestamp auf Sekunden
erweitern (`%Y-%m-%d_%H%M%S`). Kein systemd-Timer-Wechsel (überdimensioniert
für den Nutzen).

Regression risk: Gering – Paketinstallation, Lock, Namensformat
(`coder_*.sql.gz`-Rotation greift weiter).

Dependencies: F-005 (Lock + Sekunden schützen erst mit atomarem Schreiben
vollständig).

Test: Frische Minimal-Test-VM: nach Setup muss `systemctl is-active cron`
aktiv sein. Zwei parallele `backup.sh`-Läufe: zweiter bricht per `flock`
sauber ab statt zu trunkieren; beide Dateien `gzip -t`-gültig.

Status: TODO

## F-010 – `reset-passwords.sh`: DB-Wechsel und `.env`-Persistierung nicht transaktional

Severity: HIGH

Category: CORRECTNESS

Location: `setup-coder.sh` L647–669: `ALTER USER` (L649) → Grafana-Reset
(L657) → `sed -i` auf `.env` (L662–663) → Coder-Recreate (L669)

Problem: Abbruch zwischen DB-Änderung und `.env`-Schreiben (SSH-Abbruch,
Ctrl-C) hinterlässt DB=neu, `.env`=alt. Jeder spätere `compose up`
(Reboot, Update) startet Coder mit falschem Passwort – verzögerter Lockout
ohne Erkennungslogik. Kein Backup vorab.

Evidence: Reihenfolge per Lesung bestätigt; kein Backup-Aufruf im Skript.

Impact: Selbstgebauter Lockout mit Zündung beim nächsten Reboot; Ursache in
keinem Log im Klartext (zu Recht), also schwer zu diagnostizieren.

Proposed change: Vorab `.env`-Kopie (`cp -a .env .env.bak.<ts>`, 600) als
Rückfall; `.env` per Temp-Datei + `mv` aktualisieren; `trap` mit klarer
Warnmeldung („DB-Passwort ggf. bereits geändert, `.env.bak.*` prüfen") für
das Abbruchfenster. Reihenfolge DB→`.env` beibehalten (DB zuerst ist
richtig, nur absichern).

Regression risk: Gering – nur Fehlerpfad + Sicherungskopie.

Dependencies: Keine (F-006-Muster wiederverwenden).

Test: Test-Postgres: Skript mit `sleep 5` vor `sed` ausführen, per SIGTERM
abbrechen → Warnung erscheint, `.env.bak.*` existiert, Anleitung zur
Reparatur steht in der Meldung.

Status: TODO

## F-011 – Reset-Dialog: Bestätigung vor Backup, `--force` ohne Zweitbestätigung, Workspace-Warnung zu spät

Severity: HIGH

Category: OPERABILITY

Location: `setup-coder.sh` L723 (`read CONFIRM`) → L730 (Backup) →
L731–737 (`--force`-Weiterlauf); Workspace-Hinweis erst L762–766 (nach
Löschung)

Problem: Die unwiderrufliche Bestätigung bezieht sich auf Hoffnung, nicht auf
Fakten (Backup-Ergebnis steht noch aus). Mit `--force` wird auf vorher
erteilte Bestätigung gelöscht, obwohl bekannt ist, dass keine neue Sicherung
existiert. Verwaiste Workspace-Container (Compose-`down` erfasst sie nicht,
L762–764) werden erst nach der Zerstörung erwähnt – dann sind sie entkoppelt
(DB-Metadaten weg, Container laufen weiter, kollidieren nach Neuaufbau).

Evidence: Ablauf per Lesung bestätigt.

Impact: Uninformierter Datenverlust per `--force`; Neuaufbau mit
Port-/Namenskonflikten durch verwaiste Container.

Proposed change: Vor der Löschung `docker ps`-Inventar (read-only) aller
Nicht-Compose-Container anzeigen und bei laufenden Workspaces abbrechen oder
explizit behandeln lassen; Hinweis an den Skriptanfang ziehen. Bestätigung
erst nach erfolgreichem Backup verlangen; bei Backup-Fehlschlag + `--force`
Zweitbestätigung mit Anzeige des neuesten verfügbaren Backups (Alter/Größe/
`gzip -t`-Status).

Regression risk: Gering – nur Dialog-Reihenfolge + lesende Inventur.

Dependencies: F-005 (Backup-Statusanzeige nutzt dessen Verifikation).

Test: Test-VM: Backup absichtlich fehlschlagen lassen (Postgres gestoppt) →
ohne `--force` Abbruch ohne Löschung; mit `--force` Zweitbestätigung mit
Backup-Status. Dummy-Container außerhalb Compose → werden vorher angezeigt.

Status: TODO

## F-012 – Update ohne Health-Gate, mit irreführendem Rollback-Versprechen

Severity: HIGH

Category: RELIABILITY

Location: `setup-coder.sh` L561–588 (`pull` L569 → `up -d` L570 →
`prune -f` L580, danach nichts), Kommentar L572–580 (Rollback) und
Kopfkommentar L46–53 (Pins)

Problem: (a) Nach `up -d` prüft nichts Gesundheit (`ps`, `/healthz`,
`service_healthy`) – Fehl-Update fällt erst durch Nutzerbeschwerde auf.
(b) Der Prune-Kommentar verspricht Rollback durch Behalten des alten Images
– das gilt nur für exakt gepinnte Tags (Coder/Prometheus/Grafana). Für
`caddy:2.10`/`postgres:15-alpine` (beweglich, Kopfkommentar L46–53) macht
`pull` das alte Image dangling, und `prune -f` löscht es sofort – exakt das
als verhindert beschriebene Szenario. (c) `pull` zieht DB- und App-Images in
einem Befehl; Coder-Schema-Migrationen können Downgrades irreversibel machen
(Coder-Upstream-Verhalten, unbestätigt für v2.36.6).

Evidence: `update.sh`-Volltext per Lesung (kein Gate, kein Guard);
Prune-Mechanik aus Docker-Doku (dangling nach Tag-Wechsel) + bewegliche Tags
aus Skriptkopf.

Impact: Update-Fehler → Totalausfall mit ungewissem Rückweg; Vertrauen in
nicht zutreffende Doku im Ernstfall.

Proposed change: Nach `up -d` Health-Gate (Container gesund + `/healthz`
200 innert Timeout, sonst Exit ≠ 0 mit klarem Hinweis). Kommentar
präzisieren: Rollback-Garantie nur für exakt gepinnte Images; für
Caddy/Postgres erfordert Rollback erneuten Pull; DB-Downgrade-Vorbehalt bei
Migrationen dokumentieren (Major-Updates nur mit verifiziertem Dump).
Keine `app`/`db`-Aufspaltung jetzt (siehe K5/Non-Goals).

Regression risk: Gering – zusätzliche Prüfung nach dem Update-Pfad.

Dependencies: F-005 (Pre-Update-Backup ist nur mit Verifikation eine
Rollback-Basis).

Test: Test-VM mit absichtlich falscher `CODER_VERSION` → Skript muss selbst
fehlschlagen (nicht still „erfolgreich" enden). `CADDY_VERSION` zweimal auf
reale Tags wechseln → dokumentieren, ob altes Image nach `prune -f` noch da
ist (Soll nach Dok
...[truncated 15821 chars]