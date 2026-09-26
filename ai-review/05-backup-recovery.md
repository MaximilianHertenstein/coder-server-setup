# 05 – Backup-/Recovery-Review von `setup-coder.sh`

Rolle: Senior Site Reliability Engineer / Disaster Recovery Engineer.
Geprüft: `setup-coder.sh` (845 Zeilen), inkl. der vier eingebetteten
Wartungsskripte `backup.sh`, `update.sh`, `reset-passwords.sh`,
`reset-coder.sh` (per Heredoc nach `/opt/coder/*.sh` geschrieben),
der Docker-Compose-Volumes (`postgres_data`, `caddy_data`,
`caddy_config`, `prometheus_data`, `grafana_data`) und der Daten von
Coder/Postgres/Grafana/Prometheus.

Es wurde ausschließlich diese Datei (`ai-review/05-backup-recovery.md`)
bearbeitet. Keine Implementierung, keine Änderung am Skript.

## Methodik

- Vollständige Lesung von `setup-coder.sh`, aller vier eingebetteten
  Skripte sowie [AGENTS.md](../AGENTS.md) und
  [copilot-instructions.md](../copilot-instructions.md).
- Read-only-Prüfungen lokal (kein Eingriff in Produktion):
  `bash -n setup-coder.sh` → `SYNTAX_OK`; `grep`-Nachweise, dass
  `gzip -t`, `mktemp`, `trap`, `flock`, `logrotate`, `restore`,
  Restore-`psql` und Alerting-Regeln im Skript nicht vorkommen.
- Kein Restore wurde ausgeführt (kein Zielsystem verfügbar, Produktion
  tabu). Alle Aussagen über Verhalten im echten Ausfall sind daher
  `LIKELY` oder `ASSUMPTION`, nie behauptete Testergebnisse.

„Classification“ pro Befund:
- **CONFIRMED**: Code-Fakt statisch nachgewiesen (gelesener Code plus
  lokale read-only-Prüfung); keine Behauptung über ausgeführte Tests.
- **LIKELY**: Code-Fakt nachgewiesen, konkretes Auslöse-Szenario auf dem
  Zielsystem nicht durchgespielt.
- **ASSUMPTION**: Plausible Annahme ohne belastbaren Nachweis im Code.

Überschneidungen mit `ai-review/01-bash.md` (F-003 atomares Backup,
F-004 Volume-Filter, F-005 Passwort-Transaktionalität) werden hier nicht
wiederholt, sondern aus Recovery-Sicht neu bewertet und referenziert.

---

## F-001 – Gesichert wird nur die Postgres-Datenbank, sonst nichts

Severity: CRITICAL

