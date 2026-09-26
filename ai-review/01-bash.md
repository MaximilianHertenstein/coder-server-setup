# 01 – Bash-/Shell-Engineering-Review von `setup-coder.sh`

Rolle: Bash-/Shell-Engineering-Reviewer.
Geprüft: `setup-coder.sh` (844 Zeilen) inkl. der vier eingebetteten
Wartungsskripte (`backup.sh`, `update.sh`, `reset-passwords.sh`,
`reset-coder.sh`), die per Heredoc nach `/opt/coder/*.sh` geschrieben werden.
`setup-coder.sh` selbst wurde **nicht** verändert.

Werkzeuge: manuelle Analyse, `shellcheck -s bash` (Version 0.11.0) gegen
`setup-coder.sh` und gegen die vier extrahierten Heredoc-Inhalte, sowie
gezielte Reproduktion einzelner `set -e`/`pipefail`-Fälle in einer isolierten
Bash-Instanz.

Alle als „Confirmed“ markierten Befunde wurden durch Lesen des Codes und/oder
durch tatsächliche Reproduktion in einer Test-Shell verifiziert. Als
„Assumption“ markierte Punkte sind plausible, aber nicht durch Ausführung auf
dem echten Zielsystem bestätigte Risiken.

---

## F-001 – `crontab -l | grep -v … | crontab -` bricht unter `set -e`+`pipefail` bei genau einem Treffer lautlos ab

Severity: CRITICAL

