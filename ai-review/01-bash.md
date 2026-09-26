# 01 – Bash-/Shell-Engineering-Review von `setup-coder.sh`

Rolle: Senior Bash / Shell Engineering Reviewer.
Geprüft: `setup-coder.sh` (844 Zeilen, `set -euo pipefail`), inkl. der vier
eingebetteten Wartungsskripte, die per Heredoc nach `/opt/coder/*.sh`
geschrieben werden: `backup.sh`, `update.sh`, `reset-passwords.sh`,
`reset-coder.sh`. Ebenfalls gesichtet: [AGENTS.md](../AGENTS.md) und
[copilot-instructions.md](../copilot-instructions.md) als bestehende
Repository-Instruktionen.

`setup-coder.sh` wurde **nicht** verändert. Es wurde ausschließlich diese
Datei (`ai-review/01-bash.md`) bearbeitet.

## Methodik

- Vollständige manuelle Lesung des Skripts (alle 844 Zeilen) und aller vier
  eingebetteten Wartungsskripte.
- Statische Analyse mit `shellcheck -s bash` (Version 0.11.0), einmal gegen
  die Hauptdatei, einmal gegen jedes der vier extrahierten Heredoc-Skripte
  (in temporäre Dateien unter `/tmp/sc-review/` kopiert, nur lokal, keine
  Änderung am Repository).
- Gezielte, isolierte Reproduktion einzelner `set -e`/`pipefail`- und
  Quoting-Fragestellungen in einer separaten Bash-Instanz (kein Bezug zum
  Zielsystem, keine produktiven Befehle).
- Ein Live-Netzwerkcheck (`https://download.docker.com/linux/debian/dists/`)
  zur Prüfung der Debian-13("trixie")-Repo-Verfügbarkeit für Docker.

„Classification“ pro Befund:
- **CONFIRMED**: Mechanismus wurde tatsächlich reproduziert (Code-Test oder
  Tool-Lauf), nicht nur gedanklich hergeleitet.
- **LIKELY**: Der Code-Fakt ist durch Lesen zweifelsfrei nachweisbar, das
  konkrete Auslöse-Szenario auf dem Produktivsystem wurde aber nicht
  ausgeführt/reproduziert.
- **ASSUMPTION**: Plausible Vermutung ohne belastbaren Nachweis im Code oder
  durch Test.

---

## F-001 – Crontab-Migrationspipeline bricht unter `set -e`+`pipefail` bei genau einem Treffer lautlos ab

Severity: CRITICAL