Location:
- [setup-coder.sh](../setup-coder.sh#L502-L515) – eingebettetes `backup.sh`

Problem:
Der einzige Sicherungsinhalt ist ein logischer Dump:
`docker exec coder-postgres pg_dump -U coder coder | gzip > ...`.
Nicht gesichert werden: `/opt/coder/.env` (alle Passwörter),
`docker-compose.yml`, `Caddyfile`, `prometheus.yml`,
`/etc/cron.d/coder-backup`, UFW-Regeln, fail2ban-`jail.local`,
unattended-upgrades-Konfiguration, alle Docker-Volumes außer Postgres
(implizit), Workspace-Container und -Daten (siehe F-015).

Failure scenario:
Totalausfall des Servers. Auf einer frischen Debian-13-VM liegt nur
`coder_<Datum>.sql.gz` vor (falls überhaupt offsite kopiert, was nicht
vorgesehen ist). `.env` mit `POSTGRES_PASSWORD` fehlt, Compose- und
Caddy-Konfiguration müssen aus dem Kopf rekonstruiert werden.

Evidence:
```bash
docker exec coder-postgres pg_dump -U coder coder | gzip > "${BACKUP_DIR}/coder_${TIMESTAMP}.sql.gz"
```
Keine weitere Sicherungszeile im Skript; `grep` nach `mktemp|trap|restore`
liefert keinen Treffer (lokal geprüft).

Impact:
Kein vollständiger Wiederaufbau aus Sicherungen möglich. Der Dump ist
eine Datenbank-Teilsicherung, kein Server-Backup.

Proposed change:
Backup-Umfang definieren (DB-Dump + `.env` + Compose/Caddy/Prometheus-
Konfiguration + Volume-Inventar) oder explizit dokumentieren, dass nur
die DB gesichert wird und alles andere per `setup-coder.sh`-Rerun neu
entsteht.

Regression risk:
Gering – reine Erweiterung des Sicherungsumfangs; `.env`-Sicherung
erfordert restriktive Rechte (vgl. vorhandenen `umask 077`).

Test:
1. Frische Test-VM ohne Altdateien bereitstellen.
2. Ausschließlich mit den erzeugten Backup-Dateien (ohne Repo-Zugriff
   auf `setup-coder.sh`) den Stack rekonstruieren; protokollieren, was
   fehlt.

Classification: CONFIRMED

---

## F-002 – Backups liegen nur auf derselben Platte, kein Offsite

Severity: CRITICAL

Location:
- [setup-coder.sh](../setup-coder.sh#L128-L129) (`/opt/coder/backups`, `chmod 700`)
- [setup-coder.sh](../setup-coder.sh#L502-L515) (`BACKUP_DIR="/opt/coder/backups"`)

Problem:
Sicherungsquelle (Docker-Volumes auf der Systemplatte) und Sicherungsziel
(`/opt/coder/backups` auf derselben Platte) teilen sich dasselbe
Fehlerszenario. Es gibt keinen Kopier-/Sync-Schritt, keine
Verschlüsselung für externen Transport, keine Offsite-Policy.

Failure scenario:
Festplattenausfall oder vollständiger Serververlust. Datenbank und alle
Backups sind gleichzeitig weg. Die entscheidende Review-Frage ist damit
bereits beantwortet: Nein, ein ausgefallener Server ist mit den
vorgesehenen Sicherungen nicht wiederherstellbar.

Evidence:
Code-Lesung: einziger Schreibpfad ist `${BACKUP_DIR}` unter `/opt`;
kein `rsync`/`scp`/`rclone`/Objektstorage im gesamten Skript.

Impact:
Totaler, irreversibler Datenverlust bei Platten- oder Host-Verlust.
Alle weiteren Backup-Befunde sind nachrangig, solange dieser gilt.

Proposed change:
Tägliche Kopie auf ein separates Medium/Konto (mindestens manuell
dokumentierter Offsite-Schritt mit Verifikation), erst danach sind
Feinschliff-Befunde (Atomarität, Rotation) sinnvoll priorisierbar.

Regression risk:
Mittel – Transport braucht Secrets/Netzwerkziele; falsch konfiguriert
kann er Secrets exponieren. Getrennt vom lokalen Backup einführen.

Test:
1. Server-VM simuliert zerstören (Snapshot verwerfen).
2. Prüfen, ob außerhalb der VM eine lesbare, aktuelle Sicherung existiert.

Classification: CONFIRMED

---

## F-003 – Kein atomares Schreiben, keine Verifikation (leere/korrupte/abgebrochene Backups)

Severity: HIGH

Location:
- [setup-coder.sh](../setup-coder.sh#L502-L515) – eingebettetes `backup.sh`
- [setup-coder.sh#L546-L557](../setup-coder.sh#L546-L557) – Testlauf-Auswertung (nur Existenzprüfung)

Problem:
Direktes Schreiben in den finalen Dateinamen statt Temp-Datei + `mv`;
kein `gzip -t`, keine Größen-/Leerheitsprüfung, kein Test-Restore.
`set -euo pipefail` lässt das Skript bei `pg_dump`-Abbruch zwar
fehlschlagen, die unvollständige Datei unter gültigem Namen bleibt aber
liegen. Der Setup-Testlauf prüft nur Existenz (`ls -t … | head -n1`),
die täglichen Cron-Läufe gar nichts. Das widerspricht
[AGENTS.md](../AGENTS.md): „Eine erfolgreiche Backup-Datei ist keine
ausreichende Evidenz für ein erfolgreiches Backup. Restore-Tests sind
erforderlich.“ Vgl. `01-bash.md` F-003.

Failure scenario:
a) Unterbrochenes Backup (SIGTERM, SSH-Abbruch, OOM, Reboot 03:00 durch
unattended-upgrades bei überlangem Dump, Container-Neustart): defekte
Datei mit gültigem Namen bleibt als „letztes Backup“ liegen.
b) Beschädigtes Backup (Plattenfehler, volles Dateisystem, siehe F-007):
fällt erst beim Restore im Ernstfall auf.
c) Leeres Backup: `gzip` erzeugt auch aus leerem stdin ein gültiges
kleines Archiv; Existenzprüfung besteht, Inhalt ist wertlos.

Evidence:
```bash
docker exec coder-postgres pg_dump -U coder coder | gzip > "${BACKUP_DIR}/coder_${TIMESTAMP}.sql.gz"
chmod 600 "${BACKUP_DIR}/coder_${TIMESTAMP}.sql.gz"
find "${BACKUP_DIR}" -name 'coder_*.sql.gz' -type f -mtime +14 -delete
```
Lokal per `grep` bestätigt: kein `gzip -t`, kein Größenvergleich, kein
Restore-Pfad im Skript.

Impact:
Stille Unbrauchbarkeit der einzigen Sicherung. Der Ernstfall (Restore)
ist der erste Integritätstest.

Proposed change:
In Temp-Datei im selben Verzeichnis schreiben, `gzip -t` + Mindestgröße
prüfen, erst dann atomar per `mv` umbenennen; bei Fehlschlag Temp-Datei
löschen und nicht-null exiten. Separat: periodischer Test-Restore in
isolierter Umgebung (AGENTS.md-Policy).

Regression risk:
Gering – Erfolgsfall unverändert plus kurze Prüfzeit.

Test:
1. `pg_dump` durch ein nach N Bytes abbrechendes Fake ersetzen,
   `backup.sh` laufen lassen, prüfen ob eine Datei unter finalem Namen
   zurückbleibt (Soll: nein).
2. Leeren stdin füttern, prüfen ob Größenprüfung anschlägt.
3. Wöchentlich: Dump in Wegwerf-Postgres einspielen (`gunzip -t` +
   `psql`), Ergebnis protokollieren.

Classification: LIKELY (Mechanismus CONFIRMED per Code-Lesung;
Abbruch-Szenarien nicht am Zielsystem durchgespielt)

---

## F-004 – Zeitstempel nur minutengenau: Kollision und Überschreiben

Severity: MEDIUM

Location:
- [setup-coder.sh](../setup-coder.sh#L507): `TIMESTAMP=$(date +%Y-%m-%d_%H%M)`

Problem:
Zwei Läufe innerhalb derselben Minute erzeugen denselben Dateinamen,
der zweite Lauf trunkiert per `>` die Datei des ersten. Konkrete
Paare: Cron-Backup 01:00 + manuelles Backup, `update.sh`-Pre-Backup +
Cron-Backup, `reset-coder.sh`-Sicherungsbackup + Wiederholungslauf,
Retry nach Fehlschlag innerhalb derselben Minute.

Failure scenario:
`update.sh` zieht um 01:00:30 sein Pre-Update-Backup, während der
Cron-Lauf um 01:00:05 noch schreibt (oder umgekehrt): ein Dump wird
durch den anderen abgeschnitten/überschrieben; im schlimmsten Fall
bleibt genau das Pre-Update-Backup korrupt zurück, das das Update
absichern sollte.

Evidence:
Formatstring `%Y-%m-%d_%H%M` ohne `%S`; Schreibmodus `>` (trunkierend,
nicht exklusiv). Deterministischer Code-Fakt, kein Umgebungseinfluss.

Impact:
Geringe Eintrittswahrscheinlichkeit, aber exakt in den Momenten
(Update/Reset), in denen das Backup am wichtigsten ist.

Proposed change:
Sekunden (und ggf. PID/Hostname) in den Namen aufnehmen,
z. B. `date +%Y-%m-%d_%H%M%S`, plus exklusives Anlegen (`set -o noclobber`
oder `: >` mit Prüfung) oder `flock`.

Regression risk:
Gering – nur Namensgebung; Rotation per `coder_*.sql.gz` greift weiter.

Test:
1. `backup.sh` zweimal innerhalb derselben Minute starten (zweiter
   Hintergrundlauf), beide Exit-Codes und Dateiinhalte (`gzip -t`,
   Größen) prüfen.

Classification: CONFIRMED

---

## F-005 – Rotation hält keine „14 Backups“, sondern löscht nach Alter – Retention-Cliff

Severity: HIGH

Location:
- [setup-coder.sh](../setup-coder.sh#L513-L514):
  `find "${BACKUP_DIR}" -name 'coder_*.sql.gz' -type f -mtime +14 -delete`
- Kommentar L513: „Nur die letzten 14 Backups behalten“

Problem:
Kommentar verspricht stückzahlbasierte Retention (14 Backups),
implementiert ist altersbasierte (`mtime +14`, effektiv >14×24 h).
Folgen: a) Bei täglichem Erfolg liegen ~15 Dateien – harmlos, aber
Kommentar und Verhalten widersprechen sich. b) Kritisch: Fällt Cron
länger als 14 Tage aus (Urlaub, Cron-Daemon tot, VM aus, Platte voll),
altern alle vorhandenen Backups aus der Retention – der nächste
erfolgreiche Lauf löscht die letzten alten Dateien (bzw. sie sind alle
bereits „zu alt“), im Extremfall endet man mit genau einem oder null
brauchbaren Backups nach wochenlanger Lücke, ohne dass jemand warnt.

Failure scenario:
Cron unbemerkt defekt (siehe F-006), 3 Wochen keine Backups. Nach Fix
läuft ein Backup, `find` löscht alle Vorgänger als „älter als 14 Tage“.
Die wochenlange Lücke wird zur faktischen Einzelkopie ohne Historie.

Evidence:
`find … -mtime +14 -delete` ohne Stückzahl-Logik und ohne
Mindestbestands-Schutz; kein Zähler (`ls … | tail`) im Skript.

Impact:
Schleichender Verlust der Backup-Historie genau nach Ausfallphasen,
also dann, wenn Historie am wertvollsten wäre.

Proposed change:
Stückzahlbasiert rotieren (z. B. neueste N behalten) oder altersbasiert
mit Mindestbestand (konkret: lösche nur, wenn mehr als N gültige
Backups existieren); Kommentar an Verhalten anpassen.

Regression risk:
Gering – nur Löschtiefe; versehentliches Zu-viel-Behalten kostet nur
Platte, Zu-wenig-Löschen nie Daten.

Test:
1. Testverzeichnis mit 20 Dateien unterschiedlichen Alters (+ ein
   frisches), Rotationszeile laufen lassen, zählen was übrig bleibt.
2. Lückenszenario: nur Dateien älter als 14 Tage + ein neues Backup →
   prüfen, ob Altbestand komplett verschwindet.

Classification: CONFIRMED

---

## F-006 – Cron existiert auf dem Papier: kein Daemon-Nachweis, kein Overlap-Schutz, fragile Umgebung

Severity: HIGH

Location:
- [setup-coder.sh](../setup-coder.sh#L530-L534) (`/etc/cron.d/coder-backup`):
  `0 1 * * * root /opt/coder/backup.sh >> /var/log/coder-backup.log 2>&1`

Problem:
a) Nirgends wird das `cron`-Paket installiert oder der Daemon
(`cron.service`) aktiviert/verifiziert – installiert werden nur `ufw`,
`fail2ban`, `unattended-upgrades`. Auf einer minimalen Debian-13-VM ohne
Cron-Daemon läuft das Backup still nie.
b) Kein `flock`: Überlappende Läufe (hängender `pg_dump`, Retry, Update-
Backup) schreiben ggf. in dieselbe Minutendatei (F-004).
c) Cron-Umgebung ist minimal (`PATH=/usr/bin:/bin`); `backup.sh` nutzt
bare `docker`, `gzip`, `date` ohne absolute Pfade – funktioniert
üblicherweise (`/usr/bin/docker`), ist aber ungeprüft vorausgesetzt.
d) Bei Nichtexistenz von `/var/log/coder-backup.log`-Rotation (F-007)
wächst das Log unbegrenzt.