Location:
- [setup-coder.sh](setup-coder.sh#L520-L525) (Schritt 6, Backup-Cronjob-Migration)
- [setup-coder.sh](setup-coder.sh#L592-L596) (Schritt 7, Update-Cronjob-Migration)
- Top-Level-`set -euo pipefail` in [setup-coder.sh](setup-coder.sh#L68)

Problem:
Beide Stellen migrieren einen alten `crontab -e`-Eintrag in die neue
`/etc/cron.d/`-Datei mit dem Muster:

```bash
if sudo crontab -l 2>/dev/null | grep -qF "/opt/coder/backup.sh"; then
  (sudo crontab -l 2>/dev/null | grep -vF "/opt/coder/backup.sh") | sudo crontab -
fi
```

Ist der alte Cronjob-Eintrag die **einzige** Zeile in der Root-Crontab (das ist
genau der dokumentierte Altlast-Fall, den dieser Code behandeln soll),
liefert `grep -v` null Zeilen und beendet sich mit Exit-Code 1 (kein Treffer
"ausgewählt"). Diese Teil-Pipeline steht in einer Subshell `( … )`, die selbst
wieder in eine äußere Pipe zu `sudo crontab -` mündet. Mit `pipefail` gilt für
die gesamte zusammengesetzte Pipeline: der Exit-Code ist der am weitesten
rechts stehende *nicht-null* Code unter allen Pipeline-Gliedern – nicht nur
der des letzten Glieds. Da `sudo crontab -` selbst erfolgreich mit Code 0
endet, aber `grep -v` (Code 1) weiter links in der Kette liegt, wird der
Gesamtstatus der Anweisung dennoch 1. Unter `set -e` beendet das
das komplette `setup-coder.sh` sofort, ohne jede Fehlermeldung, direkt nach
der (bereits erfolgreich durchgeführten!) Crontab-Bereinigung.

Das widerspricht direkt der im Skriptkopf gemachten Aussage
"Skript ist mehrfach ausführbar (idempotent) – einfach erneut laufen lassen"
([setup-coder.sh](setup-coder.sh#L25)): Bei genau dieser Alt-Migrations-Konstellation
ist ein Re-Run *nicht* harmlos, sondern bricht mitten in Schritt 6 bzw. 7 ab,
sodass Schritt 7–10 (inkl. Passwort-Reset-Skript, Reset-Skript und
Abschlusscheck) in diesem Lauf gar nicht mehr ausgeführt werden – ohne
sichtbare Fehlermeldung, nur mit stillem Exit-Code 1 des Gesamtskripts.

Evidence (reproduziert in isolierter Bash-Instanz, identisches Muster):

```bash
$ bash -c '
set -euo pipefail
echo "before"
if printf "%s\n" "/opt/coder/backup.sh" | grep -qF "/opt/coder/backup.sh"; then
  (printf "%s\n" "/opt/coder/backup.sh" | grep -vF "/opt/coder/backup.sh") | cat
fi
echo "after"
'
before
```

`"after"` wird nie ausgegeben – die Shell wurde durch `set -e` beendet, exakt
an der Stelle des beschriebenen Musters. Status: **Confirmed** (reproduziert).

Impact:
- Stiller Abbruch mitten im produktiven Setup-Lauf, ohne Fehlermeldung außer
  dem nackten Exit-Code.
- Bei Betroffenheit von Schritt 6 (Backup-Migration): Schritt 7–10 laufen in
  diesem Aufruf nicht – `update.sh`, `reset-passwords.sh`, `reset-coder.sh`
  werden nicht (neu) bereitgestellt, kein Abschlusscheck, keine
  Zusammenfassung.
- Bei Betroffenheit von Schritt 7 (Update-Migration): Schritt 8–10 laufen
  nicht.
- Widerspricht der dokumentierten Idempotenz-Zusicherung im Kopfkommentar.

Proposed change:
Den Pipeline-Exitcode für den beabsichtigten "leer ist ok"-Fall explizit
abfangen, z. B.:

```bash
(sudo crontab -l 2>/dev/null | grep -vF "/opt/coder/backup.sh" || true) | sudo crontab -
```

oder die Ersetzung ganz ohne Pipe/Subshell-Kombination lösen (z. B. Ergebnis
zuerst in eine Variable/Datei schreiben, dann `crontab` separat aufrufen),
damit `set -e`/`pipefail` nicht auf einen aus fachlicher Sicht harmlosen
"0 verbleibende Zeilen"-Zustand reagieren.

Regression risk: Gering – reine Fehlerbehandlungs-Korrektur, ändert das
Verhalten im Erfolgsfall (Zeilen vorhanden) nicht.

Test:
1. `printf '* * * * * root /opt/coder/backup.sh\n' | sudo crontab -`
   (simuliert exakt eine Alt-Zeile).
2. `setup-coder.sh` (bzw. den migrierenden Code-Ausschnitt isoliert) mit
   `bash -x` laufen lassen und beobachten, ob Schritt 7–10 weiterhin
   ausgeführt werden.
3. `echo $?` nach Skriptende prüfen (muss 0 sein, wenn keine anderen Fehler
   vorliegen).

---

## F-002 – `.env`-Geheimnisdatei wird nicht atomar geschrieben; Idempotenz-Check prüft nur Existenz, nicht Integrität

Severity: HIGH

Location:
- [setup-coder.sh](setup-coder.sh#L134-L152) (Schritt 2)

Problem:
```bash
if [ ! -f /opt/coder/.env ]; then
  POSTGRES_PASSWORD=$(openssl rand -hex 24)
  GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 16)
  sudo tee /opt/coder/.env > /dev/null <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
DOCKER_GID=${DOCKER_GID}
EOF
  sudo chmod 600 /opt/coder/.env
  ...
```
`tee` schreibt direkt in die Zieldatei, kein Schreiben in eine temporäre Datei
mit anschließendem atomarem `mv`. Wird der Prozess während des `tee`-Aufrufs
unterbrochen (SIGINT/SIGTERM, Stromausfall, OOM-Kill, Verbindungsabbruch bei
SSH-Sitzung), bleibt eine leere oder unvollständige `.env` zurück. Beim
nächsten Lauf prüft `[ ! -f /opt/coder/.env ]` nur, **ob** die Datei
existiert – nicht, ob sie vollständig/gültig ist. Der Zweig
"existiert bereits – wird nicht überschrieben" greift dann fälschlich, und
`docker compose up -d` in Schritt 3 startet mit fehlenden/leeren
Umgebungsvariablen (`POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`,
`DOCKER_GID`) weiter.

Zusätzlich entsteht ein kurzes Zeitfenster zwischen dem Anlegen der Datei
durch `sudo tee` (Rechte gemäß aktivem `umask`, bei root-Standard-umask 022
also `644` – für alle lokalen Nutzer lesbar) und dem nachträglichen
`sudo chmod 600`. In diesem Fenster liegen Postgres- und
Grafana-Admin-Passwort im Klartext lesbar auf der Platte.

Evidence: Code-Lesung, kein produktiver Testlauf durchgeführt (Confirmed als
Code-Fakt; Ausnutzbarkeit/Timing als Assumption, da abhängig von
Systemlast/Signal-Timing).

Impact:
- Bei unterbrochenem Erstlauf: dauerhaft kaputte, aber "vorhandene" `.env`;
  Re-Runs "reparieren" das Problem nicht automatisch, weil der Existenz-Check
  greift. Widerspricht der Idempotenz-Zusicherung im Kopfkommentar.
- Kurzes, aber reales Zeitfenster mit weltlesbaren Secrets auf dem Dateisystem.

Proposed change:
- Secrets über `umask 077` (vor dem `tee`) oder direkt mit `install -m 600`
  bzw. `mktemp` + `mv` (atomar, gleiche Zielverzeichnis-Partition) schreiben,
  sodass die Datei nie mit falschen Rechten existiert.
- Idempotenz-Check verschärfen, z. B. zusätzlich prüfen, dass alle drei
  erwarteten Schlüssel (`POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`,
  `DOCKER_GID`) nicht-leer in der Datei stehen, bevor sie als "bereits
  vorhanden" akzeptiert wird.

Regression risk: Gering bis mittel – Änderung der Schreibreihenfolge/Prüfung
sollte den Erfolgsfall (frischer Server, kein Interrupt) nicht beeinflussen.

Test:
1. Skript mit `kill -TERM` exakt während des `.env`-`tee`-Aufrufs unterbrechen
   (z. B. via `strace`/`sleep`-Injektion oder gezieltem `SIGSTOP` kurz vor dem
   Schreiben) und prüfen, ob eine leere/unvollständige `.env` entsteht.
2. Skript erneut laufen lassen und prüfen, ob es die defekte `.env`
   akzeptiert oder repariert.
3. `stat -c '%a' /opt/coder/.env` unmittelbar nach dem `tee`-Aufruf in einer
   Testumgebung mit `umask 022` beobachten (vor `chmod`).

---

## F-003 – Backups: kein atomares Schreiben, keine Integritätsprüfung, Widerspruch zur Backup-Policy in AGENTS.md

Severity: HIGH

Location:
- [setup-coder.sh](setup-coder.sh#L503-L515) (eingebettetes `backup.sh`, Schritt 6)
- [setup-coder.sh](setup-coder.sh#L546-L557) (Testlauf-Auswertung)

Problem:
```bash
docker exec coder-postgres pg_dump -U coder coder | gzip > "${BACKUP_DIR}/coder_${TIMESTAMP}.sql.gz"
```
Es wird direkt in den finalen Zieldateinamen geschrieben, nicht in eine
temporäre Datei mit anschließendem atomarem `mv`. Bricht `pg_dump` mitten im
Stream ab (DB-Verbindung weg, Container neu gestartet, Platte voll), bleibt
eine unvollständige `.sql.gz`-Datei exakt unter dem für diesen Lauf
vorgesehenen, eindeutigen Zeitstempel-Namen liegen – nicht unter einem
`.tmp`-Namen, der sich leicht aussortieren ließe. `set -euo pipefail` sorgt
zwar dafür, dass der `backup.sh`-Aufruf selbst mit Fehler endet (das Cronjob-
Log bekommt also einen Fehler zu sehen), verhindert aber nicht, dass die
kaputte Datei im Verzeichnis verbleibt.

Die einzige Erfolgsprüfung im Skript ist:
```bash
LATEST_BACKUP=$(ls -t /opt/coder/backups/coder_*.sql.gz 2>/dev/null | head -n1 || true)
if [ -n "${LATEST_BACKUP:-}" ]; then
  ok "Testlauf erfolgreich, Backup-Datei angelegt: ${LATEST_BACKUP}"
```
Das prüft nur "existiert eine Datei", nicht "ist der Inhalt ein gültiges,
wiederherstellbares Gzip/SQL-Dump" (z. B. via `gzip -t` oder testweisem
Einspielen). Für die täglichen Cron-Läufe (`/etc/cron.d/coder-backup`) gibt
es überhaupt keine automatisierte Validierung – nur das Umleiten von
stdout/stderr in `/var/log/coder-backup.log`.

Das steht in direktem Widerspruch zur in [AGENTS.md](AGENTS.md) festgelegten
Projekt-Policy: "Ein erfolgreiches Backup-File ist kein ausreichender Beweis
für ein erfolgreiches Backup. Restore-Tests sind erforderlich." – aktuell
prüft weder das Setup-Skript noch der Cronjob mehr als "Datei existiert".

Evidence: Code-Lesung (Confirmed für das Fehlen von Atomarität/Validierung).
Dass ein realer Absturz mitten im `pg_dump`-Stream in der Praxis auftritt, ist
eine Annahme (plausibel, aber nicht auf dem Zielsystem reproduziert).

Impact:
- Ein fehlgeschlagener nächtlicher Cronjob kann eine defekte, aber
  gleichnamige `.sql.gz`-Datei hinterlassen, die bei einem Restore-Versuch
  Wochen später als "das letzte Backup" erscheint, aber unbrauchbar ist.
- Widerspricht der ausdrücklichen Restore-Test-Anforderung aus AGENTS.md.

Proposed change:
- In eine temporäre Datei im selben Verzeichnis schreiben (`*.sql.gz.tmp` /
  `mktemp` im `BACKUP_DIR`) und erst nach Erfolg per `mv` atomar auf den
  finalen Namen umbenennen.
- Nach dem Schreiben `gzip -t` auf die fertige Datei anwenden, bevor sie als
  Erfolg gewertet wird; bei Fehlschlag Datei löschen und Exit-Code ungleich 0
  liefern.
- Perspektivisch (nicht Teil dieses Befunds, nur Hinweis): regelmäßigen
  Restore-Test gemäß AGENTS.md-Policy ergänzen.

Regression risk: Gering – zusätzlicher Validierungsschritt, ändert das
Verhalten im Erfolgsfall nicht, außer minimal längerer Laufzeit.

Test:
1. `pg_dump` durch ein Fake-Kommando ersetzen, das nach N Bytes mit Fehler
   abbricht (`head -c 1000; false`), backup.sh laufen lassen, prüfen ob eine
   Datei mit dem "sauberen" Endnamen zurückbleibt.
2. Nach vorgeschlagener Änderung denselben Testfall wiederholen: Datei darf
   nicht unter dem finalen Namen erscheinen bzw. `gzip -t` muss den Fehler vor
   dem `ok`-Report erkennen.

---

## F-004 – `reset-coder.sh`: Volume-Auswahl beim Löschen ist nicht auf das Coder-Compose-Projekt eingeschränkt und bricht bei Mehrfachtreffern

Severity: MEDIUM

Location:
- [setup-coder.sh](setup-coder.sh#L744-L753) (eingebettetes `reset-coder.sh`, Schritt 9)

Problem:
```bash
for VOL_LABEL in postgres_data grafana_data prometheus_data; do
  VOL_NAME=$(docker volume ls -q --filter "label=com.docker.compose.volume=${VOL_LABEL}")
  if [ -n "${VOL_NAME}" ]; then
    docker volume rm "${VOL_NAME}"
  fi
done
```
Der Filter verwendet ausschließlich das Label
`com.docker.compose.volume=<name>`, nicht zusätzlich
`com.docker.compose.project=coder`. Docker Compose vergibt dieses Label rein
nach dem kurzen Volume-Schlüssel aus der `docker-compose.yml`
(`postgres_data`, `grafana_data`, `prometheus_data`), unabhängig vom
Compose-Projektnamen. Läuft auf demselben Host irgendwann ein weiteres
Compose-Projekt mit einem Volume, das zufällig denselben kurzen Namen trägt
(diese drei Namen sind sehr generisch und in vielen Compose-Beispielen
üblich), würde der Filter auch dessen Volume zurückliefern.

Zusätzlich, unabhängig vom obigen Punkt: Liefert der Filter mehr als eine
Zeile zurück, enthält `VOL_NAME` mehrere durch Zeilenumbruch getrennte
Volume-Namen. `docker volume rm "${VOL_NAME}"` übergibt das wegen der
Anführungszeichen als **ein** Argument mit eingebettetem Zeilenumbruch statt
als mehrere Argumente – `docker volume rm` kennt kein Volume mit diesem Namen
und bricht mit Fehler ab, was unter `set -euo pipefail` das gesamte
`reset-coder.sh` beendet (mitten im destruktiven Reset-Vorgang, nachdem der
Stack bereits per `docker compose down` gestoppt wurde).

Evidence: Code-Lesung (Confirmed für fehlende Projekt-Einschränkung und für
die Quoting-Schwäche bei Mehrfachtreffern). Ob auf dem konkreten
Produktionsserver aktuell ein zweites Compose-Projekt mit kollidierendem
Volume-Namen existiert, ist unbekannt/Annahme – aktuell vermutlich ein
Einzelserver nur für Coder, daher geringe reale Trefferwahrscheinlichkeit.

Impact:
- Geringe, aber reale Möglichkeit, bei zukünftiger Erweiterung des Servers um
  weitere Docker-Compose-Stacks fremde Volumes zu löschen.
- Bei Mehrfachtreffern bricht das Reset-Skript mit Fehler ab statt sauber
  aufzuräumen.

Proposed change:
Filter zusätzlich auf das Projekt einschränken, z. B.
`--filter "label=com.docker.compose.project=coder" --filter "label=com.docker.compose.volume=${VOL_LABEL}"`,
und `VOL_NAME` als Array/Zeilen-für-Zeile verarbeiten (`while IFS= read -r vol; do docker volume rm "$vol"; done`),
statt als einzelnen quotierten String.

Regression risk: Gering – schärfere Filterung und robustere Iteration ändern
das Verhalten im Normalfall (genau ein Treffer pro Label) nicht.

Test:
1. Zwei Testvolumes mit demselben `com.docker.compose.volume`-Label, aber
   unterschiedlichem `com.docker.compose.project`-Label anlegen.
2. `reset-coder.sh` (isoliert, gegen Test-Volumes) laufen lassen und prüfen,
   welches/welche Volumes tatsächlich entfernt werden.

---

## F-005 – `reset-passwords.sh`: Passwortwechsel in Postgres und Persistierung in `.env` sind nicht transaktional

Severity: MEDIUM

Location:
- [setup-coder.sh](setup-coder.sh#L635-L672) (eingebettetes `reset-passwords.sh`, Schritt 8)

Problem:
Die Reihenfolge ist: (1) `ALTER USER coder WITH PASSWORD …` gegen die laufende
Postgres-Instanz ausführen, (2) Grafana-Admin-Passwort zurücksetzen, (3) erst
danach `.env` per `sed -i` mit den neuen Werten aktualisieren, (4) den
`coder`-Container mit `--no-deps` neu erstellen. Wird der Prozess zwischen
Schritt (1) und Schritt (3) unterbrochen (Netzwerkabbruch der SSH-Sitzung,
Ctrl-C, Absturz), ist das tatsächliche Postgres-Passwort bereits geändert,
`.env` enthält aber weiterhin das **alte** Passwort. Ein späterer, davon
unabhängiger `docker compose up -d` (z. B. nach Reboot oder durch
`update.sh`) verbindet Coder dann mit dem falschen Passwort aus `.env`, und
der Coder-Container kann die Datenbank nicht mehr erreichen – ohne dass
`reset-passwords.sh` selbst dafür eine Wiederherstellungs- oder
Warnmechanik anbietet.

Evidence: Code-Lesung (Confirmed für die fehlende Atomarität/Reihenfolge-
Abhängigkeit). Dass ein Abbruch genau in diesem Fenster in der Praxis
passiert, ist eine Annahme – das Fenster ist aber nicht extrem kurz (zwei
`docker exec`-Aufrufe liegen dazwischen), reale Wahrscheinlichkeit also nicht
vernachlässigbar bei manueller, interaktiver Ausführung über SSH.

Impact:
- Inkonsistenter Zustand zwischen tatsächlichem DB-Passwort und dem in
  `.env` gespeicherten Wert, ohne automatische Erkennung.
- Wiederherstellung erfordert manuelles Nachvollziehen, welches Passwort
  zuletzt tatsächlich gesetzt wurde.

Proposed change:
`.env` unmittelbar **vor** dem `ALTER USER`-Aufruf mit dem neuen Passwort
aktualisieren (oder zumindest so nah wie möglich davor), sodass im Fehlerfall
eher `.env` und DB gemeinsam auf dem neuen Stand sind, oder ein Rollback-Pfad
ergänzt wird, der bei einem Fehler nach Schritt (1) explizit auf die
Inkonsistenz hinweist (z. B. durch eine `trap`, die bei vorzeitigem Abbruch
nach dem `ALTER USER`, aber vor dem `sed -i`, eine deutliche Warnung auf
stderr ausgibt).

Regression risk: Gering – Reihenfolgeänderung betrifft nur den Fehlerfall,
der Erfolgspfad bleibt unverändert.

Test:
1. `reset-passwords.sh` mit einem künstlich verzögerten `sed -i` (z. B. Skript
   kopieren und `sleep 5` vor den `sed`-Aufrufen einfügen) starten und in
   diesem Fenster per `SIGTERM` abbrechen.
2. Prüfen, ob `.env` noch das alte Passwort enthält, während Postgres bereits
   das neue akzeptiert (`docker exec coder-postgres psql -U coder …` mit
   beiden Passwörtern testen).

---

## F-006 – ShellCheck-Befunde (Info/Warnung) und fehlender Zeilenumbruch am Dateiende

Severity: LOW

Location:
- [setup-coder.sh](setup-coder.sh#L111) – SC1091 (Info): `. /etc/os-release`
  wird von ShellCheck nicht verfolgt. Kein echtes Problem, nur ein Hinweis;
  Inhalt/Verhalten von `/etc/os-release` auf Debian 13 ist Standard.
- [setup-coder.sh](setup-coder.sh#L543) – SC2034 (Warnung): `i` in
  `for i in $(seq 1 30); do … done` wird nie gelesen, nur als Zähler für die
  Anzahl der Wiederholungen benutzt.
- [setup-coder.sh](setup-coder.sh#L548) – SC2012 (Info): `ls -t
  .../coder_*.sql.gz | head -n1` statt `find`. Aktuell unkritisch, da die
  Dateinamen ausschließlich vom Skript selbst über `TIMESTAMP=$(date
  +%Y-%m-%d_%H%M)` erzeugt werden (keine Sonderzeichen/Zeilenumbrüche zu
  erwarten).
- Dateiende von `setup-coder.sh`: letzte Zeile (`fi`) hat keinen
  abschließenden Zeilenumbruch (verifiziert mit `tail | cat -A`).

Problem: Rein stilistische/robustheitsbezogene Hinweise ohne aktuellen
funktionalen Fehler.

Evidence: `shellcheck -s bash setup-coder.sh` (Version 0.11.0), Ausgabe siehe
oben; `tail -c` Prüfung auf fehlenden Zeilenumbruch. Confirmed.

Impact: Minimal. Fehlender Zeilenumbruch kann bei manchen Tools/`cat`-
Verkettungen zu verklebten Zeilen führen; die SC2034/SC2012-Hinweise sind
Best-Practice-Verbesserungen ohne aktuellen Bug.

Proposed change:
- `for i in $(seq 1 30)` zu `for _ in $(seq 1 30)` ändern (Absicht klarer).
- Optional `find "${BACKUP_DIR}" -maxdepth 1 -name 'coder_*.sql.gz' -printf '%T@ %p\n' | sort -rn | head -n1 | cut -d' ' -f2-` statt `ls -t`.
- Abschließenden Zeilenumbruch am Dateiende ergänzen.

Regression risk: Keins (rein kosmetisch/robustheitssteigernd).

Test: `shellcheck -s bash setup-coder.sh` erneut laufen lassen, es sollte
keine Warnungen mehr geben; `tail -c1 setup-coder.sh | xxd` zeigt `0a`.

---

## F-007 – `reset-passwords.sh`: altes Postgres-Passwort aus `.env` wird ungeprüft in einen Heredoc an die Container-Shell interpoliert

Severity: INFO

Location:
- [setup-coder.sh](setup-coder.sh#L635-L653) (eingebettetes `reset-passwords.sh`)

Problem:
```bash
OLD_PG_PW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
...
docker exec -i coder-postgres sh <<INNER_EOF
export PGPASSWORD="${OLD_PG_PW}"
psql -U coder -d coder -c "ALTER USER coder WITH PASSWORD '${NEW_PG_PW}';"
INNER_EOF
```
Der Heredoc ist unquotiert (`<<INNER_EOF`, nicht `<<'INNER_EOF'`), daher
ersetzt die äußere (Host-)Shell `${OLD_PG_PW}` und `${NEW_PG_PW}` bereits vor
dem Versand an die Container-`sh`. `NEW_PG_PW` stammt garantiert aus
`openssl rand -hex …` (nur `0-9a-f`) und ist unkritisch. `OLD_PG_PW` stammt
dagegen aus dem Inhalt von `.env` – das Skript selbst erzeugt dort ebenfalls
nur Hex-Werte, aber falls `.env` jemals manuell mit einem Passwort editiert
wurde, das ein `"`- oder `'`-Zeichen enthält, würde das die
`export PGPASSWORD="…"`-Zeile bzw. den `psql -c "…"`-String syntaktisch
aufbrechen (Fehler in der Container-Shell, kein Angriff auf den Host, da alles
innerhalb des `docker exec`-Aufrufs bleibt).

Evidence: Code-Lesung. Confirmed als theoretische Schwachstelle; nicht
ausnutzbar über den regulären Skript-Pfad, da `.env` ausschließlich von
diesem Skript-Satz mit garantiert alphanumerischen Hex-Werten befüllt wird.

Impact: Sehr gering im aktuellen Betrieb; reine Verteidigung-in-die-Tiefe-
Lücke für den hypothetischen Fall einer manuell editierten `.env`.

Proposed change: Werte statt per String-Interpolation über Umgebungsvariablen
an die Container-Shell übergeben (`docker exec -i -e OLD_PG_PW -e NEW_PG_PW
coder-postgres sh -c '...'` mit `$OLD_PG_PW`/`$NEW_PG_PW` erst innerhalb der
einfach gequoteten `-c`-Zeichenkette expandiert), um Interpolation in
SQL-/Shell-Syntax generell auszuschließen.

Regression risk: Gering, betrifft nur Übergabemechanik der Werte.

Test: `.env` testweise mit `POSTGRES_PASSWORD=abc'def` befüllen (nur in
Testumgebung!) und prüfen, ob `reset-passwords.sh` sauber fehlschlägt oder ob
es zu unerwartetem SQL/Shell-Verhalten kommt.

---

## Nicht bestätigte Punkte / bewusst nicht als Befund aufgenommen

- **Docker-Repository-Unterstützung für "trixie"**: Zeile
  [setup-coder.sh](setup-coder.sh#L108-L112) verwendet
  `$(. /etc/os-release && echo "$VERSION_CODENAME")` zur Auswahl der
  Docker-APT-Distribution. Stichprobenartige Prüfung von
  `https://download.docker.com/linux/debian/dists/` zeigt aktuell (Stand
  dieser Analyse) einen vorhandenen `trixie`-Distributionszweig – aktuell kein
  Befund, aber dies ist ein zeitabhängiger externer Zustand (kein Code-Fakt)
  und sollte bei zukünftigen Debian-Major-Wechseln erneut geprüft werden.
- **`set -Eeuo pipefail` vs. tatsächlich verwendetes `set -euo pipefail`**:
  Das `-E`-Flag (`errtrace`) fehlt in allen fünf Skripten. Da nirgends ein
  `trap … ERR` gesetzt ist, hat das Fehlen von `-E` aktuell keine
  beobachtbare Auswirkung. Kein eigener Befund, da kein aktueller
  Fehlerbehandlungscode davon betroffen ist – nur als Hinweis für den Fall,
  dass künftig ein `ERR`-Trap ergänzt wird (dann würde `-E` benötigt, damit er
  auch in Funktionen/Subshells greift).
- **`[ … ] && break` in der Healthcheck-Warteschleife**
  ([setup-coder.sh](setup-coder.sh#L543-L545)): geprüft und in einer
  Test-Shell reproduziert – dieses Muster ist unter `set -e` **sicher**, da
  ein fehlschlagender, nicht-letzter Teil einer `&&`/`||`-Liste laut
  Bash-Semantik von `set -e` ausgenommen ist. Kein Befund.

Kein weiterer belastbarer Befund zu Word-Splitting, Globbing, allgemeinem
Quoting oder Exit-Code-Weitergabe außerhalb der oben genannten Stellen
gefunden; die übrige Variablennutzung ist durchgehend korrekt quotiert
(`"${VAR}"`), und Kommandosubstitutionen außerhalb der genannten Fälle stehen
korrekt entweder in `if`/`while`-Bedingungen oder sind explizit mit `|| true`
abgesichert.