Location:
- [setup-coder.sh](../setup-coder.sh#L520-L525) – Schritt 6, `backup.sh`-Cron-Migration
- [setup-coder.sh](../setup-coder.sh#L592-L596) – Schritt 7, `update.sh`-Cron-Migration
- [setup-coder.sh](../setup-coder.sh#L68) – globales `set -euo pipefail`

Problem:
Beide Stellen migrieren einen alten `crontab -e`-Eintrag in die neue
`/etc/cron.d/`-Datei mit dem Muster `(crontab -l | grep -v X) | crontab -`.
Ist `X` die **einzige** Zeile in der Root-Crontab – genau der Altlast-Fall,
den der Code behandeln soll – liefert `grep -v` null Zeilen und beendet sich
mit Exit-Code 1. Unter `pipefail` gilt für die gesamte Pipeline (inklusive
der inneren Subshell-Pipe) als Exit-Code der am weitesten rechts stehende
*nicht-null* Code über alle Glieder hinweg, nicht nur der des letzten Glieds.
Der äußere `sudo crontab -` (rechtes Ende) liefert zwar 0, aber `grep -v`
(Code 1) liegt weiter links und bestimmt trotzdem den Gesamtstatus. Unter
`set -e` beendet das sofort das komplette `setup-coder.sh`, direkt nach der
(inhaltlich bereits erfolgreich durchgeführten!) Crontab-Bereinigung, ohne
jede Fehlermeldung.

Das widerspricht der Zusicherung im Kopfkommentar
"Skript ist mehrfach ausführbar (idempotent)"
([setup-coder.sh](../setup-coder.sh#L25)): Genau bei dieser
Migrations-Konstellation ist ein Re-Run *nicht* harmlos.

Evidence (reproduziert):
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
`"after"` erscheint nie – die Shell wurde durch `set -e` beendet.

Impact:
- Stiller Abbruch mitten im produktiven Setup-Lauf.
- Bei Auslösung in Schritt 6: Schritte 7–10 (`update.sh`, `reset-passwords.sh`,
  `reset-coder.sh`, Abschlusscheck) laufen in diesem Aufruf nicht.
- Bei Auslösung in Schritt 7: Schritte 8–10 laufen nicht.
- Widerspricht der dokumentierten Idempotenz-Zusicherung.

Proposed change:
Den "0 verbleibende Zeilen"-Fall explizit tolerieren, z. B.
`(sudo crontab -l 2>/dev/null | grep -vF "/opt/coder/backup.sh" || true) | sudo crontab -`,
oder ohne verschachtelte Pipe/Subshell lösen (Zwischenergebnis in Variable,
dann separater `crontab`-Aufruf).

Regression risk: Gering – reine Fehlerbehandlungskorrektur, Verhalten im
Fall "mehrere verbleibende Zeilen" bleibt unverändert.

Test:
1. `printf '* * * * * root /opt/coder/backup.sh\n' | sudo crontab -` (simuliert
   genau eine Alt-Zeile) in einer Testumgebung.
2. Den migrierenden Codeblock isoliert mit `bash -x` laufen lassen, prüfen ob
   nachfolgende Schritte weiterhin ausgeführt werden, und `echo $?` prüfen.

Classification: CONFIRMED (Mechanismus reproduziert, exakt dasselbe Muster
wie im Skript).

---

## F-002 – `.env`-Geheimnisdatei: kein atomares Schreiben, Idempotenz-Check prüft nur Existenz

Severity: HIGH

Location:
- [setup-coder.sh](../setup-coder.sh#L134-L152) – Schritt 2

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
```
`tee` schreibt direkt in die Zieldatei statt in eine temporäre Datei mit
anschließendem atomarem `mv`. Wird der Prozess während des Schreibens
unterbrochen (SIGINT/SIGTERM, SSH-Abbruch, OOM-Kill, Stromausfall), bleibt
eine leere/unvollständige `.env` zurück. Der Idempotenz-Check
`[ ! -f /opt/coder/.env ]` prüft nur Existenz, nicht Vollständigkeit/Gültigkeit
– ein Re-Run akzeptiert die kaputte Datei stillschweigend als "bereits
konfiguriert".

Zusätzlich entsteht ein Zeitfenster zwischen Dateierzeugung durch `tee`
(Rechte gemäß aktivem `umask`) und dem nachträglichen `chmod 600`, in dem die
Klartext-Passwörter je nach Host-`umask` breiter lesbar sind als beabsichtigt.

Evidence:
- Code-Lesung bestätigt fehlendes Temp-Datei+`mv`-Muster und den reinen
  Existenz-Check (CONFIRMED als Code-Fakt).
- Lokal verifiziert, dass ein mit Standard-`umask 022` neu angelegtes File
  vor einem expliziten `chmod` mit Modus `644` existiert:
  ```
  $ umask; bash -c 'umask 022; touch f; stat -c "%a" f'
  0022
  644
  ```
  (generischer Unix-Mechanismus, bestätigt das Zeitfenster-Argument, nicht
  spezifisch auf dem Zielserver gemessen).
- Die eigentliche Unterbrechung mitten im `tee`-Schreibvorgang auf dem
  Zielsystem wurde nicht durchgeführt (kein produktiver Eingriff erlaubt).

Impact:
- Bei unterbrochenem Erstlauf: dauerhaft kaputte, aber "vorhandene" `.env`;
  `docker compose up -d` in Schritt 3 startet mit fehlenden/leeren
  Umgebungsvariablen weiter.
- Kurzes, reales Zeitfenster mit breiter lesbaren Secrets auf der Platte.

Proposed change:
- Vor dem Schreiben `umask 077` setzen oder direkt mit `install -m 600` bzw.
  `mktemp` (gleiche Zielpartition) + `mv` atomar schreiben.
- Idempotenz-Check verschärfen: prüfen, dass alle drei erwarteten Schlüssel
  nicht-leer vorhanden sind, statt nur Datei-Existenz.

Regression risk: Gering bis mittel – ändert Schreibreihenfolge/Prüfung, sollte
den unveränderten Erfolgsfall nicht beeinflussen.

Test:
1. Skript-Ausschnitt mit gezieltem Abbruch (`kill -TERM`) während des
   `tee`-Aufrufs in einer Testumgebung ausführen, Zustand der `.env` danach
   prüfen.
2. `stat -c '%a'` unmittelbar nach `tee`, vor `chmod`, in einer
   `umask 022`-Umgebung beobachten.

Classification: LIKELY (Code-Defekt bestätigt gelesen und Umask-Mechanismus
lokal reproduziert; die konkrete Unterbrechungs-Szene selbst nicht am Skript
durchgespielt).

---

## F-003 – Backups: kein atomares Schreiben, keine Integritätsprüfung – Widerspruch zur Backup-Policy in AGENTS.md

Severity: HIGH

Location:
- [setup-coder.sh](../setup-coder.sh#L503-L515) – eingebettetes `backup.sh`
- [setup-coder.sh](../setup-coder.sh#L546-L557) – Testlauf-Auswertung in Schritt 6

Problem:
```bash
docker exec coder-postgres pg_dump -U coder coder | gzip > "${BACKUP_DIR}/coder_${TIMESTAMP}.sql.gz"
```
Es wird direkt in den finalen, für diesen Lauf eindeutigen Zieldateinamen
geschrieben statt in eine temporäre Datei mit anschließendem atomarem `mv`.
Bricht `pg_dump`/`gzip` mitten im Stream ab, bleibt eine unvollständige Datei
exakt unter dem "sauberen" Namen liegen. `set -euo pipefail` sorgt zwar dafür,
dass `backup.sh` selbst mit Fehler endet, verhindert aber nicht, dass die
kaputte Datei im Verzeichnis verbleibt.

Die einzige im Skript vorhandene Erfolgsprüfung ist Existenz der Datei
(`ls -t … | head -n1`), nicht Inhaltsvalidität (kein `gzip -t`, kein
Test-Restore). Für die täglichen Cron-Läufe existiert überhaupt keine
automatisierte Validierung.

Das steht im Widerspruch zur Policy aus [AGENTS.md](../AGENTS.md):
"Ein erfolgreiches Backup-File ist keine ausreichende Evidenz für ein
erfolgreiches Backup. Restore-Tests sind erforderlich" (sinngemäß, siehe
Abschnitt "Backups").

Evidence: Code-Lesung bestätigt Fehlen von Temp+`mv` und von
Integritätsprüfung (CONFIRMED als Code-Fakt). Ein tatsächlicher Abbruch
mitten im `pg_dump`-Stream wurde nicht gegen das echte Zielsystem
durchgespielt.

Impact:
- Ein fehlgeschlagener nächtlicher Cronjob kann eine defekte, aber gültig
  benannte `.sql.gz`-Datei hinterlassen, die bei einem späteren Restore-
  Versuch als "letztes Backup" erscheint, aber unbrauchbar ist.
- Widerspricht der expliziten Restore-Test-Anforderung aus AGENTS.md.

Proposed change:
- In temporäre Datei im selben Verzeichnis schreiben, nach Erfolg per `mv`
  atomar umbenennen.
- Nach dem Schreiben `gzip -t` gegen die fertige Datei prüfen, bei Fehlschlag
  Datei löschen und mit Exit-Code ≠ 0 abbrechen.

Regression risk: Gering – zusätzlicher Validierungsschritt, kein
Verhaltensunterschied im Erfolgsfall außer minimal längerer Laufzeit.

Test:
1. `pg_dump` durch ein Fake-Kommando ersetzen, das nach N Bytes mit Fehler
   abbricht, `backup.sh` laufen lassen, prüfen ob eine Datei unter dem
   finalen Namen zurückbleibt.
2. Nach Änderung denselben Testfall wiederholen und verifizieren, dass keine
   defekte Datei unter dem finalen Namen erscheint.

Classification: LIKELY (Code-Fakt bestätigt, Fehlerszenario nicht gegen das
reale System reproduziert).

---

## F-004 – `reset-coder.sh`: Volume-Filter nicht projektgebunden, Quoting bricht bei Mehrfachtreffern

Severity: MEDIUM

Location:
- [setup-coder.sh](../setup-coder.sh#L744-L753) – eingebettetes `reset-coder.sh`, Schritt 9

Problem:
```bash
for VOL_LABEL in postgres_data grafana_data prometheus_data; do
  VOL_NAME=$(docker volume ls -q --filter "label=com.docker.compose.volume=${VOL_LABEL}")
  if [ -n "${VOL_NAME}" ]; then
    docker volume rm "${VOL_NAME}"
  fi
done
```
Der Filter beschränkt sich auf `com.docker.compose.volume=<name>`, nicht
zusätzlich auf `com.docker.compose.project=coder`. Compose vergibt dieses
Label rein nach dem kurzen Volume-Schlüssel aus der jeweiligen
`docker-compose.yml`, unabhängig vom Projektnamen. Ein zweites
Compose-Projekt auf demselben Host mit einem gleichnamigen Volume (die drei
Namen sind generisch) würde ebenfalls gefunden.

Unabhängig davon: Liefert der Filter mehrere Zeilen, enthält `VOL_NAME`
mehrere durch Zeilenumbruch getrennte Namen. Wegen der Anführungszeichen wird
das als **ein** Argument mit eingebettetem Zeilenumbruch an
`docker volume rm` übergeben statt als mehrere Argumente – das schlägt fehl
(kein Volume mit diesem Namen), was unter `set -euo pipefail` das gesamte
`reset-coder.sh` mitten im destruktiven Reset abbricht (Stack bereits
gestoppt).

Evidence:
- Code-Lesung bestätigt das Fehlen der Projekt-Einschränkung (CONFIRMED als
  Code-Fakt).
- Quoting-Mechanismus lokal reproduziert (ohne echtes Docker, generisches
  Bash-Verhalten):
  ```
  $ bash -c '
  fakecmd() { echo "called with $# arg(s): [$1]"; }
  VOL_NAME=$(printf "vol_a\nvol_b\n")
  fakecmd "${VOL_NAME}"
  '
  called with 1 arg(s): [vol_a
  vol_b]
  ```
  Bestätigt: ein mehrzeiliges `VOL_NAME` wird als ein einzelnes Argument
  übergeben.
- Ob auf dem konkreten Produktionsserver aktuell ein zweites Compose-Projekt
  mit kollidierendem Volume-Namen existiert, ist unbekannt (ASSUMPTION,
  vermutlich Einzelserver nur für Coder → geringe reale
  Trefferwahrscheinlichkeit für den Mehrfachtreffer-Fall).

Impact:
- Geringe, aber reale Möglichkeit, bei künftiger Erweiterung des Servers um
  weitere Compose-Stacks fremde Volumes zu löschen.
- Bei Mehrfachtreffern bricht das Reset-Skript mit Fehler ab statt sauber
  aufzuräumen.

Proposed change:
Filter zusätzlich auf `label=com.docker.compose.project=coder` einschränken
und `VOL_NAME` zeilenweise verarbeiten (`while IFS= read -r vol; do … done`)
statt als einzelnen quotierten String.

Regression risk: Gering – schärfere Filterung/robustere Iteration ändert den
Normalfall (genau ein Treffer je Label) nicht.

Test:
1. Zwei Testvolumes mit gleichem `com.docker.compose.volume`-Label, aber
   unterschiedlichem `com.docker.compose.project`-Label anlegen.
2. `reset-coder.sh` isoliert gegen Test-Volumes laufen lassen und beobachten,
   welche Volumes entfernt werden bzw. ob das Skript abbricht.

Classification: LIKELY (Quoting-Mechanismus CONFIRMED reproduziert; fehlende
Projektbindung CONFIRMED per Code-Lesung; tatsächliche Kollision auf dem
Zielserver ASSUMPTION).

---

## F-005 – `reset-passwords.sh`: Passwortwechsel in Postgres und Persistierung in `.env` nicht transaktional

Severity: MEDIUM

Location:
- [setup-coder.sh](../setup-coder.sh#L635-L672) – eingebettetes `reset-passwords.sh`, Schritt 8

Problem:
Reihenfolge: (1) `ALTER USER coder WITH PASSWORD …` gegen die laufende
Postgres-Instanz, (2) Grafana-Admin-Passwort zurücksetzen, (3) erst danach
`.env` per `sed -i` aktualisieren, (4) `coder`-Container mit `--no-deps` neu
erstellen. Bricht der Prozess zwischen (1) und (3) ab (SSH-Abbruch, Ctrl-C,
Absturz), ist das reale Postgres-Passwort bereits geändert, `.env` enthält
aber weiterhin das alte. Ein späterer, unabhängiger `docker compose up -d`
(Reboot, `update.sh`) verbindet Coder dann mit dem falschen Passwort – ohne
dass das Skript dafür eine Erkennungs- oder Wiederherstellungslogik anbietet.

Evidence: Code-Lesung bestätigt die Reihenfolge-Abhängigkeit eindeutig
(CONFIRMED als Code-Fakt). Ein Abbruch genau in diesem Fenster wurde nicht am
echten System durchgespielt.

Impact:
- Inkonsistenter Zustand zwischen tatsächlichem DB-Passwort und `.env`-Inhalt
  ohne automatische Erkennung.
- Wiederherstellung erfordert manuelles Nachvollziehen des zuletzt gesetzten
  Passworts.

Proposed change:
`.env` möglichst unmittelbar vor dem `ALTER USER`-Aufruf aktualisieren, oder
einen klaren Hinweis/Trap ergänzen, der bei Abbruch zwischen (1) und (3)
explizit auf die Inkonsistenz hinweist.

Regression risk: Gering – Reihenfolgeänderung betrifft nur den Fehlerfall.

Test:
1. Kopie von `reset-passwords.sh` mit künstlicher Verzögerung (`sleep 5`) vor
   den `sed`-Aufrufen ausführen und in diesem Fenster per `SIGTERM`
   abbrechen.
2. Prüfen, ob `.env` noch das alte Passwort enthält, während Postgres bereits
   das neue akzeptiert.

Classification: LIKELY (Reihenfolge-Fakt CONFIRMED per Code-Lesung, Abbruch-
Szenario nicht praktisch reproduziert).

---

## F-006 – ShellCheck-Befunde und fehlender Zeilenumbruch am Dateiende

Severity: LOW

Location:
- [setup-coder.sh](../setup-coder.sh#L111) – SC1091 (Info)
- [setup-coder.sh](../setup-coder.sh#L543) – SC2034 (Warnung): `i` in
  `for i in $(seq 1 30); do … done` wird nie gelesen
- [setup-coder.sh](../setup-coder.sh#L548) – SC2012 (Info): `ls -t` statt
  `find`
- Dateiende von `setup-coder.sh`: letzte Zeile (`fi`) ohne abschließenden
  Zeilenumbruch

Problem: Stilistische/robustheitsbezogene Hinweise ohne aktuellen
funktionalen Fehler.

Evidence:
```
$ shellcheck -s bash setup-coder.sh
setup-coder.sh:111 SC1091 (info) ...
setup-coder.sh:543 SC2034 (warning): i appears unused ...
setup-coder.sh:548 SC2012 (info): Use find instead of ls ...
```
plus `tail -5 setup-coder.sh | cat -A`, zeigt kein Zeilenende-Zeichen nach
`fi` (kein abschließender Newline). Die vier extrahierten eingebetteten
Skripte (`backup.sh`, `update.sh`, `reset-passwords.sh`, `reset-coder.sh`)
wurden separat mit ShellCheck geprüft und sind **ohne** Beanstandungen.

Impact: Minimal. Kein aktueller Bug, reine Robustheits-/Stil-Hinweise.

Proposed change:
- `for i in $(seq 1 30)` zu `for _ in $(seq 1 30)` (Absicht klarer machen).
- Optional `ls -t` durch `find`-basierte Lösung ersetzen.
- Abschließenden Zeilenumbruch ergänzen.

Regression risk: Keins (rein kosmetisch).

Test: `shellcheck -s bash setup-coder.sh` erneut ausführen, sollte keine
Warnungen mehr liefern; `tail -c1 setup-coder.sh | xxd` zeigt `0a`.

Classification: CONFIRMED (Tool tatsächlich ausgeführt, Ausgabe wie oben
zitiert).

---

## F-007 – `reset-passwords.sh`: altes Postgres-Passwort aus `.env` wird ungeprüft in Heredoc an Container-Shell interpoliert

Severity: INFO

Location:
- [setup-coder.sh](../setup-coder.sh#L635-L653) – eingebettetes `reset-passwords.sh`

Problem:
```bash
OLD_PG_PW=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
...
docker exec -i coder-postgres sh <<INNER_EOF
export PGPASSWORD="${OLD_PG_PW}"
psql -U coder -d coder -c "ALTER USER coder WITH PASSWORD '${NEW_PG_PW}';"
INNER_EOF
```
Der Heredoc ist unquotiert, daher expandiert die Host-Shell `${OLD_PG_PW}`
und `${NEW_PG_PW}` bereits vor dem Versand an die Container-`sh`.
`NEW_PG_PW` stammt garantiert aus `openssl rand -hex …` (nur `0-9a-f`) und ist
unkritisch. `OLD_PG_PW` stammt aus dem Inhalt von `.env` – regulär ebenfalls
nur Hex, aber falls `.env` jemals manuell mit einem `"`/`'`-haltigen Passwort
editiert wurde, würde das die Anführungszeichen-Struktur der `export`- bzw.
`psql -c`-Zeile aufbrechen (Fehler in der Container-Shell, kein
Host-Angriff, da alles innerhalb des `docker exec`-Aufrufs verbleibt).

Evidence: Code-Lesung, Quotierungsmechanik nachvollzogen (CONFIRMED als
Code-Fakt für die Mechanik). Ob `.env` in der Praxis je manuell mit
Sonderzeichen editiert wird, ist ASSUMPTION.

Impact: Sehr gering im Normalbetrieb; reine Verteidigung-in-die-Tiefe-Lücke
für den hypothetischen Fall einer manuell editierten `.env`.

Proposed change: Werte über Umgebungsvariablen an die Container-Shell
übergeben (`docker exec -i -e OLD_PG_PW -e NEW_PG_PW coder-postgres sh -c '...'`
mit Expansion erst innerhalb einfach gequoteter `-c`-Zeichenkette), statt
String-Interpolation vor dem Versand.

Regression risk: Gering, betrifft nur Übergabemechanik.

Test: `.env` testweise (nur in Testumgebung) mit `POSTGRES_PASSWORD=abc'def`
befüllen und beobachten, ob `reset-passwords.sh` sauber fehlschlägt oder zu
unerwartetem Shell-/SQL-Verhalten führt.

Classification: LIKELY (Quotierungsmechanik CONFIRMED nachvollzogen, aber
nicht mit echtem `docker exec` gegen eine Postgres-Instanz reproduziert).

---

## F-008 – Wiederholte externe `ufw status`-Aufrufe statt einmaliger Auswertung

Severity: LOW

Location:
- [setup-coder.sh](../setup-coder.sh#L305-L336) – Schritt 4, Abschluss-Checks

Problem:
Im Anschluss an die Firewall-Konfiguration wird `sudo ufw status` bzw.
`sudo ufw status verbose` insgesamt sieben Mal separat aufgerufen (einmal zur
Anzeige, sechs weitere Male für einzelne `grep -q`-Prüfungen), obwohl eine
einmalige Ausgabe in eine Variable ausreichen würde. Jeder Aufruf startet
einen neuen `ufw`-Python-Prozess (spürbar langsamer als reine Textverarbeitung).

Evidence: Code-Lesung, Anzahl der Aufrufe im entsprechenden Codeabschnitt
ausgezählt (CONFIRMED als Code-Fakt für die Aufrufanzahl; die Aussage zur
Performance-Relevanz ist ASSUMPTION, da nicht gemessen).

Impact: Rein kosmetisch/geringfügig langsamer; kein funktionales Risiko,
da `ufw status` zwischen den Aufrufen keinen sich ändernden Zustand hat (das
Regelwerk wird in diesem Codeabschnitt nicht mehr verändert).

Proposed change: Ausgabe einmal in eine Variable schreiben
(`UFW_STATUS=$(sudo ufw status verbose)`) und alle nachfolgenden `grep`-
Prüfungen gegen diese Variable laufen lassen.

Regression risk: Keins, sofern die Variable vor der ersten Prüfung zuverlässig
befüllt wird.

Test: Anzahl der `ufw`-Prozessaufrufe vor/nach der Änderung zählen
(`grep -c 'ufw status' setup-coder.sh`).

Classification: CONFIRMED (Aufrufanzahl im Code nachgezählt).

---

## F-009 – Keine Formatvalidierung für `DOMAIN_CODER`/`ACME_EMAIL` vor Einbettung in generierte Konfigurationsdateien

Severity: INFO

Location:
- [setup-coder.sh](../setup-coder.sh#L70-L76) – Default-Variablen
- [setup-coder.sh](../setup-coder.sh#L163-L260) – Einbettung in
  `docker-compose.yml`/Caddyfile

Problem:
`DOMAIN_CODER`, `ACME_EMAIL` und die Versions-Variablen werden per
`: "${VAR:=default}"` gesetzt und ungeprüft in generierte
Konfigurationsdateien (docker-compose.yml, Caddyfile) eingebettet. Es gibt
keine Prüfung auf ein plausibles Domain-/E-Mail-Format. Da die Heredocs
unquotiert sind, wird der Variablenwert nur als literaler Text eingesetzt
(keine erneute Shell-Interpretation), ein Injection-Risiko über die
generierten Dateien besteht dadurch nicht unmittelbar – ein fehlerhafter Wert
würde aber erst spät auffallen: `docker compose config --quiet` in Schritt 3
prüft nur YAML-Syntax, keine inhaltliche Plausibilität von Domain/E-Mail;
ein tatsächlicher Fehler (z. B. ungültige Domain) würde frühestens beim
Caddy-Zertifikatsversuch bzw. beim Health-Check in Schritt 10 sichtbar.

Evidence: Code-Lesung (CONFIRMED als Code-Fakt für das Fehlen jeder
Formatprüfung).

Impact: Gering – betrifft nur den Aufrufenden selbst (bereits root/sudo),
kein Risiko durch nicht vertrauenswürdige Dritte. Führt im Fehlerfall zu
später und weniger eindeutiger Fehlermeldung statt eines frühen, klaren
Abbruchs direkt nach der Variablenzuweisung.

Proposed change: Optionale, einfache Sanity-Checks direkt nach den
Default-Zuweisungen ergänzen (z. B. grobes Regex-Muster für Domain/E-Mail),
die bei offensichtlich fehlerhaften Werten sofort mit klarer Meldung
abbrechen.

Regression risk: Gering, sofern die Prüfung großzügig genug ist, um gültige
reale Domains/E-Mails nicht fälschlich abzulehnen.

Test: Skript mit `DOMAIN_CODER=""` bzw. `ACME_EMAIL="ungueltig"` aufrufen und
beobachten, an welcher Stelle der Fehler zum ersten Mal sichtbar wird.

Classification: LIKELY (Fehlen der Prüfung CONFIRMED, das genaue spätere
Fehlerbild wurde nicht end-to-end gegen einen echten Server durchgespielt).

---

## Bereits korrekt gelöste Punkte (positiv hervorzuheben)

- **`set -euo pipefail` global sowie in allen vier eingebetteten Skripten** –
  konsistent gesetzt, keine Lücke gefunden.
- **`HTTP_CODE=$(curl …)` steht bewusst direkt in der `if`-Bedingung**
  ([setup-coder.sh](../setup-coder.sh#L800-L811)), mit explizitem, korrektem
  Kommentar, warum eine vorgelagerte separate Zuweisung unter `set -e` das
  Skript beim ersten DNS-/Netzwerkfehler sofort und ohne Meldung beendet
  hätte. Kommentar und Verhalten stimmen hier nachweislich überein.
- **Healthcheck-Wartepolling** (`for i in $(seq 1 30); do [ … ] && break; sleep 2; done`,
  [setup-coder.sh](../setup-coder.sh#L543-L545)) – geprüft und in einer
  Test-Shell reproduziert: Dieses Muster ist unter `set -e` sicher, da ein
  fehlschlagender, nicht-letzter Teil einer `&&`-Liste von `set -e`
  ausgenommen ist. Kein Befund.
- **`docker compose config --quiet` vor `docker compose up -d`**
  ([setup-coder.sh](../setup-coder.sh#L263-L268)) – validiert Syntax/Variablen-
  Interpolation frühzeitig, mit korrektem erklärendem Kommentar; reduziert das
  Risiko kryptischer Fehler mitten in `up -d`.
- **Idempotente Firewall-Regel-Bereinigung** vor Neuanlage
  ([setup-coder.sh](../setup-coder.sh#L272-L276)) mit `|| true` sauber gegen
  Fehlschlag auf vorherigen Läufen abgesichert.
- **Reihenfolge der ufw-Regeln**: `ufw limit 22/tcp` wird gesetzt, bevor
  `ufw --force enable` aufgerufen wird – verhindert ein versehentliches
  Aussperren der SSH-Sitzung während der Firewall-Aktivierung.
- **Passwortübergabe an `psql`/`grafana-cli` per STDIN-Heredoc statt als
  `docker exec -e`-Argument** ([setup-coder.sh](../setup-coder.sh#L644-L657)) –
  vermeidet, dass Klartext-Passwörter über `ps aux` auf dem Host sichtbar
  werden; Kommentar beschreibt das korrekt.
- **`reset-coder.sh` verlangt explizite interaktive Bestätigung** (`RESET`
  eintippen) vor jeder destruktiven Aktion, bricht bei fehlgeschlagenem
  Sicherheits-Backup ohne `--force` sauber ab, und lässt Zertifikate/Backups
  bewusst unangetastet – Kommentar und Verhalten stimmen überein.
- **`declare -a SUMMARY=()` und `"${SUMMARY[@]}"`** – Array wird korrekt
  deklariert, angehängt und beim Ausgeben vollständig gequotet iteriert; keine
  Word-Splitting-Probleme bei Einträgen mit Leerzeichen.
- **`find … -mtime +14 -delete`** in `backup.sh` – Glob-Muster korrekt in
  Anführungszeichen an `-name` übergeben, keine vorzeitige Shell-Expansion.
- **`/etc/cron.d/coder-backup` statt Wurzel-Crontab-Fummelei** – eigene,
  nachvollziehbare Datei statt fragilem Parsen/Überschreiben der gesamten
  Root-Crontab; Kommentar begründet das nachvollziehbar korrekt.
- **`backend=systemd` für fail2ban explizit gesetzt** statt `auto` – Kommentar
  verweist korrekt auf bekanntes, dokumentiertes Verhalten auf
  systemd-Distributionen.
- **Kein `eval`, kein `curl | bash`/`curl | sh`, kein `rm -rf` mit
  Variablen-Interpolation, kein `chmod 777`** an keiner Stelle im gesamten
  Skript gefunden.
- **Debian-13("trixie")-Kompatibilität des Docker-Repos**: Stichprobe gegen
  `https://download.docker.com/linux/debian/dists/` zeigt aktuell einen
  vorhandenen `trixie`-Zweig – zum Zeitpunkt dieser Analyse kein Problem
  (aber ein extern veränderlicher Zustand, kein reiner Code-Fakt; sollte bei
  künftigen Debian-Wechseln erneut geprüft werden).

---

## Nicht bestätigte Punkte / bewusst nicht als Befund aufgenommen

- **`set -Eeuo pipefail` vs. tatsächlich verwendetes `set -euo pipefail`**:
  Das `-E`-Flag fehlt in allen fünf Skripten. Da nirgends ein `trap … ERR`
  gesetzt ist, hat das aktuell keine beobachtbare Auswirkung. Kein Befund,
  nur ein Hinweis für den Fall, dass künftig ein `ERR`-Trap ergänzt wird.
- **Geheimnisse werden einmalig im Klartext auf dem Terminal ausgegeben**
  (`echo "Postgres-Passwort: …"`, Schritt 2 und in `reset-passwords.sh`) –
  dies ist ein bewusster, dokumentierter Kompromiss (Admin muss neu erzeugte
  Passwörter mindestens einmal sehen können) und kein Implementierungsfehler;
  kein eigener Befund, da keine sinnvolle Alternative ohne separaten
  Secrets-Store ersichtlich ist.

Kein weiterer belastbarer Befund zu Word-Splitting, Globbing, Arrays,
allgemeinem Quoting oder Signalbehandlung außerhalb der oben genannten
Stellen gefunden. Die übrige Variablennutzung ist durchgehend korrekt
quotiert (`"${VAR}"`), Kommandosubstitutionen stehen dort, wo sie unter
`set -e` kritisch wären, korrekt in `if`/`while`-Bedingungen oder sind
explizit mit `|| true` abgesichert.

---

## Summary

- CRITICAL: 1
- HIGH: 2
- MEDIUM: 2
- LOW: 2
- INFO: 2

(Gesamt: 9 Befunde)

---

## Top 10 Priorities

1. **F-001** – Crontab-Migrationspipeline bricht unter `set -e`+`pipefail` bei
   genau einem Treffer lautlos ab (CRITICAL, reproduziert).
2. **F-002** – `.env`-Geheimnisdatei nicht atomar geschrieben, Idempotenz-
   Check prüft nur Existenz (HIGH).
3. **F-003** – Backups nicht atomar geschrieben, keine Integritätsprüfung,
   Widerspruch zur AGENTS.md-Backup-Policy (HIGH).
4. **F-004** – `reset-coder.sh`-Volume-Löschung nicht projektgebunden,
   Quoting bricht bei Mehrfachtreffern (MEDIUM).
5. **F-005** – `reset-passwords.sh`: DB-Passwortwechsel und `.env`-
   Persistierung nicht transaktional (MEDIUM).
6. **F-006** – ShellCheck-Warnungen (`SC2034`, `SC2012`) und fehlender
   abschließender Zeilenumbruch (LOW).
7. **F-008** – Sieben separate `ufw status`-Aufrufe statt einmaliger
   Auswertung (LOW).
8. **F-007** – Ungeprüfte Interpolation des alten Postgres-Passworts aus
   `.env` in Heredoc an Container-Shell (INFO, defense-in-depth).
9. **F-009** – Keine Formatvalidierung für `DOMAIN_CODER`/`ACME_EMAIL` vor
   Einbettung in generierte Konfigurationsdateien (INFO).
10. **Beobachtung ohne Einzelbefund**: Fehlendes `-E`-Flag in
    `set -euo pipefail` – aktuell folgenlos, aber relevant, sobald künftig ein
    `ERR`-Trap ergänzt wird (siehe Abschnitt "Nicht bestätigte Punkte").