Failure scenario:
Neu aufgesetzte VM-Variante ohne Cron-Daemon: Setup meldet „Backup-
Cronjob ist eingetragen“ ([OK]), tatsächlich läuft nie ein Backup.
Bemerkt wird es erst beim Datenverlust.

Evidence:
Installationsliste Schritt 1/4/5 enthält kein `cron`; kein
`systemctl … cron`-Check im Abschlusscheck (Schritt 10 prüft Container,
ufw, fail2ban, DNS – aber keinen Backup-Daemon). Cron-Zeile selbst per
Lesung bestätigt.

Impact:
Totalausfall der Sicherungsfunktion ohne jede Fehlermeldung im Setup.

Proposed change:
`cron` (bzw. vorhandenen Scheduler) installieren, enablen, im
Abschlusscheck verifizieren (`systemctl is-active cron`, Datei in
`/etc/cron.d` vorhanden, Testlauf – letzterer existiert bereits);
`flock -n` in der Cron-Zeile ergänzen.

Regression risk:
Gering – Paketinstallation und ein zusätzlicher Check.

Test:
1. In isolierter Debian-13-Test-VM ohne vorinstalliertes cron das Setup
   laufen lassen, danach `systemctl is-active cron` und Zeitstempel in
   `/opt/coder/backups/` nach 24 h (oder manipulierter Systemzeit)
   prüfen.
2. Zwei manuelle `backup.sh`-Läufe parallel starten, Dateiintegrität
   beider Ergebnisse prüfen.

Classification: LIKELY (Fehlen von Installations-/Verifikationscode
CONFIRMED; Daemon-Abwesenheit auf konkretem Zielimage ASSUMPTION)

---

## F-007 – Fehler fallen niemandem auf: Logging ohne Alerting, Monitoring ohne Alarme

Severity: MEDIUM

Location:
- [setup-coder.sh](../setup-coder.sh#L531) (Log-Redirect)
- [setup-coder.sh](../setup-coder.sh#L322-L334) (`prometheus.yml`: nur zwei Scrape-Jobs)

Problem:
Backup-Fehler landen ausschließlich in `/var/log/coder-backup.log`:
kein Zeitstempel im Log (nur Cron-Output), keine `logrotate`-
Konfiguration (unbegrenztes Wachstum als root-Log), kein `MAILTO`,
kein Healthcheck, keine Prometheus-Alert-Regel, kein Alertmanager.
`prometheus.yml` enthält nur Scrape-Targets, keinerlei
`alerting_rules.yml`; node-exporter misst zwar Plattenfüllung, aber
niemand wertet sie aus. RPO-Überschreitung (kein erfolgreiches Backup
seit N Tagen) bemerkt kein Mensch und keine Maschine.

Failure scenario:
`pg_dump` schlägt ab März jede Nacht fehl (z. B. Container nach Update
umbenannt, Platte voll). Log wächst, niemand liest es. Im Juni ist die
Datenbank defekt – letztes brauchbares Backup: Februar (falls dank
F-005 überhaupt noch vorhanden).

Evidence:
Kein `logrotate`-File, kein `MAILTO`, keine Alerting-Sektion in der
generierten `prometheus.yml` – alles per Lesung/​grep bestätigt
abwesend.

Impact:
Jeder Backup-Defekt wird zum stillen Defekt; RPO ist faktisch unendlich.

Proposed change:
Mindestens: `logrotate`-Konfiguration für `coder-backup.log`,
Erfolgs-/Fehler-Trap mit `logger` + Zeitstempel, und eine triviale
Frische-Prüfung (Alter des neuesten gültigen Backups, z. B. im
Abschlusscheck oder eigenem Check-Skript). Prometheus-Alerting ist
optional, aber Platten-/Backup-Frische gehört irgendwo hin.

Regression risk:
Gering – nur Beobachtung, kein Eingriff in den Backup-Pfad.

Test:
1. Backup absichtlich fehlschlagen lassen (Container gestoppt), prüfen
   ob irgendein Signal außer der Log-Datei entsteht (Soll nach Fix: ja).
2. `logrotate --debug` gegen die neue Konfiguration laufen lassen.

Classification: CONFIRMED

---

## F-008 – Kein Restore-Verfahren: kein Skript, keine Doku, kein Test

Severity: CRITICAL

Location:
- Gesamtes Skript: kein `restore.sh`, kein Restore-Kommentar; einziger
  Restore-Bezug ist „Backups bleiben erhalten“ im Reset-Kontext
  ([setup-coder.sh](../setup-coder.sh#L689-L704))

Problem:
Es ist nirgends beschrieben (und nicht automatisiert), wie aus
`coder_<Datum>.sql.gz` wieder eine laufende Coder-Instanz wird:
Reihenfolge (`.env` neu → Stack hoch → Dump einspielen? oder Dump zuerst?),
exakter `psql`/`pg_restore`-Befehl, Umgang mit abweichendem
`POSTGRES_PASSWORD`, Umgang mit Coder-Schema-Migrationen, Umgang mit
Caddy-Zertifikaten, Umgang mit Workspace-Resten. AGENTS.md verlangt
Restore-Tests; es gibt null.

Failure scenario:
Beliebiges Restore-Szenario (Platte getauscht, Update zerschossen,
Reset bereut): Der Operator steht nachts mit einer `.sql.gz` da und
muss das Verfahren improvisieren – gegen eine Datenbank, deren
Passwort er ggf. nicht mehr hat (F-009), in einen Coder, dessen Version
ggf. Migrationen erwartet (F-010).

Evidence:
`grep -n "restore|psql <|pg_restore" setup-coder.sh` liefert nur den
Reset-Kommentar und das `ALTER USER`-`psql` in `reset-passwords.sh`;
kein Einspiel-Befehl, kein Restore-Skript (lokal geprüft).

Impact:
RTO unbekannt und im Ernstfall maximal (Recherche + Improvisation unter
Druck). Ein Backup ohne geprobten Restore ist Dekoration.

Proposed change:
Restore-Runbook schreiben und mindestens einmal in isolierter VM
durchspielen (Dump einspielen, Coder-Login verifizieren); Ergebnis
protokollieren. Kein neues Produktiv-Feature nötig – Doku + ein Test.

Regression risk:
Keins – nur Dokumentation und Testumgebung.

Test:
1. Isolierte Test-VM: Stack per Setup hochfahren, Testdaten anlegen,
   Backup ziehen, VM verwerfen, nur aus Backup + Runbook
   wiederherstellen, Zeit stoppen (= gemessene RTO), Login prüfen.

Classification: CONFIRMED

---

## F-009 – `.env` wird nie gesichert und bei Reset gelöscht: Restore ohne Passwort

Severity: HIGH

Location:
- [setup-coder.sh](../setup-coder.sh#L502-L515) (Backup-Umfang: nur DB)
- [setup-coder.sh](../setup-coder.sh#L754-L755) (`rm -f .env` in `reset-coder.sh`)

Problem:
`POSTGRES_PASSWORD` existiert nur in `/opt/coder/.env` (Modus 600) und
im Terminal-Output bei Erzeugung. Kein Backup enthält es. Nach
Serververlust oder nach `reset-coder.sh` (das `.env` löscht und beim
nächsten Setup neue Passwörter würfelt) passt kein altes Backup mehr
ohne Handarbeit zur neuen Datenbank-Instanz: Der Dump lässt sich zwar
mit neuem Passwort einspielen, aber das Verfahren (neue Credentials
setzen, `CODER_PG_CONNECTION_URL` neu verdrahten) ist undokumentiert
(F-008) und der alte DB-Inhalt referenziert ggf. Secrets/Tokens, die
mit der neuen Instanz neu ausgestellt werden müssen.

Failure scenario:
Reset bereut: Backup vom Vortag vorhanden, aber `.env` neu gewürfelt.
Operator muss manuell Dump einspielen und Passwörter synchronisieren –
ohne Anleitung, mit laufendem Coder, der bereits ein leeres Schema
angelegt haben kann (Konflikt Dump-vs-Neuinstallation).

Evidence:
Backup-Zeile sichert ausschließlich per `pg_dump`; `rm -f .env`
per Lesung bestätigt; kein `.env`-Backup-Schritt im Skript.

Impact:
Jeder Totalverlust und jeder Reset macht aus dem DB-Dump ein
manuelles Puzzlespiel statt eines Wiederherstellungslaufs.

Proposed change:
`.env` in den Backup-Umfang aufnehmen (gleiche Rechte, `umask 077`,
idealerweise verschlüsselt für Offsite) und im Restore-Runbook den
Passwort-Abgleich als expliziten Schritt beschreiben.

Regression risk:
Mittel – `.env`-Kopien sind zusätzliche Secret-Träger; Rechte und
Aufbewahrung müssen stimmen (sonst neue Exfiltrationsfläche).

Test:
1. Test-VM: `.env` löschen, Stack neu aufsetzen, alten Dump nach Runbook
   einspielen, Coder-Login prüfen.

Classification: CONFIRMED

---

## F-010 – Update ohne Verifikation und ohne belastbaren Rollback; Migrationen irreversibel möglich

Severity: HIGH

Location:
- [setup-coder.sh](../setup-coder.sh#L561-L588) – eingebettetes `update.sh`

Problem:
```bash
/opt/coder/backup.sh
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
```
a) Das Pre-Update-Backup wird nicht verifiziert (F-003) – Rollback-Basis
möglicherweise wertlos.
b) Nach `up -d` folgt keine Gesundheitsprüfung (kein `ps`, kein
`/healthz`, kein Warten auf `service_healthy`) – anders als Schritt 10
des Setups. Ein fehlgeschlagenes Update fällt erst durch Nutzerbeschwerde
auf.
c) Der Kommentar begründet `-f` statt `-a` beim Prune korrekt (altes
Image behalten für Rollback) – aber Rollback heißt hier: alte
`CODER_VERSION` setzen + Setup erneut laufen lassen. Coder führt beim
Start automatische Postgres-Schema-Migrationen aus; war das Update mit
einer Migration verbunden, kann der Downgrade gegen das migrierte Schema
fehlschlagen – das alte Image startet dann nicht mehr sauber. Kein Wort
dazu im Skript.
d) `docker compose pull` zieht `postgres:15-alpine` (floating Major-Tag)
und `caddy:2.10` (Minor-Pin) unkontrolliert mit – ein Major-Sprung der
Datenbank läge im selben Befehl wie ein Coder-Patch.

Failure scenario:
Coder-Update mit DB-Migration startet, scheitert an anderer Stelle
(z. B. Template-Inkompatibilität). Rollback auf altes Image: Coder
alter Version verweigert das neue Schema → Stack down, einziges
„Backup“ ist ein ungeprüfter Dump, Restore-Verfahren unbekannt (F-008).

Evidence:
`update.sh`-Volltext per Lesung bestätigt (kein Healthcheck, kein
Versions-Guard); Coder-Auto-Migration ist dokumentiertes
Upstream-Verhalten (Annahme über Coder, nicht über dieses Skript –
deshalb LIKELY, nicht CONFIRMED).

Impact:
Update-Fehler werden zum Totalausfall mit ungewissem Rückweg.

Proposed change:
Nach `up -d`: Health-Gate (Container gesund + `/healthz` 200) mit
klarem Abbruchhinweis; Rollback-Abschnitt dokumentieren inkl.
Migrations-Vorbehalt (vor Major-Updates Dump + Versionsnotiz);
`postgres`-Image-Pin und DB-Update-Pfad explizit trennen.

Regression risk:
Gering – zusätzliche Prüfung, kein Eingriff in den Update-Pfad selbst.

Test:
1. In Test-VM Update mit absichtlich falscher `CODER_VERSION` fahren,
   prüfen ob das Skript den Fehler selbst meldet (Soll nach Fix: ja).
2. Major-/Minor-Update in Test-VM inkl. dokumentiertem Rollback
   durchspielen.

Classification: LIKELY

---

## F-011 – `reset-coder.sh`: Volume-Auswahl nicht projektgebunden, Mehrfachtreffer brechen Reset mittendrin ab

Severity: CRITICAL

Location:
- [setup-coder.sh](../setup-coder.sh#L740-L752) – eingebettetes `reset-coder.sh`

Problem:
```bash
VOL_NAME=$(docker volume ls -q --filter "label=com.docker.compose.volume=${VOL_LABEL}")
if [ -n "${VOL_NAME}" ]; then
  docker volume rm "${VOL_NAME}"
fi
```
a) Filter nur auf `com.docker.compose.volume=<name>`, ohne
`com.docker.compose.project=coder`. Das Label vergibt Compose nach dem
kurzen Volume-Schlüssel, unabhängig vom Projektnamen – ein zweites
Compose-Projekt mit gleichnamigem Volume (`postgres_data`,
`grafana_data`, `prometheus_data` sind generisch) würde mitgelöscht.
b) Bei mehreren Treffern enthält `VOL_NAME` mehrere Zeilen, wird aber
quotiert als ein Argument übergeben → `docker volume rm` scheitert →
`set -euo pipefail` bricht das Skript ab, nachdem `docker compose down`
bereits lief und ggf. schon einzelne Volumes gelöscht sind:
halbzerstörter Stack ohne `.env`-Löschung, ohne Abschlussmeldung.
(Mechanik in `01-bash.md` F-004 reproduziert; hier die
Recovery-Bewertung.)

Failure scenario:
Falsche Volume-Auswahl: Versehentliches Löschen fremder
Produktiv-Volumes eines anderen Stacks auf demselben Host
(derzeit unwahrscheinlich – Einzelserver –, aber ohne jeden Guard).
Unvollständige Wiederherstellung: Abbruch nach Teil-Löschung lässt einen
weder lauffähigen noch sauber neu aufsetzbaren Zustand zurück.

Evidence:
Filterzeile per Lesung bestätigt; Quoting-Abbruch-Mechanik in
`01-bash.md` F-004 lokal reproduziert (generisches Bash-Verhalten).

Impact:
Fremddatenverlust (worst case) bzw. halb durchgeführter Destruktivlauf
ohne definierten Folgezustand.

Proposed change:
Filter um `label=com.docker.compose.project=coder` einschränken,
aufzulösende Volume-Namen vor dem Löschen anzeigen, zeilenweise löschen.
Fehlende Sicherheitsprüfung (Allowlist der drei erwarteten Volumes)
ergänzen.

Regression risk:
Gering – schärferer Filter ändert den Normalfall (genau ein Treffer)
nicht.

Test:
1. Zwei Test-Volumes mit gleichem `volume`-Label, aber unterschiedlichem
   `project`-Label anlegen; Reset-Logik trocken laufen lassen und prüfen,
   welche Volumes entfernt würden.
2. Mehrzeiligen `VOL_NAME`-Fall simulieren, prüfen ob das Skript
   abbricht (Soll nach Fix: nein, iteriert sauber).

Classification: CONFIRMED (Filter- und Quoting-Fakten per Lesung und
lokaler Reproduktion bestätigt; Existenz eines kollidierenden
Fremd-Stacks auf dem Zielserver ASSUMPTION – derzeit unwahrscheinlich)

---

## F-012 – `reset-coder.sh`: Bestätigung vor dem Backup, `--force` nach Fehlschlag

Severity: HIGH

Location:
- [setup-coder.sh](../setup-coder.sh#L723-L738) – Bestätigung + Sicherungsbackup + `--force`

Problem:
Die unwiderrufliche Bestätigung (`RESET` eintippen) wird *vor* dem
Sicherungsbackup verlangt; dessen Ergebnis steht zu diesem Zeitpunkt
noch aus. Schlägt das Backup fehl, bricht das Skript ohne `--force`
korrekt ab (gut) – mit `--force` läuft es auf vorher erteilte
Bestätigung weiter und löscht Datenbank, Grafana-, Prometheus-Volumes
und `.env`, obwohl bekannt ist, dass keine (neue) Sicherung existiert.
Es gibt keine zweite, informierte Bestätigung nach Backup-Fehlschlag.

Failure scenario:
Operator tippt `RESET`, Backup schlägt fehl (Platte voll, Postgres
down), Operator wiederholt mit `--force` „um es hinter sich zu bringen“
– die einzige Datenrettung war das fehlgeschlagene Backup. Nebeneffekt:
Alte Backups unter `/opt/coder/backups` bleiben zwar erhalten
(dokumentiert), aber deren Aktualität und Gültigkeit ist ungeprüft
(F-003/F-005).

Evidence:
Ablauf per Lesung bestätigt: `read … CONFIRM` (L723) → Backup (L730) →
`--force`-Weiterlauf (L731). Kein zweiter Confirm-Pfad.

Impact:
Bewusst herbeigeführter, aber uninformierter Datenverlust; `--force`
hebelt genau die Sicherung aus, die den Reset absichern sollte.

Proposed change:
Bestätigung erst nach erfolgreichem Backup verlangen (oder nach
Fehlschlag explizit erneut bestätigen lassen, mit Anzeige des neuesten
verfügbaren Backups und dessen Alter/Größe).

Regression risk:
Gering – nur Reihenfolge/Dialog, keine Logikänderung im Löschpfad.

Test:
1. Backup absichtlich fehlschlagen lassen (Container gestoppt), ohne
   `--force` laufen lassen (muss abbrechen, nichts löschen), dann mit
   `--force` (Soll nach Fix: verlangt neue, explizite Bestätigung mit
   Backup-Statusanzeige).

Classification: CONFIRMED

---

## F-013 – `reset-coder.sh`: Workspace-Container bleiben stehen, Warnung kommt zu spät

Severity: MEDIUM

Location:
- [setup-coder.sh](../setup-coder.sh#L762-L766) – Hinweis erst am Skriptende

Problem:
Coder erzeugt Workspace-Container direkt über den Docker-Socket, nicht
über Compose – `docker compose down` erfasst sie nicht. Das Skript
warnt erst *nach* der Zerstörung (DB, Volumes, `.env` weg): „Falls vor
dem Reset Workspaces liefen … Prüfen … `docker ps -a`“. Zu diesem
Zeitpunkt sind die Workspaces verwaist (Datenbank mit ihren Metadaten
gelöscht), laufen aber weiter und kollidieren nach Neuaufbau ggf. mit
neu erzeugten Workspaces (Namens-/Netz-/Volume-Konflikte, veraltete
Images).

Failure scenario:
Reset bei laufenden Workspaces → Neuaufbau per `setup-coder.sh` →
neue Coder-Instanz kennt alte Workspace-Container nicht; alte Container
belegen Ports/Namen, Nutzerdaten in Workspace-Containern sind vom
Buchungsstand entkoppelt.

Evidence:
Hinweistext per Lesung bestätigt; `docker compose down` ohne
Workspace-Bereinigung per Lesung bestätigt.

Impact:
Unvollständige Wiederherstellung: Stack „neu“, aber Host voller
verwaister Container mit unklarem Datenstand.

Proposed change:
Vor der Löschung laufende Workspace-Container auflisten (read-only
`docker ps`) und Abbruch oder explizite Behandlung anbieten; Hinweis an
den Anfang des Skripts ziehen.

Regression risk:
Gering – nur Inventarisierung und Dialogreihenfolge.

Test:
1. Test-VM mit Dummy-Containern außerhalb von Compose: Reset trocken
   durchspielen, prüfen ob sie vorher angezeigt werden.

Classification: CONFIRMED

---

## F-014 – Caddy-Zertifikate, Grafana-Dashboards, Prometheus-Historie: nie gesichert

Severity: MEDIUM

Location:
- Compose-Volumes [setup-coder.sh](../setup-coder.sh#L275-L280)
- Reset-Warntext [setup-coder.sh](../setup-coder.sh#L713-L721)

Problem:
`caddy_data`/`caddy_config` (Let's-Encrypt-Zertifikate inkl. aller
On-Demand-Workspace-Zertifikate), `grafana_data` (Dashboards,
Datenquellen, Einstellungen) und `prometheus_data` (15-Tage-Historie)
werden nie gesichert. Der Reset löscht Grafana/Prometheus bewusst
(Warntext nennt es), Caddy-Zertifikate bleiben bewusst erhalten
(Rate-Limit-Schutz) – aber bei Serververlust ist alles weg:
Zertifikate müssen neu ausgestellt werden (DNS + Portweiterleitung
Voraussetzung, On-Demand-Erstaufruf 5–30 s Verzögerung, LE-Limit
50/Woche pro Domain – siehe Skriptkopf), Dashboards sind verloren,
Metrik-Historie beginnt bei null.

Failure scenario:
Frischer Server nach Totalausfall: Coder startet, aber jede
Workspace-Subdomain braucht ein neues Zertifikat; bei vielen
Workspace-URLs in der ersten Woche droht das Rate-Limit; Grafana ist
leer, alte Dashboards müssen neu gebaut werden.

Evidence:
Backup-Umfang (nur `pg_dump`) vs. Volume-Liste per Lesung bestätigt;
Reset-Warntext bestätigt bewusste Löschung ohne vorherige Sicherung.

Impact:
Verlängerte RTO (Zertifikats-Neuausstellung, Dashboard-Neuaufbau),
verlorene Historie. Für Prometheus (15 d Retention) akzeptabel, für
Grafana-Dashboards und Zertifikate schmerzhaft – und undokumentiert.

Proposed change:
Festlegen und dokumentieren: Zertifikate = rekonstruierbar
(Voraussetzungen DNS/Ports nennen), Grafana-Dashboards = als Code oder
per Export sichern, Prometheus = als verzichtbar deklarieren. Derzeit
ist nichts davon festgelegt.

Regression risk:
Gering – zunächst nur Festlegung/Dokumentation.

Test:
1. Frische Test-VM: Stack hochfahren, messen bis `https://…/healthz`
   200 liefert und bis N Workspace-Subdomains Zertifikate haben
   (= Zertifikats-RTO-Anteil).

Classification: CONFIRMED

---

## F-015 – Workspace-Nutzdaten (die eigentlichen Unterrichtsdaten) werden überhaupt nicht gesichert

Severity: CRITICAL

Location:
- Gesamtes Skript: kein Workspace-Backup-Pfad; Workspaces entstehen
  laufzeitseitig über den Docker-Socket
  ([setup-coder.sh](../setup-coder.sh#L762-L764))

Problem:
Der `pg_dump` sichert Coder-Metadaten (Nutzer, Templates,
Workspace-Definitionen), aber nicht die Inhalte der Workspaces
(Dateien, Repos, Hausaufgaben) – diese leben in Containern/Volumes auf
dem Host, außerhalb jedes Backups. Bei Serververlust ist genau das weg,
worum es im Schulbetrieb geht.

Failure scenario:
Vollständiger Serververlust am Semesterende: Coder-Datenbank
restauriert (theoretisch), alle Schülerarbeiten weg – unwiederbringlich,
da nie eine Kopie existierte.

Evidence:
Abwesenheit per Lesung bestätigt: kein Workspace-Volumen, kein
Datei-Backup, kein Export-Schritt im gesamten Skript.

Impact:
Größter realer Datenverlust des Szenarios „frische VM“ – größer als DB,
Dashboards und Metriken zusammen.

Proposed change:
Workspace-Backup-Strategie festlegen (Verantwortung klären: Server-Backup
vs. Nutzer-Export, z. B. Git-Push-Pflicht), dokumentieren und RPO dafür
definieren. Technisch ist das kein Einzeiler mehr – deshalb als
strategischer Punkt, nicht als Skript-Patch.

Regression risk:
Mittel bis hoch je nach Lösung (zentrales Workspace-Backup berührt
laufende Container und kann Workspaces stören) – geplant einführen, nicht
adhoc.

Test:
1. In Test-Installation Datei in Workspace anlegen, Backup + Restore
   nach Runbook durchführen, prüfen ob die Datei wieder da ist
   (Soll derzeit: nein – dokumentiert den Gap).

Classification: CONFIRMED (Abwesenheit im Code; Annahme dabei: Workspaces
halten zustandsbehaftete Nutzdaten – für Unterrichtsbetrieb plausibel,
auf dem Zielsystem nicht verifiziert → dieses Detail ASSUMPTION)

---

## F-016 – Volles Dateisystem: Backup auf die volle Platte, ohne Vorprüfung, ohne Alarm

Severity: MEDIUM

Location:
- [setup-coder.sh](../setup-coder.sh#L502-L515) (Ziel = lokale Platte)
- `prometheus.yml` ohne Alerting (siehe F-007)

Problem:
Kein `df`-Vorabcheck, kein reservierter Mindestplatz, keine
Platten-Alarmierung (node-exporter misst, niemand wertet aus).
Schlägt `gzip` an `ENOSPC` fehl, bleibt eine partielle Datei zurück
(F-003), das Skript exitt nicht-null (gut), aber die Cron-Fehlermeldung
versandet im Log (F-007). Ironie: Docker-Images, Prometheus-Daten und
unrotierte Logs (F-007) sind die wahrscheinlichsten Plattenfresser – alle
auf derselben Platte wie das Backup.

Failure scenario:
Platte läuft über Monate voll (Images durch `pull` bei jedem Update,
Log ohne Rotation). Genau dann, wenn die Sicherung am dringendsten wäre
(System instabil), schlägt sie fehl – und niemand erfährt es.

Evidence:
Kein `df`/`stat -f` im Skript (grep-bestätigt abwesend); Plattenmetriken
ohne Auswertung (Alerting-Abwesenheit per Lesung bestätigt).

Impact:
Backup-Ausfall korreliert mit System-Stress – schlechtestmögliche
Korrelation.

Proposed change:
Vor dem Dump freien Platz prüfen (gegen Schätzung/letzte Dump-Größe),
bei Unterschreitung klar abbrechen *ohne* partielle Datei; Plattenalarm
(z. B. simple `df`-Prüfung im Backup-Skript mit `logger`) einführen.

Regression risk:
Gering – zusätzliche Prüfung vor dem Schreiben.

Test:
1. Test-Partition gezielt füllen (kleines tmpfs), `backup.sh` laufen
   lassen, prüfen: keine partielle Finaldatei, klarer Fehler im Log.

Classification: LIKELY (Code-Abwesenheit CONFIRMED; ENOSPC-Ablauf nicht
am Zielsystem durchgespielt)

---

## F-017 – `reset-passwords.sh` wechselt Passwörter ohne vorheriges Backup, nicht transaktional

Severity: MEDIUM

Location:
- [setup-coder.sh](../setup-coder.sh#L612-L677) – eingebettetes `reset-passwords.sh`

Problem:
Reihenfolge: `ALTER USER … PASSWORD` in Postgres → Grafana-Reset →
erst danach `.env`-Aktualisierung per `sed -i` → Coder-Recreate.
Kein Backup vorab, keine Transaktionalität (ausführlich in `01-bash.md`
F-005): Abbruch zwischen DB-Änderung und `.env`-Schreiben hinterlässt
DB mit neuem und `.env` mit altem Passwort – jeder spätere
`compose up` (Reboot, Update) startet Coder mit falschem Passwort.
Keine Erkennungs- oder Reparaturanleitung.

Failure scenario:
SSH-Abbruch während des Resets → Stack wirkt gesund, bis zum nächsten
Reboot → Coder verbindet sich nicht mehr zur DB → Ausfall ohne
offensichtliche Ursache (Passwort-Mismatch steht in keinem Log in
Klartext, zu Recht).

Evidence:
Befehlsreihenfolge per Lesung bestätigt; kein Backup-Aufruf im Skript.

Impact:
Selbstgebauter Lockout mit verzögerter Zündung; Wiederherstellung
erfordert manuelles Setzen beider Seiten auf einen bekannten Wert.

Proposed change:
Vorab-Backup (oder mindestens `.env`-Kopie als `tmp` + atomarer `mv`),
`.env` zuerst aktualisieren oder Abbruch-Fenster per Trap mit klarer
Warnmeldung schließen.

Regression risk:
Gering – betrifft nur Fehlerpfad und Reihenfolge.

Test:
1. Test-Postgres: Skript mit Verzögerung vor `sed` ausführen, per
   `SIGTERM` abbrechen, `.env`- vs. DB-Passwort vergleichen.

Classification: LIKELY (Reihenfolge-Fakt CONFIRMED per Lesung;
Abbruch-Szenario nicht durchgespielt)

---

## F-018 – Backup hängt an implizitem Postgres-Trust (kein Passwort im `pg_dump`-Aufruf)

Severity: LOW

Location:
- [setup-coder.sh](../setup-coder.sh#L510): `docker exec coder-postgres pg_dump -U coder coder`

Problem:
Der Dump nutzt weder `PGPASSWORD` noch `.pgpass` – er verlässt sich auf
die Default-`pg_hba`-Regeln des `postgres:15-alpine`-Images (lokaler
Trust über Socket). Das funktioniert heute, ist aber eine ungesicherte,
undokumentierte Voraussetzung: Ändert sich das Image-Verhalten, wird
`pg_hba` gehärtet oder der Aufruf auf TCP umgestellt, schlägt jedes
Backup (und damit jedes Update/Reset-Sicherungsbackup) fehl – still per
Cron-Nachtlauf.

Evidence:
Aufrufzeile per Lesung bestätigt (kein Passwort-Handling); Image-
Default-Verhalten aus Upstream-Dokumentation, nicht am Zielsystem
verifiziert.

Impact:
Latente Sprengfalle für alle Backup-abhängigen Pfade.

Proposed change:
Explizit machen: entweder dokumentieren („verlässt sich auf lokalen
Trust des offiziellen Images“) oder Passwort aus `.env` robust
übergeben (ohne `ps`-Sichtbarkeit, vgl. STDIN-Muster in
`reset-passwords.sh`).

Regression risk:
Gering – Authentifizierungspfad wird nur explizit.

Test:
1. `pg_hba.conf` in Test-Postgres auf `scram-sha-256` für local
   umstellen, `backup.sh` laufen lassen, Fehlermeldung prüfen.

Classification: ASSUMPTION (hängt von Upstream-Image-Defaults ab)

---

## Aktuelle Recovery-Fähigkeit

Nachweislich vorhanden (Code-Lesung):

- Täglicher logischer Postgres-Dump (`pg_dump | gzip`, 01:00 Uhr,
  `/etc/cron.d`), Rechte sauber (`umask 077`, Verzeichnis `700`, Datei
  `600`), Pipefail korrekt gesetzt (ein `pg_dump`-Fehler bricht den Lauf
  mit nicht-null ab – kein stiller Erfolgs-Tarn).
- Setup-Testlauf mit Health-Wartezeit (bis 60 s) und Existenzprüfung.
- Pre-Update- und Pre-Reset-Sicherungsbackup (Achtung: ungeprüft, F-003).
- Reset schützt Backups und Caddy-Zertifikate bewusst vor Löschung;
  verlangt `RESET`-Bestätigung; bricht ohne `--force` bei Backup-Fehler
  ab.
- Rollback-Imagenotiz (`prune -f` statt `-a`) ist kommentiert und korrekt
  begründet.

Fazit in einem Satz: Es existiert genau eine belastbare Schicht – ein
täglicher, rechte-sauberer, aber ungeprüfter, rein lokaler
Datenbank-Dump ohne Restore-Verfahren.

## Fehlende Recovery-Fähigkeiten

- Kein Offsite, kein Medienbruch: Platten-/Serververlust = Totalverlust.
- Kein Restore-Verfahren (Skript/Doku/Test); RTO unbekannt und ungemessen.
- Keine Backup-Verifikation (`gzip -t`, Größe, Test-Restore).
- Kein atomares Schreiben; partielle Dateien unter gültigem Namen möglich.
- `.env`, Compose-/Caddy-/Prometheus-Konfiguration, Zertifikate,
  Grafana-Dashboards, Prometheus-Historie: nicht gesichert.
- Workspace-Nutzdaten: gar kein Sicherungskonzept.
- RPO/RTO-Ziele: nicht definiert; keine Frische-/Platten-Alarmierung.
- Update: kein Health-Gate, kein Migrations-Rollback-Plan.
- Reset: keine Projektsicherung der Volume-Auswahl, keine
  Nach-Fehlschlag-Bestätigung bei `--force`, keine
  Workspace-Inventarisierung vor der Löschung.
- Rotation per Alter statt Stückzahl, ohne Mindestbestand.
- Cron-Daemon weder installiert noch verifiziert; kein Overlap-Schutz;
  Log ohne Rotation und ohne Alerting.

## Entscheidende Frage

> „Kann ich mit den vorgesehenen Sicherungen einen ausgefallenen Server
> auf einer frischen Debian-13-VM wiederherstellen?“

**Nein.** Selbst im Bestfall (aktueller, gültiger Dump liegt offsite
vor – was nicht vorgesehen ist) fehlt das Verfahren (kein Runbook, kein
Restore-Skript, kein Test), fehlen `.env` und alle Konfigurationen,
müssen Zertifikate neu ausgestellt werden (DNS/Portweiterleitung,
Rate-Limit), sind Dashboards und Metrik-Historie verloren und sind alle
Workspace-Nutzdaten unwiederbringlich weg. Im wahrscheinlichen
Schlimmstfall (Dump nie offsite kopiert) existiert nach Plattenverlust
überhaupt keine Sicherung mehr. Vor einem belastbaren „Ja“ braucht es:
Offsite-Kopie, verifizierte Backups, geprobtes Restore-Runbook mit
gemessener RTO, `.env`-/Konfigurations-Sicherung und ein
Workspace-Daten-Konzept.

## Top-Prioritäten

1. **F-002** – Offsite-Kopie einführen (ohne sie ist alles andere
   Dekoration). CRITICAL, CONFIRMED.
2. **F-008** – Restore-Runbook schreiben und einmal in isolierter VM
   durchspielen (gemessene RTO). CRITICAL, CONFIRMED.
3. **F-001/F-015** – Backup-Umfang festlegen: `.env` + Konfigurationen
   sichern; Workspace-Daten-Strategie entscheiden (größter realer
   Verlust). CRITICAL, CONFIRMED.
4. **F-003** – Atomares Schreiben + `gzip -t` + Größenprüfung +
   periodischer Test-Restore (AGENTS.md-Policy). HIGH, LIKELY.
5. **F-011** – Reset-Volume-Auswahl projektscharf machen + Treffer vor
   dem Löschen anzeigen (Fremddaten-Gefahr). CRITICAL, CONFIRMED.
6. **F-012** – Bestätigung nach (nicht vor) erfolgreichem Backup;
   `--force` mit Zweitbestätigung. HIGH, CONFIRMED.
7. **F-006** – Cron-Daemon installieren/verifizieren + `flock`
   (sonst läuft ggf. nie ein Backup). HIGH, LIKELY.
8. **F-005** – Stückzahl-Rotation mit Mindestbestand statt reiner
   Alterslöschung. HIGH, CONFIRMED.
9. **F-007** – Log-Rotation + Frische-Alarmierung (sonst bleibt jeder
   Defekt still). MEDIUM, CONFIRMED.
10. **F-010** – Update-Health-Gate + dokumentierter Rollback inkl.
    Migrations-Vorbehalt. HIGH, LIKELY.
11. **F-009** – `.env` in Backup/Restore-Runbook aufnehmen (Restore
    ohne Passwort-Puzzle). HIGH, CONFIRMED.
12. **F-013/F-014/F-016/F-017/F-004/F-018** – Nachgelagert:
    Workspace-Inventar vor Reset, Zertifikats-/Dashboard-Strategie,
    `df`-Vorabcheck, Passwort-Transaktionalität, Sekunden-Timestamps,
    `pg_hba`-Annahme explizit machen.
